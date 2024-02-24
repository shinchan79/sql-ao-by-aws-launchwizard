#!/bin/bash
###############################################################################
# Script Name	: PMC Cluster Node Installation
# Description	: This script install a cluster nodes ready for the creation of 
#				a Placemaker cluster service.
# Created		: 12-June-2020
# Version		: 2.0
###############################################################################
#
# THIS SCRIPT MUST BE EXECUTED ON ALL NODES.
#
# PARAMETERS 
#
# cmdline ./pcs-install.sp PCS_CLUSTER_PASSWORD_KEY
#
#
###############################################################################
#
if [ -z $2 ]; then
    echo '######## NO ARGS ########'
    exit 1
else
    echo '######## ARGS OK ########'
fi
set -e
PCS_CLUSTER_LOGIN=$1
#
echo "Using pcs_cluster_login=$PCS_CLUSTER_LOGIN"
PCS_CLUSTER_PASSWORD_KEY=$2
PCS_CLUSTER_PASSWORD=$(aws ssm get-parameter --name $PCS_CLUSTER_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value) # MOVE to command and use whole.
#
###############################################################################
#
# MAIN 
#
###############################################################################
#
echo '-- Pacemaker Instalation Starting'
#
echo '-- Installing Pacemaker and RequiredResource Agents'
#
sudo apt -y install pacemaker pcs fence-agents resource-agents
#
echo '--- Installing PCSD Daemon'
#
sudo systemctl enable pcsd
sudo systemctl start pcsd
#
echo '--- Disable Pacemaker and Corosync Daemons'
#
sudo systemctl disable pacemaker.service
sudo systemctl disable corosync.service
#
echo '-- Set HA Cluster user password'
#
echo "$PCS_CLUSTER_LOGIN:$PCS_CLUSTER_PASSWORD" | sudo chpasswd
#
echo '-- Pacemaker Cluster Installation Completed'
#
echo '-- Running fence_aws path'
# fence_awc patch - this patch installs fence_aws version 4.5.2
wget --retry-on-http-error=500,502,503 http://launchpadlibrarian.net/448473810/fence-agents_4.5.2-1_amd64.deb
sudo apt install ./fence-agents_4.5.2-1_amd64.deb -y
#
# resource-agents - this patch installs resource-agents version 4.5.0-2
wget --retry-on-http-error=500,502,503 https://launchpad.net/ubuntu/+archive/primary/+files/resource-agents_4.5.0-2ubuntu2_amd64.deb
sudo apt install ./resource-agents_4.5.0-2ubuntu2_amd64.deb -y

rm $PWD/resource-agents_4.5.0-2ubuntu2_amd64.deb
rm $PWD/fence-agents_4.5.2-1_amd64.deb
#
echo '--- System Patch'
# END
#
