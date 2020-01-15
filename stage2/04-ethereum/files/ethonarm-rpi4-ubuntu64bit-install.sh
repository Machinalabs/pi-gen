#!/bin/bash
#
# Copyright (c) Ethereum on ARM
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# https://github.com/diglos/pi-gen
#
# This script turns James Chambers Ubuntu 64bit image for Raspberry Pi 4 into a full Ethereum node
# You need to install a Raspbian image and run the script "ethonarm-rpi4-ubuntu64bit-setup.sh" before running this script
#
# More information about the image here:
#
# https://jamesachambers.com/raspberry-pi-4-ubuntu-server-desktop-18-04-3-image-unofficial/
# https://github.com/TheRemote/Ubuntu-Server-raspi4-unofficial
#

# Modify hostname (ethnode-$MAC-HASH-CHUNK)
echo Changing hostname
MAC_HASH=`cat /sys/class/net/eth0/address | sha256sum | awk '{print substr($0,0,9)}'`
echo ethnode-$MAC_HASH > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\tethnode-$MAC_HASH/g" /etc/hosts

# Mount /home and add entry to fstab
echo Mounting /home
mount /dev/sda1 /home
echo '/dev/sda1 /home ext4 defaults 0 2' >> /etc/fstab

# Create Ethereum account
echo "Creating ethereum  user"
if ! id -u ethereum >/dev/null 2>&1; then
        adduser --disabled-password --gecos "" ethereum
fi

echo "ethereum:ethereum" | chpasswd
for GRP in sudo netdev audio video dialout plugdev bluetooth; do
	adduser ethereum $GRP
done

# Force password change on first login for security reasons
chage -d 0 ethereum


# Create some swap memory in the USB device for avoiding memory issues.
echo "Creating swap memory and activating Zram"
if stat  /dev/sda > /dev/null 2>&1;
then
	mkdir -p /home/ethereum/swap
	dd if=/dev/zero of=/home/ethereum/swap/swapfile bs=16k count=256k
	chmod 600 /home/ethereum/swap/swapfile
	mkswap /home/ethereum/swap/swapfile
	swapon /home/ethereum/swap/swapfile
	echo "/home/ethereum/swap/swapfile none swap sw 0 0" >> /etc/fstab
else
	echo no swap created
fi

mkdir -p /usr/lib/armbian
# Enable Zram (based on ARMBIAN script)
cat << EOF | tee /etc/default/armbian-zram-config >/dev/null
# configuration values for the armbian-zram-config service
#
# enable the armbian-zram-config service
ENABLED=true
ZRAM_PERCENTAGE=25
EOF

# Enable Zram (ARMBIAN script)
cat << 'EOF' | tee /usr/lib/armbian/armbian-zram-config >/dev/null
#!/bin/bash
#
# Copyright (c) Authors: http://www.armbian.com/authors
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.

# Functions:
#
# activate_zram_swap
# activate_ramlog_partition
# activate_compressed_tmp


# Read in basic OS image information
#. /etc/armbian-release
# and script configuration
#. /usr/lib/armbian/armbian-common

# It's possible to override ZRAM_PERCENTAGE, ZRAM_MAX_DEVICES, SWAP_ALGORITHM,
# RAMLOG_ALGORITHM and TMP_ALGORITHM here:
[ -f /etc/default/armbian-zram-config ] && . /etc/default/armbian-zram-config

