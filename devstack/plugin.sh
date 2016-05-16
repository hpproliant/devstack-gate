#!/bin/bash
#
# Copyright 2015 Hewlett-Packard Development Company, L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

# Defaults
# --------

# Set up default directories
GITDIR["proliantutils"]=$DEST/proliantutils
GITREPO["proliantutils"]=${PROLIANTUTILS_REPO:-${GIT_BASE}/openstack/proliantutils.git}
GITBRANCH["proliantutils"]=${PROLIANTUTILS_BRANCH:-master}

ILO_DRIVER_PLUGIN_NAME="ironic_ilo_driver"

# The names for parameters in driver_info of a bare metal node.
IRONIC_DEPLOY_KERNEL_KEY=deploy_kernel
IRONIC_DEPLOY_RAMDISK_KEY=deploy_ramdisk
IRONIC_DEPLOY_ISO_KEY=ilo_deploy_iso

# Absolute path of the user image may be specified in this variable.
# If this is partition image, the user image kernel and user image ramdisk
# may also be specified.
IRONIC_USER_IMAGE=${IRONIC_USER_IMAGE:-}
IRONIC_USER_IMAGE_KERNEL=${IRONIC_USER_IMAGE_KERNEL:-}
IRONIC_USER_IMAGE_RAMDISK=${IRONIC_USER_IMAGE_RAMDISK:-}

# Preferred distro for the user image. If absolute path of the user image
# is specified, this should be specified to convey the instance user to
# tempest.
IRONIC_USER_IMAGE_PREFERRED_DISTRO=${IRONIC_USER_IMAGE_PREFERRED_DISTRO:-}

# This variable conveys if whole disk user image is to be used.
IRONIC_WHOLE_DISK_USER_IMAGE=$(trueorfalse False IRONIC_WHOLE_DISK_USER_IMAGE)

# The information about ProLiant hardware to be registered as Ironic node.
# This is of the following format:
#   <ip-address of ilo> <mac address> <ilo username> <ilo password> <size of root disk>
IRONIC_ILO_HWINFO=${IRONIC_ILO_HWINFO-}

# Set this variable to the subnet in which iLO NICs are present. Leave this
# empty if iLO NICs are in the same subnet as that of server NICs.
IRONIC_ILO_NETWORK=${IRONIC_ILO_NETWORK:-}

# Returns 0 if whole disk image, 1 otherwise.
function is_whole_disk_image_required {
    is_deployed_by_agent || [[ "$IRONIC_WHOLE_DISK_USER_IMAGE" == "True" ]] && return 0
    return 1
}

