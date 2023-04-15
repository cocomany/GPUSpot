# GPUSpot
GPUSpot提供脚本一条命令实现GPU Spot Instance的管理，代替控制台界面上繁琐的操作。控制台上的操作可参考[这里](https://mp.weixin.qq.com/s?src=11&timestamp=1681523769&ver=4469&signature=mNQm044CVe1MS*rDkMxiYdZnu8mA130O4kkD0ZkZvqWWH95lsTPteJ5fd564nDCLGPmfWwaUeW6DUITr5dzjxKSeCcjFNJCygwDedQfyvx0HaJ4XFeRNI2uTjCnm3MYG&new=1)。

# 背景
对于不需要长时间使用GPU的情况，使用公有云竞价实例，挂载额外的可持久化的数据盘，可以节省开支。

使用AWS GPU 竞价实例和EBS Volume（云硬盘）能最大程度的同时保证**资源不用等，联网速度快，花费不太高**。

选择AWS主要有以下原因：
- AWS上GPU Instance数量多，大多数时候想开就有。
- AWS上选美国东部区域，下载很多库，模型文件速度会很快，实测达到100MB/s。
- AWS上免费带宽1Gbps以上，流入数据不收费，而国内厂带宽或流量都要收费，还很贵。
- 综合花费大概一小时2-3元 (4 vCPU, 16GB Mem, 16GB GPU)，比腾讯云便宜.

# 前提条件

- 注册AWS账号: https://aws.amazon.com/
- 在个人Billing Dashboard里绑定支付方式，一般用外币信用卡 （要求注册人信息和信用卡信息一致）
- 默认不能启动GPU spot instance，需要在Support Center提交一个Service Limit Increase的Case。现在审核较严格，不要申请多了，多跟进和回复一下Case，一般要1-2天通过。
- 本地安装AWS CLI，[link](https://docs.aws.amazon.com/zh_cn/cli/latest/userguide/getting-started-install.html)
- 本地有类Linux Shell环境， 比如Windows WSL或者Windows上安装Git Bash, [link](https://git-scm.com/)
- 新建AWS Access Key， 登陆AWS console后，点右上角个人Profile - Security credentials - Create access Key

# 使用方法
下地gpuspot.sh到本地，更新AWS_ACCESS_KEY_ID和AWS_SECRET_ACCESS_KEY。 去掉前面的#。 其它变量视自己需求更新。
```
# Update parameters as per your need. You can either do `aws configure` in advance, or update below AWS Keys in the script.
#export AWS_ACCESS_KEY_ID=***    # Add AWS access key ID 
#export AWS_SECRET_ACCESS_KEY=*** # Add AWS secret access key
export AWS_DEFAULT_REGION=us-east-1              # Set default AWS region
IMG_NAME="PyTorch 2.0.0 (Ubuntu 20.04) 20230401" # AMI image name
INSTANCE_TYPE="g4dn.xlarge"                     # EC2 instance type，suggested：'g4dn.xlarge,g4dn.2xlarge,g5.xlarge,g5.2xlarge', refer  https://aws.amazon.com/ec2/instance-types/#Accelerated_Computing
DATA_DISK_SIZE_GB=100                           # EBS volume size in GB
MAX_HOURLY_COST=1                               # Set maximum hourly cost for spot instance
```

在命令行中运行以下命令，创建GPU spot instance，初始化一个ELB Volume（云硬盘），并挂载到实例上（默认100GB 在 /data 下)。本地会生成用于SSH访问实例的pem key文件。 注意：Windows下的cmd, powershell不支持shell脚本。
```
 sh gpuspot.sh init 
```

第二个参数自定义实例名(可选,默认是gpuspot)，如果要创建另一个实例，在后面加上自定义实例名。
```
sh gpuspot.sh init mygpuinstance
```

停止实例，保留云硬盘
```
sh gpuspot.sh stop
```

启动实例，挂载已有的云硬盘
```
$ sh gpuspot.sh check 
...
Now begin to check the spot instance ins-gpuspot
Instance name is ins-gpuspot
Instance type is g4dn.xlarge
Instance gpuspot has been running: 0 days, 0:10:35
SSH Logon command
    ssh -i ./key-gpuspot.pem ubuntu@44.201.60.47
```

删除所有Cloud资源，包括虚拟网络，安全组，云硬盘等
```
sh gpuspot.sh delete
```


放开公网端口，比如要开放gpuspot instance的7860端口
```
gpuspot.sh openport gpuspot 7860 # Open port 7860 to the world
```


# 登陆实例
获取实例信息，比如IP，Private Key等， 然后命令行用 `ssh -i`方式登陆。如果要使用[SecureCRT](https://blog.csdn.net/wmj2004/article/details/53215969)或[PuTTY](https://blog.csdn.net/weixin_41506373/article/details/108710523)登陆，需要做密钥转换，参考对应链接。
```
$ sh gpuspot.sh check 
Now begin to check the spot instance ins-gpuspot
Instance name is ins-gpuspot
Instance type is g4dn.xlarge
Instance gpuspot has been running: 0 days, 0:10:35
SSH Logon command
    ssh -i ./key-gpuspot.pem ubuntu@44.201.60.47
```

登陆后，默认镜像已安装好cuda, conda. 
```
ubuntu@ip-172-11-1-125:~$ nvidia-smi
Sat Apr 15 08:27:29 2023       
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 525.85.12    Driver Version: 525.85.12    CUDA Version: 12.0     |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf  Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
|                               |                      |               MIG M. |
|===============================+======================+======================|
|   0  Tesla T4            Off  | 00000000:00:1E.0 Off |                    0 |
| N/A   38C    P0    26W /  70W |      0MiB / 15360MiB |      0%      Default |
|                               |                      |                  N/A |
+-------------------------------+----------------------+----------------------+

+-----------------------------------------------------------------------------+
| Processes:                                                                  |
|  GPU   GI   CI        PID   Type   Process name                  GPU Memory |
|        ID   ID                                                   Usage      |
|=============================================================================|
|  No running processes found                                                 |
+-----------------------------------------------------------------------------+
WARNING: infoROM is corrupted at gpu 0000:00:1E.0
ubuntu@ip-172-11-1-125:~$ nvcc -V
nvcc: NVIDIA (R) Cuda compiler driver
Copyright (c) 2005-2022 NVIDIA Corporation
Built on Wed_Sep_21_10:33:58_PDT_2022
Cuda compilation tools, release 11.8, V11.8.89
Build cuda_11.8.r11.8/compiler.31833905_0
ubuntu@ip-172-11-1-125:~$ conda -V
conda 22.11.1
```

可创建新的virtual env，指定在数据盘 `/data` 。所要需要停机保留的数据都放在 `/data`目录下。
```
conda create -y --prefix /data/py310 python=3.10
conda create -n py310 python=3.10
```


# RoadMap
- [ ] 支持Windows cmd运行
- [ ] 支持阿里云，腾讯云，Azure等
