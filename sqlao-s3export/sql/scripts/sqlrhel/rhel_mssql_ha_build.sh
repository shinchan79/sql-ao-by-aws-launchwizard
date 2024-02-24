#!/bin/bash
###############################################################################
# Script Name	:   rhel_mssql_ha_build   
# Description	:   This script builds a Microsoft SQL Server 2019 on Linux (MSSQL) 
#                   Always on Availability Group (AG)
#               :   on Red Hat Enterprise Linux (RHEL) v x.x 
# Author		:   Alexander (Sandy) Millar 
# Created		:   dd-month-2021
# Version		:   0.1
###############################################################################
#
# This script must be executed on each mssql clusternode, at the same time.  the script may
# pause and wait for the other cluster nodes
#
# Linux Distribution - RHEL (version 7.9 and 8.4)
#
# PARAMETERS  (updates required)
# cmdline ./ TBD
# 
###############################################################################
#
echo "##############################################################################"
echo '--- mssql/rhel/ha build starting'
echo "##############################################################################"
#
echo "built on " $(date)
#
echo '--- basic command line arguments check'
#
if [ -z $1 ]; then
    echo '######## NO ARGS ########'
    exit 0
else
    echo '######## ARGS OK ########'
fi
echo "##############################################################################"
echo '--- build preparation'
echo "##############################################################################"
#
echo '--- setting command line arguments into parameters'
#
NODE_ROLE=$1                    #  From CloudFormation
# echo $NODE_ROLE
NODE_NAME=$2                    #  From CloudFormation
# echo $NODE_NAME
BUCKET_NAME=$3                  # From CloudFormation
#echo $BUCKET_NAME
MSSQL_LISTENER_NAME=$4          # From CloudFormation
# echo $MSSQL_LISTENER_NAME
MSSQL_LISTENER_IP=$5            # From CloudFormation
# echo $MSSQL_LISTENER_IP
TEMPDB_DISK_SIZE_GB=$6          # From Cloud Formation
# echo $TEMPDB_DISK_SIZE_GB
TEMPDB_VOLUME_TYPE=$7          # From Cloud Formation
# echo $TEMPDB_VOLUME_TYPE
TEMPDB_VOLUME_IOPS=$8          # From Cloud Formation
# echo $TEMPDB_VOLUME_IOPS
DATA_DISK_SIZE_GB=$9            # From Cloud Formation
# echo $DATA_DISK_SIZE_GB
DATA_VOLUME_TYPE=${10}          # From Cloud Formation
# echo $DATA_VOLUME_TYPE
DATA_VOLUME_IOPS=${11}          # From Cloud Formation
# echo $DATA_VOLUME_IOPS
LOG_DISK_SIZE_GB=${12}            # From Cloud Formation
# echo $LOG_DISK_SIZE_GB
LOG_VOLUME_TYPE=${13}          # From Cloud Formation
# echo $LOG_VOLUME_TYPE
LOG_VOLUME_IOPS=${14}          # From Cloud Formation
# echo $LOG_VOLUME_IOPS
BACKUP_DISK_SIZE_GB=${15}          # From Cloud Formation
# echo $BACKUP_DISK_SIZE_GB
BACKUP_VOLUME_TYPE=${16}          # From Cloud Formation
# echo $DATA_VOLUME_TYPE
BACKUP_VOLUME_IOPS=${17}          # From Cloud Formation
# echo $DATA_VOLUME_IOPS
MSSQL_PACEMAKER_LOGIN=${18}      # From Cloud Formation
# echo $MSSQL_PACEMAKER_LOGIN
PMC_CLUSTER_NAME=${19}           # From Cloud Formation
# echo $PMC_CLUSTER_NAME
MSSQL_TEMP_DATABASE=${20}         # From Cloud Formation
# echo $MSSQL_TEMP_DATABASE
VPC_ROUTING_TABLE_ID=${21}          # From Cloud Formation
# echo $VPC_ROUTING_TABLE_ID
MSSQL_AG_NAME=${22}             #  From Cloud Formation
# echo $MSSQL_AG_NAME
MSSQL_AG_ENDPOINT=${23}         #  From Cloud Formation
# echo $MSSQL_AG_NAME
SQLSAPASSWORD=${24}         #  From Cloud Formation
# echo $SQLSAPASSWORD
SQLPACEMAKERPASSWORD=${25}         #  From Cloud Formation
# echo $SQLPACEMAKERPASSWORD
PACEMAKERCLUSTERPASSWORD=${26}         #  From Cloud Formation
# echo $PACEMAKERCLUSTERPASSWORD
LW_RESOURCE_GROUP_ID=${27}
# echo $LW_RESOURCE_GROUP_ID
SQLAMIID=${28}
#echo SQLAMIID
#
echo "--- reset inter-host sync lags" ### can be removed -- used during testing.
rm $PWD/ag_creation.done --force
#
OS_MAJOR_VERSION=`sed -rn 's/.*([0-9])\.[0-9].*/\1/p' /etc/redhat-release`
OS_MINOR_VERSION=`sed -rn 's/.*[0-9].([0-9]).*/\1/p' /etc/redhat-release`
#
#
echo '--- get required aws parameters'
#
echo '--- get currect aws region'
#
#
echo '--- installing jq' # jq is not included in the RHEL AMI 7.9, but may be RHEL 8.4.
#
# added the epel repository from fedora project.
# suspect that a rhel repo would be better.
#
if [[ "$NODE_ROLE" == "configonly" ]];then
    #
    echo "--- installing aws cli"
    #
    sudo yum install awscli -y
    #