function prepare_deploy_image {

    local output_file_prefix
    local cloud_image
    local cloud_image_kernel
    local cloud_image_ramdisk

    # NOTE(rameshg87): Some thing in lib/tempest install python-requests as a
    # dependency in the end due to which uploading images to glance fails.
    # requests library is already installed via pip, so just uninstall the one
    # installed through apt-get. This is a no-op if python-requests isn't
    # installed.
    sudo apt-get -y purge python-requests

    if [ -z "$IRONIC_USER_IMAGE" ]; then
        if is_whole_disk_image_required; then
            output_file_prefix="${TOP_DIR}/files/${IRONIC_USER_IMAGE_PREFERRED_DISTRO}-cloud-image-disk"
        else
            output_file_prefix="${TOP_DIR}/files/${IRONIC_USER_IMAGE_PREFERRED_DISTRO}-cloud-image"
        fi

        cloud_image="${output_file_prefix}.qcow2"
        cloud_image_kernel="${output_file_prefix}.vmlinuz"
        cloud_image_ramdisk="${output_file_prefix}.initrd"
        DEFAULT_IMAGE_NAME=$(basename $output_file_prefix)
    else
        cloud_image=$IRONIC_USER_IMAGE
        cloud_image_kernel=$IRONIC_USER_IMAGE_KERNEL
        cloud_image_ramdisk=$IRONIC_USER_IMAGE_RAMDISK
        DEFAULT_IMAGE_NAME=$(basename $cloud_image)
    fi


    if [ ! -e "$cloud_image" ] || \
            ( ! is_whole_disk_image_required &&  \
              [ ! -e "$cloud_image_kernel" ] && \
              [ ! -e "$cloud_image_ramdisk" ] ); then

        DISK_IMAGE_CREATE_ELEMENTS="$IRONIC_USER_IMAGE_PREFERRED_DISTRO dhcp-all-interfaces"
        if is_whole_disk_image_required; then
            DISK_IMAGE_CREATE_ELEMENTS+=" vm"
        else
            DISK_IMAGE_CREATE_ELEMENTS+=" baremetal grub2"
        fi

        DIB_CLOUD_INIT_DATASOURCES="ConfigDrive, OpenStack" disk-image-create \
            -o "$output_file_prefix" "$DISK_IMAGE_CREATE_ELEMENTS"
    fi

    local token
    token=$(openstack token issue -c id -f value)
    die_if_not_set $LINENO token "Keystone fail to get token"

    IMAGE_META=""
    if ! is_whole_disk_image_required; then
        local cloud_image_kernel_uuid=$(openstack \
            --os-token "$token" \
            --os-url "http://$GLANCE_HOSTPORT" \
            image create \
            $(basename $cloud_image_kernel) \
            --public --disk-format=aki \
            --container-format=aki \
            < "$cloud_image_kernel" | grep ' id ' | get_field 2)

        local cloud_image_ramdisk_uuid=$(openstack \
            --os-token "$token" \
            --os-url "http://$GLANCE_HOSTPORT" \
            image create \
            $(basename $cloud_image_ramdisk) \
            --public --disk-format=ari \
            --container-format=ari \
            < "$cloud_image_ramdisk" | grep ' id ' | get_field 2)

        IMAGE_META+=" --property ramdisk_id=$cloud_image_ramdisk_uuid "
        IMAGE_META+=" --property kernel_id=$cloud_image_kernel_uuid "
    fi

    local cloud_image_uuid=$(openstack \
        --os-token "$token" \
        --os-url "http://$GLANCE_HOSTPORT" \
        image create \
        $DEFAULT_IMAGE_NAME \
        --public --disk-format=qcow2 \
        --container-format=bare \
        $IMAGE_META \
        < "$cloud_image" | grep ' id ' | get_field 2)

    iniset $TEMPEST_CONFIG baremetal active_timeout 3000
    iniset $TEMPEST_CONFIG baremetal power_timeout 600

    iniset $TEMPEST_CONFIG compute build_timeout 3000

    # Note(nisha): 551 was the earlier hardcoded flavor value created by Ironic.
    # Now that Ironic has changed that to take the dynamically created value as
    # the flavor id for baremetal, it takes the value from ``nova flavor-list``
    local FLAVOR_ID=$(nova flavor-list | grep 'baremetal' | awk '{print $2}')
    iniset $TEMPEST_CONFIG compute flavor_ref $FLAVOR_ID
    iniset $TEMPEST_CONFIG compute flavor_ref_alt $FLAVOR_ID

    iniset $TEMPEST_CONFIG compute ssh_user $IRONIC_USER_IMAGE_PREFERRED_DISTRO
    iniset $TEMPEST_CONFIG compute image_ref $cloud_image_uuid
    iniset $TEMPEST_CONFIG compute image_ref_alt $cloud_image_uuid
    iniset $TEMPEST_CONFIG compute image_ssh_user $IRONIC_USER_IMAGE_PREFERRED_DISTRO
    iniset $TEMPEST_CONFIG compute network_for_ssh $PHYSICAL_NETWORK
    iniset $TEMPEST_CONFIG compute image_alt_ssh_user $IRONIC_USER_IMAGE_PREFERRED_DISTRO
    iniset $TEMPEST_CONFIG compute ssh_connect_method fixed
    iniset $TEMPEST_CONFIG compute ssh_timeout 600

    iniset $TEMPEST_CONFIG scenario ssh_user $IRONIC_USER_IMAGE_PREFERRED_DISTRO

    iniset $TEMPEST_CONFIG validation ssh_timeout 600
    iniset $TEMPEST_CONFIG validation connect_method fixed
    iniset $TEMPEST_CONFIG validation network_for_ssh $PHYSICAL_NETWORK
    iniset $TEMPEST_CONFIG validation image_ssh_user $IRONIC_USER_IMAGE_PREFERRED_DISTRO


    # NOTE(rameshg87): Disable debug logging in tempest as it throws up the
    # below error:
    #   Length too long: 5689789
    #   error: testr failed (3)
    #
    # On searching in the internet, this seems to be because of huge size of
    # logs inside .testrepository because debug logging is enabled. We don't
    # require debug logging in tempest to triage most of the issues.
    iniset $TEMPEST_CONFIG DEFAULT debug False
}

