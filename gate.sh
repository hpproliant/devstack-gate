#!/bin/bash -x

# Gate script for running tempest tests with iLO drivers in different
# configurations.  The following environment variables are expected:
#
# ILO_HWINFO_GEN8_SYSTEM - Hardware info for Gen8 system.
# ILO_HWINFO_GEN9_SYSTEM - Hardware info for Gen9 system.
# IRONIC_ELILO_EFI - Absolute path of elilo.efi file
# IRONIC_FEDORA_SHIM - Absolute path of fedora signed shim.efi
# IRONIC_FEDORA_GRUBX64 - Absolute path of fedora signed grubx64.efi
# IRONIC_UBUNTU_SHIM - Absolute path of ubuntu signed shim.efi
# IRONIC_UBUNTU_GRUBX64 - Absolute path of grub signed grubx64.efi
# http_proxy - Proxy settings
# https_proxy - Proxy settings
# HTTP_PROXY - Proxy settings
# HTTPS_PROXY - Proxy settings
# no_proxy - Proxy settings

set -e
set -o pipefail

export PATH=$PATH:/var/lib/gems/1.8/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games
export DIB_DEPLOY_ISO_KERNEL_CMDLINE_ARGS="console=ttyS1"
export IRONIC_USER_IMAGE_PREFERRED_DISTRO=${IRONIC_USER_IMAGE_PREFERRED_DISTRO:-fedora}
export BOOT_OPTION=${BOOT_OPTION:-}
export SECURE_BOOT=${SECURE_BOOT:-}
export BOOT_LOADER=${BOOT_LOADER:-elilo}
export BOOT_LOADER=${LOGDIR:-/opt/stack/logs}
export IRONIC_IPA_RAMDISK_DISTRO=fedora

function stop_ilo_gate_process {
    local pid
    local stopped

    pid=$(pidof $1 || true)
    if [[ -n "$pid" ]]; then
        stopped=$(sudo kill $pid)
    fi
}

function stop_console {
    stop_ilo_gate_process "sshpass"
}

function stop_tcpdump {
    stop_ilo_gate_process "tcpdump"
}

# Workaround for killing left over glance processes
# TODO: Need to figure out why this happens.
function kill_glance_processes {
    local stopped

    for i in `ps -ef | grep -i '[g]lance' | awk '{print $2}'`
    do
        stopped=$(sudo kill $i)
    done
}