fi
echo '--- setting default profile and current region'
#
aws configure set profile default
#
aws configure set region "$REGION"
#
echo "--- installing required installation tools and support tools"
#
echo '--- installing jq epel repo (latest version)'
#
if [ $OS_MAJOR_VERSION == "7" ];then
    #
    echo "--- installing epel repo for jq  (rhel major version 7)"
    #
    sudo yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    #
    sudo yum install jq -y
    #
else
    echo "--- installing epel repo for rhel version 8" # may drop this because of dependencies
    #
    yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
    #
    sudo yum install jq -y
    #
fi
#########################################################
# echo "--- installing aws ssm"
#
echo '--- installing jq'
#
yum install jq -y
# this can be removed after the install is competed

IMDS_TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

REGION=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
echo $REGION

AVAILABILITY_ZONE=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/placement/availability-zone)
echo $AVAILABILITY_ZONE

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/instance-id)
echo $INSTANCE_ID

NODE_IP=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/local-ipv4)
echo $NODE_IP

#AMI_ID=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/ami-id)
#echo $AMI_ID

AMI_NAME=$(aws ec2 describe-images --image-id $SQLAMIID --region $REGION)
echo $AMI_NAME

if [[ "$AMI_NAME" == *"2019"* ]]; then
    #
    MSSQL_VERSION="2019"
    #
else
    #
    MSSQL_VERSION="2017"
    #
fi

echo '--- set default profile and current region'
#
aws configure set profile default
#
aws configure set region "$REGION"
#
echo '--- creating json file that stores instance data that will be copied to the other nodes.'
#
cat > $PWD/$NODE_ROLE.json <<EOF
 {"nodename":"$NODE_NAME","ipaddress":"$NODE_IP","role":"$NODE_ROLE","instanceid":"$INSTANCE_ID"}
EOF
#
echo '--- instaling required packages'

echo '--- set mssql and tools search paths'
#
echo PATH="$PATH:/opt/mssql-tools/bin" >> ~/.bash_profile
echo 'export PATH="$PATH:/opt/mssql-tools/bin"' >> ~/.bashrc
source ~/.bashrc
#
echo "##############################################################################"
echo '--- creating node specific varables and settings'
echo "##############################################################################"
#
echo '--- getting mssql sa, mssql/pacemaker and pacemaker passwords from ssm paramater store'
#
MSSQL_SA_PASSWORD=$(aws ssm get-parameter --name $SQLSAPASSWORD --with-decryption | jq -r .Parameter.Value)
#
MSSQL_PACEMAKER_PASSWORD=$(aws ssm get-parameter --name $SQLPACEMAKERPASSWORD --with-decryption | jq -r .Parameter.Value)
#
PCS_CLUSTER_PASSWORD=$(aws ssm get-parameter --name $PACEMAKERCLUSTERPASSWORD --with-decryption | jq -r .Parameter.Value)
#
echo "##############################################################################"
echo "--- update mssql repos and tools to the latest version for active distro"
echo "##############################################################################"
#
echo "--- selecting and installing mssql and tools repos"
#
  echo "Setting repo as per AMI"
if [ $OS_MAJOR_VERSION == "7" ] ; then
#
echo "--- installing repos for mssql and tools (rhel major version 7)"
#
sudo curl -o /etc/yum.repos.d/mssql-server.repo https://packages.microsoft.com/config/rhel/7/mssql-server-${MSSQL_VERSION}.repo
#
sudo curl -o /etc/yum.repos.d/msprod.repo https://packages.microsoft.com/config/rhel/7/prod.repo
#
else
      echo "--- installing repos for mssql and tools  (rhel major version 8)"
  #
  sudo curl -o /etc/yum.repos.d/mssql-server.repo https://packages.microsoft.com/config/rhel/8/mssql-server-${MSSQL_VERSION}.repo
  #
  sudo curl -o /etc/yum.repos.d/msprod.repo https://packages.microsoft.com/config/rhel/8/prod.repo
fi
#
echo "--- primary and secondary cluster node time tweak 15s"
 #the primary and secondary have less to do than the configonly
 #this pauses allows the configuonly cluster node to catch up
if [[ "$NODE_ROLE" == primary ]] || [[ "$NODE_ROLE" == secondary ]];then
    echo "--sleeping for 90 seconds for config only lag node"
    sleep 90
fi

if [[ "$NODE_ROLE" == "configonly" ]];then
    #
    echo "###############################################################################"
    echo "--- mssql express edition installation started on the configonly cluster node"
    echo "###############################################################################"
    #
    # This will always be the newest from the repo
    #
    echo "--- installing mssql server"

    sudo yum install -y mssql-server

    echo "-- sql set up on config complete"

    sudo /opt/mssql/bin/mssql-conf setup

    echo "--- installing mssql-tools"
    #
    sudo ACCEPT_EULA=Y yum install -y mssql-tools unixODBC-devel
    #
    echo "--- enable sqlagent"
    #
    sudo /opt/mssql/bin/mssql-conf set sqlagent.enabled true
    #
    echo "--- restarting mssql"
    #
    sudo systemctl restart mssql-server # coud leave out and catch it later, to avoid services not loading
    #
    echo "##############################################################################"
    echo '--- mssql express edition - configonly cluster node installation completed'
    echo "##############################################################################"
    #
