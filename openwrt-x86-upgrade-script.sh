#!/bin/ash

# Exit script on non-zero exit code (this was causing the script to exit prematurely at e2fsck)
#set -e

# install dependencies
opkg update && opkg install lsblk curl rsync

# Set mount point for second OpenWrt installation
mount_pt=/tmp/mnt
mkdir ${mount_pt}

# Check current release vs new release
current_dist=$(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d "'" -f 2)
## TODO - Perhaps use the https://sysupgrade.openwrt.org/ api to get new release versions
new_release=$(wget -qO- https://downloads.openwrt.org | grep releases | awk -F'/' '{print $2}' | tr '\n' ' ' | awk '{print $1}')

if [[ $current_dist == $new_release ]]
	then echo -e "Already on newest release: /n/t Current: ${current_dist} = Newest: ${new_release}"; exit 1
fi

# Which device/partition is the currently mounted, which is the target
boot_dev=$(lsblk -pPo LABEL,PATH | grep kernel | sed -E 's/.*PATH="(.*)".*/\1/')
current_dev=$(lsblk -pPo MOUNTPOINTS,PATH | grep 'MOUNTPOINTS="/"' | sed -E 's/.*PATH="(.*)".*/\1/')
if [[ $current_dev =~ 2 ]]
	then target_dev=$(lsblk -pPo PATH | grep '3"' | sed -E 's/.*PATH="(.*)".*/\1/')
else target_dev=$(lsblk -pPo PATH | grep '2"' | sed -E 's/.*PATH="(.*)".*/\1/')
fi

# Mount the target device, check old version
mount ${target_dev} ${mount_pt}
old_dist=`grep DISTRIB_RELEASE ${mount_pt}/etc/openwrt_release | cut -d "'" -f 2`

echo "Current OpenWRT release: ${current_dist} on ${current_dev}"
echo "New OpenWRT release: ${new_release} to replace ${old_dist} on target ${target_dev}"

# Ask user to confirm continuation of upgrade process
read -n1 -p "Continue with upgrade? (WARNING: THIS WILL OVERWRITE ${target_dev}) [y/N]: " doit

if [[ ! $doit =~ [yY] ]]; then
	umount ${mount_pt}
	echo -e "\nExiting...\n"
	exit 1
fi

### Slow but perhaps more accurate installed packages list
# From user: spence
# https://forum.openwrt.org/t/detecting-user-installed-pkgs/161588/8

##############################################################
#myDeviceName=$(ubus call system board | jsonfilter -e '@.board_name' | tr ',' '_')
#myDeviceTarget=$(ubus call system board | jsonfilter -e '@.release.target')
#myDeviceVersion=$(ubus call system board | jsonfilter -e '@.release.version')
#myDeviceJFilterString=@[\"profiles\"][\"$myDeviceName\"][\"device_packages\"]
#myDefaultJFilterString=@[\"default_packages\"]
#
####myDeviceProfilesURL="https://downloads.openwrt.org/releases/$myDeviceVersion/targets/$myDeviceTarget/profiles.json"
#if [ "$myDeviceVersion" = 'SNAPSHOT' ] ; then
#    myDeviceProfilesURL="https://downloads.openwrt.org/snapshots/targets/$myDeviceTarget/profiles.json"
#else
#    myDeviceProfilesURL="https://downloads.openwrt.org/releases/$myDeviceVersion/targets/$myDeviceTarget/profiles.json"
#fi
#
##### 2023-10-17: Potential better way to get URL:
#myDeviceProfilesURL=$(grep openwrt_core /etc/opkg/distfeeds.conf / | grep -o "https.*[/]")profiles.json
#
#wget -O /tmp/profiles.json "$myDeviceProfilesURL"
#
#jsonfilter -i /tmp/profiles.json -e $myDeviceJFilterString | sed s/\"/''/g | tr '[' ' ' | tr ']' ' ' | sed s/\ /''/g | tr ',' '\n' > /tmp/my-def-pkgs
#
#jsonfilter -i /tmp/profiles.json -e $myDefaultJFilterString | sed s/\"/''/g | tr '[' ' ' | tr ']' ' ' | sed s/\ /''/g | tr ',' '\n' >> /tmp/my-def-pkgs
#
###############################################################

### OR
# From user: efahl
# https://forum.openwrt.org/t/detecting-user-installed-pkgs/161588/16

printf "\n---Getting list of user-installed packages for Image Builder---\n"

package_list=./installed-packages
rm -f $package_list

examined=0
for pkg in $(opkg list-installed | awk '{print $1}') ; do
    examined=$((examined + 1))
    printf '%5d - %-40s\r' "$examined" "$pkg"
    #deps=$(opkg whatdepends "$pkg" | awk '/^\t/{printf $1" "}')
    deps=$(
        cd /usr/lib/opkg/info/ &&
        grep -lE "Depends:.* ${pkg}([, ].*|)$" -- *.control | awk -F'\.control' '{printf $1" "}'
    )
    count=$(echo "$deps" | wc -w)
    if [ "$count" -eq 0 ] ; then
        printf '%s\t%s\n' "$pkg" "$deps" >> $package_list
    fi
done

n_logged=$(wc -l < $package_list)
printf 'Done, logged %d of %d entries\n' "$n_logged" "$examined"

####################################################################

# Build json for Image Builder request
awk -v new_release=${new_release} '{
    items[NR] = $1
}
END {
    printf "{\n"
    printf "  \"packages\": [\n"
    for (i = 1; i <= NR; i++) {
        printf "    \"%s\"", items[i]
        if (i < NR) {
            printf ","
        }
        printf "\n"
    }
    printf "  ],\n"
    printf "  \"filesystem\": \"ext4\",\n"
    printf "  \"profile\": \"generic\",\n"
    printf "  \"target\": \"x86/64\",\n"
    printf "  \"version\": \"%s\"\n", new_release
    printf "}\n"
}' installed-packages > json_data