function run_stack {

    local ironic_node
    local capabilities
    local hardware_info
    local root_device_hint

    # Move the current local.conf to the logs directory.
    cp /opt/stack/devstack/local.conf $LOGDIR

    cd /opt/stack/devstack

    # Do unstack to make sure there aren't any previous leftover services.
    ./unstack.sh

    # Remove leftover glance processes and remove previous data.
    kill_glance_processes
    sudo rm -rf /opt/stack/data/*

    # Final environment variable list.
    echo "-----------------------------------"
    echo "Final list of environment variables"
    echo "-----------------------------------"
    env
    echo "-----------------------------------"

    # Run stack.sh
    ./stack.sh

    # Modify the node to reflect the boot_mode and secure_boot capabilities.
    # Also modify the nova flavor accordingly.
    source /opt/stack/devstack/openrc admin admin
    ironic_node=$(ironic node-list | grep -v UUID | grep "\w" | awk '{print $2}' | tail -n1)
    capabilities="boot_mode:$BOOT_MODE"
    if [[ "$BOOT_OPTION" = "local" ]]; then
        capabilities="$capabilities,boot_option:local"
        nova flavor-key baremetal set capabilities:boot_option="local"
    fi
    if [[ "$SECURE_BOOT" = "true" ]]; then
        capabilities="$capabilities,secure_boot:true"
        nova flavor-key baremetal set capabilities:secure_boot="true"
    fi
    ironic node-update $ironic_node add properties/capabilities="$capabilities"

    # Update the root device hint if it was specified for some node.
    hardware_info=${IRONIC_ILO_HWINFO}
    root_device_hint=$(echo $hardware_info |awk '{print $5}')
    if [[ -n "$root_device_hint" ]]; then
        ironic node-update $ironic_node add properties/root_device="{\"size\": \"$root_device_hint\"}"
    fi

    # Setup the bootloader for uefi.
    if [[ "$BOOT_LOADER" = "elilo" ]]; then
        # Copy elilo.efi (temporary workaround - add it to devstack)
        local dir
        dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
        cp $IRONIC_ELILO_EFI /opt/stack/data/ironic/tftpboot
    elif [[ "$BOOT_LOADER" = "grub2" ]]; then
        local ironic_tftpboot_path
        local ironic_map_file
        local grub_distro
        local grub_dir

        ironic_tftpboot_path=/opt/stack/data/ironic/tftpboot
        ironic_map_file=$ironic_tftpboot_path/map-file
        cat << 'EOF' > $ironic_map_file
re ^(/opt/stack/data/ironic/tftpboot/) /opt/stack/data/ironic/tftpboot/\2
re ^/opt/stack/data/ironic/tftpboot/ /opt/stack/data/ironic/tftpboot/
re ^(^/) /opt/stack/data/ironic/tftpboot/\1
re ^([^/]) /opt/stack/data/ironic/tftpboot/\1
EOF
        grub_distro="ubuntu"
        if [[ "$IRONIC_IPA_RAMDISK_DISTRO" = "fedora" ]]; then
            grub_distro="fedora"
        elif ([[ "$IRONIC_USER_IMAGE_PREFERRED_DISTRO" = "ubuntu-signed" ]] ||
            [[ "$IRONIC_USER_IMAGE_PREFERRED_DISTRO" = "ubuntu" ]] ||
            [[ "$IRONIC_USER_IMAGE_PREFERRED_DISTRO" = "ubuntu-signed" ]] ||
            [[ "$IRONIC_USER_IMAGE_PREFERRED_DISTRO" = "ubuntu" ]] ); then
            grub_distro="ubuntu"
        fi

        grub_dir=$ironic_tftpboot_path
        if [[ "$grub_distro" = "fedora" ]]; then
            cp $IRONIC_FEDORA_SHIM $ironic_tftpboot_path/bootx64.efi
            cp $IRONIC_FEDORA_GRUBX64 $ironic_tftpboot_path/grubx64.efi
            grub_dir=$ironic_tftpboot_path/EFI/fedora
        else
            cp $IRONIC_UBUNTU_SHIM $ironic_tftpboot_path/bootx64.efi
            cp $IRONIC_UBUNTU_GRUBX64 $ironic_tftpboot_path/grubx64.efi
            grub_dir=$ironic_tftpboot_path/grub
        fi
        mkdir -p $grub_dir
        cat << 'EOF' > $grub_dir/grub.cfg
set default=master
set timeout=5
set hidden_timeout_quiet=false

menuentry "master"  {
configfile /opt/stack/data/ironic/tftpboot/$net_default_ip.conf
}
EOF
        chmod 644 $grub_dir/grub.cfg

        sed -i '/uefi_pxe_config_template/c\uefi_pxe_config_template=$pybasedir/drivers/modules/pxe_grub_config.template' /etc/ironic/ironic.conf
        sed -i '/uefi_pxe_config_template/c\uefi_pxe_config_template=$pybasedir/drivers/modules/pxe_grub_config.template' /etc/ironic/ironic.conf
        sed -i '/uefi_pxe_bootfile_name/c\uefi_pxe_bootfile_name=bootx64.efi' /etc/ironic/ironic.conf
    fi

    #------------------------------------------------
    # Enable below lines to a put any temporary patches
    #------------------------------------------------
    # Temporary workaround until bug/1466729 is fixed
    #cd /opt/stack/ironic
    #<PUT TEMPORARY PATCHES HERE>
    #screen -S stack -p ir-cond -X stuff 
    #screen -S stack -p ir-cond -X stuff '/usr/local/bin/ironic-conductor --config-file=/etc/ironic/ironic.conf & echo $! >/opt/stack/status/stack/ir-cond.pid; fg || echo "ir-cond failed to start" | tee "/opt/stack/status/stack/ir-cond.failure"\r'
    #------------------------------------------------

    # Sleep for a while for resource changes to be reflected.
    #sleep 60

    # Stop any previous console and tcpdump processes.
    stop_console
    stop_tcpdump

    # Get the iLO IP, username and password and start logging bare metal console.
    local ilo_ip
    local ilo_username
    local ilo_password
    ilo_ip=$(echo $hardware_info |awk  '{print $1}')
    ilo_username=$(echo $hardware_info |awk '{print $3}')
    ilo_password=$(echo $hardware_info |awk '{print $4}')
    ssh-keygen -R $ilo_ip
    ssh-keyscan -H $ilo_ip > ~/.ssh/known_hosts
    sshpass -p $ilo_password ssh $ilo_ip -l $ilo_username vsp >& $LOGDIR/console &

    # Enable tcpdump for pxe drivers
    if [[ "$ILO_DRIVER" = "pxe_ilo" ]]; then
        local interface
        interface=$(awk -F'=' '/PUBLIC_INTERFACE/{print $2}' /opt/stack/devstack/local.conf)
        if [[ -n "$interface" ]]; then
            sudo tcpdump -i $interface | grep -i DHCP >& $LOGDIR/tcpdump &
        fi
    fi

    # Run the tempest test.
    cd /opt/stack/tempest
    export OS_TEST_TIMEOUT=3000
    tox -eall -- test_baremetal_server_ops

    # Stop console and tcpdump processes.
    stop_console
    stop_tcpdump
}

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
evalInstructions=$(python $DIR/parsing_n_executing_jenny_data.py "$JENNY_INPUT")
eval "$evalInstructions"

sudo chmod 777 $WORKSPACE
sudo rm -rf $WORKSPACE/*
export LOGDIR=$WORKSPACE

run_stack
