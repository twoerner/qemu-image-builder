#!/bin/bash

exec 6>&1
rm -f LOG
exec >> LOG 2>&1

declare -i CYL
declare -i PARTITION_CNT
declare -ai BLOCKSZ
declare -ai OFFSETS
declare -a FORMATS
declare -a DATA
declare -i HDDSIZE

MOUNT_LIST=()
MOUNT_CNT=0
OLDLOSETUP=2
LOOP_LIST=()
LOOPDEV=""
DEFAULTFMT="mke2fs"

LILO=0
EXTLINUX=0

say() {
	local _nopt=""
	local _eopt=""
	local _break=0
	local _args

	_args=`getopt -o n,e,b -n "say" -- "$@"`
	if [ $? -ne 0 ]; then
		echo "getopt(1) invocation error"
		return
	fi
	eval set -- "$_args"
	while true; do
		case "$1" in
			-n)
				_nopt=n
				;;
			-e)
				_eopt=e
				;;
			-b)
				_break=1
				;;
			--)
				break
				;;
			*)
				echo "getopt(1) internal error"
				return
		esac
		shift
	done
	shift

	if [ $_break -ne 0 ]; then
		echo -e "\n\n================================================="
	else
		echo -n "  "
		echo -n "  " >&6
	fi

	if [ -z "$_nopt" -a -z "$_eopt" ]; then
		echo "$*"
		echo "$*" >&6
	else
		echo -${_nopt}${_eopt} "$*"
		echo -${_nopt}${_eopt} "$*" >&6
	fi
}

usage() {
	say "usage: $0 [OPTIONS] <size> <out> <data>"
	say "  <size>:"
	say "    Specify the size of the disk in bytes"
	say "  <out>:"
	say "    Provide the output filename"
	say "  <data>:"
	say "    Specify, as one argument, the data to place in each partition"
	say ""
	say "  options:"
	say "    --help|-h     Provide help information and exit successfully"
	say "    --partitions  Specify, as one argument, the set of partition size percentages"
	say "    --format      Specify, as one argument, how to format each partition"
	say "    --default-format"
	say "                  Format all partitions (for which no format instructions have"
	say "                  been specified with the --format option) with this command"
	say "                  (default: $DEFAULTFMT)"
	say "    --ids         Specify, as one argument, the set of partition IDs, default=83"
	say "    --lilo <conf> Use lilo and specify the partial config file"
	say "    --extlinux <menu>,<mbr>,<conf>"
	say "                  Use extlinux and specify location of <menu>, <mbr>, and <config> files"
}