activate_zram_swap() {
	# Do not interfere with already present config-zram package
	dpkg -l | grep -q 'zram-config' && exit 0

	[[ "$ENABLED" != "true" ]] && exit 0

	# Load zram module with n instances for swap: one per CPU core, $ZRAM_MAX_DEVICES
	# defines the maximum, on modern kernels we overwrite this with 1 and rely on
	# max_comp_streams being set to count of CPU cores or $ZRAM_MAX_DEVICES
	uname -r | grep -q '^3.' && zram_max_devs=${ZRAM_MAX_DEVICES:=4} || zram_max_devs=1
	cpu_cores=$(grep -c '^processor' /proc/cpuinfo | sed 's/^0$/1/')
	[[ ${cpu_cores} -gt ${zram_max_devs} ]] && zram_devices=${zram_max_devs} || zram_devices=${cpu_cores}
	module_args="$(modinfo zram | awk -F" " '/num_devices/ {print $2}' | cut -f1 -d:)"
	[[ -n ${module_args} ]] && modprobe zram ${module_args}=$(( ${zram_devices} + 2 )) || return

	# Expose 50% of real memory as swap space by default
	zram_percent=${ZRAM_PERCENTAGE:=50}
	mem_info=$(LC_ALL=C free -w 2>/dev/null | grep "^Mem" || LC_ALL=C free | grep "^Mem")
	memory_total=$(awk '{printf("%d",$2*1024)}' <<<${mem_info})
	mem_per_zram_device=$(( ${memory_total} / ${zram_devices} * ${zram_percent} / 100 ))

	# Limit memory available to zram to 50% by default
	mem_limit_percent=${MEM_LIMIT_PERCENTAGE:=50}
	mem_limit_per_zram_device=$(( ${memory_total} / ${zram_devices} * ${mem_limit_percent} / 100 ))

	swap_algo=${SWAP_ALGORITHM:=lzo}
	for (( i=1; i<=zram_devices; i++ )); do
		[[ -f /sys/block/zram${i}/comp_algorithm ]] && echo ${swap_algo} >/sys/block/zram${i}/comp_algorithm 2>/dev/null
		if [ "X${ZRAM_BACKING_DEV}" != "X" ]; then
			echo ${ZRAM_BACKING_DEV} >/sys/block/zram${i}/backing_dev
		fi
		echo -n ${ZRAM_MAX_DEVICES:=4} > /sys/block/zram${i}/max_comp_streams
		echo -n ${mem_per_zram_device} > /sys/block/zram${i}/disksize
		echo -n ${mem_limit_per_zram_device} > /sys/block/zram${i}/mem_limit
		mkswap /dev/zram${i}
		swapon -p 5 /dev/zram${i}
	done

	# Swapping to HDDs is stupid so switch to settings made for flash memory and zram/zswap
	echo 0 > /proc/sys/vm/page-cluster

	echo -e "\n### Activated ${zram_devices} ${swap_algo} zram swap devices with $(( ${mem_per_zram_device} / 1048576 )) MB each\n" >>${Log}
} # activate_zram_swap

activate_ramlog_partition() {
	# /dev/zram0 will be used as a compressed /var/log partition in RAM if
	# ENABLED=true in /etc/default/armbian-ramlog is set
	ENABLED=$(awk -F"=" '/^ENABLED/ {print $2}' /etc/default/armbian-ramlog)
	[[ "$ENABLED" != "true" ]] && return
	
	# read size also from /etc/default/armbian-ramlog
	ramlogsize=$(awk -F"=" '/^SIZE/ {print $2}' /etc/default/armbian-ramlog)
	disksize=$(sed -e 's/M$/*1048576/' -e 's/K$/*1024/' <<<${ramlogsize:=50M} | bc)

	# choose RAMLOG_ALGORITHM if defined in /etc/default/armbian-zram-config
	# otherwise try to choose most efficient compression scheme available.
	# See https://patchwork.kernel.org/patch/9918897/
	if [ "X${RAMLOG_ALGORITHM}" = "X" ]; then
		for algo in lz4 lz4hc quicklz zlib brotli zstd ; do
			echo ${algo} >/sys/block/zram0/comp_algorithm 2>/dev/null
		done
	else
		echo ${RAMLOG_ALGORITHM} >/sys/block/zram0/comp_algorithm 2>/dev/null
	fi
	echo -n ${disksize} > /sys/block/zram0/disksize

	# if it fails, select $swap_algo. Workaround for some older kernels
	if [[ $? == 1 ]]; then
		echo ${swap_algo} > /sys/block/zram0/comp_algorithm 2>/dev/null
		echo -n ${disksize} > /sys/block/zram0/disksize
	fi

	mkfs.ext4 -O ^has_journal -s 1024 -L log2ram /dev/zram0
	algo=$(sed 's/.*\[\([^]]*\)\].*/\1/g' </sys/block/zram0/comp_algorithm)
	echo -e "### Activated Armbian ramlog partition with ${algo} compression" >>${Log}
} # activate_ramlog_partition

