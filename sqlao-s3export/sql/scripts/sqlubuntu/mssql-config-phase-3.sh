#!/bin/bash
###############################################################################
# Script Name	: MSSQL Configuration (Phase 3)
# Description	: This script configures MSSQL on each cluster nodes ready
#                 for the creation of the MSSQL Always on Availability Group service.
# Created		: 12-June-2020
# Version		: 2.0
###############################################################################
#
# THIS SCRIPT MUST BE EXECUTED ON THE PRIMARY NODE ONLY!
#
# PARAMETERS
#
# cmdline ./mssql-config-phase-3 PCS_NODE_01 PCS_NODE_02 PCS_NODE_03 MSSQL_AG_NAME MSSQL_TEMP_DATABASE MSSQL_SA_PASSWORD_KEY MSSQL_PACEMAKER_LOGIN MSSQL_PACEMAKER_PASSWORD_KEY
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
MSSQL_SA_PASSWORD_KEY=$6
MSSQL_SA_PASSWORD=$(aws ssm get-parameter --name $MSSQL_SA_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value)  ################### move!

PCS_NODE_01=$1 # Primary
echo $PCS_NODE_01

PCS_NODE_02=$2 # Secondary
echo $PCS_NODE_02

PCS_NODE_03=$3 # Quorum
echo $PCS_NODE_03

TMP_NODE_NAME=$(hostname)
NODE_NAME=${TMP_NODE_NAME^^}
echo $NODE_NAME "---primary"
#
# Create an array to store all nodes.
#
declare -a NODES 
NODES=($PCS_NODE_01 $PCS_NODE_02 $PCS_NODE_03)
#
# Create an array to store non-primary nodes.
#
declare -a NODE_ALT
#
mapfile -t NODE_ALT < <(printf "%s\n" "${NODES[@]}" | grep -iv ${NODE_NAME})
#
MSSQL_AG_NAME=$4
echo $MSSQL_AG_NAME
#
MSSQL_TEMP_DATABASE=$5
echo $MSSQL_TEMP_DATABASE

MSSQL_PACEMAKER_LOGIN=$7
echo $MSSQL_PACEMAKER_LOGIN
MSSQL_PACEMAKER_PASSWORD_KEY=$8
echo $MSSQL_PACEMAKER_PASSWORD_KEY

MSSQL_PACEMAKER_PASSWORD=$(aws ssm get-parameter --name $MSSQL_PACEMAKER_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value)
#
################################################################################
#
# Main 
#
################################################################################
#
echo '-- MSSQL phase 3 configuration script creation starting'
#
# The following steps create a SQL script file, executes it, creating a temporary database .
#
echo '-- Ceating initial database'
#
cat > $PWD/mssql-config-create-db.sql <<EOF

-- Create Initial Database

USE MASTER
GO
CREATE DATABASE $MSSQL_TEMP_DATABASE
GO
CREATE TABLE dbo.Employee (EmployeeID int);
GO
INSERT INTO dbo.Employee (EmployeeID) Values (1)
INSERT INTO dbo.Employee (EmployeeID) Values (2)
INSERT INTO dbo.Employee (EmployeeID) Values (3)
GO

-- Backing up initial database

BACKUP DATABASE $MSSQL_TEMP_DATABASE TO DISK = '/var/opt/mssql/data/vg_backup01/$MSSQL_TEMP_DATABASE.bak' WITH FORMAT;
GO
-- Database Backup Completed

EOF
#
echo '-- Initial database creation script completed'  
#
sudo chmod +x $PWD/mssql-config-create-db.sql
#
sudo /opt/mssql-tools/bin/sqlcmd -Slocalhost -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-create-db.sql
#
echo '-- Temporary database creation completed' 
#
# The following steps create a SQL script file, executes it, creating the AOAG.
#
echo '--- Configure Node Roles'
cat > $PWD/mssql-config-phase-3-1.sql <<EOF
USE [master]
GO
 
CREATE AVAILABILITY GROUP [$MSSQL_AG_NAME]
WITH 
(
   AUTOMATED_BACKUP_PREFERENCE = PRIMARY,
   DB_FAILOVER = ON,
   DTC_SUPPORT = NONE,
   CLUSTER_TYPE = EXTERNAL
)
FOR DATABASE [$MSSQL_TEMP_DATABASE]
REPLICA ON  
N'${NODES[0]}'
 WITH 
(
   ENDPOINT_URL = N'TCP://${NODES[0]}:5022', 
   FAILOVER_MODE = EXTERNAL, 
   AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, 
   SEEDING_MODE = AUTOMATIC
),
   
N'${NODES[1]}' WITH 
(
   ENDPOINT_URL = N'TCP://${NODES[1]}:5022', 
   FAILOVER_MODE = EXTERNAL, 
   AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, 
   SEEDING_MODE = AUTOMATIC
),   
N'${NODES[2]}' WITH 
(
ENDPOINT_URL = N'TCP://${NODES[2]}:5022',
AVAILABILITY_MODE = CONFIGURATION_ONLY 
);
GO

EOF
#
sudo chmod +x $PWD/mssql-config-phase-3-1.sql
#
sudo /opt/mssql-tools/bin/sqlcmd -Slocalhost -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-phase-3-1.sql
#
echo '--- Availability Group Created On The Primary Node'
#
echo '--- Secondary And Quorum Configuration'
#
cat > $PWD/mssql-config-phase-3-2.sql <<EOF

USE master

ALTER AVAILABILITY GROUP [$MSSQL_AG_NAME] JOIN WITH (CLUSTER_TYPE = EXTERNAL)
ALTER AVAILABILITY GROUP [$MSSQL_AG_NAME] GRANT CREATE ANY DATABASE;
GO

EOF
#
sudo chmod +x $PWD/mssql-config-phase-3-2.sql
#
echo '-- Add replicas to non-primary nodes'
#
for NODE in ${NODE_ALT[@]}
    do
      echo "-- Adding replicas to $NODE"
      sudo /opt/mssql-tools/bin/sqlcmd -S$NODE -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-phase-3-2.sql
    done
#
#  -- Create Pacemaker login and permissions
#
cat > $PWD/mssql-config-phase-3-3.sql <<EOF

-- Create Pacemaker login and permissions

USE master  
GO

CREATE LOGIN $MSSQL_PACEMAKER_LOGIN 
WITH PASSWORD = "$MSSQL_PACEMAKER_PASSWORD";  
GO

USE master  
GO

GRANT ALTER, CONTROL, VIEW DEFINITION ON AVAILABILITY GROUP::$MSSQL_AG_NAME TO $MSSQL_PACEMAKER_LOGIN
GO

GRANT VIEW SERVER STATE TO $MSSQL_PACEMAKER_LOGIN

EOF
#
sudo chmod +x $PWD/mssql-config-phase-3-3.sql
#
for NODE in ${NODES[@]}
    do
      echo -- Adding permissions to $NODE""
      sudo /opt/mssql-tools/bin/sqlcmd -S$NODE -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-config-phase-3-3.sql
    done
# End
echo '-- MSSQL Phase 3 Configration Completed'
#
# Clean-up
#
# sudo rm $PWD/mssql-config-phase-3.sql -force
# sudo rm $PWD/mssql-config-phase-3-1.sql -force
# sudo rm $PWD/mssql-config-phase-3-2.sql -force
# sudo rm $PWD/mssql-config-phase-3-3.sql -force
#
# END
#