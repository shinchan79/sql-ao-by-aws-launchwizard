#!/bin/bash
###############################################################################
# Script Name	: MSSQL Configuration (Phase 1)
# Description	: This script configures MSSQL on each cluster nodes ready
#                for the creation of the MSSQL Always on Availability Group service.
# Created		: 12-June-2020
# Version		: 2.0
###############################################################################
#
# THIS SCRIPT MUST BE EXECUTED ON ALL NODES!
#
# PARAMETERS
#
# cmdline ./mssql-config-phase-1  MSSQL_AG_NAME MSSQL_PASSWORD_KEY NODE_CERT_S3_PATH
#
################################################################################
#
if [ -z $2 ]; then
    echo '######## NO ARGS ########'
    exit 0
else
    echo '######## ARGS OK ########'
fi
set -e
#
MSSQL_PASSWORD_KEY=$2
MSSQL_SA_PASSWORD=$(aws ssm get-parameter --name $MSSQL_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value)  ################### move!
#
NODE_NAME=$(hostname)
echo $NODE_NAME
#
NODE_ROLE=$4
# 
MSSQL_NODE_CERT_NAME=${NODE_NAME,,}"_cert"
echo $MSSQL_NODE_CERT_NAME
#
MSSQL_NODE_CERT_FILENAME=$MSSQL_NODE_CERT_NAME".cer"
echo $MSSQL_NODE_CERT_FILENAME
#
MSSQL_AG_NAME=$1
echo $MSSQL_AG_NAME
#
MSSQL_AG_ENDPOINT=$MSSQL_AG_NAME"_endpoint"
echo $MSSQL_AG_ENDPOINT
#
# MSSQL_CERT_STORAGE=$(aws ssm get-parameter --name mssql_cert_storage  --with-decryption | jq -r .Parameter.Value) # should come from cloud formation!!
# echo $MSSQL_CERT_STORAGE
#
################################################################################
#
# Main 
#
################################################################################\#
echo '-- MSSQL phase 1 configuration script creation starting'
#
# The following steps create a SQL script file and the executes it.
#
sudo cat > $PWD/mssql-config-phase-1.sql  <<EOF

-- MSSQL phase 1 configuration for each cluster node

-- Create encryption master key

USE master
CREATE MASTER KEY ENCRYPTION BY PASSWORD = "$MSSQL_SA_PASSWORD";  
GO

-- Create node cerficate

USE master
CREATE CERTIFICATE $MSSQL_NODE_CERT_NAME
WITH SUBJECT = '$NODE_NAME certificate for Availability Group'; 
GO

-- Create AOAG endpoint

USE master  
 
CREATE ENDPOINT $MSSQL_AG_ENDPOINT 
STATE = STARTED 
AS TCP 
(
   LISTENER_PORT = 5022, LISTENER_IP = ALL
)  
FOR DATABASE_MIRRORING 
(
   AUTHENTICATION = CERTIFICATE $MSSQL_NODE_CERT_NAME , 
   ENCRYPTION = REQUIRED ALGORITHM AES,
   ROLE = $NODE_ROLE
);  
GO

-- Backup certificate

BACKUP CERTIFICATE $MSSQL_NODE_CERT_NAME 
TO FILE = '/var/opt/mssql/data/$MSSQL_NODE_CERT_FILENAME'; 
EOF
#
echo '-- MSSQL phase 1 script creation completed'  
#
sudo chmod +x $PWD/mssql-config-phase-1.sql
#
echo '-- Running MSSQL phase 1 configuration script started'  
#
sudo /opt/mssql-tools/bin/sqlcmd -Slocalhost -Usa -P $MSSQL_SA_PASSWORD -i $PWD/mssql-config-phase-1.sql
#
echo '-- Copy the certificate files to S3'
#
#  aws s3 cp /var/opt/mssql/data/$MSSQL_NODE_CERT_FILENAME s3:// $MSSQL_CERT_STORAGE/$MSSQL_NODE_CERT_FILENAME
#
NODE_CERT_S3_PATH=$3
aws s3 cp /var/opt/mssql/data/*.cer $NODE_CERT_S3_PATH/

echo 'Sleep 1m to allow consistency between nodes' #TODO: Think of a better way
sleep 1m
#
# sudo rm $PWD/mssql-config-phase-1.sql -force
#
# End
echo '-- MSSQL phase 1 configration completed'
#