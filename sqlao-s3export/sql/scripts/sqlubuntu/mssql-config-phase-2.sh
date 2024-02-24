#!/bin/bash
###############################################################################
# Script Name	: MSSQL Configuration (Phase 2)
# Description	: This script configures MSSQL on each cluster nodes ready
#                 for the creation of the MSSQL Always on Availability Group service.
# Created		: 12-June-2020
# Version		: 2.0
###############################################################################
#
# THIS SCRIPT MUST BE EXECUTED ON EACH CLUSTER NODE!
#
# PARAMETERS
#
# cmdline ./mssql-config-phase-2 PCS_NODE_01 PCS_NODE_02 PCS_NODE_03 MSSQL_AG_NAME MSSQL_PACEMAKER_LOGIN MSSQL_PACEMAKER_PASSWORD_KEY MSSQL_PASSWORD_KEY NODE_CERT_S3_LOCATION STACK_ID
#
################################################################################
#
if [ -z $1 ]; then
    echo '######## NO ARGS ########'
    exit 0
else
    echo '######## ARGS OK ########'
fi
#
set -e
IMDS_TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

MSSQL_PASSWORD_KEY=$7
MSSQL_SA_PASSWORD=$(aws ssm get-parameter --name $MSSQL_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value)

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/instance-id 2> /dev/null)
VPC_ID=$(aws ec2 describe-instances --instance-id $INSTANCE_ID | jq -r .Reservations[0].Instances[0].VpcId)

STACK_ID=$9
echo $STACK_ID

PCS_NODE_01=$1 # Primary
PCS_NODE_IP_01=$(aws ec2 describe-instances --filters Name=vpc-id,Values=$VPC_ID --filters "Name=tag:Name,Values=$PCS_NODE_01" "Name=tag:aws:cloudformation:logical-id,Values=ClusterNode1" "Name=tag:aws:cloudformation:stack-id,Values="$STACK_ID | jq -r .Reservations[0].Instances[0].PrivateIpAddress)
echo $PCS_NODE_01
echo $PCS_NODE_IP_01

PCS_NODE_02=$2 # Secondary
PCS_NODE_IP_02=$(aws ec2 describe-instances --filters Name=vpc-id,Values=$VPC_ID --filters "Name=tag:Name,Values=$PCS_NODE_02" "Name=tag:aws:cloudformation:logical-id,Values=ClusterNode2" "Name=tag:aws:cloudformation:stack-id,Values="$STACK_ID | jq -r .Reservations[0].Instances[0].PrivateIpAddress)
echo $PCS_NODE_02
echo $PCS_NODE_IP_02

PCS_NODE_03=$3 # Quorum
PCS_NODE_IP_03=$(aws ec2 describe-instances --filters Name=vpc-id,Values=$VPC_ID --filters "Name=tag:Name,Values=$PCS_NODE_03" "Name=tag:aws:cloudformation:logical-id,Values=ClusterNode3" "Name=tag:aws:cloudformation:stack-id,Values="$STACK_ID | jq -r .Reservations[0].Instances[0].PrivateIpAddress)
echo $PCS_NODE_03
echo $PCS_NODE_IP_03

sudo cp /etc/hosts /etc/hosts.bak
sudo echo "$PCS_NODE_IP_01 $PCS_NODE_01" >> /etc/hosts
sudo echo "$PCS_NODE_IP_02 $PCS_NODE_02" >> /etc/hosts
sudo echo "$PCS_NODE_IP_03 $PCS_NODE_03" >> /etc/hosts

#
# Create an array to store all nodes, for later exclusion from certain configration steps.
#
declare -a NODES 
NODES=($PCS_NODE_01 $PCS_NODE_02 $PCS_NODE_03)
declare -a NODE_ALT
#
TMP_NODE_NAME=$(hostname)
NODE_NAME=${TMP_NODE_NAME^^}
echo $NODE_NAME
# 
MSSQL_NODE_CERT_NAME=${NODE_NAME,,}"_cert"
echo $MSSQL_NODE_CERT_NAME
#
MSSQL_NODE_CERT_FILENAME=$MSSQL_NODE_CERT_NAME".cer"
echo $MSSQL_NODE_CERT_FILENAME
#
MSSQL_AG_NAME=$4
echo $MSSQL_AG_NAME
#
MSSQL_AG_ENDPOINT=$MSSQL_AG_NAME"_endpoint"
echo $MSSQL_AG_ENDPOINT

