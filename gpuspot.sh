#!/bin/bash
# Description: Script to manage AWS EC2 spot instances (GPU)
# Author: yaha.sun#gmail.com
# Usage: 
# gpuspot.sh init     # Initialize resources, will create a new EBS/Disk volume or format the exsiting one
# gpuspot.sh start    # Start a spot instance, will reuse created EBS/Disk volume
# gpuspot.sh stop     # Stop a running spot instance, keep EBS/Disk volume
# gpuspot.sh delete   # Delete all resources, like EBS/Disk volume, key pair, VPC, etc 
# gpuspot.sh openport gpuspot 7860 # Open port 7860 to the world
# gpuspot.sh check gpuspot  # Check the instance status (type, launch time, IP, logon command, etc)


# Update parameters as per your need. You can either do `aws configure` in advance, or update below AWS Keys in the script.
#export AWS_ACCESS_KEY_ID=***    # Add AWS access key ID 
#export AWS_SECRET_ACCESS_KEY=*** # Add AWS secret access key
export AWS_DEFAULT_REGION=us-east-1              # Set default AWS region
IMG_NAME="PyTorch 2.0.0 (Ubuntu 20.04) 20230401" # AMI image name
INSTANCE_TYPE="g4dn.xlarge"                     # EC2 instance type，suggested：'g4dn.xlarge,g4dn.2xlarge,g5.xlarge,g5.2xlarge', refer  https://aws.amazon.com/ec2/instance-types/#Accelerated_Computing
DATA_DISK_SIZE_GB=100                           # EBS volume size in GB
MAX_HOURLY_COST=1                               # Set maximum hourly cost for spot instance


#######
#######
# Check if first argument is valid
if [[ "$1" != "init" && "$1" != "start" && "$1" != "stop" && "$1" != "delete" && "$1" != "openport"  && "$1" != "check" ]]; then
    echo "First argument must be either 'init', 'start', 'stop' or 'delete'"
    exit 1
fi
ACTION=$1                                      # Set action variable
DEPL_NAME=${2:-gpuspot}                        # Set aws resource name, default is gpuspot, or pass in at the 2nd parameter.
AZ=${AWS_DEFAULT_REGION}a                      # Set availability zone, default is the 1st az in the region.
# Generate resource names
KEY_NAME=key-${DEPL_NAME}
KEY_FULL_PATH=./${KEY_NAME}.pem
VPC_NAME="vpc-${DEPL_NAME}"
SG_NAME="secgrp-${DEPL_NAME}"
SUBNET_NAME="suba-${VPC_NAME}"
IGW_NAME="igw-${VPC_NAME}"
INSTANCE_NAME="ins-${DEPL_NAME}"


echo "Now begin to $ACTION the spot instance $INSTANCE_NAME"

