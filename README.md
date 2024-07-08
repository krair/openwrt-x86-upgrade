## OpenWrt x86 Automated Upgrade Script

This script was written to help aid the confusing upgrade path for people running OpenWrt on an x86 machine.

**The script is very much a WIP, and at best an alpha release at this point!**

There are practically no checks, minimal backups created, and no guarantee of success!

## Prerequisites

* An x86 machine running OpenWrt
* Main drive > 256 Mb
* Main drive split into at least 3 partitions

The 256 Mb drive requirement is a bit ridiculous, I know, but it's to make my next point. You'll need a /boot partition (16 Mb by default), and two others > 100 Mb each. For example, I have a 128 Gb drive, split like this:

```bash
NAME   MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda      8:0    0 119.2G  0 disk 
├─sda1   8:1    0    16M  0 part 
├─sda2   8:2    0    10G  0 part 
├─sda3   8:3    0    10G  0 part /
└─sda4   8:4    0  99.2G  0 part /opt
```

Here, sda1 is the boot drive (containing the kernels), sda2 and sda3 are my OpenWrt root filesystem partitions, and sda4 (optional) is simply the 'rest' of the drive which I mount to `/opt` to keep certain files between upgrades.

### NOTE

The script is (currently) only designed to work with your boot partition on sda1, and two OpenWrt partitions on sda2 and sda3. Partitions sda4+ are not used by the script. **If you have anything else on sda2 or sda3, this script will not work for you in its current state!**

You have been warned.

## Installation and Usage

1) Download the script to your x86 based OpenWrt router
2) Ensure the script has "execute" permissions (`chmod +x openwrt-x86-upgrade-script.sh`)
3) Run the script.

At one point it will ask you if you want to continue with the upgrade process. From that point on, the changes are not currently reversible.

### Recommendation

If possible, make a full backup of the disk of your OpenWrt x86 router box. Then, use the backup to create a virtual machine, and test the script on the VM first. If everything goes well, use it on your main router. At least you'll have some idea how it functions!

## Read More

While I could write about the script here, I decided to turn it into a blog post [here](https://rair.dev/openwrt-upgrade/).