fi
#
echo "--- waiting for mssql script upgrade mode to complete (30 seconds)"
#
# mssql "script update mode" occurs after the initial binary installation
#
sudo sleep 30
#
echo '--- set mssql and tools search paths'
#
echo PATH="$PATH:/opt/mssql-tools/bin" >> ~/.bash_profile
echo 'export PATH="$PATH:/opt/mssql-tools/bin"' >> ~/.bashrc
source ~/.bashrc
#
echo "##############################################################################"
echo '--- change sa password, set edition and install mssql ha components'
echo "##############################################################################"
#
if [ "$NODE_ROLE" == "configonly" ];then
   MSSQL_PID="express" # do we confirm with the user to use express.
else 
   MSSQL_PID="enterprise" 
fi
#
echo "--- mssql edition $MSSQL_PID" selected
#
echo '--- running mssql-conf setup'
#
echo '--- stopping mssql service'
#
sudo systemctl stop mssql-server
#
echo '--- installing mssql server ha components and mssql agent'  #could be ami ####################
#
sudo yum install -y mssql-server-ha 
#
sudo /opt/mssql/bin/mssql-conf set hadr.hadrenabled 1
#
echo '--- misc mssql settings' # If further settings could be added as required
#
sudo /opt/mssql/bin/mssql-conf set telemetry.customerfeedback false
#
echo '--- set mssql sa password, mssql edition and eula acceptance' ###############
#
sudo MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD MSSQL_PID=$MSSQL_PID ACCEPT_EULA='Y' /opt/mssql/bin/mssql-conf -n setup
#
echo '--- start mssql service'
#
sudo systemctl start mssql-server
#
#echo '--- rename mssql instance'
#
sudo hostnamectl set-hostname "$NODE_NAME"
#
echo '--- renaming the mssql instance to match the linux hostname'
#
sudo cat > $PWD/mssql-rename-instance.sql <<EOF
    
    --- rename mssql instance name 

        DECLARE @NEW_MSSQL_SERVER_NAME nvarchar(50);
        SET @NEW_MSSQL_SERVER_NAME = convert(nvarchar(50), SERVERPROPERTY('MachineName'));
        EXEC sp_DROPSERVER @@SERVERNAME;
        EXEC sp_ADDSERVER @NEW_MSSQL_SERVER_NAME,'local';
        GO

    --- enable always on extended events

        ALTER EVENT SESSION  ALWAYSON_HEALTH ON SERVER WITH (STARTUP_STATE=ON);
        GO 