if [[ "$ACTION" == "init" || "$ACTION" == "start" || "$ACTION" == "delete" ]]; then
    # Create key pair if it does not exist
    if [ -f $KEY_FULL_PATH ]; then
        echo "Key pair $KEY_FULL_PATH already exists" 
    else
        echo "Creating key pair $KEY_NAME"
        aws ec2 delete-key-pair --key-name $KEY_NAME && rm -rf $KEY_FULL_PATH
        aws ec2 create-key-pair --key-name $KEY_NAME --key-type ed25519 --key-format pem --query 'KeyMaterial' --output text | sed 's/\\n/\n/g' > $KEY_FULL_PATH
    fi

    # Prepare VPC
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query "Vpcs[0].VpcId" --output text)
    if [ "$VPC_ID" == "None" ]; then
        echo "Creating VPC ${VPC_NAME}..."
        VPC_ID=$(aws ec2 create-vpc --cidr-block 172.11.0.0/16 --query "Vpc.VpcId" --output text)
        aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
        echo "VPC ${VPC_NAME} created with ID ${VPC_ID}"
    else 
        echo "VPC ${VPC_NAME} already exists with ID ${VPC_ID}"
    fi

    # Prepare subnet
    SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=availabilityZone,Values=$AZ" --query 'Subnets[0].SubnetId' --output text)
    if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" == "None" ]; then
        echo "Creating subnet ${SUBNET_NAME}..."
        SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.11.1.0/24 --availability-zone ${AZ} --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value='$SUBNET_NAME'}]' --query 'Subnet.SubnetId' --output text)
        aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch
        echo "Subnet ${SUBNET_NAME} created with ID ${SUBNET_ID}"
    else 
        echo "Subnet ${SUBNET_NAME} already exists with ID ${SUBNET_ID}"
    fi


    # Create and associate route table
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID Name=association.main,Values=true --query 'RouteTables[0].Associations[0].RouteTableId' --output text)

    if [ -z "$ROUTE_TABLE_ID" ] || [ "$ROUTE_TABLE_ID" == "None" ]; then
        echo "Creating route table..."
        ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value='$SUBNET_NAME-rt'}]' --query "RouteTable[0].RouteTableId" --output text)
        aws ec2 associate-route-table --route-table-id $ROUTE_TABLE_ID --subnet-id $SUBNET_ID
        echo "Route table created with ID ${ROUTE_TABLE_ID} and associated with subnet ${SUBNET_NAME}" 
    else
        echo "Route table already associated with subnet ${SUBNET_NAME} with ID ${ROUTE_TABLE_ID}"
    fi

    # Create and attach internet gateway
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text)
    if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
        echo "Creating internet gateway..."
        IGW_ID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output text)
        aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=${IGW_NAME}
        aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
        echo "Internet gateway created with ID ${IGW_ID} and attached to VPC ${VPC_NAME}" 
    else
        echo "Internet gateway already attached to VPC ${VPC_NAME} with ID ${IGW_ID}"
    fi
    
    # Add route to internet gateway in route table
    # Check if the IGW is already associated with the Route Table
    assoflag=$(aws ec2 describe-route-tables --filters "Name=route.gateway-id,Values=$IGW_ID" "Name=route.state,Values=active" "Name=route.destination-cidr-block,Values=0.0.0.0/0" "Name=association.route-table-id,Values=$ROUTE_TABLE_ID" | grep -q 'RouteTables')

    if [ ! -z $assoflag ]; then
    # The IGW is already associated with the Route Table
    echo "The Internet Gateway $IGW_ID is already associated with the Route Table $ROUTE_TABLE_ID."
    else
    # The IGW is not associated with the Route Table, so create a new route
    aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
    echo "Added route to internet gateway ${IGW_ID} in route table ${ROUTE_TABLE_ID}."
    fi


    # Create security group 
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query "SecurityGroups[0].GroupId" --output text)
    if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
        echo "Creating security group ${SG_NAME}..."
        SG_ID=$(aws ec2 create-security-group --group-name "${SG_NAME}" --description "Automatically createdby script" --vpc-id "${VPC_ID}" --query "GroupId" --output text)
        aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol all --cidr 0.0.0.0/0
        echo "Security group ${SG_NAME} created with ID ${SG_ID}" 
    else
        echo "Security group ${SG_NAME} already exists with ID ${SG_ID}"
    fi

    # Create EBS volume
    VOLUME_ID=$(aws ec2 describe-volumes --filters Name=tag:Name,Values=disk-$DEPL_NAME --query 'Volumes[0].{ID:VolumeId}' --output text)
    if [ -z "$VOLUME_ID" ] || [ "$VOLUME_ID" == "None" ]; then
        VOLUME_ID=$(aws ec2 create-volume --availability-zone ${AZ} --size ${DATA_DISK_SIZE_GB} --volume-type gp3 --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=disk-$DEPL_NAME}]" --query 'VolumeId' --output text) 
    else
        echo "EBS Volume disk-$DEPL_NAME already exists with ID ${VOLUME_ID}"
    fi
fi


# Launch spot instance
if [[ "$ACTION" == "init" || "$ACTION" == "start" ]]; then
    # Get AMI image ID
    IMGID=$(aws ec2 describe-images --filters "Name=name,Values=*$IMG_NAME*" --owners amazon --query 'Images[*].[ImageId]' --output text|head -1)
    echo "Launch spot instance with spot instance request for $INSTANCE_TYPE"
    # Request spot instance
    SIRID=$(aws ec2 request-spot-instances --instance-count 1 \
--type one-time \
--spot-price $MAX_HOURLY_COST \
--launch-specification \
InstanceType="$INSTANCE_TYPE",\
ImageId=$IMGID,\
KeyName=$KEY_NAME,\
SecurityGroups=$SG_NAME,\
SubnetId=$SUBNET_ID \
| grep -o 'SpotInstanceRequestId": "[^"]*' | cut -d'"' -f3)

    sleep 5
    INSTANCE_ID=$(aws ec2 describe-spot-instance-requests --spot-instance-request-ids $SIRID --query 'SpotInstanceRequests[*].InstanceId' --output text)

    # Wait for instance to start
    echo "Waiting for instance $INSTANCE_ID be ready"
    aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID --cli-connect-timeout 180

    for i in {1..36}; do
        INSTANCE_STATUS=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].State.Name' --output text)
        if [ "$INSTANCE_STATUS" = "running" ]; then
            aws ec2 create-tags --resources $INSTANCE_ID --tags Key=Name,Value=${INSTANCE_NAME}
            aws ec2 attach-volume --volume-id $VOLUME_ID --instance-id $INSTANCE_ID --device '//dev\sdf'
            INSTANCE_STARTTIME=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].LaunchTime')
            echo "Instance $INSTANCE_ID is running, start at UTC time $INSTANCE_STARTTIME"
            break
        else
            echo "Instance status: $INSTANCE_STATUS"
            sleep 5
        fi
        if [ $i -eq 36 ]; then
            echo "Timeout waiting for instance to start"
            exit 1
        fi
    done

    # Get public IP of instance
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)

    # Create script to mount EBS volume
    cat << EOF > mount.volume.sh
    blkname=\$(lsblk | tail -1 | awk '{print \$1}'| tr -d '[:space:]')
    sudo mkfs -t ext4 /dev/\$blkname
    sudo mkdir -p /data/conda
    sudo mount /dev/\$blkname /data
    sudo chown -R ubuntu: /data
    conda config --append pkgs_dirs /data/conda