MSSQL_AG_LOGIN=$MSSQL_AG_NAME"_login"
echo $MSSQL_AG_LOGIN
#
MSSQL_AG_USER=$MSSQL_AG_NAME"_user"
echo $MSSQL_AG_USER

MSSQL_PACEMAKER_LOGIN=$5
echo $MSSQL_PACEMAKER_LOGIN
#
MSSQL_PACEMAKER_PASSWORD_KEY=$6
MSSQL_PACEMAKER_PASSWORD=$(aws ssm get-parameter --name $MSSQL_PACEMAKER_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value)

NODE_CERT_S3_LOCATION=$8
#
################################################################################
#
# Main 
#
################################################################################
echo '-- MSSQL phase 2 configuration script creation starting'
#
# MSSQL phase 2 configuration for each cluster node
#
# Copy Certificates to each cluster node. (Assumes that all nodes have completed phase 1 instalation)
#

sudo aws s3 sync $NODE_CERT_S3_LOCATION/ /var/opt/mssql/data/ --include "*.cer"
numCerts=$(ls /var/opt/mssql/data/*.cer | wc -l)
while [[ ${numCerts} -lt 3 ]]
  do
    echo "Only ${numCerts}/3 certs available. sleeping 30s"
    sleep 30;
    sudo aws s3 sync $NODE_CERT_S3_LOCATION/ /var/opt/mssql/data/ --include "*.cer"
    numCerts=$(ls /var/opt/mssql/data/*.cer | wc -l);
  done
#
# Reset permissions for MSSQL account to have execute rights for all certificate
#
sudo chown mssql:mssql /var/opt/mssql/data/*.cer  
#
# Create alternate nodes list.  This exclues the current node, executing the commmands on the remaining nodes
#
mapfile -t NODE_ALT < <(printf "%s\n" "${NODES[@]}" | grep -iv $NODE_NAME)

#
# The following steps create a SQL script file and the executes it.
#
sudo cat > $PWD/mssql-config-phase-2.sql <<EOF

-- Create logins and associate certificates 

USE master  
 
CREATE LOGIN $MSSQL_AG_LOGIN
WITH PASSWORD = "$MSSQL_SA_PASSWORD"
GO

USE master 

CREATE USER $MSSQL_AG_LOGIN  
FOR LOGIN $MSSQL_AG_LOGIN  
GO

USE master  

CREATE CERTIFICATE ${NODE_ALT[0]}_cert
AUTHORIZATION $MSSQL_AG_LOGIN  
FROM FILE = '/var/opt/mssql/data/${NODE_ALT[0],,}_cert.cer'
GO

USE master  

CREATE CERTIFICATE ${NODE_ALT[1]}_cert
AUTHORIZATION $MSSQL_AG_LOGIN  
FROM FILE = '/var/opt/mssql/data/${NODE_ALT[1],,}_cert.cer'
GO

USE master  

GRANT CONNECT ON ENDPOINT::$MSSQL_AG_ENDPOINT
TO [$MSSQL_AG_LOGIN];    
GO

EOF
#
echo '-- MSSQL phase 2 script creation completed'  
#
sudo chmod +x $PWD/mssql-config-phase-2.sql
#
echo '-- Running MSSQL phase 2 configuration script'  
#
sudo /opt/mssql-tools/bin/sqlcmd -Slocalhost -Usa -P $MSSQL_SA_PASSWORD -i $PWD/mssql-config-phase-2.sql
#
# sudo rm /opt/mssql/mssql-config-phase-2.sh -force
#
echo '-- Save Pacemaker password to password file'
#
sudo echo "$MSSQL_PACEMAKER_LOGIN">>/var/opt/mssql/secrets/passwd 
sudo echo "$MSSQL_PACEMAKER_PASSWORD">>/var/opt/mssql/secrets/passwd 
#
sudo chmod 400 /var/opt/mssql/secrets/passwd  

echo '-- MSSQL Phase 2 Configration Completed'
#
# END
#