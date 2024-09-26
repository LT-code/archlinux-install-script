#!/bin/bash
set -e

if [[ "$#" -ne "1" ]]; then
	echo "usage : <command> <json config file>"
	exit -1
fi

if [ ! -f $1 ]; then
	echo "Config file $1 not found."
	exit -1
fi
JSON_CONFIG_FILE=$1

yes | pacman -Sy archlinux-keyring
yes | pacman -Sy jq arch-install-scripts

_jq_f() {
	jq -r -c $1 $JSON_CONFIG_FILE
}

_jq() {
	echo $1 | jq -r -c $2
}

######################################################
# Parameters
######################################################

# STATIC
INSTALL_PATH=/mnt

# FROM JSON FILE
DISK_USED=$(_jq_f ".disk.name")
DISK_PREFIX=$(_jq_f '.disk.prefix_num')
DISK_CLEAR=$(_jq_f ".disk.wipe")

INSTALL_ON_USB_KEY=$(_jq_f ".install.on_usb_key")
INSTALL_ANSIBLE_LOCAL=$(_jq_f ".install.ansible_local")

MACHINE_NAME=$(_jq_f ".machine.name")
MACHINE_ZONEINFO=$(_jq_f ".machine.zoneinfo")
MACHINE_LANG=$(_jq_f ".machine.lang")
MACHINE_KEYBOARD=$(_jq_f ".machine.keyboard")

LVM_USED=0
DISK_ENCRYPTED=0
SWAP_DISK_NAME=""
DISK_LUKS_NAME="archinstall_luks_root"

######################################################
# functions
######################################################

update_config_file()
{
	FILE_TO_UPDATE=$1
	KEY_TO_UPDATE=$2
	VALUE_TO_ADD=$3
	LAST_CHAR=$4

	grep -w "$FILE_TO_UPDATE" -e "^$KEY_TO_UPDATE.*$VALUE_TO_ADD.*$" || sed -i "s#$KEY_TO_UPDATE[^$LAST_CHAR]*#& $VALUE_TO_ADD#" $FILE_TO_UPDATE
}

##=========================
# Partitionning
##=========================
disk_create_partition()
{
	SIZE=+
	if [ "$1" == "ALL" ]
	then
		SIZE= 
	else
		SIZE=+$1
	fi
	TYPE=$(get_disk_type $2)
  NUMBER=$3
  DISK=$4
	
	(
	echo n # Add a new partition
	echo p # Primary partition
	echo $NUMBER # Partition number
	echo   # First sector (Accept default: 1)
	echo $SIZE # Last sector (Accept default: varies)
	echo t # change partition type
	echo  # partition number
	echo $TYPE
  echo
	echo w # Write changes
	) | fdisk -W auto $DISK
}

disk_init()
{
	(
	echo o # clear partition table
	echo w # Write changes
	) | fdisk --wipe auto $DISK_USED
}

get_disk_type()
{

	case $1 in
    		vfat)
			echo 1
			;;
		ext4)
			echo linux
			;;
		swap)
			echo swap
			;;
		lvm)
			echo lvm
			;;
		*)
			echo "Coun't format, unkown partition type"
			;;
		esac
}

disk_format()
{
	DISK=$1
	TYPE=$2
	
	case $TYPE in
    vfat)
			yes | mkfs -t vfat -F 32  $DISK
			;;
		ext4)
			yes | mkfs.ext4 $DISK
			;;
		swap)
			SWAP_DISK_NAME=$DISK
			yes | mkswap $DISK
			;;
		ntfs)
			yes | mkfs.ntfs $DISK
			;;
		lvm)
			echo ============ pvcreate $DISK
			yes | pvcreate $DISK
			;;
		*)
			echo "Coun't format, unkown partition type"
			;;
	esac
}