EOF
#
sudo chmod +x $PWD/mssql-rename-instance.sql
#
sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-rename-instance.sql
#
echo '--- restarting mssql'
#
sudo systemctl restart mssql-server 
#
echo '--- updating /etc/hosts file with allocated cluster node names'
# 
sudo cp /etc/hosts /etc/hosts.bak 
#
echo '--- copying configuration file to s3'
#
sudo aws s3 cp $PWD/$NODE_ROLE.json $BUCKET_NAME/
#
# Move on after all the node json files have arrived in S3.
#
# Move on after all the cluster node json files have arrived in S3.
#
echo '--- extracting bucket name and prefix'
#
S3_BUCKET_WITH_PREFIX=${BUCKET_NAME:5}
echo $S3_BUCKET_WITH_PREFIX
BUCKET_ARRAY=(${S3_BUCKET_WITH_PREFIX//// })
echo ${BUCKET_ARRAY[0]}
echo ${BUCKET_ARRAY[1]}
if [[ $NODE_ROLE == primary ]];then
    pricount=0
    echo '--- waiting for secondary node'
    sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"secondary.json"
    echo '--- waiting for configonly node'
    while [[ "$pricount" -le 10 ]]; do
      sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"configonly.json"
      if [ "$?" -eq 0 ]; then
        echo 'Config file written.Exiting loop'
        break
      else
        sleep 60
        pricount=$((pricount+1))
      fi
    done
    echo "Found config file after $pricount attempts on primary"
fi
if [[ $NODE_ROLE == secondary ]];then
    seccount=0
    echo '--- waiting for primary node'
    sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"primary.json"
    echo '--- waiting for configonly node'
    while [[ "$seccount" -le 10 ]]; do
      sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"configonly.json"
      if [ "$?" -eq 0 ]; then
        echo 'Config file written.Exiting loop'
        break
      else
        sleep 60
        seccount=$((seccount+1))
      fi
    done
    echo "Found config file after $seccount attempts on secondary"
fi
if [[ $NODE_ROLE == configonly ]];then
    echo '--- waiting for primary node'
    sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"primary.json"
    echo '--- waiting for secondary node'
    sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"secondary.json"
fi
#
echo "--- sync json files to each node"
#
sudo aws s3 sync $BUCKET_NAME/ $PWD/ --include "*.json"
#
echo '--- updating the hosts file'
#
PRIMARY_IP=`cat $PWD/primary.json | jq -r '.ipaddress'`
PRIMARY_NODE=`cat $PWD/primary.json | jq -r '.nodename'`
PRIMARY_INSTANCE=`cat $PWD/primary.json | jq -r '.instanceid'`
#
echo $PRIMARY_IP " " $PRIMARY_NODE " " $PRIMARY_NODE.'DOMAIN'>> /etc/hosts
#
SECONDARY_IP=`cat $PWD/secondary.json | jq -r '.ipaddress'`
SECONDARY_NODE=`cat $PWD/secondary.json | jq -r '.nodename'`
SECONDARY_INSTANCE=`cat $PWD/secondary.json | jq -r '.instanceid'`
#
echo $SECONDARY_IP " " $SECONDARY_NODE " " $SECONDARY_NODE.'DOMAIN'>> /etc/hosts
#  
CONFIGONLY_IP=`cat $PWD/configonly.json | jq -r '.ipaddress'`
CONFIGONLY_NODE=`cat $PWD/configonly.json | jq -r '.nodename'`
CONFIGONLY_INSTANCE=`cat $PWD/configonly.json | jq -r '.instanceid'`
#
echo $CONFIGONLY_IP " " $CONFIGONLY_NODE " " $CONFIGONLY_NODE.'DOMAIN'>> /etc/hosts
#sudo yum install -y mssql-server
# including avability group listener name
#
sudo echo "$MSSQL_LISTENER_IP   $MSSQL_LISTENER_NAME" >> /etc/hosts    # check looks wrong
#
echo "##############################################################################"
echo '--- starting mssql cluster node configuration'
echo "##############################################################################"
#
echo '--- disabling network source and destination test'  
#
aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check 

# <<COMMENTS
#
echo "##############################################################################"
echo "--- disk configuration (all instances)"
echo "##############################################################################"
#
# the primary or secondary cluster nodes disks will be ebs.  the configonly cluster
# node does not require any disk however small disk are implemented to keep the
# configuration consistence between cluster notes
#
# The Following Disks Will Be created; tempdb, data and backup on the primary
# or secondary
#
echo '--- backup fstab'
#
sudo cp -p /etc/fstab /etc/fstab.bak
#
echo '--- creating mssql primary directories'
#
MSSQL_ROOT_DIR="/var/opt/mssql"  ###### this is default folder for mssql
#
echo '--- creating disk volumes (tempdb, data and backup)'
declare -A GLOBAL_TAGS=( ["LaunchWizardResourceGroupID"]=${LW_RESOURCE_GROUP_ID} ["LaunchWizardApplicationType"]=SQLHALinuxRhel )
declare -a global_tag_list=()
declare -a root_volume_global_tag_list=()

for key in "${!GLOBAL_TAGS[@]}";
    do
        global_tag_list+=("{Key=${key},Value=${GLOBAL_TAGS[${key}]}}");
        root_volume_global_tag_list+=("{\"Key\":\"${key}\",\"Value\":\"${GLOBAL_TAGS[${key}]}\"}");
    done

GLOBAL_TAG_SPECS="[$(IFS=','; echo "${global_tag_list[*]}")]"
#
for MSSQL_DISK in {"tempdb","data","backup"}
    do
        if [ "$MSSQL_DISK" == "tempdb" ];then
            sizeGB=$TEMPDB_DISK_SIZE_GB
            deviceId="/dev/sdb"
            mappedDevice="/dev/nvme1n1"
            volumetype=$TEMPDB_VOLUME_TYPE
            volumeiops=$TEMPDB_VOLUME_IOPS
        fi
        if [ "$MSSQL_DISK" == "data" ];then
            sizeGB=$DATA_DISK_SIZE_GB
            deviceId="/dev/sdc"
            mappedDevice="/dev/nvme2n1"
            volumetype=$DATA_VOLUME_TYPE
            volumeiops=$DATA_VOLUME_IOPS
        fi
        if [ "$MSSQL_DISK" == "backup" ];then
            sizeGB=$BACKUP_DISK_SIZE_GB
            deviceId="/dev/sdd"
            mappedDevice="/dev/nvme3n1"
            volumetype=$BACKUP_VOLUME_TYPE
            volumeiops=$BACKUP_VOLUME_IOPS
        fi

        if [[ $NODE_ROLE == configonly ]];then
            echo "--- set the configonly node volume to $sizeGB"
            sizeGB=4
            volumetype="gp2"
        fi
        #
        echo "--- creating volume ($MSSQL_DISK)"
        ########################## need to test if already there #######################
        VOLUMECMD="aws ec2 create-volume --region ${REGION} --availability-zone ${AVAILABILITY_ZONE} --size ${sizeGB} --volume-type ${volumetype} --encrypted --tag-specifications ResourceType=volume,Tags=${GLOBAL_TAG_SPECS}"
        if [[ "$volumetype" == "io1" ]] || [[ "$volumetype" == "io2" ]];
         then
            VOLUMECMD+=" --iops $volumeiops"
        fi
        #
        volume=`${VOLUMECMD}`
        volumeId=`echo ${volume}|jq '.VolumeId'` ########### clean up required
        volumeId="${volumeId%\"}"
        volumeId="${volumeId#\"}"
        #
        echo "--- volume id ${volumeId} successfully created"
        if [ -z ${volumeId+x} ]; then
            echo "volume id " ${volumeId} "failed to create"
            exit -1;
        fi
        echo "--- waiting for volume (id "${volumeId}") to become available"
        #
        aws ec2 wait volume-available --volume-ids ${volumeId}
        #
        echo "--- attaching volume (id ${volumeId})"
        #
        aws ec2 attach-volume --volume-id ${volumeId} --instance-id ${INSTANCE_ID} --device ${deviceId}
        #
        echo "--- waiting for volume (id $volumeId to attach to $deviceId) - 30 seconds"
        #
        sleep 60s
        #
        echo "volume $volumeId attached to $deviceId"
        #
        echo "--- format disk $MSSQL_DISK"
        #
        sudo mkfs.ext4 -L $MSSQL_DISK $mappedDevice -F
        #
        echo "--- creating mount point ($MSSQL_ROOT_DIR/$MSSQL_DISK)"
        #
        MOUNTPOINT="$MSSQL_ROOT_DIR/$MSSQL_DISK"
        #
        echo '--- creating mount point folder'
        #
        sudo mkdir -p ${MOUNTPOINT}
        #
        echo "--- mount disk ($MSSQL_DISK)"
        #
        sudo mount LABEL="\""$MSSQL_DISK"\"" $MOUNTPOINT # displays error yet works - check #####################
        #
        echo "--- disk $MSSQL_DISK created and configured"
        #
        echo '--- update /etc/fstab'
        #
        echo "LABEL=$MSSQL_DISK ${MOUNTPOINT} ext4 defaults,nofail   0 0" >> /etc/fstab
        #
        echo "--- set volume configuration (${volumeId})"
        #
        aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --block-device-mappings "[{\"DeviceName\": \"$deviceId\",\"Ebs\":{\"DeleteOnTermination\":true}}]"
    done
echo "--- $NODE_ROLE node disk configuration completed"
#
echo '--- update folder permissions'
#
# COMMENTS
#
echo "--- updating mssql file permissions"
#
sudo chown -R mssql.mssql /var/opt/mssql/tempdb
sudo chown -R mssql.mssql /var/opt/mssql/data
sudo chown -R mssql.mssql /var/opt/mssql/backup
#sudo chown -R mssql.mssql /var/opt/mssql/data
#
echo '--- configuring mssql disks'
#
echo '--- setting mssql folders defaults'
#
sudo systemctl stop mssql-server
#
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultdatadir /var/opt/mssql/data  
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultbackupdir /var/opt/mssql/backup
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultlogdir /var/opt/mssql/data
#
sudo MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD MSSQL_PID=$MSSQL_PID ACCEPT_EULA='Y' /opt/mssql/bin/mssql-conf -n setup
#
sudo systemctl start mssql-server
#
cat > $PWD/mssql-move-tempdb.sql <<EOF

USE MASTER
GO
    --- moving mssql tempdb
        ALTER DATABASE tempdb MODIFY FILE (NAME = templog, FILENAME = '/var/opt/mssql/tempdb/templog.ldf')
        GO
        ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, FILENAME = '/var/opt/mssql/tempdb/tempdb.mdf')
        GO
        ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev2, FILENAME = '/var/opt/mssql/tempdb/tempdb2.ndf')
        GO
        ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev3, FILENAME = '/var/opt/mssql/tempdb/tempdb3.ndf')
        GO
        ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev4, FILENAME = '/var/opt/mssql/tempdb/tempdb4.ndf')
        GO
