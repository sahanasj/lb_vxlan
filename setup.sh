#!/bin/bash
# grab the puppet_openstack_builder code
# and update it if it doesn't have the right
# elements already defined for VLAN/VXLan/LB
# 
# Also, create a new scenario, and role mapping
# for this enviornment

set -o errexit

usage() {
cat <<EOF
usage: $0 options

OPTIONS:
-h                  Show this message
-p {proxy_address}  http proxy i.e. -p http://username:password@host:port/
-v {vlan}           single interface vlan to enable
-m                  set 8950 MTU
-r                  run install.sh for all_in_one/lb_vxlan use case
EOF
}
export -f usage


# wrapper all commands with sudo in case this is not run as root
# also map in a proxy in case it was passed as a command line argument
function run_cmd () {
  if [ -z "$PROXY" ]; then
    sudo $*
  else
    sudo env http_proxy=$PROXY https_proxy=$PROXY $*
  fi
}
export -f run_cmd

# Define some useful APT parameters to make sure you get the latest versions of code

APT_CONFIG="-o Acquire::http::No-Cache=True -o Acquire::BrokenProxy=true -o Acquire::Retries=3"

# check if the environment is set up for http and https proxies
if [ -n "$http_proxy" ]; then
  if [ -z "$https_proxy" ]; then
    echo "Please set https_proxy env variable."
    exit 1
  fi
  PROXY=$http_proxy
fi

function valid_ip()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

export valid_ip

# parse CLI options
while getopts "h:p:v:m:" OPTION
do
  case $OPTION in
    h)
      usage
      exit 1
      ;;
    p)
      PROXY=$OPTARG
      export http_proxy=$PROXY
      export https_proxy=$PROXY
      ;;
    v)
      VLAN=$OPTARG
      export vlan=$VLAN
      ;;
    m)
       export MTU=9000
      ;;
    r)
      export run_all_in_one=true
      ;;
  esac
done

if [ ${ARGV} eq "0" ] ;then
  usage()
  exit1
fi

# Make sure the apt repository list is up to date
echo -e "\n\nUpdate apt repository...\n\n"
if ! run_cmd apt-get $APT_CONFIG update; then
  echo "Can't update apt repository"
  exit 1
fi

# Install prerequisite packages
echo "Installing prerequisite apps: git, vlan, vim..."
if ! run_cmd apt-get $APT_CONFIG install -qym git vlan vim; then
  echo "Can't install prerequisites!..."
  exit 1
fi


echo "Enable 8021q module for VLAN config"
if [ -z "`grep 8021q /etc/modules`" ] ;then 
  echo 8021q >> /etc/modules
  modprobe 8021q
fi

if [ ! -z "${VLAN}" ] ;then
  while true; do
    while true; do
      read -ep "Enter the VLAN:${VLAN} IPv4 Address: " ip_address
      if ! valid_ip $ip_address ; then
        echo "That's not an IP address"
      else
        break
      fi
    done

    while true; do
      read -ep "Enter the VLAN:${VLAN} Netmask: " ip_netmask
      if ! valid_ip $ip_netmask ; then
        echo "That's not a valid IPv4 Netmask"
      else
        break
      fi
    done

    while true; do
      read -ep "Enter the VLAN:${VLAN} IPv4 Gateway: " ip_gateway
      if ! valid_ip $ip_gateway ; then
        echo "That's not a valid IPv4 address"
      else
        break
      fi
    done

    while true; do
      read -ep "Enter the initial VLAN:${VLAN} DNS Server IP Address: " dns_address
      if ! valid_ip $dns_address ; then
        echo "That's not a valid IPv4 address"
      else
        break
      fi
    done

    if [ ! "${MTU}" ] ;then
      while true; do
        read -n 1 -p "Do you want 9K MTU? [y|n]" yn
        case $yn in
          [Yy]* ) MTU=9000; echo 'MTU will be set to 8950, configure your VMs appropriately'; break;;
          [Nn]* ) echo 'MTU will remain default, it is recommened to set VM MTU to 1450';
        esac
      done
    fi

    echo -e "IP Address: $ip_address\nNetmask: $ip_netmask\nGateway: $ip_gateway\nDNS: $dns_address\nMTU: ${MTU:-1500}\n"
    read -n 1 -p "Is this correct [y|n]" yn
    case $yn in
      [Yy]* ) break;;
      [Nn]* ) echo "Try again."
    esac
  done

  initial_interface=`grep 'auto eth' /etc/network/interfaces | awk '{print $2}'`
  if [ ! -z $initial_interface ] ;then
    sed -e '/gateway/d ' -i /etc/network/interfaces
    dns_search=`grep dns-search /etc/network/interfaces | awk '{print $2}'`
    vconfig add $initial_interface $VLAN
    cat >> /etc/network/interfaces <<EOF
    auto $initial_interface.$VLAN
    iface $initial_interface.$VLAN inet static
    address $ip_address
    netmask $ip_netmask
    gateway $ip_gateway
    dns-nameserver $dns_server
    dns-search $dns_search