disk_mount()
{
	DISK=$1
	PATH_TO_MOUNT=$INSTALL_PATH/$2
	
	mkdir -p $PATH_TO_MOUNT
	
	case $2 in
    null)
			echo swapon $DISK
			swapon $DISK
			;;
		*)
			mount $DISK $PATH_TO_MOUNT
			echo mount $DISK $PATH_TO_MOUNT
			;;
	esac
}

disk_setup_luks()
{
	DISK_FULL=$1
	DISK_PASSWORD=$2

	modprobe dm-crypt
	modprobe dm-mod

  vgchange -an
  cryptsetup close $DISK_LUKS_NAME | true

	(
		echo cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --iter-time 2000 --pbkdf argon2id --use-urandom -v -s 512 -h sha512 $DISK_FULL
		echo $DISK_PASSWORD 
	) | bash

	(
		echo cryptsetup open $DISK_FULL $DISK_LUKS_NAME
		echo $DISK_PASSWORD
	) | bash

	DISK_ENCRYPTED=$DISK_FULL
}

##=========================
# Exec command
##=========================

arch_exec()
{
	(
	echo $1 # exec command
	) | arch-chroot $INSTALL_PATH
}

arch_exec_params()
{
	(
	echo $1 # exec command
	echo $2 # param
	) | arch-chroot $INSTALL_PATH
}

#####################################################
# Start intall
#####################################################
 
#echo ======== Get date and time from server ==========
timedatectl set-ntp true

if $DISK_CLEAR; then
  echo ==============Wiping partitionning disk=================

  disk_init
	wipefs -a -ff $DISK_USED

  # disk label type to gpt
  (
    echo mklabel gpt # exec command
    echo quit # param
  ) | parted $DISK_USED
fi

echo ================ Partitionning ===================
declare -xA mount_array
for part in $(jq -c '.partitions[]' $JSON_CONFIG_FILE);
do
	luks="$(_jq $part '.luks_password')"
	part_type="$(_jq $part '.type')"
	size=$(_jq $part '.size')
  do_create=$(_jq $part '.create')
  do_format=$(_jq $part '.format')
	partition_number=$(_jq $part '.number')
	echo ========================= $DISK_PREFIX
	if [[ "$DISK_PREFIX" != "null" ]]; then
		disk_full=$DISK_USED$DISK_PREFIX$partition_number
	else
		disk_full=$DISK_USED$partition_number
	fi

  [ $do_format ] && disk_create_partition $size $part_type $partition_number $DISK_USED

	if [[ "$luks" != "null" ]]; then
		disk_setup_luks $disk_full $luks
		disk_full="/dev/mapper/$DISK_LUKS_NAME"
		#disk_create_partition $size $part_type $partition_number $disk_full
		dd if=/dev/zero of=$disk_full bs=512 count=1
	fi

	[ $do_create ] && disk_format $disk_full $part_type

	case $part_type in
    lvm)
			LVM_USED=1
			vol_name="$(_jq $part '.vol_name')"

			[ $do_create ] && vgcreate $vol_name $disk_full

			for lvm_part in $(echo $part | jq -c '.partitions[]');
			do
				part_type=$(_jq $lvm_part '.type')
				path=$(_jq $lvm_part '.path')
				size=$(_jq $lvm_part '.size')
				name=$(_jq $lvm_part '.name')
				lv_create=$(_jq $lvm_part '.create')
				lv_format=$(_jq $lvm_part '.format')
				disk_full=/dev/mapper/$vol_name-$name

				if [ "$size" == "ALL" ]; then
					size="-l 100%FREE"
				else
					size="-L $size"
				fi

				[ $lv_create ] && lvcreate $size $vol_name -n $name

				[ $lv_format ] && disk_format $disk_full $part_type
				mount_array[$path]=$disk_full
			done
			;;
		*)
			path=$(_jq $part '.path')

			mount_array[$path]=$disk_full
			;;
	esac
done

echo ================ Mounting partitions ===================
for path in $(printf '%s\n' "${!mount_array[@]}" | sort | tr '\n' ' ')
do
	disk_mount "${mount_array[$path]}" $path 