EOF
#
sudo chmod +x $PWD/mssql-move-tempdb.sql
#
sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-move-tempdb.sql
#
echo "--- restarting mssql server"
#
sudo systemctl restart mssql-server
#
echo "--- deleting old mssql tempdb files"
#
sudo rm /var/opt/mssql/data/tempdb.mdf
sudo rm /var/opt/mssql/data/templog.ldf
sudo rm /var/opt/mssql/data/tempdb*.ndf
#
echo "##############################################################################"
echo '--- mssql cluster node configuration completed'
echo "##############################################################################"
#
echo "##############################################################################"
echo '--- creating and implementing certificates'
echo "##############################################################################"
#
echo "--- creating master key ($NODE_NAME)"
#
sudo cat > $PWD/mssql-config-step-1.sql <<EOF
USE MASTER
GO
--- creating encryption master certificate ($NODE_NAME)

    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$MSSQL_SA_PASSWORD';  
    GO
EOF
#
sudo chmod +x $PWD/mssql-config-step-1.sql
#
sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-1.sql
#
if [[ $NODE_ROLE == primary ]];then
    #
    echo "--- creating primary cluster node certificate ($NODE_NAME)"
    #
    sudo cat > $PWD/mssql-config-step-2.sql  <<EOF
    
    USE MASTER;
    GO
        --- creating primary cluster node certificate ($NODE_NAME)

            CREATE CERTIFICATE mssql_certificate WITH SUBJECT = 'mssql-availability-group-certificate';
            BACKUP CERTIFICATE mssql_certificate TO FILE = '/var/opt/mssql/data/mssql_certificate.cer'
            WITH PRIVATE KEY (FILE = '/var/opt/mssql/data/mssql_certificate.pvk',ENCRYPTION BY PASSWORD = '$MSSQL_SA_PASSWORD');
            GO
EOF
    #
    sudo chmod +x $PWD/mssql-config-step-2.sql
    #
    sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-2.sql
    #
    echo "--- copying primary cluster node certificate and private key to s3 ($BUCKET_NAME)"
    #
    aws s3 cp /var/opt/mssql/data/mssql_certificate.cer $BUCKET_NAME/"mssql_certificate.cer"
    aws s3 cp /var/opt/mssql/data/mssql_certificate.pvk $BUCKET_NAME/"mssql_certificate.pvk"
    #
else 
    #
    echo "--- waiting for primary node certificate on s3 ($NODE_NAME)"
    #
    sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"mssql_certificate.cer"
    #
    echo "--- copying primary node certificate and private key from s3 ($NODE_NAME)"
    #
    aws s3 cp $BUCKET_NAME/"mssql_certificate.cer" /var/opt/mssql/data/mssql_certificate.cer
    aws s3 cp $BUCKET_NAME/"mssql_certificate.pvk" /var/opt/mssql/data/mssql_certificate.pvk
    #
    echo "--- creating secondary/configonly node certificate ($NODE_NAME)"
    #
    chown mssql:mssql /var/opt/mssql/data/mssql_certificate.*
    #
    sudo cat > $PWD/mssql-config-step-3.sql <<EOF
    
    USE MASTER
    GO
        --- creating cluster node certificate for non-primary cluster nodes ($NODE_NAME)

            CREATE CERTIFICATE mssql_certificate
            FROM FILE = '/var/opt/mssql/data/mssql_certificate.cer'
            WITH PRIVATE KEY (FILE = '/var/opt/mssql/data/mssql_certificate.pvk', DECRYPTION BY PASSWORD = '$MSSQL_SA_PASSWORD');
            GO