function enroll_ilo_hardware {

    if [ -z "$IRONIC_ILO_HWINFO" ]; then
        return
    fi

    local ironic_node_cpu=$IRONIC_HW_NODE_CPU
    local ironic_node_ram=$IRONIC_HW_NODE_RAM
    local ironic_node_disk=$IRONIC_HW_NODE_DISK

    local hardware_info=${IRONIC_ILO_HWINFO}
    local ilo_address=$(echo $hardware_info |awk  '{print $1}')
    local mac_address=$(echo $hardware_info |awk '{print $2}')
    local ilo_username=$(echo $hardware_info |awk '{print $3}')
    local ilo_passwd=$(echo $hardware_info |awk '{print $4}')
    local root_device_hint=$(echo $hardware_info |awk '{print $5}')

    local node_options="-i ilo_address=$ilo_address "
    node_options+="-i ilo_password=$ilo_passwd "
    node_options+="-i ilo_username=$ilo_username "

    if [ "$IRONIC_DEPLOY_DRIVER" = "pxe_ilo" ]; then
        node_options+=" -i $IRONIC_DEPLOY_KERNEL_KEY=$IRONIC_DEPLOY_KERNEL_ID"
        node_options+=" -i $IRONIC_DEPLOY_RAMDISK_KEY=$IRONIC_DEPLOY_RAMDISK_ID"
    else
        node_options+=" -i $IRONIC_DEPLOY_ISO_KEY=$IRONIC_DEPLOY_ISO_ID"
    fi

    if [ -n "$root_device_hint" ]; then
        node_options+=' -p root_device="{\"size\": \"$root_device_hint\"}"'
    fi

    local node_id=$(ironic node-create \
                    -d $IRONIC_DEPLOY_DRIVER \
                    -p cpus=$ironic_node_cpu \
                    -p memory_mb=$ironic_node_ram \
                    -p local_gb=$ironic_node_disk \
                    -p cpu_arch=x86_64 \
                    $node_options \
                    | grep " uuid " | get_field 2)

    ironic port-create --address $mac_address --node $node_id

    wait_for_nova_resources "count" 1
    wait_for_nova_resources "vcpus" $ironic_node_cpu
}

function install_proliantutils {
    echo "Installing proliantutils library"
    if use_library_from_git "proliantutils"; then
        git_clone_by_name "proliantutils"
        setup_dev_lib "proliantutils"
    else
        sudo -E pip install -U proliantutils
    fi
}

# This hack is required because soon after stack is up
# and running, no IPs in the baremetal network is pingable.  On
# experimenatation it was found that flushing and reassigning IP of
# PUBLIC_INTERFACE solves the issue.
function flush_and_reassign_ovs_interface {
    if is_provider_network; then
        local ip=$(ip addr show dev $OVS_PHYSICAL_BRIDGE | grep ' inet ' | awk '{print $2}')
        sudo ip addr flush dev $OVS_PHYSICAL_BRIDGE
        sudo ip addr add $ip dev $OVS_PHYSICAL_BRIDGE
    fi
}

function add_ilo_network_gateway {
    if [ -n "$IRONIC_ILO_NETWORK" ] && is_provider_network; then
        sudo ip route add $IRONIC_ILO_NETWORK via $NETWORK_GATEWAY dev $OVS_PHYSICAL_BRIDGE
    fi
}

function change_tempest_os_test_timeout {
    # Change tempest timeout to 3000.
    local tempest_tox="$TEMPEST_DIR/tox.ini"
    sed -i -e "s/OS_TEST_TIMEOUT=[[:digit:]]\+/OS_TEST_TIMEOUT=3000/g" $tempest_tox
}

# We use the same agent ramdisk for all 3 drivers.  But devstack lib/ironic
# creates a new ramdisk with different names ir-deploy-pxe_ilo.*,
# ir-deploy-iscsi_ilo.* and ir-deploy-agent_ilo.*. There is no need
# to build the ramdisk again for every driver.  To avoid building the ramdisk
# for each driver we do the following:
#
# 1) Whenever one ramdisk is available from any of the drivers, we create a
#    soft link of master copy ir-deploy-master.*.
#
# 2) After creating the master copy, if ramdisk for this driver is not
#    available, we link the master copy to the ramdisk of this driver.
function ensure_deploy_ramdisk_soft_links {
    # TODO: This function doesn't consider the distro from which deploy ramdisk
    # was built.  Ensure we create softlinks only for ramdisk built from the
    # same distro.
    for file in kernel initramfs iso; do
        local master_path="$TOP_DIR/files/ir-deploy-master.$file"
        if [ ! -e "$master_path" ]; then
            for driver in pxe_ilo iscsi_ilo agent_ilo; do
                local driver_path=$TOP_DIR/files/ir-deploy-${driver}.${file}
                if [ -e "$driver_path" ]; then
                    ln -s $driver_path $master_path
                fi
            done
        fi
    done

    for file in kernel initramfs iso; do
        local driver_path=$TOP_DIR/files/ir-deploy-${IRONIC_DEPLOY_DRIVER}.${file}
        local master_path=$TOP_DIR/files/ir-deploy-master.${file}
        if [ ! -e "$driver_path" -a -e "$master_path" ]; then
            ln -s $master_path $driver_path
        fi
    done
}

if [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
    echo_summary "Pre-install phase of $ILO_DRIVER_PLUGIN_NAME"
    install_proliantutils
    ensure_deploy_ramdisk_soft_links
fi

if [[ "$1" == "stack" && "$2" == "extra" ]]; then
    echo_summary "Configuring for iLO hardware"
    prepare_deploy_image
    enroll_ilo_hardware

    # NOTE(rameshg87): Some hacks required.
    change_tempest_os_test_timeout
    flush_and_reassign_ovs_interface
    add_ilo_network_gateway
fi