done

echo ================ Install base ===================
pacstrap $INSTALL_PATH base base-devel linux linux-firmware 

# list partition
genfstab -U -p $INSTALL_PATH >> $INSTALL_PATH/etc/fstab

#cp /etc/pacman.d/mirrorlist $INSTALL_PATH/etc/pacman.d/mirrorlist.backup
#sed -s 's/^#Server/Server/' $INSTALL_PATH/etc/pacman.d/mirrorlist.backup
#rankmirrors -n 10 /etc/pacman.d/mirrorlist.backup > $INSTALL_PATH/etc/pacman.d/mirrorlist

echo ================ Machine Info setting ===================
arch_exec_params "pacman -S lvm2" "y"

modprobe efivars | true

arch_exec "echo $MACHINE_NAME > /etc/hostname"

arch_exec "echo '127.0.1.1 $MACHINE_NAME.localdomain $MACHINE_NAME' >> /etc/hosts"

arch_exec "ln -sf /usr/share/zoneinfo/$MACHINE_ZONEINFO /etc/localtime"

arch_exec "echo $MACHINE_LANG.UTF-8 UTF-8 > /etc/locale.gen"

arch_exec "locale-gen"

arch_exec "echo LANG=\"$MACHINE_LANG.UTF-8\" > /etc/locale.conf"

arch_exec "export LANG=$MACHINE_LANG.UTF-8"

arch_exec "echo KEYMAP=$MACHINE_KEYBOARD > /etc/vconsole.conf"

echo ================ Building kernel ===================
[ $LVM_USED -eq 1 ] && update_config_file /mnt/etc/mkinitcpio.conf "HOOKS=(" "lvm2" ")"
[ "$DISK_ENCRYPTED" != "" ] && update_config_file /mnt/etc/mkinitcpio.conf "HOOKS=(" "encrypt" ")"

arch_exec "mkinitcpio -p linux"

echo ================ Useful Package ===================
# for connection and administration
arch_exec_params "pacman -S dhcpcd openssh git" "y"
arch_exec "pacman -S netctl dialog netctl wpa_supplicant vi --noconfirm"

if $INSTALL_ANSIBLE_LOCAL; then
  arch_exec_params "pacman -S ansible python" "y"
fi

# enabling services
arch_exec "systemctl enable dhcpcd.service"
arch_exec "systemctl enable sshd.service"

# allow ssh root connection
 arch_exec "sed -i -e 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config"

echo ================ Bootloader ===================
arch_exec_params "pacman -S grub efibootmgr" "y"

if $INSTALL_ON_USB_KEY
then
  arch_exec "grub-install --target=x86_64-efi --efi-directory=/boot --recheck --removable"
else
  arch_exec "grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch_grub --recheck"
fi
 
[ $LVM_USED -eq 1 ] && update_config_file /mnt/etc/default/grub "GRUB_PRELOAD_MODULES=\"" "lvm" "\""
[ "$DISK_ENCRYPTED" != "" ] && update_config_file /mnt/etc/default/grub "GRUB_CMDLINE_LINUX=\"" "cryptdevice=$DISK_ENCRYPTED:$DISK_LUKS_NAME" "\""

arch_exec "grub-mkconfig -o /boot/grub/grub.cfg"

echo ================ Security ===================
# set password
(
	echo passwd # exec command
	echo password # param
	echo password # param
) | arch-chroot $INSTALL_PATH

echo -e "\ntmpfs /tmp tmpfs defaults 0 0\n" >> /mnt/etc/fstab

echo ================ Finishing ===================
if $INSTALL_ANSIBLE_LOCAL; then git clone https://github.com/LT-code/archlinux-ansible  $INSTALL_PATH/root/ArchInstall-ansible; fi
umount -R $INSTALL_PATH
swapoff $SWAP_DISK_NAME