EOF
    #
    sudo chmod +x $PWD/mssql-config-step-3.sql
    #
    sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-3.sql
    #
fi 
#
echo "--- setting permissions for mssql account to certificates rights"
#
sudo chown mssql:mssql /var/opt/mssql/data/mssql_certificate.*
#
echo "--- creating mssql ha endpoint on primary and secondary ($NODE_NAME)"
#
if [[ "$NODE_ROLE" == primary ]] || [[ "$NODE_ROLE" == secondary ]];then
# 
    sudo cat > $PWD/mssql-config-step-4.sql  <<EOF
    
    USE MASTER
    GO
        --- creating availability group primary/secondary endpoint ($NODE_NAME)  

            CREATE ENDPOINT [$MSSQL_AG_ENDPOINT]
            AS TCP (LISTENER_PORT = 5022)
            FOR DATABASE_MIRRORING (ROLE = ALL,
	            AUTHENTICATION = CERTIFICATE mssql_certificate,
	            ENCRYPTION = REQUIRED ALGORITHM AES);

            ALTER ENDPOINT [$MSSQL_AG_ENDPOINT] STATE = STARTED;
            GO
EOF
    #
    sudo chmod +x $PWD/mssql-config-step-4.sql
    #
    sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-4.sql
    #
else 
    sudo cat > $PWD/mssql-config-step-5.sql  <<EOF
    
    USE MASTER
    GO
        --- creating availability group configonly witness endpoint ($NODE_NAME)

            CREATE ENDPOINT [$MSSQL_AG_ENDPOINT]
            AS TCP (LISTENER_PORT = 5022)
            FOR DATABASE_MIRRORING (ROLE = WITNESS,
	            AUTHENTICATION = CERTIFICATE mssql_certificate,
		        ENCRYPTION = REQUIRED ALGORITHM AES);

            ALTER ENDPOINT [$MSSQL_AG_ENDPOINT] STATE = STARTED;
            GO
EOF
    #
    sudo chmod +x $PWD/mssql-config-step-5.sql
    #
    sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-5.sql
#    
fi 
#
if [[ $NODE_ROLE == primary ]];then
    #
    echo '--- creating initial database'
    #
    # The creation of this test database is required to form the aways on availiabilty group
    #
    cat > $PWD/mssql-config-step-9.sql <<EOF
    
    USE MASTER
    GO
        --- creating initial database
            CREATE DATABASE $MSSQL_TEMP_DATABASE
            GO
            CREATE TABLE dbo.Employee (EmployeeID int);
            GO
            INSERT INTO dbo.Employee (EmployeeID) Values (1)
            INSERT INTO dbo.Employee (EmployeeID) Values (2)
            INSERT INTO dbo.Employee (EmployeeID) Values (3)
            GO

        --- backing up initial database
            BACKUP DATABASE $MSSQL_TEMP_DATABASE TO  DISK = N'$MSSQL_TEMP_DATABASE.bak' WITH NOFORMAT, NOINIT,  NAME = N'$MSSQL_TEMP_DATABASE-Full Database Backup', SKIP, NOREWIND, NOUNLOAD,  STATS = 10
            GO
EOF
    #
    sudo chmod +x $PWD/mssql-config-step-9.sql
    #
    sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-9.sql
    #
    echo '--- creating initial database and backup completed'
fi
#
if [[ $NODE_ROLE == primary ]];then
    #
    echo "--- creating availability group ($MSSQL_AG_NAME)"
    # 
    sudo cat > $PWD/mssql-config-step-6.sql <<EOF
    USE MASTER
    GO
        --- creating availability group ($MSSQL_AG_NAME) 

        CREATE AVAILABILITY GROUP [$MSSQL_AG_NAME]
        WITH (
            CLUSTER_TYPE = EXTERNAL,
            AUTOMATED_BACKUP_PREFERENCE = PRIMARY,
            DB_FAILOVER = ON,
            DTC_SUPPORT = NONE
            )
            FOR DATABASE [$MSSQL_TEMP_DATABASE]
            REPLICA ON

            N'${PRIMARY_NODE}' WITH (ENDPOINT_URL = N'TCP://${PRIMARY_NODE}:5022',
                AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
                FAILOVER_MODE = EXTERNAL,
                SEEDING_MODE = AUTOMATIC),

            N'${SECONDARY_NODE}' WITH (ENDPOINT_URL = N'TCP://${SECONDARY_NODE}:5022', 
                AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
                FAILOVER_MODE = EXTERNAL,
                SEEDING_MODE = AUTOMATIC),

            N'${CONFIGONLY_NODE}' WITH (ENDPOINT_URL = N'TCP://${CONFIGONLY_NODE}:5022', 
                AVAILABILITY_MODE = CONFIGURATION_ONLY);
            GO
        
        --- assigned required permissions

            ALTER AVAILABILITY GROUP [$MSSQL_AG_NAME] GRANT CREATE ANY DATABASE
            GO
