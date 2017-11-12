
#!/bin/bash
echo $(date) " - Starting Script"
## first set proxy 

HTTP_PROXY=$1
HTTP_PROXY_PORT=$2
HTTP_PROXY_USER=$3
HTTP_PROXY_PASS=$4

### configure the yum proxy settings
echo 'proxy=http://$HTTP_PROXY_USER:$HTTP_PROXY_PASS@$HTTP_PROXY:$HTTP_PROXY_PORT' >> /etc/yum.conf
echo 'http_caching=packages' >> /etc/yum.conf
### configure the profile proxy setting. this is done as the /etc/environment requires a restart to take effect
echo 'export NO_PROXY=127.0.0.1,localhost' >> /etc/profile.d/proxy.sh
echo 'export HTTP_PROXY=http://$HTTP_PROXY_USER:$HTTP_PROXY_PASS@$HTTP_PROXY:$HTTP_PROXY_PORT' >> /etc/profile.d/proxy.sh
echo 'export HTTPS_PROXY=http://$HTTP_PROXY_USER:$HTTP_PROXY_PASS@$HTTP_PROXY:$HTTP_PROXY_PORT' >> /etc/profile.d/proxy.sh
## add to system wide settings 
echo 'export HTTP_PROXY=http://$HTTP_PROXY_USER:$HTTP_PROXY_PASS@$HTTP_PROXY:$HTTP_PROXY_PORT' >> /etc/environment
echo 'export HTTPS_PROXY=http://$HTTP_PROXY_USER:$HTTP_PROXY_PASS@$HTTP_PROXY:$HTTP_PROXY_PORT' >> /etc/environment

##  reload profile 
source /etc/profile.d/proxy.sh


# Update system to latest packages and install dependencies
echo $(date) " - Update system to latest packages and install dependencies"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
yum -y update --exclude=WALinuxAgent

# Install EPEL repository
echo $(date) " - Installing EPEL"

yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

sed -i -e "s/^enabled=1/enabled=0/" /etc/yum.repos.d/epel.repo

# Install Docker 1.12.x
echo $(date) " - Installing Docker 1.12.x"

yum -y install docker
sed -i -e "s#^OPTIONS='--selinux-enabled'#OPTIONS='--selinux-enabled --insecure-registry 172.30.0.0/16'#" /etc/sysconfig/docker

# Create thin pool logical volume for Docker
echo $(date) " - Creating thin pool logical volume for Docker and staring service"

DOCKERVG=$( parted -m /dev/sda print all 2>/dev/null | grep unknown | grep /dev/sd | cut -d':' -f1 | awk 'NR==1')

echo "DEVS=${DOCKERVG}" >> /etc/sysconfig/docker-storage-setup
echo "VG=docker-vg" >> /etc/sysconfig/docker-storage-setup
docker-storage-setup
if [ $? -eq 0 ]
then
   echo "Docker thin pool logical volume created successfully"
else
   echo "Error creating logical volume for Docker"
   exit 5
fi

# Enable and start Docker services

systemctl enable docker
systemctl start docker

echo $(date) " - Script Complete"

