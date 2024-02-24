#!/bin/bash
###############################################################################
# Script Name	: PMC Cluster Node Preparation
# Description	: This script configures cluster nodes ready for the creation of 
#				a Placemaker cluster service.
# Created		: 12-June-2020
# Version		: 2.0
###############################################################################
#
# THIS SCRIPT MUST BE EXECUTED ON THE PRIMARY CLUSTER NODE ONLY!
#
# PARAMETERS
#
# cmdline ./pcs-config-phase-1.sh PCS_NODE_01 PCS_NODE_02 PCS_NODE_03 PCS_CLUSTER_NAME PCS_USER PCS_CLUSTER_PASSWORD_KEY MSSQL_LISTENER_NAME MSSQL_LISTENER_IPADDR MSSQL_AG_NAME  VPC_ROUTING_TABLE_ID STACK_ID
#
###############################################################################
#
set -e
IMDS_TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/instance-id 2> /dev/null)
VPC_ID=$(aws ec2 describe-instances --instance-id $INSTANCE_ID | jq -r .Reservations[0].Instances[0].VpcId)
echo $VPC_ID
PCS_NODE_01=$1 # PRIMARY NODE
echo $PCS_NODE_01
STACK_ID=${11}
PCS_NODE_01_ID=$(aws ec2 describe-instances --filters Name=vpc-id,Values=$VPC_ID --filters "Name=tag:Name,Values=$PCS_NODE_01" "Name=tag:aws:cloudformation:logical-id,Values=ClusterNode1" "Name=tag:aws:cloudformation:stack-id,Values="$STACK_ID | jq -r .Reservations[0].Instances[0].InstanceId)
echo "Node 1 Instance ID $PCS_NODE_01_ID"
#
PCS_NODE_02=$2 # SECONDARY NODE
echo $PCS_NODE_02
PCS_NODE_02_ID=$(aws ec2 describe-instances --filters Name=vpc-id,Values=$VPC_ID --filters "Name=tag:Name,Values=$PCS_NODE_02" "Name=tag:aws:cloudformation:logical-id,Values=ClusterNode2" "Name=tag:aws:cloudformation:stack-id,Values="$STACK_ID | jq -r .Reservations[0].Instances[0].InstanceId)
echo "Node 2 Instance ID $PCS_NODE_02_ID"
#
PCS_NODE_03=$3 # QUORAM NODE
echo $PCS_NODE_03
PCS_NODE_03_ID=$(aws ec2 describe-instances --filters Name=vpc-id,Values=$VPC_ID --filters "Name=tag:Name,Values=$PCS_NODE_03" "Name=tag:aws:cloudformation:logical-id,Values=ClusterNode3" "Name=tag:aws:cloudformation:stack-id,Values="$STACK_ID | jq -r .Reservations[0].Instances[0].InstanceId)
echo "Node 3 Instance ID $PCS_NODE_03_ID"

PCS_CLUSTER_NAME=$4 
echo $PCS_CLUSTER_NAME

PCS_USER=$5
echo $PCS_USER

PCS_CLUSTER_PASSWORD_KEY=$6
PCS_CLUSTER_PASSWORD=$(aws ssm get-parameter --name $PCS_CLUSTER_PASSWORD_KEY --with-decryption | jq -r .Parameter.Value)

MSSQL_LISTENER_NAME=$7
echo $MSSQL_LISTENER_NAME
MSSQL_LISTENER_IPADDR=$8
echo $MSSQL_LISTENER_IPADDR

MSSQL_AG_NAME=$9
echo $MSSQL_AG_NAME

VPC_ROUTING_TABLE_ID=${10}
echo $VPC_ROUTING_TABLE_ID

REGION=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
echo $REGION
#
###############################################################################
#
# Main 
#
###############################################################################
#
echo '-- Pacemaker Configuration Starting'
#
echo '-- Authorising Configuring PCS Cluster'
#
sudo pcs cluster auth ${PCS_NODE_01,,} ${PCS_NODE_02,,} ${PCS_NODE_03,,} -u $PCS_USER -p $PCS_CLUSTER_PASSWORD
#
echo '-- Creating PCS Cluster'
#
sudo pcs cluster setup --name $PCS_CLUSTER_NAME ${PCS_NODE_01,,} ${PCS_NODE_02,,} ${PCS_NODE_03,,} -u $PCS_USER -p $PCS_CLUSTER_PASSWORD --force
#
echo '-- Enable and Start PCS Cluster'
#
sudo pcs cluster start --all --wait
#
echo '-- Setting PCS cluster properties'
#
sudo pcs property set stonith-enabled=true
#
sudo pcs property set start-failure-is-fatal=true
#
sudo pcs property set cluster-recheck-interval=1min
#
echo '--- Configuring Stonith Fencing'
#
sudo pcs stonith create clusterfence fence_aws region=$REGION pcmk_host_map="${PCS_NODE_01,,}:$PCS_NODE_01_ID;${PCS_NODE_02,,}:$PCS_NODE_02_ID;${PCS_NODE_03,,}:$PCS_NODE_03_ID" power_timeout=240 pcmk_reboot_timeout=480 pcmk_reboot_retries=4 --force
#
echo '--- Creating Cluster Resource Agent (AWS-VPC-MOVE-IP)'
#
sudo pcs resource create $MSSQL_LISTENER_NAME ocf:heartbeat:aws-vpc-move-ip ip=$MSSQL_LISTENER_IPADDR interface="ens5" routing_table=$VPC_ROUTING_TABLE_ID op monitor timeout="30s" interval="60s"
#
echo '-- Creating PCS MSSQL Resource Agents'
#
sudo pcs resource create $MSSQL_AG_NAME ocf:mssql:ag ag_name=$MSSQL_AG_NAME --master notify=true meta failure-time=60s --force
#
sudo pcs resource update $MSSQL_AG_NAME meta failure-timeout=60s
#
echo '--- Adding Cluster Colocation Constraints'
#
sudo pcs constraint colocation add $MSSQL_LISTENER_NAME with master $MSSQL_AG_NAME-master INFINITY --force ## with-rsc-role --force
#
echo '--- Adding Cluster Order Constraints'
#
sudo pcs constraint order promote $MSSQL_AG_NAME-master then start $MSSQL_LISTENER_NAME --force
#
echo '--- Pacemaker Cluster Configuration Completed'
#
# END
#