EOF
    #
    sudo chmod +x $PWD/mssql-config-step-6.sql
    #
    sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-6.sql
    #
    echo "--- flagging ag creation as completed"
    #
    touch $PWD/ag_creation.done
    #
    sudo aws s3 cp $PWD/ag_creation.done $BUCKET_NAME/
    #
fi 
#
echo "--- creating local pacemaker account"
#
sudo echo "$MSSQL_PACEMAKER_LOGIN">> ~/pacemaker-passwd
sudo echo "$MSSQL_PACEMAKER_PASSWORD">> ~/pacemaker-passwd
sudo mv ~/pacemaker-passwd /var/opt/mssql/secrets/passwd
sudo chown root:root /var/opt/mssql/secrets/passwd
sudo chmod 400 /var/opt/mssql/secrets/passwd
#
if [[ "$NODE_ROLE" == secondary ]] || [[ "$NODE_ROLE" == configonly ]];then
    #
    echo "--- joining availability group ($NODE_NAME)"
    #
    sudo cat > $PWD/mssql-config-step-7.sql <<EOF

    USE MASTER
    GO
        --- joining availability group ($MSSQL_AG_NAME)

            ALTER AVAILABILITY GROUP [$MSSQL_AG_NAME] JOIN WITH (CLUSTER_TYPE = EXTERNAL);
            ALTER AVAILABILITY GROUP [$MSSQL_AG_NAME] GRANT CREATE ANY DATABASE;
            GO
EOF
   sudo chmod +x $PWD/mssql-config-step-7.sql
   #
   sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-7.sql
fi
#

echo "--- preparing local pacemaker services"
#
if [[ "$NODE_ROLE" == secondary ]] || [[ "$NODE_ROLE" == configonly ]];then
    #
    echo "--- waiting for primary node to create availability group"
    #
    sudo aws s3api wait object-exists --bucket ${BUCKET_ARRAY[0]} --key ${BUCKET_ARRAY[1]}/"ag_creation.done"
    #
    echo "--- ag created (ag_creation.done found)"
    #
fi
#
echo "--- creating pacemaker logins"
#
sudo cat > $PWD/mssql-config-step-8.sql <<EOF
USE MASTER
GO
    --- creating pacemaker login and permissions ($NODE_NAME)

        CREATE LOGIN $MSSQL_PACEMAKER_LOGIN WITH PASSWORD = '$MSSQL_PACEMAKER_PASSWORD'
        GO
        GRANT ALTER, CONTROL, VIEW DEFINITION ON AVAILABILITY GROUP::$MSSQL_AG_NAME TO $MSSQL_PACEMAKER_LOGIN
        GO
        GRANT VIEW SERVER STATE TO $MSSQL_PACEMAKER_LOGIN
        GO
        ALTER SERVER ROLE [sysadmin] ADD MEMBER [$MSSQL_PACEMAKER_LOGIN]
        GO
EOF
#
sudo chmod +x $PWD/mssql-config-step-8.sql
#
echo "--- creating pacemaker login ($NODE_NAME)"
#
sudo /opt/mssql-tools/bin/sqlcmd -S127.0.0.1 -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-step-8.sql
#
echo "--- saving pacemaker password to password file ($NODE_NAME)"
#
sudo echo "$MSSQL_PACEMAKER_LOGIN">>/var/opt/mssql/secrets/passwd 
sudo echo "$MSSQL_PACEMAKER_PASSWORD">>/var/opt/mssql/secrets/passwd 

sudo chown root:root /var/opt/mssql/secrets/passwd
sudo chmod 400 /var/opt/mssql/secrets/passwd 
#
#
echo "--- starting and enabling pacemaker daemon"
#
sudo systemctl start pcsd.service
sudo systemctl enable pcsd.service

if [ $OS_MAJOR_VERSION == "7" ];then
    #
    echo "--- configing local cluster nodes security (rhel major version 7)"
    #
    echo "hacluster:$PCS_CLUSTER_PASSWORD" | sudo chpasswd
    #
else
    #
    echo "--- configuring local cluster nodes security (rhel major version 8)"
    #
    echo "hacluster:$PCS_CLUSTER_PASSWORD" | sudo chpasswd
    #
    sudo pcs host auth $PRIMARY_NODE $SECONDARY_NODE $CONFIGONLY_NODE -u hacluster -p $PCS_CLUSTER_PASSWORD

    sudo pcs host auth $PRIMARY_NODE $SECONDARY_NODE $CONFIGONLY_NODE -u hacluster -p $PCS_CLUSTER_PASSWORD
    # may not always work
    #

fi
echo "--- pacemaker preparation completed and services started"
#
if [[ "$NODE_ROLE" == "secondary" ]];then

    echo "################################################################################"
    echo '--- secondary node installation and configuration has completed'    
    echo "################################################################################"
    exit 0

fi
#
if [[ "$NODE_ROLE" == "configonly" ]];then 

    echo "################################################################################"
    echo '--- configonly cluster node installation and configuration has completed'
    echo "################################################################################"
    exit 0
    #
fi    
#
echo "################################################################################"
echo '--- primary cluster node installation and configuration has completed'
echo "################################################################################"
#

echo "--- waiting for the secondary and configonly cluster nodes to complete $NODE_ROLE"