cleanup() {
	local _exitval=$?
	say -b "exit value: $_exitval"

	if [ $_exitval -ne 0 -a -n "$VMIMG" ]; then
		say " -> removing $VMIMG"
		rm -f $VMIMG
	fi

	if [ -e lilo.TMP ]; then
		say " -> removing lilo.TMP"
		rm -f lilo.TMP
	fi

	if [ $_exitval -eq 2 ]; then
		say " -> mount/umount failure, the following may still be mounted:"
		say "    ${MOUNT_LIST[*]}"
	else
		say " -> mounted items: $MOUNT_CNT"
		while [ $MOUNT_CNT -gt 0 ]; do
			umount_pop
		done
	fi

	if [ $_exitval -eq 3 ]; then
		say " -> losetup failure, the following may still be attached:"
		say "    ${LOOP_LIST[*]}"
	else
		say " -> loop items: ${#LOOP_LIST[*]}"
		while [ ${#LOOP_LIST[*]} -gt 0 ]; do
			detach_loop ${LOOP_LIST[0]}
		done
	fi
}

attach_loop() {
	local _cnt

	# check whether we're using the old or new 'losetup'
	if [ $OLDLOSETUP -eq 2 ]; then
		OLDLOSETUP=0

		losetup -a > /dev/null 2>&1
		if [ $? -ne 0 ]; then
			OLDLOSETUP=1
		fi
	fi

	if [ $OLDLOSETUP -eq 0 ]; then
		LOOPDEV=`losetup --show -f $*`
		if [ $? -ne 0 ]; then
			say "  -> losetup error"
			exit 3
		fi
		losetup -a | grep $LOOPDEV > /dev/null 2>&1
		if [ $? -ne 0 ]; then
			say "  -> loop device appears to have not been created for $1"
			exit 3
		fi
	else
		_cnt=0
		while [ $_cnt -lt 10 ]; do
			LOOPDEV=`losetup -f`
			losetup $LOOPDEV $*
			if [ $? -eq 0 ]; then
				break
			fi
			LOOPDEV=""
			_cnt=`expr $_cnt + 1`
		done
	fi

	if [ -z "$LOOPDEV" ]; then
		say "  -> can't wrangle loop device (OLDLOSETUP:$OLDLOSETUP)"
		exit 3
	fi

	LOOP_LIST=(${LOOP_LIST[*]} $LOOPDEV)
	echo "    -- attaching loop ($LOOPDEV) and adding to list"
	echo "       `losetup $LOOPDEV`"
}

detach_loop() {
	local _cnt=1
	local _i

	if [ -z "$1" ]; then
		say "  -> detach_loop() requires an argument"
		exit 3
	fi

	# detach
	while [ 1 ]; do
		sync
		losetup -d $1 > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			break
		fi
		_cnt=`expr $_cnt + 1`
		if [ $_cnt -gt 5 ]; then
			say "  -> can't detach $1 after 5 tries"
			exit 3
		fi
		sleep 1
	done

	# remove from list
	for ((_i=0; _i<${#LOOP_LIST[*]}; ++_i)); do
		if [ X"${LOOP_LIST[$_i]}" = X"$1" ]; then
			break
		fi
	done
	if [ $_i -lt ${#LOOP_LIST[*]} ]; then
		echo "    -- detaching loop ($1) and removing from list"
		LOOP_LIST=(${LOOP_LIST[*]:0:$_i} ${LOOP_LIST[*]:$(($_i + 1))})
	else
		say "  -> can't find $1, loop-count:${#LOOP_LIST[*]}, LOOP_LIST:'${LOOP_LIST[*]}'"
	fi
}

dd_disk() {
	# arguments
	if [ -z "$1" ]; then
		say " -> need to specify disk size"
		exit 1
	fi
	if [ -z "$2" ]; then
		say " -> need to specify filename for image"
		exit 1
	fi
	declare -i _size
	local _size="$1"
	local _name="$2"
	local _cnt=1
	local _mult=1

	if [ $_size -le 0 ]; then
		say " -> bad disk size: $_size"
		exit 1
	fi

	rm -f $_name
	if [ $? -ne 0 ]; then
		say " -> can't delete already-existing image: $_name"
		exit 1
	fi

	while [ 1 ]; do
		say -ne " -> trying 'dd' with $_size * $_mult... "
		dd if=/dev/zero of=$_name bs=$_size count=$_mult > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			say "good"
			return
		fi

		_cnt=`expr $_cnt + 1`
		_mult=`expr $_mult \* 2`
		_size=`echo "$_size/2" | bc`
		if [ $_size -eq 0 ]; then
			say "  -> size can't be shrunk further after $_cnt attempts"
			exit 1
		fi
		say ""
	done

	say " -> how did we get here?"
	exit 1
}

generate_sfdisk_str() {
	if [ -z "$1" ]; then
		echo ","
		return 0
	fi

	declare -a _sizes
	local _sizes=($*)
	local _rtnstr="0"
	local _i
	local _cnt=$#
	declare -i _part
	local _part
	local _id

	_i=0
	for _part in $*; do
		if [ $_part -le 0 ]; then
			echo "non positive integer detected: '$_part'"
			return 1
		fi
		_i=`expr $_i + $_part`
	done
	if [ $_i -ge 100 ]; then
		echo "percentages ($_i) are not supposed to equal or exceed 100%"
		return 1
	fi

	for ((_i=0; _i<$_cnt; ++_i)); do
		_id=$(trim ${PARTITION_IDS[$_i]})
		if [ $_cnt -gt 3 -a $_i -eq 3 ]; then
			_rtnstr="${_rtnstr},,E\n"
		fi
		_part=`expr $CYL \* 100 \* ${_sizes[$_i]} / 10000`
		if [ $_part -le 0 ]; then
			echo "invalid calculated number of cylinders ($_part) for partition $((_i+1))"
			return 2
		fi
		_rtnstr="${_rtnstr},${_part},${_id}\n"
	done
	_rtnstr="${_rtnstr},"
	echo $_rtnstr

	return 0
}

mount_push() {
	declare -a _args
	local _args=($*)
	local _where=${_args[$((${#_args[*]}-1))]}
	echo "mount $*"

	if [ ! -d $_where ]; then
		mkdir -p $_where
		if [ $? -ne 0 ]; then
			say "  -> can't make mount point $_where"
			exit 2
		fi
	fi

	mount $*
	if [ $? -ne 0 ]; then
		say "  -> mount error"
		exit 2
	fi
	sync

	MOUNT_LIST[$MOUNT_CNT]="`pwd`/$_where"
	MOUNT_CNT=`expr $MOUNT_CNT + 1`
}

umount_pop() {
	local _args
	local _keep=0

	_args=`getopt -o "" --long keep -n "umount_pop" -- "$@"`
	if [ $? -ne 0 ]; then
		echo "umount_pop() invocation error"
		return
	fi
	eval set -- "$_args"
	while true; do
		case "$1" in
			--keep)
				_keep=1
				;;
			--)
				break
				;;
			*)
				echo "getopt(1) internal error"
				return
		esac
		shift
	done
	shift

	if [ $MOUNT_CNT -le 0 ]; then
		say "  -> bad pop ($MOUNT_CNT)"
		return
	fi

	local _toumount=${MOUNT_LIST[$((MOUNT_CNT - 1))]}

	echo "umount $_toumount"
	umount $_toumount
	if [ $? -ne 0 ]; then
		say "  -> problem unmounting $_toumount"
		exit 2
	fi
	sync

	if [ $_keep -ne 1 ]; then
		rmdir $_toumount
	fi

	MOUNT_CNT=`expr $MOUNT_CNT - 1`
}

get_format_options() {
	if [ -n "$*" ]; then
		FORMATS=("$@")
	fi
}

get_data_options() {
	if [ -n "$*" ]; then
		DATA=("$@")
	fi
}

get_partitions_ids() {
	if [ -n "$*" ]; then
		PARTITION_IDS=("$@")
	fi
}

trim() {
	echo $1
}

if [ $UID -ne 0 ]; then
	say "must be root to run this script"
	exit 1
fi

#####################################
trap cleanup EXIT

#####################################
say -b "processing cmdline"
CMDLINE=`getopt -o "h" --long help,partitions:,format:,lilo:,extlinux:,default-format:,ids: -n $0 -- "$@"`
if [ $? -ne 0 ]; then
	say " -> invocation error (invalid/incorrect cmdline)"
	usage
	exit 1
fi
eval set -- "$CMDLINE"
while true; do
	case "$1" in
		--help|-h)
			usage
			exit 0
			;;
		--partitions)
			PARTITION_SIZES="$2"
			shift
			;;
		--format)
			OLDIFS="$IFS"
			IFS=","
			get_format_options $2
			IFS="$OLDIFS"
			shift
			;;
		--default-format)
			DEFAULTFMT="$2"
			shift
			;;
		--ids)
			OLDIFS="$IFS"
			IFS=","
			get_partitions_ids $2
			IFS="$OLDIFS"
			shift
			;;
		--lilo)
			if [ $EXTLINUX -eq 1 ]; then
				say " -> can't specify both --lilo and --extlinux, choose just one"
				usage
				exit 1
			fi
			LILO=1
			if [ ! -f "$2" ]; then
				say " -> lilo config not a file"
				usage
				exit 1
			fi
			LILO_CONF="$2"
			echo "lilo bootloader configuration file from cmdline:"
			echo "  conf: '$LILO_CONF'"
			shift
			;;
		--extlinux)
			if [ $LILO -eq 1 ]; then
				say " -> can't specify both --lilo and --extlinux, choose just one"
				usage
				exit 1
			fi
			EXTLINUX=1
			EXTLINUX_MENU=`echo "$2" | cut -d',' -f1`
			EXTLINUX_MBR=`echo "$2" | cut -d',' -f2`
			EXTLINUX_CONF=`echo "$2" | cut -d',' -f3`
			if [ ! -f "$EXTLINUX_MENU" ]; then
				say " -> the provided menu ($EXTLINUX_MENU) is not a file"
				usage
				exit 1
			fi
			if [ ! -f "$EXTLINUX_MBR" ]; then
				say " -> the provided MBR file ($EXTLINUX_MBR) is not valid"
				usage
				exit 1
			fi
			if [ ! -f "$EXTLINUX_CONF" ]; then
				say " -> the provided config ($EXTLINUX_CONF) is not a file"
				usage
				exit 1
			fi
			echo "extlinux bootloader cmdline options:"
			echo "  menu: '$EXTLINUX_MENU'"
			echo "   mbr: '$EXTLINUX_MBR'"
			echo "  conf: '$EXTLINUX_CONF'"
			shift
			;;
		--)
			break
			;;
		*)
			say " -> getopt(1) internal error!"
			exit 1
	esac
	shift