activate_compressed_tmp() {
	# create /tmp not as tmpfs but zram compressed if no fstab entry exists
	grep -q '^tmpfs /tmp' /etc/mtab && return

	tmp_device=$(( ${zram_devices} + 1 ))
	if [[ -f /sys/block/zram${tmp_device}/comp_algorithm ]]; then
		if [ "X${TMP_ALGORITHM}" = "X" ]; then
			echo ${swap_algo} >/sys/block/zram${tmp_device}/comp_algorithm 2>/dev/null
		else
			echo ${TMP_ALGORITHM} >/sys/block/zram${tmp_device}/comp_algorithm 2>/dev/null
		fi
	fi
	echo -n $(( ${memory_total} / 2 )) > /sys/block/zram${tmp_device}/disksize
	mkfs.ext4 -O ^has_journal -s 1024 -L tmp /dev/zram${tmp_device}
	mount -o nosuid,discard /dev/zram${tmp_device} /tmp
	chmod 777 /tmp
	algo=$(sed 's/.*\[\([^]]*\)\].*/\1/g' </sys/block/zram${tmp_device}/comp_algorithm)
} # activate_compressed_tmp

case $1 in
	*start*)
		activate_zram_swap
		activate_ramlog_partition
		activate_compressed_tmp
		;;
esac
EOF

cat << 'EOF' | tee /etc/systemd/system/armbian-zram-config.service >/dev/null
# Armbian ZRAM configuration service
# Create 1 + number of cores compressed block devices
# This service may block the boot process for up to 30 sec

[Unit]
Description=Armbian ZRAM config
DefaultDependencies=no
After=local-fs.target
Before=armbian-ramlog.target
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/lib/armbian/armbian-zram-config start
ExecStop=/usr/lib/armbian/armbian-zram-config stop
RemainAfterExit=yes
TimeoutStartSec=30sec

[Install]
WantedBy=sysinit.target
EOF

cat << 'EOF' | tee /etc/default/armbian-ramlog >/dev/null
# configuration values for the armbian-ram-logging service
#
# enable the armbian-ram-logging service?
ENABLED=true
#
# size of the tmpfs mount -- please keep in mind to adjust /etc/default/armbian-zram-config too when increasing
SIZE=50M
#
# use rsync instead of cp -r
# requires rsync installed, may provide better performance
# due to copying only new and changed files
USE_RSYNC=true
EOF

chmod +x /usr/lib/armbian/armbian-zram-config
systemctl enable armbian-zram-config

# Swap and Zram tweaks
# Page allocation error workout
echo "vm.min_free_kbytes=65536" >> /etc/sysctl.conf
# Modify swappiness parameter
echo "vm.swappiness=100" >> /etc/sysctl.conf

# Ethereum software installation
# Add APT EthRaspbian repository
echo "Adding Ethereum repositories"
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 8A584409D327B0A5
add-apt-repository -n "deb http://apt.ethraspbian.com bionic main"
add-apt-repository -n "deb http://apt.ethraspbian.com bionic-security main"
add-apt-repository "deb http://apt.ethraspbian.com bionic-upgrades main"

# Install Ethereum packages
echo Installing Ethereum packages
apt-get install geth
apt-get install parity swarm parity ipfs raiden status.im-node vipnode prysm-beacon prysm-validator lighthouse

# Set Geth cache to 768
echo 'ARGS="--lightserv 25 --lightpeers 25 --maxpeers 128 --port 30304 --cache 768"' > /etc/ethereum/geth.conf

echo "Done. Please, reboot the systems for changes to take effect"

exit 0