printf "---Requesting build from https://sysupgrade.openwrt.org/api/v1/build---\n"

curl -H 'accept: application/json' -H 'Content-Type: application/json' --data-binary '@json_data' 'https://sysupgrade.openwrt.org/api/v1/build' > build_reply
build_status=$(cat build_reply | jsonfilter -e '@.status')
if [ $build_status == 202 ] || [ $build_status == 200 ]; then
	build_hash=$(cat build_reply | jsonfilter -e '@.request_hash')
	printf "Request OK. Request hash: %s\n" "${build_hash}"
else
	echo "Error requesting Image build:"
	cat build_reply
	umount ${mount_pt}
	exit 1
fi

i=0
spin='-\|/'
build_time=0
while [ true ]; do 
	# Sleep to comply with API rules
	sleep 6
	building=$(curl -s "https://sysupgrade.openwrt.org/api/v1/build/${build_hash}")
	build_status=$(echo $building | jsonfilter -e '@.status')
	# 202 = in-progress
	if [ $build_status == 202 ]; then
		i=$(( (i+1) %4 ))
		build_time=$(( build_time + 6 ))
		printf "\rWaiting for build to complete ${spin:$i:1}"
		continue
	# 200 = build complete
	elif [ $build_status == 200 ]; then
		image=$(echo $building | jsonfilter -e '@.images[@.filesystem="ext4" && @.type="rootfs"].name')
		hash=$(echo $building | jsonfilter -e '@.images[@.filesystem="ext4" && @.type="rootfs"].sha256')
		image_hash="${hash} ${image}"
		printf "\nBuild finished in %d seconds\n" "${build_time}"
		break
	else 
		# Sleep an extra 5 seconds to not hit the API back-to-back just to report an error
		sleep 5
		printf "\nError with Image Builder:\n"
    	curl "https://sysupgrade.openwrt.org/api/v1/build/${build_hash}"
		exit 1
	fi
done

echo -e "\n---Downloading the rootfs image and copying to ${target_dev}---\n"
cd /tmp
# Download new release
wget "https://sysupgrade.openwrt.org/store/${build_hash}/${image}"
# Check sha256 hash against file downloaded
csum=$(echo $image_hash | sha256sum -c | awk '{ print $2 }')
printf "Checksum %s!\n" "${csum}"
if [ $csum != "OK" ]; then
	# If hash doesn't match, exit
	printf "Downloaded image doesn't match sha256sum! Exiting...\n\n"
	umount ${mount_pt}
	exit 1
else
	printf "---Image downloaded and hash OK. Installing---\n"
fi

# Unzip and write directly to partition
gzip -d -c ${image} | dd of=${target_dev}
# Unmount partition to resize without error
umount ${target_dev}
# Check filesystem for errors
e2fsck -fp ${target_dev}
# Resize filesystem to partition size
resize2fs ${target_dev}
# Check partition for errors
fsck.ext4 ${target_dev}
# Remount target device
mount ${target_dev} ${mount_pt}