EOF

    # Remove mkfs command if not initializing 
    if [ "$ACTION" == "start" ]; then
        sed -i '/mkfs/d' mount.volume.sh
    fi

    # Copy script to instance and run
    scp -o "StrictHostKeyChecking=no" -i $KEY_FULL_PATH mount.volume.sh ubuntu@${PUBLIC_IP}:/tmp/
    ssh -o "StrictHostKeyChecking=no" -i $KEY_FULL_PATH ubuntu@${PUBLIC_IP} 'bash /tmp/mount.volume.sh'

    # Output login command
    echo -e "Please logon with command\n    ssh -o 'StrictHostKeyChecking=no' -i $KEY_FULL_PATH ubuntu@${PUBLIC_IP}"
fi

# Stop spot instance
if [[ "$ACTION" == "shutdown" || "$ACTION" == "stop" ]]; then  
    #aws ec2 cancel-spot-instance-requests --spot-instance-request-ids $SIRID
    INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" --query 'Reservations[].Instances[].InstanceId' --output text)
    if [ -z $INSTANCE_ID ]; then 
        echo "instance $INSTANCE_ID doesn't exist"
    else
        aws ec2 terminate-instances --instance-ids $INSTANCE_ID
    fi
fi

# Delete resources
if [ "$ACTION" == "delete" ]; then
    echo "will delete AWS resources: EBS/Disk volume, key pair, VPC, security group, etc"
    echo "Terminate EC2"
    for INSTANCE_ID in $(aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" --query "Reservations[*].Instances[*].InstanceId" --output text); do
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID
    done
    aws ec2 delete-key-pair --key-name $KEY_NAME && rm -rf $KEY_FULL_PATH && echo "Key pair $KEY_NAME deleted"
    #aws ec2 delete-subnet --subnet-id $SUBNET_ID && echo "Subnet $SUBNET_ID deleted"
    #aws ec2 delete-route-table --route-table-id $ROUTE_TABLE_ID && echo "Route table $ROUTE_TABLE_ID deleted"
    aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID && echo "Internet gateway $IGW_ID detached from VPC $VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID && echo "Internet gateway $IGW_ID deleted"
    aws ec2 delete-security-group --group-id $SG_ID && echo "Security group $SG_ID deleted"
    aws ec2 delete-vpc --vpc-id $VPC_ID && echo "VPC $VPC_ID deleted"
    aws ec2 delete-volume --volume-id $VOLUME_ID && echo "Volume $VOLUME_ID deleted"
fi

# Open Port
if [ "$ACTION" == "openport" ]; then
    ALLOWPORT="$3"
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query "SecurityGroups[0].GroupId" --output text)
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $ALLOWPORT --cidr 0.0.0.0/0
    echo "Open port $ALLOWPORT on security group $SG_NAME to the world."
fi

# Check EC2 instance
if [ "$ACTION" == "check" ]; then
    echo "Instance name is $INSTANCE_NAME"
    
    INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" --query 'Reservations[].Instances[].InstanceId' --output text)

    if [ -z "INSTANCE_ID" ]; then
        echo "no such instance $INSTANCE_NAME"
    else
        INSTANCE_STATUS=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].State.Name' --output text)
        if [ "$INSTANCE_STATUS" != "running" ]; then echo "instance $INSTANCE_NAME is not running"; exit 1; fi
        INSTANCE_TYPE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[].Instances[].InstanceType' --output text)

        echo "Instance type is $INSTANCE_TYPE"

        # Get the launch time of the instance
        launch_time=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[].Instances[].LaunchTime' --output text)

        # Convert the launch time to seconds since epoch
        launch_time_seconds=$(date -d "$launch_time" +%s)

        # check local timezone, convert current time UTC time, then Get the UTC time in seconds since epoch, 
        now_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        now_utc_seconds=$(date -d "$now_utc" +%s)

        # Calculate the duration until now in seconds
        duration_seconds=$((now_utc_seconds - launch_time_seconds))

        # Convert the duration to days, hours, minutes, and seconds
        days=$((duration_seconds / 86400))
        hours=$(( (duration_seconds % 86400) / 3600 ))
        minutes=$(( (duration_seconds % 3600) / 60 ))
        seconds=$((duration_seconds % 60))

        # Print the duration until now
        echo "Instance $DEPL_NAME has been running: $days days, $hours:$minutes:$seconds"

        PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)
        echo -e "SSH Logon command\n    ssh -i $KEY_FULL_PATH ubuntu@${PUBLIC_IP}"
    fi
fi