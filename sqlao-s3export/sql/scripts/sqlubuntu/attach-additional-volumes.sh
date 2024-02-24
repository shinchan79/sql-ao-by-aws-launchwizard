#!/bin/bash
###############################################################################
# Script Name	: Attach Additional Volumes
# Description	: This script creates, attaches and configures additional EBS volumes for MSSQL on each cluster nodes ready
#                1 each for tempdb,logs,backup,data.
###############################################################################
#
# THIS SCRIPT MUST BE EXECUTED ON ALL NODES!
#
# PARAMETERS
# ./attach-additional-volumes.sh 500,500,500,500 /dev/sdm,/dev/sdn,/dev/sdo,/dev/sdp tempdb,data,logs,backup \
# gp2,gp2,gp2,gp2 5000,5000,5000,5000 LaunchWizardResourceGroupId 1 1 Tag1Key,Tag1Value,Tag2Key,Tag2Value


if [ -z $7 ]; then
    echo '######## Need 7 ARGS ########'
    exit 1
else
    echo '######## ARGS OK ########'
fi

set -e

VOLUME_SIZES=(${1//,/ })
DEVICE_IDS=(${2//,/ })
DEVICE_NAMES=(${3//,/ })
VOLUME_TYPES=(${4//,/ })
VOLUME_IOPS=(${5//,/ })
LW_RESOURCE_GROUP_ID=$6
NUM_CUSTOM_TAGS=$7

#
IMDS_TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

REGION=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
echo $REGION

AVAILABILITY_ZONE=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/placement/availability-zone)
echo $AVAILABILITY_ZONE

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" -v http://169.254.169.254/latest/meta-data/instance-id)
echo $INSTANCE_ID

INSTANCE=$(aws ec2 describe-instances --instance-id=$INSTANCE_ID  | jq ".Reservations[0].Instances[0]")
echo $INSTANCE

ROOT_DEVICE_NAME=$(echo ${INSTANCE} | jq ".RootDeviceName")
ROOT_VOLUME_ID=$(echo ${INSTANCE} | jq -r ".BlockDeviceMappings[] | select(.DeviceName == $ROOT_DEVICE_NAME)".Ebs.VolumeId)
MSSQL_ROOT_DIR="/var/opt/mssql/data"
#
#
#
# ################################## MAIN #####################################
#
################################################################################
#
#
echo '---'
echo '--- Creating Disk Volumes'
echo '---'
#
declare -A GLOBAL_TAGS=( ["LaunchWizardResourceGroupID"]=${LW_RESOURCE_GROUP_ID} ["LaunchWizardApplicationType"]=SQL_SERVER_LINUX )
declare -a global_tag_list=()
declare -a root_volume_global_tag_list=()

for key in "${!GLOBAL_TAGS[@]}";
    do
        global_tag_list+=("{Key=${key},Value=${GLOBAL_TAGS[${key}]}}");
        root_volume_global_tag_list+=("{\"Key\":\"${key}\",\"Value\":\"${GLOBAL_TAGS[${key}]}\"}");
    done

GLOBAL_TAG_SPECS="[$(IFS=','; echo "${global_tag_list[*]}")]"

declare -A CUSTOM_TAGS=()
declare -a custom_tag_list=()

if [ ${NUM_CUSTOM_TAGS} -ne 0 ]; then
    # Process custom tags and add to TAGS dictionary

    INPUT_CUSTOM_TAGS=(${8//,/ })
    declare -i tagNumber=0
    while [[ ${tagNumber} -lt $((NUM_CUSTOM_TAGS*2)) ]]
        do
            CUSTOM_TAGS["${INPUT_CUSTOM_TAGS[$tagNumber]}"]=${INPUT_CUSTOM_TAGS[$(($tagNumber+1))]}
            tagNumber=tagNumber+2
        done

    for key in "${!CUSTOM_TAGS[@]}";
        do
            custom_tag_list+=("Key=${key},Value=${CUSTOM_TAGS[${key}]}");
        done
fi

blkdev_template="[{\"DeviceName\":\"DEVICE_STRING\",\"Ebs\":{\"DeleteOnTermination\":true}}]"

declare -i numExtDevices=$(nvme list -o json | jq '.["Devices"] | length')

MAPPED_DEVICES=( \
    "/dev/nvme${numExtDevices}n1" \
    "/dev/nvme$((numExtDevices+1))n1" \
    "/dev/nvme$((numExtDevices+2))n1" \
    "/dev/nvme$((numExtDevices+3))n1" \
)

declare -i index=0

for mappedDevice in "${MAPPED_DEVICES[@]}"
    do
        sizeGB=${VOLUME_SIZES[${index}]}
        deviceId=${DEVICE_IDS[${index}]}
        mssqlDisk=${DEVICE_NAMES[${index}]}
        volumeType=${VOLUME_TYPES[${index}]}
        #
        echo '---'
        echo "--- Creating Volume for $mssqlDisk"
        echo '---'
        #
        VOLUMECMD="aws ec2 create-volume --encrypted --region ${REGION} \
                    --availability-zone ${AVAILABILITY_ZONE} \
                    --size ${sizeGB} \
                    --volume-type ${volumeType}\
                    --encrypted  \
                    --tag-specifications ResourceType=volume,Tags=${GLOBAL_TAG_SPECS}"
        if [[ "$volumetype" == "io1" ]] || [[ "$volumetype" == "io2" ]];
         then
            iops=${VOLUME_IOPS[${index}]}
            echo "VolumeType is io. Applying IOPS $iops"
            VOLUMECMD+=" --iops $iops"
        fi
        #
        volume=`${VOLUMECMD}`
        volumeId=`echo ${volume}|jq '.VolumeId'`
        volumeId="${volumeId%\"}"
        volumeId="${volumeId#\"}"
        echo "--- Volume ID ${volumeId} Successfully Created"
        if [ -z ${volumeId+x} ]; then
            echo "Volume ID " ${volumeId} "Failed To Create"
            exit -1;
        fi
        echo '--- Waiting For Volume' ${volumeId} 'To Be Fully Available'
        aws ec2 wait volume-available --volume-ids ${volumeId}

        if (( ${#custom_tag_list[@]} )); then
            echo '---- Creating custom tags on ' ${volumeId}
            aws ec2 create-tags --resource ${volumeId} --tags ${custom_tag_list[@]}
        fi

        echo '--- Attaching Volume ID ' ${volumeId}
        aws ec2 attach-volume --volume-id ${volumeId} --instance-id ${INSTANCE_ID} --device ${deviceId} ##################
        while [ ! -e ${mappedDevice} ];
        do
            ## TODO: Potential infinite loop
            echo 'Waiting for Volume' ${volumeId} 'To Attach To' ${mappedDevice}
            sleep 10
        done

	    echo "--- Set DeleteOnTermination=true for ${deviceId} on ${volumeId} "
	    blkdev_json=$(echo -n ${blkdev_template} | sed "s:DEVICE_STRING:$deviceId:")
        aws ec2 modify-instance-attribute --region ${REGION} --instance-id ${INSTANCE_ID} --block-device-mappings ${blkdev_json}
        #
        echo '--- Format Disk'
        #
        sudo mkfs.ext4 -L $mssqlDisk ${mappedDevice} -F ##  changed ##
        #
        echo '--- Create Mount Point'
        #
        MOUNTPOINT="$MSSQL_ROOT_DIR/$mssqlDisk"  ## changed ##
        #
        echo '--- Make Mount Point Directory'
        #
        sudo mkdir -p ${MOUNTPOINT}
        #
        echo '--- Mount Disk' $mssqlDisk
        #
        sudo mount LABEL="\""$mssqlDisk"\"" $MOUNTPOINT
        #
        echo '--- Disk' $mssqlDisk 'Created and Configured'
        #
        echo '--- Update /etc/fstab'
        #
        # echo "${mappedDevice}       ${MOUNTPOINT}                   ext4 defaults,nofail,auto        0 0" >> /etc/fstab
        echo "LABEL=$mssqlDisk ${MOUNTPOINT} ext4 defaults,nofail   0 0" >> /etc/fstab
        #
        index=index+1
    done

    echo '---- Creating global tags on ' ${ROOT_VOLUME_ID}
    aws ec2 create-tags --resource ${ROOT_VOLUME_ID} --tags ${root_volume_global_tag_list[@]}
#