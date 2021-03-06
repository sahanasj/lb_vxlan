#!/bin/bash


# Grab the openstack credentials
source ~/openrc

if [ ! -z "`facter | grep kvm`" ] ;then
  arch=i386
else
  arch=amd64
fi

if [ -z "`glance image-list | grep trusty`" ] ;then
	if [ ! -f ./trusty-server-cloudimg-${arch}-disk1.img ] ; then
	  wget https://cloud-images.ubuntu.com/trusty/current/trusty-server-cloudimg-${arch}-disk1.img
    fi
glance image-create --name=trusty --disk-format=qcow2 --container-format=bare --is-public=true \
--file=./trusty-server-cloudimg-${arch}-disk1.img
fi

 
# Create user data if it doesn't exist
if [ ! -d ~/user.data ]; then
cat > ~/user.data <<EOF
#!/bin/bash

apt-get install vlan -y
echo 8021q >> /etc/modules
modprobe 8021q
vconfig add eth0 143
ip_host=`ip addr show eth0 | awk '/ inet / {print $2}' | cut -d/ -f1 | cut -d. -f4`
ifconfig eth0.143 	192.168.143.\$ip_host netmask 255.255.255.0 mtu 8950 up
EOF
fi

if [ -z "`nova keypair-list | grep root`" ] ;then
	ssh-keygen -t rsa -f ~/.ssh/id_rsa -N ''
	nova keypair-add --pub-key ~/.ssh/id_rsa.pub root
fi

# Create a vlan provider network against physnet1 on vlain 144
neutron net-create --tenant-id `keystone tenant-list | awk '/ openstack /  {print $2}'` \
  vlannet1 --shared --provider:network_type vlan --provider:physical_network physnet1 --provider:segmentation_id 144
neutron subnet-create --ip-version 4 --tenant-id `keystone tenant-list | awk '/ openstack / {print $2}'` \
 vlannet1 192.168.144.0/24 --allocation-pool start=192.168.144.100,end=192.168.144.200 --dns_nameservers \
 list=true 8.8.8.8

# Create a flat provider network against physnet2
neutron net-create --tenant-id `keystone tenant-list | awk '/ openstack /  {print $2}'` \
  sharednet1 --shared --provider:network_type flat --provider:physical_network physnet2
neutron subnet-create --ip-version 4 --tenant-id `keystone tenant-list | awk '/ openstack / {print $2}'` \
 sharednet1 192.168.149.0/24 --allocation-pool start=192.168.149.100,end=192.168.149.200 --dns_nameservers \
 list=true 8.8.8.8

# Create a tenant network which will default to vxlan
neutron net-create --tenant-id `keystone tenant-list | awk '/ openstack /  {print $2}'` tenantnet1
neutron subnet-create --ip-version 4 --tenant-id `keystone tenant-list | awk '/ openstack / {print $2}'` \
 tenantnet1 192.168.0.0/24 --allocation-pool start=192.168.0.100,end=192.168.0.200 --dns_nameservers \
 list=true 8.8.4.4

nova boot --flavor 2 --image trusty --nic net-id=`neutron net-list | awk '/ sharednet1 /  {print $2}'` \
  --nic net-id=`neutron net-list | awk '/ tenantnet1 / {print $2}'` --key-name root \
  --user-data ~/user.data vxa

nova boot --flavor 2 --image trusty --nic net-id=`neutron net-list | awk '/ sharednet1 / {print $2}'` \
  --nic net-id=`neutron net-list | awk '/ vlannet1 / {print $2}'` --key-name root \
  --user-data ~/user.data vxb

nova boot --flavor 2 --image trusty --nic net-id=`neutron net-list | awk '/ vlannet1 / {print $2}'` \
  --nic net-id=`neutron net-list | awk '/ tenantnet1 / {print $2}'` --key-name root \
  --user-data ~/user.data vxc