EOF
  fi

  if [ ! -z $MTU ]; then
    sed -e "/iface eth[0-9]/a mtu=${MTU}" -i /etc/network/interfaces
    echo "NOTE: You should reboot and log in on: $ip_address before proceeding"
  fi
fi

# Git clone puppet_openstack_builder from cisco
echo "Cloning puppet_openstack_builder branch from CiscoSystems github.com..."
if [ -d /root/puppet_openstack_builder ] ; then
  echo -e "Looks like perhaps you ran this script before? We'll try to update your os-docs directory, just in case..."
  if ! run_cmd git --git-dir=/root/puppet_openstack_builder/.git/ pull ; then
     echo "That did not work.  Perhaps rename your os-docs directory, and try again?"
     exit 1
        fi
fi

# Get a new set, as there was no previous download
if [ ! -d /root/puppet_openstack_builder ] ; then
  if ! run_cmd git clone -b icehouse https://github.com/CiscoSystems/puppet_openstack_builder /root/puppet_openstack_builder ; then
    echo "Can't run git clone!"
    exit 1
  fi
fi

# add ml2 parameters
cat >> /root/puppet_openstack_builder/data/hiera_data/user.common.yaml <<EOF
neutron::server::disableml2: false
EOF

# create scenario for lb_vxlan with no l3
if [ -f /root/puppet_openstack_builder/data/scenarios/all_in_one.yaml.orig ]; then
  echo -e "You've run this script already, please just run: \n  puppet apply -v /etc/pupppet/manifests/site.pp"
  exit 1
fi
echo "Over-write all_in_one.yaml scenario with lb_vxlan scenario (backup to .orig)"
cp /root/puppet_openstack_builder/data/scenarios/all_in_one.yaml{,.orig}
cat > /root/puppet_openstack_builder/data/scenarios/all_in_one.yaml <<EOF
#
# scenario for lb_vxlan
#
roles:
  :
    classes:
      - coe::base
       - "nova::%{rpc_type}"
    class_groups:
      - build
      - glance_all
      - keystone_all
      - cinder_controller
      - nova_controller
      - horizon
      - "%{db_type}_database"
      - nova_compute
      - cinder_volume
      - l2_network_controller
      - test_file
  compute:
    classes:
      - coe::base
    class_groups:
      - nova_compute
      - cinder_volume
EOF

# create classgroup for l2_network_controller
echo "Create a l2_newtork_controller class_group"
cat > /root/puppet_openstack_builder/data/class_groups/l2_network_controller.yaml <<EOF
classes:
  - "%{network_service}"
  - "%{network_service}::server"
  - "%{network_service}::server::notifications"
  - "%{network_service}::config"
  - "%{network_service}::agents::metadata"
  - "%{network_service}::agents::l3"
  - "%{network_service}::agents::lbaas"
  - "%{network_service}::agents::vpnaas"
  - "%{network_service}::agents::dhcp"
  - "%{network_service}::services::fwaas"
  - vxlan_lb::ml2
EOF

echo "Fix install.sh script to include cobbler_server in all_in_one/lb_vxlan model"
sed -e '/cobbler_server/d ' -i /root/puppet_openstack_builder/install-scripts/install.sh

echo "Add VXLan configuration to default user.yaml for all_in_one/lb_vxlan"
sed -e '/neutron::agents/a \
openstack_release: icehouse\
vni_ranges:\
 - 100:10000\
vxlan_group: 229.1.2.3\
flat_networks:\
 - physnet1\
physical_interface_mappings:\
 - physnet1:\${external_interface}\
' -i /root/puppet_openstack_builder/install-scripts/install.sh

echo "Add VXLan+LinuxBridge module to puppet_openstack_builder and copy over modules"
if [ ! -d /etc/puppet_openstack_builder/modules ] ;then
  mkdir -p /etc/puppet_openstack_builder/modules
fi
tar xfz vxlan_lb.tgz -C /root/puppet_openstack_builder/modules/
if [ ! "`grep builder\/modules /root/puppet_openstack_builder/install-scripts/install.sh`" ] ;then
sed -e '/builder\/manifests/a cp -R ~\/puppet_openstack_builder\/modules \/etc\/puppet\/' \
  -i /root/puppet_openstack_builder/install-scripts/install.sh
fi

echo "It is recomended that you reboot and log in via the newly defined IP address: ${ip_address}"

# Run all_in_one deployment?
#if [ ! -z "${run_all_in_one}" ] ;then
#  (cd /etc/puppet_openstack_builder/install-scripts; export external_interface=$external_interface; \
#    export default_interface=$default_interface; ./install.sh)
#fi

# reboot