echo "################################################################################"
echo '--- pacemaker cluster configuration (primary only) starting'
echo "################################################################################"
echo "--- installing pacemaker fencing"
#
# sudo yum install -y pcs pacemaker fence-agents-all resource-agents
#
if [ $OS_MAJOR_VERSION == "7" ];then
    #
    echo "--- configuring cluster nodes (rhel major version 7)"
    #
    # To avoid a race condition when a rebooted cluster node return to service
    #
    sudo systemctl disable pacemaker.service
    sudo systemctl disable corosync.service
    #
    echo '--- authorising pacemaker cluster nodes'
    #
    sudo pcs cluster auth $PRIMARY_NODE $SECONDARY_NODE $CONFIGONLY_NODE -u hacluster -p $PCS_CLUSTER_PASSWORD
    #
    echo '--- creating pcs cluster'
    #
    sudo pcs cluster setup --name $PMC_CLUSTER_NAME $PRIMARY_NODE $SECONDARY_NODE $CONFIGONLY_NODE -u hacluster -p $PCS_CLUSTER_PASSWORD --force
    #
    echo '--- enabling and starting pcs cluster'
    #
    sudo pcs cluster start --all
    #
    echo '--- configuring and starting stonith fencing'
    #
    sudo pcs stonith create clusterfence fence_aws region=$REGION pcmk_host_map="$PRIMARY_NODE:$PRIMARY_INSTANCE;$SECONDARY_NODE:$SECONDARY_INSTANCE;$CONFIGONLY_NODE:$CONFIGONLY_INSTANCE" power_timeout=240 pcmk_reboot_timeout=480 pcmk_reboot_retries=4 --force

    #
    sudo pcs property set stonith-enabled=true
    #
    echo '--- creating cluster resource agent (mssql_ag)'
    #
    sudo pcs resource create $MSSQL_AG_NAME ocf:mssql:ag ag_name=$MSSQL_AG_NAME master notify=true meta failure-time=60s --force
    #
    echo '--- creating cluster resource agent (aws-vpc-move-ip)'
    #
    sudo pcs resource create $MSSQL_LISTENER_NAME ocf:heartbeat:aws-vpc-move-ip ip=$MSSQL_LISTENER_IP interface="eth0" routing_table=$VPC_ROUTING_TABLE_ID op monitor timeout="30s" interval="60s" --force
    #
    echo '--- adding cluster colocation constraints'
    #
    sudo pcs constraint colocation add $MSSQL_LISTENER_NAME with $MSSQL_AG_NAME-master INFINITY with-rsc-role=Master --force
    #
    echo '--- adding cluster order constraints'
    #
    sudo pcs constraint order promote $MSSQL_AG_NAME-master then start $MSSQL_LISTENER_NAME --force
    #
    echo '--- setting pcs cluster properties'
    #
    sudo pcs resource update $MSSQL_AG_NAME meta failure-timeout=60s
    #
    sudo pcs property set start-failure-is-fatal=true
    #
    sudo pcs property set cluster-recheck-interval=75s
    #

else
    #
    echo "--- configuring cluster nodes (rhel major version 8)"
    #
    # To avoid a race condition when a rebooted cluster node return to service
    #
    sudo systemctl disable pacemaker.service
    sudo systemctl disable corosync.service
    #
    echo '--- authorising pacemaker cluster nodes'
    #
    sudo pcs host auth $PRIMARY_NODE $SECONDARY_NODE $CONFIGONLY_NODE -u hacluster -p $PCS_CLUSTER_PASSWORD
    #
    echo '--- creating and starting te pcs cluster'
    #
    sudo pcs cluster setup $PMC_CLUSTER_NAME -start $PRIMARY_NODE $SECONDARY_NODE $CONFIGONLY_NODE
    #
    echo '--- enabling pcs cluster'
    #
    sudo pcs cluster start --all
    #
    echo '--- configuring and starting stonith fencing'
    #
    sudo pcs stonith create clusterfence fence_aws region=$REGION pcmk_host_map="$PRIMARY_NODE:$PRIMARY_INSTANCE;$SECONDARY_NODE:$SECONDARY_INSTANCE;$CONFIGONLY_NODE:$CONFIGONLY_INSTANCE" power_timeout=240 pcmk_reboot_timeout=480 pcmk_reboot_retries=4 --force
    #
    sudo pcs property set stonith-enabled=true
    #
    echo '--- creating cluster resource agent (mssql_ag)'
    #
    sudo pcs resource create $MSSQL_AG_NAME ocf:mssql:ag ag_name=$MSSQL_AG_NAME promotable notify=true meta failure-time=60s --force
    #
    echo '--- creating cluster resource agent (aws-vpc-move-ip)'
    #
    sudo pcs resource create $MSSQL_LISTENER_NAME ocf:heartbeat:aws-vpc-move-ip ip=$MSSQL_LISTENER_IP interface="eth0" routing_table=$VPC_ROUTING_TABLE_ID op monitor timeout="30s" interval="60s" --force
    #
    echo '--- adding cluster colocation constraints'
    #
    sudo pcs constraint colocation add $MSSQL_LISTENER_NAME with $MSSQL_AG_NAME-clone INFINITY with-rsc-role=Master --force
    #
    echo '--- adding cluster order/promote constraints'
    #
    sudo pcs constraint order promote $MSSQL_AG_NAME-clone then start $MSSQL_LISTENER_NAME --force
    #
    echo '--- setting pcs cluster properties'
    #
    sudo pcs resource update $MSSQL_AG_NAME meta failure-timeout=60s
    #
    sudo pcs property set start-failure-is-fatal=true
    #
    sudo pcs property set cluster-recheck-interval=75s

fi
#
echo "################################################################################"
echo '--- pacemaker cluster configuration completed'
echo "################################################################################"
#
# END
#
# Microsoft SQL Server on Linux Always on Availabilty Groups Build Completed.
#