done
shift

# required arguments
if [ $# -ne 3 ]; then
	say " -> 3 cmdline args required, given:$#"
	usage
	exit 1
fi

# required arg 1 - size of disk in bytes
HDDSIZE=$1
if [ $HDDSIZE -le 0 ]; then
	say " -> invalid or non-numeric size given for disk ($1)"
	usage
	exit 1
fi

# required arg 2 - output filename
VMIMG="$2"

# required arg 3 - data for each partition
OLDIFS="$IFS"
IFS=","
get_data_options $3
IFS="$OLDIFS"
if [ ${#DATA[*]} -eq 0 ]; then
	say " -> no data given for partitions"
	usage
	exit 1
fi
say " -> verifying data items"
for data in ${DATA[*]}; do
	if [ ! -e $data ]; then
		say "  -> data item '$data' does not appear to exist"
		exit 1
	fi
done

# make sure partition count, data items, and format count make sense
say " -> verifying partition, data, and format counts"
PARTITION_ARR=($PARTITION_SIZES)
PARTITION_CNT=`expr ${#PARTITION_ARR[*]} + 1`
if [ $PARTITION_CNT -gt 4 ]; then
	PARTITION_CNT=`expr $PARTITION_CNT + 1`
fi

if [ ${#DATA[*]} -gt $PARTITION_CNT ]; then
	say " -> number of data items (${#DATA[*]}) exceeds partition count ($PARTITION_CNT)"
	exit 1
fi
if [ ${#FORMATS[*]} -gt $PARTITION_CNT ]; then
	say " -> number of format specifiers (${#FORMATS[*]}) exceeds partition count ($PARTITION_CNT)"
	exit 1
fi

#####################################
# check for required tools
say -b "checking for required tools"
FMTTOOL=`echo $DEFAULTFMT | cut -d' ' -f1`
for tool in bc losetup fdisk dd sfdisk tune2fs $FMTTOOL; do
	say -n " -> ${tool}..."
	which $tool > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		say "NOT FOUND"
		exit 1
	fi
	say "found"
done

for fmttool in "${FORMATS[@]}"; do
	if [ -n "$fmttool" ]; then
		FMTTOOL=`echo $fmttool | cut -d' ' -f1`
		say -n " -> $FMTTOOL..."
		which $FMTTOOL > /dev/null 2>&1
		if [ $? -ne 0 ]; then
			say "NOT FOUND"
			exit 1
		fi
		say "found"
	fi
done

if [ $LILO -eq 1 ]; then
	say -n " -> lilo..."
	which lilo > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		say "NOT FOUND"
		exit 1
	fi
	say "found"
fi

if [ $EXTLINUX -eq 1 ]; then
	say -n " -> extlinux..."
	which extlinux > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		say "NOT FOUND"
		exit 1
	fi
	say "found"
fi

#####################################
# create virtual disk in file
say -b "creating virtual disk file of $HDDSIZE bytes"
dd_disk $HDDSIZE $VMIMG


#####################################
# determine geometry
# qemu is kinda restrictive in what it will allow for disk geometries (see man(8) page):
# 1 <= c <= 16383, 1 <= h <= 16, 1 <= s <= 63
# since heads and sectors are the most restrictive, use these values get fdisk
# to calculate the number of cylinders
# if the partition scheme based on the calculated numbers won't work (i.e. it would
# try to create a partition using zero cylinders) reduce the H/S and try again
say -b "determining disk geometry"
HDS=16
SEC=63
while [ true ]; do
	say " -> trying with HDS:$HDS SEC:$SEC"
	attach_loop $VMIMG

	FDISK=`fdisk -H $HDS -S $SEC -l $LOOPDEV 2> /dev/null | head -3 | tail -1 | tr -s ' '`
	if [ X"`echo $FDISK | cut -d' ' -f6 | cut -d',' -f1`" != X"cylinders" ]; then
		say "  -> can't determine cylinders automatically, please specify on cmdline"
		say "  -> fdisk output: $FDISK"
		exit 1
	fi
	CYL=`echo $FDISK | cut -d' ' -f5`

	say "  -> calculated CYL:$CYL"
	detach_loop $LOOPDEV
	if [ $CYL -le 0 -o $CYL -gt 16383 ]; then
		say "  -> the cylinder value '$CYL' is out of range (1 to 16383) or non-numeric"
		exit 1
	fi

	SFDISK_STR=`generate_sfdisk_str $PARTITION_SIZES`
	case $? in
		0)
			break
			;;
		1)
			exit 1
			;;
		2)
			HDS=`expr $HDS / 2`
			SEC=`expr $SEC / 2`
			if [ $HDS -le 0 -o $SEC -lt 0 ]; then
				say "  -> can't find geometry"
				exit 1
			fi
			;;
	esac
done

GEOM="-C $CYL -H $HDS -S $SEC"
say " -> using disk geometry: $GEOM"


#####################################
# partition
say -b "partitioning drive"
say " -> detected $PARTITION_CNT partitions"
if [ $PARTITION_CNT -le 0 ]; then
	say "  -> invalid calculated number of partitions: $PARTITION_CNT"
	exit 1
fi
say " -> performing partitioning with sfdisk"
echo -e "using partition string:\n$SFDISK_STR\n"
sfdisk $GEOM $VMIMG << EOF
`echo -e $SFDISK_STR`
EOF
if [ $? -ne 0 ]; then
	say "  -> sfdisk reports an error"
	exit 1
fi

# verify partitioning
sfdisk $GEOM -V $VMIMG
if [ $? -ne 0 ]; then
	say "  -> device partitioning verification failed"
	exit 1
fi


#####################################
## figure out the block sizes (for mke2fs)
say -b "obtaining partition block sizes"
UNITS=`fdisk $GEOM -lu $VMIMG | grep "^Units" | cut -d' ' -f3`
if [ X"$UNITS" != X"sectors" ]; then
	say "  -> can't get partition block sizes in sectors"
	exit 1
fi
BLOCKSZ=(`fdisk $GEOM -lu $VMIMG | tail -${PARTITION_CNT} |  tr -s ' ' | cut -d' ' -f4 | cut -d'+' -f1`)
if [ ${#BLOCKSZ[*]} -ne ${PARTITION_CNT} ]; then
	say "  -> can't get block sizes"
	fdisk $GEOM -lu $VMIMG | tail -${PARTITION_CNT} >&6
	exit 1
fi
for item in ${BLOCKSZ[*]}; do
	if [ $item -le 0 ]; then
		say "  -> non-numeric or out-of-range block size: $item"
		fdisk $GEOM -lu $VMIMG | tail -${PARTITION_CNT} >&6
		exit 1
	fi
done
echo ${BLOCKSZ[*]}


#####################################
## figure out the start offsets (for losetup -o <OFFSET>)
say -b "obtaining partition start offsets"
OFFSETS=(`fdisk $GEOM -lu $VMIMG | tail -${PARTITION_CNT} | tr -s ' ' | cut -d' ' -f2`)
if [ ${#OFFSETS[*]} -ne $PARTITION_CNT ]; then
	say "  -> can't get partition offsets"
	fdisk $GEOM -lu $VMIMG | tail -${PARTITION_CNT} >&6
	exit 1
fi
for item in ${OFFSETS[*]}; do
	if [ $item -le 0 ]; then
		say "  -> non-numeric or out-of-range offset: $item"
		fdisk $GEOM -lu $VMIMG | tail -${PARTITION_CNT}
		exit 1
	fi
done
echo ${OFFSETS[*]}

#####################################
# process each partition
for ((CNT=0; CNT<$PARTITION_CNT; ++CNT)); do
	# skip extended partition
	if [ $CNT -eq 3 -a $PARTITION_CNT -gt 4 ]; then
		continue
	fi

	say -b "processing partition $((CNT+1))"
	OFFSET=`expr 512 \* ${OFFSETS[$CNT]}`
	echo " -> offset: $OFFSET"
	echo " -> blocks: ${BLOCKSZ[$CNT]}"
	echo " -> format: ${FORMATS[$CNT]}"
	echo " ->   data: ${DATA[$CNT]}"

	attach_loop -o $OFFSET $VMIMG

	# format
	say " -> formatting"
	if [ -n "${FORMATS[$CNT]}" ]; then
		${FORMATS[$CNT]} ${LOOPDEV} ${BLOCKSZ[$CNT]} > /dev/null 2>&1
	else
		$DEFAULTFMT ${LOOPDEV} ${BLOCKSZ[$CNT]} > /dev/null 2>&1
	fi
	if [ $? -ne 0 ]; then
		say "  -> formatting error"
		exit 1
	fi
	sync

	mount_push $LOOPDEV partition

	# data
	if [ -n "$(trim ${DATA[$CNT]})" ]; then
		say " -> processing data: '${DATA[$CNT]}'"
		PROCESSED=0
		TYPE=`file -b ${DATA[$CNT]}`

		# check for symbolic links
		echo $TYPE | grep "symbolic link" > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			DATA[$CNT]=`readlink -f ${DATA[$CNT]}`
			TYPE=`file -b ${DATA[$CNT]}`
		fi

		# fs image
		echo $TYPE | grep filesystem > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			say "  -> filesystem image ($TYPE)"
			mount_push -o loop ${DATA[$CNT]} data
			cp -a data/* partition/
			if [ $? -ne 0 ]; then
				say "   -> copy error"
				exit 1
			fi
			umount_pop
			PROCESSED=1
		fi

		# directory
		echo $TYPE | grep directory > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			say "  -> directory ($TYPE)"
			cp -a ${DATA[$CNT]}/* partition/
			if [ $? -ne 0 ]; then
				say "   -> copy error"
				exit 1
			fi
			PROCESSED=1
		fi

		# bzip2, gzip, tar, and xz
		echo $TYPE | grep bzip2 > /dev/null 2>&1
		BZIP2=$?
		echo $TYPE | grep gzip > /dev/null 2>&1
		GZIP=$?
		echo $TYPE | grep "tar archive" > /dev/null 2>&1
		TAR=$?
		echo $TYPE | grep "xz compressed" > /dev/null 2>&1
		XZ=$?
		if [ $BZIP2 -eq 0 -o $GZIP -eq 0 -o $TAR -eq 0 -o $XZ -eq 0 ]; then
			say "  -> tarball ($TYPE)"
			tar xvaf ${DATA[$CNT]} -C partition/
			if [ $? -ne 0 ]; then
				say "   -> uncompress error"
				exit 1
			fi
			PROCESSED=1
		fi

		# otherwise
		if [ $PROCESSED -eq 0 ]; then
			say "  -> other ($TYPE)"
			cp ${DATA[$CNT]} partition/
			if [ $? -ne 0 ]; then
				say "   -> copy error"
				exit 1
			fi
		fi
	fi

	umount_pop # partition with offset
	detach_loop $LOOPDEV
done

#####################################
# bootloader
say -b "installing bootloader"
if [ $LILO -ne 0 -o $EXTLINUX -ne 0 ]; then
	PART=0
	OFFSET=`expr 512 \* ${OFFSETS[$PART]}`
	echo " -> offset: $OFFSET"
	echo " -> blocks: ${BLOCKSZ[$PART]}"
	echo " -> format: ${FORMATS[$PART]}"
	attach_loop $VMIMG
	LOOPDEVP0=$LOOPDEV
	attach_loop -o $OFFSET $VMIMG
	LOOPDEVP1=$LOOPDEV
	mount_push ${LOOPDEVP1} part1

	if [ $LILO -eq 1 ]; then
		say " -> lilo"
		rm -f lilo.TMP
		echo "disk=$LOOPDEVP0" >> lilo.TMP
		echo -e "\tbios=0x80" >> lilo.TMP
		echo -e "\tcylinders=$CYL" >> lilo.TMP
		echo -e "\theads=$HDS" >> lilo.TMP
		echo -e "\tsectors=$SEC" >> lilo.TMP
		echo -e "\tpartition=$LOOPDEVP1" >> lilo.TMP
		echo -e "\t\tstart=${OFFSETS[0]}" >> lilo.TMP
		echo "" >> lilo.TMP
		echo "lba32" >> lilo.TMP
		echo "boot=$LOOPDEVP0" >> lilo.TMP
		echo -e "prompt\ntimeout=200\nmap=part1/boot/map\ninstall=part1/boot/boot.b" >> lilo.TMP
		echo "" >> lilo.TMP
		cat $LILO_CONF >> lilo.TMP
		echo "-------------------"
		echo "lilo config file:"
		cat lilo.TMP
		echo "-------------------"
		lilo -v3 -C lilo.TMP
		RET=$?
		rm -f lilo.TMP
		if [ $RET -ne 0 ]; then
			say "   -> lilo error"
			exit 1
		fi
	fi

	if [ $EXTLINUX -eq 1 ]; then
		say " -> extlinux"
		sfdisk $GEOM -A1 $LOOPDEVP0
		if [ $? -ne 0 ]; then
			say "  -> can't setup bootable partition"
			exit 1
		fi
		dd if="$EXTLINUX_MBR" of=$LOOPDEVP0
		if [ $? -ne 0 ]; then
			say "  -> failed to setup MBR ($EXTLINUX_MBR) of $LOOPDEVP0"
			exit 1
		fi
		cp "$EXTLINUX_MENU" "$EXTLINUX_CONF" part1/boot
		if [ $? -ne 0 ]; then
			say "  -> copy error"
			exit 1
		fi
		sync
		extlinux -H $HDS -S $SEC --install part1/boot
		if [ $? -ne 0 ]; then
			say "  -> extlinux failure"
			exit 1
		fi
		sync
	fi

	umount_pop # part1
	detach_loop $LOOPDEVP1
	detach_loop $LOOPDEVP0
else
	# just set first partition bootable
	say " -> no bootloader specified, setting boot flag on first partition"
	attach_loop $VMIMG
	sfdisk $GEOM -A1 $LOOPDEV
	if [ $? -ne 0 ]; then
		say "  -> can't setup bootable partition"
		exit 1
	fi
	detach_loop $LOOPDEV
fi
