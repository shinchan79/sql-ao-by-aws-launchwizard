#!/bin/bash
###############################################################################
# Script Name	: MSSQL Cluster Node Preparation
# Description	: This script configures cluster nodes ready for the creation of 
#				a MSSQL Always on Availability Group service.
# Created		: 12-June-2020
# Version		: 2.0
###############################################################################
#
# THIS SCRIPT MUST BE EXECUTED ON ALL CLUSTER NODES
#
# PARAMETERS
#
# cmdline ./mssql-install.sh MSSQL_EDITION MSSQL_PASSWORD_KEY
#
###############################################################################
#
if [ -z $2 ]; then
    echo '######## NO ARGS ########'
    exit 0
else
    echo '######## ARGS OK ########'
fi
#
MSSQL_PASSWORD_KEY=$2
MSSQL_SA_PASSWORD=$(aws ssm get-parameter --name $MSSQL_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value)  ### move to the line that calls it
#
MSSQL_EDITION=$1 
echo $MSSQL_EDITION
#
. /etc/os-release
echo $VERSION_ID
#
###############################################################################
#
# Main 
#
###############################################################################
#
echo '--- MSSQL Instalation Starting'
#
echo '--- Import and Register Repository Keys'
#
sudo wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
#
sudo add-apt-repository "$(wget -qO- https://packages.microsoft.com/config/ubuntu/$VERSION_ID/mssql-server-2019.list)"
#
echo '--- Installing MSSQL Server Components and MSSQL Agent'
#
sudo apt-get -y update
#
echo '--- Installing MSSQL High Availibilty Components'
#
sudo apt install -y -qq mssql-server-ha
sudo /opt/mssql/bin/mssql-conf set hadr.hadrenabled 1
#
echo '--- Configure Microsoft SQL Server on Linux'
#
sudo systemctl stop mssql-server
#
sudo MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD MSSQL_PID=$MSSQL_EDITION ACCEPT_EULA='Y' /opt/mssql/bin/mssql-conf -n setup 
#
echo 'Misc MSSQL Settings'
#
sudo /opt/mssql/bin/mssql-conf set telemetry.customerfeedback false
#
echo '--- Starting MSSQL Node Based Configuration'
#
echo '--- Update Folder Permissions'
#
sudo chown -R mssql.mssql /var/opt/mssql/data/tempdb
sudo chown -R mssql.mssql /var/opt/mssql/data/data
sudo chown -R mssql.mssql /var/opt/mssql/data/logs
sudo chown -R mssql.mssql /var/opt/mssql/data/backup
#
echo '--- Waiting 60 seconds For Upgrade Mode To Complete'
#
sleep 60s
#
echo '--- Configure MSSQL Disk Settings'
#
sudo systemctl stop mssql-server
#
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultdatadir /var/opt/mssql/data/data
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultlogdir /var/opt/mssql/data/logs
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultbackupdir /var/opt/mssql/data/backup
echo '-- Starting MSSQL'
#
sudo systemctl start mssql-server

# Rename comp - https://docs.microsoft.com/en-us/sql/database-engine/install-windows/rename-a-computer-that-hosts-a-stand-alone-instance-of-sql-server?view=sql-server-ver15
echo '-- Rename computer name that hosts sql server'
#
cat > $PWD/mssql-rename-comp.sql <<EOF
USE master;
DECLARE @InternalInstanceName sysname;
DECLARE @MachineInstanceName sysname;
SELECT @InternalInstanceName = @@SERVERNAME, @MachineInstanceName = CAST(SERVERPROPERTY('MACHINENAME') AS VARCHAR(128)) + COALESCE('\' + CAST(SERVERPROPERTY('INSTANCENAME') AS VARCHAR(128)), '');
IF @InternalInstanceName <> @MachineInstanceName
    BEGIN 
    EXEC sp_dropserver @InternalInstanceName;
    EXEC sp_addserver @MachineInstanceName, 'LOCAL';
    END
GO
EOF
#
sudo chmod +x $PWD/mssql-rename-comp.sql
sudo /opt/mssql-tools/bin/sqlcmd -Slocalhost -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-rename-comp.sql
sudo systemctl restart mssql-server
sleep 60s
#
echo '-- Move mssql TEMPDB'
#
cat > $PWD/mssql-move-tempdb.sql <<EOF
USE master;
GO
ALTER DATABASE tempdb
MODIFY FILE (NAME = tempdev, FILENAME = '/var/opt/mssql/data/tempdb/tempdb.mdf');
GO
ALTER DATABASE tempdb
MODIFY FILE (NAME = templog, FILENAME = '/var/opt/mssql/data/tempdb/templog.ldf');
GO
EOF
#
sudo chmod +x $PWD/mssql-move-tempdb.sql
#
sudo /opt/mssql-tools/bin/sqlcmd -Slocalhost -Usa -P$MSSQL_SA_PASSWORD -i $PWD/mssql-move-tempdb.sql
#
sudo mv /var/opt/mssql/data/tempdb.mdf /var/opt/mssql/data/tempdb
sudo mv /var/opt/mssql/data/templog.ldf /var/opt/mssql/data/tempdb
#
sudo systemctl restart mssql-server
sleep 30s
#
echo '-- MSSQL Base Configuration Completed'