echo "---Removing old kernel(s)---"
mkdir -p /tmp/boot
# Mount /boot into a tmp directory
mount ${boot_dev} /tmp/boot
# Check if more that one kernel exists
num_kernels=$(find /tmp/boot/boot/ -name *vmlinuz* | wc -l)
if [[ $num_kernels > 1 ]]; then
	current_root_partuuid=$(lsblk -pPo MOUNTPOINTS,PARTUUID | grep 'MOUNTPOINTS="/"' | sed -E 's/.*PARTUUID="(.*)".*/\1/')
	current_kernel=$(grep ${current_root_partuuid} /tmp/boot/boot/grub/grub.cfg | sed -E 's/.*linux \/boot\/(.*) .*/\1/g' | cut -d " " -f 1 | uniq)
	find /tmp/boot/boot -name *vmlinuz* ! -name ${current_kernel} -exec mv {} /tmp \;
else
	echo "One existing kernel found, not deletion required"
fi

echo "---Downloading new kernel---"
new_kernel=vmlinuz-${new_release}
wget https://downloads.openwrt.org/releases/${new_release}/targets/x86/64/openwrt-${new_release}-x86-64-generic-kernel.bin -O /tmp/boot/boot/${new_kernel}

echo "---Updating Grub---"
# Get new partition UUID
new_partuuid=`lsblk -pPo PATH,PARTUUID | grep ${target_dev} | sed -E 's/.*PARTUUID="(.*)".*/\1/'`

# Create a backup copy of grub in case something fails
cp /tmp/boot/boot/grub/grub.cfg /tmp/boot/boot/grub/grub.cfg.bak

# Copy the first menu entry to create an additional entry
sed -i '1,/menuentry/{/menuentry/{N;N;p;N}}' /tmp/boot/boot/grub/grub.cfg
## Update the first menu entry
# Name 
sed -i "1,/menuentry/s/\"OpenWrt.*\"/\"OpenWrt-${new_release}\"/" /tmp/boot/boot/grub/grub.cfg
# Kernel
sed -i "1,/linux/s/vmlinuz[-0-9.]*/${new_kernel}/" /tmp/boot/boot/grub/grub.cfg
# Partition
sed -i "1,/linux/s/PARTUUID=[-0-9a-f]*/PARTUUID=${new_partuuid}/" /tmp/boot/boot/grub/grub.cfg

# Leave the second entry as is - the current working (old) version

# If there are now 4 menu entries, delete the 3rd (oldest version)
grub_entries=`grep menuentry /tmp/boot/boot/grub/grub.cfg | wc -l`
if [[ grub_entries == 4 ]]; then
	awk 'BEGIN {count=0} /menuentry/ {count++} count!=3' /tmp/boot/boot/grub/grub.cfg > tmp && mv tmp /tmp/boot/boot/grub/grub.cfg
fi

## Update failsafe entry
# Copy (new) first entry to the end of grub, add failsafe
sed -n '1,/menuentry/{/menuentry/{N;N;p}}' /tmp/boot/boot/grub/grub.cfg | sed -E 's/(\"OpenWrt-.*)\"/\1 \(failsafe\)"/' | sed -E 's/(^.*)(root=PARTUUID=.*$)/\1failsafe=true \2/' >> /tmp/boot/boot/grub/grub.cfg
# Delete the old failsafe entry
sed -i '1,/failsafe/{/failsafe/{N;N;d}}' /tmp/boot/boot/grub/grub.cfg

# Since we used awk to replace the file, restore original permissions
chmod 755 /tmp/boot/boot/grub/grub.cfg

echo "---Copying /etc files to new OpenWRT---"
rsync -aAXP --exclude banner* --exclude openwrt_* --exclude opkg/ --exclude os_release /etc/. /tmp/mnt/etc

echo "---Copying files in sysupgrade.conf---"
for file in $(awk '!/^[ \t]*#/&&NF' /etc/sysupgrade.conf); do 
	directory=$(dirname ${file})
	if [ ! -d $directory ]; then
		mkdir -p "/tmp/mnt${directory}"
	fi 
	rsync -aAXP $file /tmp/mnt$file
done

echo "---Finished!---"
umount /tmp/boot
umount ${mount_pt}
echo "Reboot to start new OpenWrt version!"