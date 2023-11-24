#!/bin/bash
# It is designed to build Debian Linux for Variscite iMX modules
# prepare host OS system:
#  sudo apt-get install binfmt-support qemu qemu-user-static debootstrap kpartx
#  sudo apt-get install lvm2 dosfstools gpart binutils git lib32ncurses5-dev python-m2crypto
#  sudo apt-get install gawk wget git-core diffstat unzip texinfo gcc-multilib build-essential chrpath socat libsdl1.2-dev
#  sudo apt-get install autoconf libtool libglib2.0-dev libarchive-dev
#  sudo apt-get install python-git xterm sed cvs subversion coreutils texi2html
#  sudo apt-get install docbook-utils python-pysqlite2 help2man make gcc g++ desktop-file-utils libgl1-mesa-dev
#  sudo apt-get install libglu1-mesa-dev mercurial automake groff curl lzop asciidoc u-boot-tools mtd-utils
#

# -e  Exit immediately if a command exits with a non-zero status.
set -e

SCRIPT_NAME=${0##*/}

#### Exports Variables ####
#### global variables ####
readonly ABSOLUTE_FILENAME=`readlink -e "$0"`
readonly ABSOLUTE_DIRECTORY=`dirname ${ABSOLUTE_FILENAME}`
readonly SCRIPT_POINT=${ABSOLUTE_DIRECTORY}
readonly SCRIPT_START_DATE=`date +%Y%m%d`
readonly LOOP_MAJOR=7

# default mirror
readonly DEB_RELEASE="bookworm"
readonly DEF_ROOTFS_TARBALL_NAME="rootfs.tar.zst"
readonly DEF_CONSOLE_ROOTFS_TARBALL_NAME="console_rootfs.tar.zst"

# base paths
readonly DEF_BUILDENV="${ABSOLUTE_DIRECTORY}"
readonly DEF_SRC_DIR="${DEF_BUILDENV}/src"
readonly G_ROOTFS_DIR="${DEF_BUILDENV}/rootfs"
readonly G_ROOTFS_DEV_DIR="${DEF_BUILDENV}/rootfs-dev"
readonly G_TMP_DIR="${DEF_BUILDENV}/tmp"
readonly G_TOOLS_PATH="${DEF_BUILDENV}/toolchain"
readonly G_VARISCITE_PATH="${DEF_BUILDENV}/variscite"

#### user rootfs packages ####
readonly G_USER_PACKAGES=""

export LC_ALL=C

#### Input params ####
PARAM_OUTPUT_DIR="${DEF_BUILDENV}/output"
PARAM_DEBUG="0"
PARAM_CMD="all"
PARAM_BLOCK_DEVICE="na"

IS_QXP_B0=false

LOOP_DEV=""

### printing functions ###

# print error message
# $1 - printing string
function pr_error()
{
	echo "E: $1"
}

# print warning message
# $1 - printing string
function pr_warning()
{
	echo "W: $1"
}

# print info message
# $1 - printing string
function pr_info()
{
	echo "I: $1"
}

# print debug message
# $1 - printing string
function pr_debug() {
	echo "D: $1"
}

### usage ###
function usage()
{
	echo "Make Debian ${DEB_RELEASE} image and create a bootabled SD card"
	echo
	echo "Usage:"
	echo " MACHINE=<imx8mq-var-dart|imx8mm-var-dart|imx8mp-var-dart|imx8qxp-var-som|imx8qxpb0-var-som|imx8qm-var-som|imx8mn-var-som|imx6ul-var-dart|var-som-mx7> ./${SCRIPT_NAME} options"
	echo
	echo "Options:"
	echo "  -h|--help   -- print this help"
	echo "  -c|--cmd <command>"
	echo "     Supported commands:"
	echo "       deploy      -- prepare environment for all commands"
	echo "       all         -- build or rebuild kernel/bootloader/rootfs"
	echo "       bootloader  -- build or rebuild U-Boot"
	echo "       freertosvariscite - build or rebuild freertos for M4/M7 core"
	echo "       kernelpackage -- build or rebuild the Linux kernel packages"
	echo "       rootfs      -- build or rebuild the Debian root filesystem and create rootfs.tar.zst"
	echo "                       (including: make & install Debian packages, firmware and kernel modules & headers)"
	echo "       rubi        -- generate or regenerate rootfs.ubi.img image from rootfs folder "
	echo "       rtar        -- generate or regenerate rootfs.tar.zst image from the rootfs folder"
	echo "       clean       -- clean all build artifacts (without deleting sources code or resulted images)"
	echo "       sdcard      -- create a bootable SD card"
	echo "       sdimage     -- create a bootable SD card image"
	echo "  -o|--output -- custom select output directory (default: \"${PARAM_OUTPUT_DIR}\")"
	echo "  -d|--dev    -- specify SD card device (exmple: -d /dev/sde)"
	echo "  --debug     -- enable debug mode for this script"
	echo "Examples of use:"
	echo "  deploy and build:                 ./${SCRIPT_NAME} --cmd deploy && sudo ./${SCRIPT_NAME} --cmd all"
	echo "  make the Linux kernel only:       sudo ./${SCRIPT_NAME} --cmd kernel"
	echo "  make rootfs only:                 sudo ./${SCRIPT_NAME} --cmd rootfs"
	echo "  create SD card:                   sudo ./${SCRIPT_NAME} --cmd sdcard --dev /dev/sdX"
	echo
}

# umount previus mounts
function cleanup_mounts() {
	umount ${ROOTFS_BASE}/{sys,proc,dev/pts,dev} 2>/dev/null || true
}

# detach loop device(s)
function cleanup_losetup() {
	if [ ! -z "${LOOP_DEV}" ]; then
		pr_info "Detaching ${LOOP_DEV}"
		losetup -d ${LOOP_DEV}
		LOOP_DEV=""
	fi
}

# Run any cleanup before exiting
function cleanup {
    pr_info "Cleaning up..."

	cleanup_mounts
	cleanup_losetup
}

# Set up the trap command to run the cleanup function
trap 'cleanup EXIT' EXIT

if [ "${MACHINE}" = "imx8qxpb0-var-som" ]; then
	MACHINE="imx8qxp-var-som"
	IS_QXP_B0=true
fi

if [ ! -e ${G_VARISCITE_PATH}/${MACHINE}/${MACHINE}.sh ]; then
	echo "Illegal MACHINE: ${MACHINE}"
	echo
	usage
	exit 1
fi

source ${G_VARISCITE_PATH}/${MACHINE}/${MACHINE}.sh
# freertos-variscite globals
if [ ! -z "${G_FREERTOS_VAR_SRC_DIR}" ]; then
	readonly G_FREERTOS_VAR_BUILD_DIR="${G_FREERTOS_VAR_SRC_DIR}.build"
fi

# check for toolchain
function check_toolchain() {
	# Toolchain globals
	case "${SOC_FAMILY}" in
		am6)
			#32 and 64 bit CROSS_COMPILERs
			if [ -z "${G_CROSS_COMPILER_32BIT_NAME}" ] || [ -z "${G_CROSS_COMPILER_64BIT_NAME}" ]; then
				return 0
			fi
			;;
		imx6*|imx7*)
			#32 bit CROSS_COMPILER
			if [ -z "${G_CROSS_COMPILER_32BIT_NAME}" ]; then
				return 0
			fi
			;;
		imx8*|imx9*)
			#64 bit CROSS_COMPILER
			if [ -z "${G_CROSS_COMPILER_64BIT_NAME}" ]; then
				return 0
			fi
			;;

		*)
			return 0
		;;
	esac

	return 1
}

if check_toolchain; then
	echo "E: Unknown toolchain for SOC_FAMILY '${SOC_FAMILY}'"
	exit 1;
fi

readonly G_CROSS_COMPILER_JOPTION="-j$(nproc)"

# Setup helper scripts according to SOC_FAMILY
case "${SOC_FAMILY}" in
	am6)
		source ${G_VARISCITE_PATH}/u-boot-am6.sh
		source ${G_VARISCITE_PATH}/kernel-am6.sh
		source ${G_VARISCITE_PATH}/weston_rootfs_am6.sh
		;;
	imx*)
		source ${G_VARISCITE_PATH}/u-boot-imx.sh
		source ${G_VARISCITE_PATH}/kernel-imx.sh
		source ${G_VARISCITE_PATH}/weston_rootfs_imx.sh
		;;
	*)
		echo "E: Unknown SOC_FAMILY \"${SOC_FAMILY}\" when setting up helper scripts";
		exit 1
		;;
esac

# Setup cross compiler path, name, kernel dtb path, kernel image type, helper scripts
if [ "${ARCH_CPU}" = "64BIT" ]; then
	G_CROSS_COMPILER_NAME=${G_CROSS_COMPILER_64BIT_NAME}
	G_EXT_CROSS_COMPILER_LINK=${G_EXT_CROSS_64BIT_COMPILER_LINK}
	G_CROSS_COMPILER_ARCHIVE=${G_CROSS_COMPILER_ARCHIVE_64BIT}
	G_CROSS_COMPILER_PREFIX=${G_CROSS_COMPILER_64BIT_PREFIX}
	ARCH_ARGS="arm64"
	# Include weston backend rootfs helper
	source ${G_VARISCITE_PATH}/base_rootfs.sh
	source ${G_VARISCITE_PATH}/weston_rootfs.sh
	source ${G_VARISCITE_PATH}/linux-headers_debian_src/create_kernel_tree.sh
elif [ "${ARCH_CPU}" = "32BIT" ]; then
	G_CROSS_COMPILER_NAME=${G_CROSS_COMPILER_32BIT_NAME}
	G_EXT_CROSS_COMPILER_LINK=${G_EXT_CROSS_32BIT_COMPILER_LINK}
	G_CROSS_COMPILER_ARCHIVE=${G_CROSS_COMPILER_ARCHIVE_32BIT}
	G_CROSS_COMPILER_PREFIX=${G_CROSS_COMPILER_32BIT_PREFIX}
	ARCH_ARGS="arm"
	# Include x11 backend rootfs helper
	source ${G_VARISCITE_PATH}/base_rootfs.sh
	source ${G_VARISCITE_PATH}/console_rootfs.sh
	source ${G_VARISCITE_PATH}/linux-headers_debian_src/create_kernel_tree_arm.sh
	source ${G_VARISCITE_PATH}/x11_rootfs.sh
else
	echo " Error unknown CPU type"
	exit 1
fi

PARAM_DEB_LOCAL_MIRROR="${DEF_DEBIAN_MIRROR}"
G_CROSS_COMPILER_PATH="${G_TOOLS_PATH}/${G_CROSS_COMPILER_NAME}/bin"

## parse input arguments ##
readonly SHORTOPTS="c:o:d:i:h"
readonly LONGOPTS="cmd:,output:,dev:,imagename:,help,debug"

ARGS=$(getopt -s bash --options ${SHORTOPTS}  \
  --longoptions ${LONGOPTS} --name ${SCRIPT_NAME} -- "$@" )

eval set -- "$ARGS"

while true; do
	case $1 in
		-c|--cmd ) # script command
			shift
			PARAM_CMD="$1";
			;;
		-o|--output ) # select output dir
			shift
			PARAM_OUTPUT_DIR="$1";
			;;
		-d|--dev ) # SD card block device
			shift
			[ -e ${1} ] && {
				PARAM_BLOCK_DEVICE=${1};
			};
			;;
		-i|--imagename) # SD card image name
			shift
			PARAM_IMAGE_NAME=${1};
			;;
		--debug ) # enable debug
			PARAM_DEBUG=1;
			;;
		-h|--help ) # get help
			usage
			exit 0;
			;;
		-- )
			shift
			break
			;;
		* )
			shift
			break
			;;
	esac
	shift
done

# enable trace option in debug mode
[ "${PARAM_DEBUG}" = "1" ] && {
	echo "Debug mode enabled!"
	set -x
};

echo "=============== Build summary ==============="
if [ "${IS_QXP_B0}" = true ]; then
	echo "Building Debian ${DEB_RELEASE} for imx8qxpb0-var-som"
else
	echo "Building Debian ${DEB_RELEASE} for ${MACHINE}"
fi
echo "Building Debian ${DEB_RELEASE} for ${MACHINE}"
echo "U-Boot config:      ${G_UBOOT_DEF_CONFIG_MMC}"
echo "Kernel config:      ${G_LINUX_KERNEL_DEF_CONFIG}"
echo "Default kernel dtb: ${DEFAULT_BOOT_DTB}"
echo "kernel dtbs:        ${G_LINUX_DTB}"
echo "============================================="
echo

## declarate dynamic variables ##
readonly G_ROOTFS_TARBALL_PATH="${PARAM_OUTPUT_DIR}/${DEF_ROOTFS_TARBALL_NAME}"
readonly G_CONSOLE_ROOTFS_TARBALL_PATH="${PARAM_OUTPUT_DIR}/${DEF_CONSOLE_ROOTFS_TARBALL_NAME}"

###### local functions ######

readonly STEP_FILE=${ABSOLUTE_DIRECTORY}/.build_steps
# Save step to ${STEP_FILE}
# $1 - step
save_step() {
	if ! [ -f "$STEP_FILE" ] || ! grep -q "$1" "$STEP_FILE"; then
		echo "$(date) $1" >> "${STEP_FILE}"
	fi
}

# Check if step exists in ${STEP_FILE}
# $1 - step
check_step() {
	if [ -f "$STEP_FILE" ] && grep -q "$1" "$STEP_FILE"; then
		pr_info "skip: $1"
		return 0 # state found
	else
		return 1 # state not found
	fi
}

# Run a function if it hasn't already finished
# $1 - function to run
run_step() {
	local function_name="$1"
	shift
	# Save step name and trim white space
	local step_name="${function_name} $@"
	step_name="${step_name%"${step_name##*[![:space:]]}"}"

	# Call function_name if the step is new
	check_step "${step_name}" || "${function_name}" "$@"
	save_step "${step_name}"
}

# Remove a step from the steps file.
# $1 - step
clean_step() {
    local step="$1"
    local temp_file=$(mktemp)

    # Copy lines not containing the search string to a temporary file
    grep -v "$step" "${STEP_FILE}" > "$temp_file"

    # Move the temporary file back to the original file
    mv "$temp_file" "${STEP_FILE}"
}


### work functions ###
# get_var_required - retrieves the value of a required variable constructed from a prefix and suffix
# Arguments:
#   $1 - The prefix of the variable name
#   $2 - The suffix of the variable name
# Returns:
#   The value of the variable, or exits with an error message if the variable is empty or does not exist
get_var_required() {
	local prefix="$1"
	local suffix="$2"
	local var_name="${prefix}${suffix}"
	if [ -z "${!var_name}" ]; then
		echo "Error: Variable ${var_name} does not exist or is empty" >&2
		exit 1
	fi
	echo "${!var_name}"
}

# get_var_required - retrieves the value of a optional variable constructed from a prefix and suffix
# Arguments:
#   $1 - The prefix of the variable name
#   $2 - The suffix of the variable name
# Returns:
#   The value of the variable
get_var_optional() {
	local prefix="$1"
	local suffix="$2"
	local var_name="${prefix}${suffix}"
	echo "${!var_name}"
}

# get sources from git repository
# $1 - git repository
# $2 - branch name
# $3 - output dir
# $4 - commit id
# $5 - optional list of local patches
function get_git_src()
{
	# clone src code
	git clone ${1} -b ${2} ${3}
	cd ${3}
	git reset --hard ${4}
	if [ -n "${5}" ]; then
		for patch in ${5}; do
			echo "Applying ${patch}"
			patch -p1 < ${patch}
		done
	fi
	cd -
}

# get remote file
# $1 - remote file
# $2 - local file
# $3 - optional sha256sum
function get_remote_file()
{
	# download remote file
	wget -c ${1} -O ${2}

	# verify sha256sum
	if [ -n "${3}" ]; then
		echo "${3} ${2}" | sha256sum -c
	fi
}

function make_prepare()
{
	# create src dir
	mkdir -p ${DEF_SRC_DIR}

	# create toolchain dir
	mkdir -p ${G_TOOLS_PATH}

	# create rootfs dir
	mkdir -p ${G_ROOTFS_DIR}

	# create out dir
	mkdir -p ${PARAM_OUTPUT_DIR}

	# create tmp dir
	mkdir -p ${G_TMP_DIR}
}


# make tarball from footfs
# $1 -- packet folder
# $2 -- output tarball file (full name)
function make_tarball()
{
	cd $1

	chown root:root .
	pr_info "make tarball from folder ${1}"
	pr_info "Remove old tarball $2"
	rm -f $2

	pr_info "Create $2"

	RETVAL=0
	tar -cf - . | zstd -T0 -8 -o $2 || {
		RETVAL=1
		rm -f $2
	};
	chmod +r $2

	cd -
	return $RETVAL
}

compile_fw() {
    DIR_GCC="$1"
    cd ${DIR_GCC}
    ./clean.sh
    ./build_all.sh > /dev/null
}

# build freertos_variscite
# $1 -- output directory
function make_freertos_variscite()
{
    export ARMGCC_DIR=${G_TOOLS_PATH}/${G_CM_GCC_OUT_DIR}

    # Clean previous build
    rm -rf ${G_FREERTOS_VAR_BUILD_DIR}
    cp -r ${G_FREERTOS_VAR_SRC_DIR} ${G_FREERTOS_VAR_BUILD_DIR}

    # Copy and patch hello_world demo to disable_cache demo
    if [[ -f "${G_VARISCITE_PATH}/${MACHINE}/${DISABLE_CACHE_PATCH}" ]]; then
        # Copy hello_world demo
        cp -r ${G_FREERTOS_VAR_BUILD_DIR}/boards/${CM_BOARD}/demo_apps/hello_world/ ${G_FREERTOS_VAR_BUILD_DIR}/boards/${CM_BOARD}/demo_apps/disable_cache
        # Rename hello_world strings to disable_cache
        grep -rl hello_world ${G_FREERTOS_VAR_BUILD_DIR}/boards/${CM_BOARD}/demo_apps/disable_cache | xargs sed -i 's/hello_world/disable_cache/g'
        # Rename hello_world files to disable_cache
        find ${G_FREERTOS_VAR_BUILD_DIR}/boards/${CM_BOARD}/demo_apps/disable_cache/ -name '*hello_world*' -exec sh -c 'mv "$1" "$(echo "$1" | sed s/hello_world/disable_cache/)"' _ {} \;
    fi

    for cm_board in ${CM_BOARD}; do
        # Build all demos in CM_DEMOS
        for CM_DEMO in ${CM_DEMOS}; do
            compile_fw "${G_FREERTOS_VAR_BUILD_DIR}/boards/${cm_board}/${CM_DEMO}/armgcc"
        done
    done

    # Build firmware to reset cache
    if [[ -f "${G_VARISCITE_PATH}/${MACHINE}/${DISABLE_CACHE_PATCH}" ]]; then
        # Apply patch to disable cache for machine
        cd $G_FREERTOS_VAR_BUILD_DIR && git apply ${G_VARISCITE_PATH}/${MACHINE}/${DISABLE_CACHE_PATCH}

        # Build the firmware
        for CM_DEMO in ${CM_DEMOS_DISABLE_CACHE}; do
                compile_fw "${G_FREERTOS_VAR_BUILD_DIR}/boards/${CM_BOARD}/${CM_DEMO}/armgcc"
        done
        fi
    cd -
}

# build sc firmware
# $1 -- output directory
function make_imx_sc_fw()
{
    cd ${G_IMX_SC_FW_SRC_DIR}/src/scfw_export_${G_IMX_SC_MACHINE_NAME}
    TOOLS=${G_TOOLS_PATH} make clean-${G_IMX_SC_FW_FAMILY}
    TOOLS=${G_TOOLS_PATH} make ${G_IMX_SC_FW_FAMILY} R=B0 B=var_som V=1
    cp build_${G_IMX_SC_MACHINE_NAME}/scfw_tcm.bin $1
	cd -
}

# generate seco firmware
# $1 -- output directory
function make_imx_seco_fw()
{
	# Cleanup
	rm -rf ${G_IMX_SECO_SRC_DIR}
	mkdir -p ${G_IMX_SECO_SRC_DIR}

	# Fetch
	cd ${G_IMX_SECO_SRC_DIR}
	get_remote_file ${G_IMX_SECO_URL} ${G_IMX_SECO_SRC_DIR}/${G_IMX_SECO_BIN} ${G_IMX_SECO_SHA256SUM}

	# Build
	chmod +x ${G_IMX_SECO_SRC_DIR}/${G_IMX_SECO_BIN}
	${G_IMX_SECO_SRC_DIR}/${G_IMX_SECO_BIN} --auto-accept
	cp ${G_IMX_SECO_IMG} $1
	cd -
}

# make *.ubi image from rootfs
# params:
#  $1 -- path to rootfs dir
#  $2 -- tmp dir
#  $3 -- output dir
#  $4 -- ubi file name
function make_ubi() {
	readonly local _rootfs=${1};
	readonly local _tmp=${2};
	readonly local _output=${3};
	readonly local _ubi_file_name=${4};

	readonly local UBI_CFG="${_tmp}/ubi.cfg"
	readonly local UBIFS_IMG="${_tmp}/rootfs.ubifs"
	readonly local UBI_IMG="${_output}/${_ubi_file_name}"
	readonly local UBIFS_ROOTFS_DIR="${DEF_BUILDENV}/rootfs_ubi_tmp"

	rm -rf ${UBIFS_ROOTFS_DIR}
	cp -a ${_rootfs} ${UBIFS_ROOTFS_DIR}

	# prepare qemu 32bit
	if [ ! -f "${UBIFS_ROOTFS_DIR}/usr/bin/qemu-arm-static" ]; then
		cp "${G_VARISCITE_PATH}/qemu_32bit/qemu-arm-static" "${UBIFS_ROOTFS_DIR}/usr/bin/qemu-arm-static"
	fi

## ubifs rootfs clenup command
echo "#!/bin/bash
apt-get clean
rm -rf /tmp/*
rm -f cleanup
" > ${UBIFS_ROOTFS_DIR}/cleanup

	# clean all packages
	pr_info "ubifs rootfs: clean"
	chmod +x ${UBIFS_ROOTFS_DIR}/cleanup
	chroot ${UBIFS_ROOTFS_DIR} /cleanup
	rm ${UBIFS_ROOTFS_DIR}/usr/bin/qemu-arm-static

	prepare_ubifs_rootfs ${UBIFS_ROOTFS_DIR}
	# gnerate ubifs file
	pr_info "Generate ubi config file: ${UBI_CFG}"
cat > ${UBI_CFG} << EOF
[ubifs]
mode=ubi
image=${UBIFS_IMG}
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_flags=autoresize
EOF
	# delete previus images
	rm -f ${UBI_IMG}
	rm -f ${UBIFS_IMG}

	pr_info "Creating $UBIFS_IMG image"
	mkfs.ubifs -x zlib -m 2048  -e 124KiB -c 3965 -r ${UBIFS_ROOTFS_DIR} $UBIFS_IMG

	pr_info "Creating $UBI_IMG image"
	ubinize -o ${UBI_IMG} -m 2048 -p 128KiB -s 2048 -O 2048 ${UBI_CFG}

	# delete unused file
	rm -f ${UBIFS_IMG}
	rm -f ${UBI_CFG}
	return 0;
}

# clean U-Boot
# $1 -- U-Boot dir path
function clean_uboot()
{
	pr_info "Clean U-Boot"
	make ARCH=${ARCH_ARGS} -C ${1}/ mrproper
}

# verify the SD card
# $1 -- block device
function check_sdcard()
{
	# Check that parameter is a valid block device
	if [ ! -b "$1" ]; then
		pr_error "$1 is not a valid block device, exiting"
		return 1
	fi

	local dev=$(basename $1)

	# Check that /sys/block/$dev exists
	if [ ! -d /sys/block/$dev ]; then
		pr_error "Directory /sys/block/${dev} missing, exiting"
		return 1
	fi

	# Get device parameters
	local removable=$(cat /sys/block/${dev}/removable)
	local block_size=$(cat /sys/class/block/${dev}/queue/physical_block_size)
	local size_bytes=$((${block_size}*$(cat /sys/class/block/${dev}/size)))
	local size_gib=$(bc <<< "scale=1; ${size_bytes}/(1024*1024*1024)")

	# Non removable SD card readers require additional check
	if [ "${removable}" != "1" ]; then
		local drive=$(udisksctl info -b /dev/${dev}|grep "Drive:"|cut -d"'" -f 2)
		local mediaremovable=$(gdbus call --system --dest org.freedesktop.UDisks2 --object-path ${drive} \
			--method org.freedesktop.DBus.Properties.Get org.freedesktop.UDisks2.Drive MediaRemovable)
		if [[ "${mediaremovable}" = *"true"* ]]; then
			removable=1
		fi
	fi

	# Check that device is either removable or loop
	if [ "$removable" != "1" -a $(stat -c '%t' /dev/$dev) != ${LOOP_MAJOR} ]; then
		pr_error "$1 is not a removable device, exiting"
		return 1
	fi

	# Check that device is attached
	if [ ${size_bytes} -eq 0 ]; then
		pr_error "$1 is not attached, exiting"
		return 1
	fi

	pr_info "Device: ${LPARAM_BLOCK_DEVICE}, ${size_gib}GiB"
	echo "============================================="
	read -p "Press Enter to continue"

	return 0
}

# make imx sdma firmware
# $1 -- linux-firmware directory
# $2 -- rootfs output dir
function make_imx_sdma_fw() {
	pr_info "Install imx sdma firmware"
	install -d ${2}/lib/firmware/imx/sdma
	if [ "${MACHINE}" = "imx6ul-var-dart" ]; then
		install -m 0644 ${1}/imx/sdma/sdma-imx6q.bin \
		${2}/lib/firmware/imx/sdma
	elif  [ "${MACHINE}" = "var-som-mx7" ]; then
		install -m 0644 ${1}/imx/sdma/sdma-imx7d.bin \
		${2}/lib/firmware/imx/sdma
	fi
	install -m 0644 ${1}/LICENSE.sdma_firmware ${2}/lib/firmware/
}

# make ethos-u-firmware
# $1 -- ethos-u-firmware git directory
# $2 -- rootfs output dir
function make_ethosu_fw() {
	pr_info "Install ethos-u-firmware"
	install -m 0644 ${1}/ethosu_firmware ${2}/lib/firmware/
}

# make firmware for wl bcm module
# $1 -- brcm source directory
# $2 -- rootfs output dir
function make_brcm_fw()
{
	pr_info "Make and install brcm configs and firmware"

	install -d ${2}/lib/firmware/brcm
	install -m 0644 ${1}/lib/firmware/brcm/* ${2}/lib/firmware/brcm/
	install -m 0644 ${1}/LICENSE ${2}/lib/firmware/LICENCE.broadcom_bcm43xx

	for model in ${MODEL_LIST}; do
		# Add model symbolic links to brcmfmac4339
		ln -sf brcmfmac4339-sdio.txt \
			${2}/lib/firmware/brcm/brcmfmac4339-sdio.variscite,${model}.txt
		ln -sf brcmfmac4339-sdio.bin \
			${2}/lib/firmware/brcm/brcmfmac4339-sdio.variscite,${model}.bin

		# Add model symbolic links to brcmfmac43430
		ln -sf brcmfmac43430-sdio.txt \
			${2}/lib/firmware/brcm/brcmfmac43430-sdio.variscite,${model}.txt
		ln -sf brcmfmac43430-sdio.bin \
			${2}/lib/firmware/brcm/brcmfmac43430-sdio.variscite,${model}.bin
	done
}

# make firmware for wl murata/nxp module
# $1 -- rootfs output dir
function make_iw612_fw()
{
	pr_info "Make and install iw612 configs and firmware"

	# Install Firmware
	set -x
	install -d ${1}/lib/firmware/nxp/IW612_SD_RFTest
	install -m 0644 ${G_IW612_FW_WORK_DIR}/*.se ${1}/lib/firmware/nxp
	install -m 0644 ${G_IW612_FW_WORK_DIR}/IW612_SD_RFTest/*.se ${1}/lib/firmware/nxp/IW612_SD_RFTest
	install -m 0644 ${G_IW612_FW_WORK_DIR}/../wifi_mod_para.conf ${1}/lib/firmware/nxp

	# Install Config
	install -d ${1}/etc/modprobe.d/
	install -m 0644 ${G_META_VARISCITE_BSP_SRC_DIR}/recipes-kernel/kernel-modules/kernel-module-nxp-wlan/moal_modprobe.conf \
		${1}/etc/modprobe.d/
}

################ commands ################

function cmd_make_deploy()
{
	# get 32 bit toolchain
	if [ -n "$G_CROSS_COMPILER_32BIT_PATH" ]; then
		(( `ls ${G_CROSS_COMPILER_32BIT_PATH} 2>/dev/null | wc -l` == 0 )) && {
			pr_info "Get and unpack cross compiler";
			get_remote_file ${G_EXT_CROSS_32BIT_COMPILER_LINK} \
				${DEF_SRC_DIR}/${G_CROSS_COMPILER_ARCHIVE_32BIT}
			tar -xJf ${DEF_SRC_DIR}/${G_CROSS_COMPILER_ARCHIVE_32BIT} \
				-C ${G_TOOLS_PATH}/
		};
	fi

	# get 64 bit toolchain
	if [ -n "$G_CROSS_COMPILER_64BIT_PATH" ]; then
		(( `ls ${G_CROSS_COMPILER_64BIT_PATH} 2>/dev/null | wc -l` == 0 )) && {
			pr_info "Get and unpack cross compiler";
			get_remote_file ${G_EXT_CROSS_64BIT_COMPILER_LINK} \
				${DEF_SRC_DIR}/${G_CROSS_COMPILER_ARCHIVE_64BIT}
			tar -xJf ${DEF_SRC_DIR}/${G_CROSS_COMPILER_ARCHIVE_64BIT} \
				-C ${G_TOOLS_PATH}/
		};
	fi

	# get scfw dependencies
	if [ -n ${G_IMX_SC_FW_REV} ]; then
		# get scfw toolchain
		readonly G_SCFW_CROSS_COMPILER_PATH="${G_TOOLS_PATH}/${G_IMX_SC_FW_TOOLCHAIN_NAME}"
		(( `ls ${G_SCFW_CROSS_COMPILER_PATH} 2>/dev/null | wc -l` == 0 )) && {
			pr_info "Get and unpack scfw cross compiler";
			get_remote_file ${G_IMX_SC_FW_TOOLCHAIN_LINK} \
				${DEF_SRC_DIR}/${G_IMX_SC_FW_TOOLCHAIN_ARCHIVE} \
				${G_IMX_SC_FW_TOOLCHAIN_SHA256SUM}
			tar -xf ${DEF_SRC_DIR}/${G_IMX_SC_FW_TOOLCHAIN_ARCHIVE} \
				-C ${G_TOOLS_PATH}/
		};
	fi

	# Fetch git sources added to git_repos
	#   Assign a default number of git repositories to fetch at once
	#   PARALLEL_FETCH can be overriden by the command line
	PARALLEL_FETCH=${PARALLEL_FETCH:-4}
	pr_info "Fetching from git using ${PARALLEL_FETCH} threads"
	for repo in "${git_repos[@]}"; do
		repo_src_dir=$(get_var_required "$repo" "_SRC_DIR")
		repo_git=$(get_var_required "$repo" "_GIT")
		repo_branch=$(get_var_required "$repo" "_BRANCH")
		repo_rev=$(get_var_required "$repo" "_REV")
		repo_patches=$(get_var_optional "$repo" "_PATCHES")

		(( `ls ${repo_src_dir} 2>/dev/null | wc -l` == 0 )) && {
			pr_info "Fetching ${repo_branch}@${repo_rev:0:8} from ${repo_git}"
			# Fetch the source in the background
			get_git_src "${repo_git}" "${repo_branch}" "${repo_src_dir}" "${repo_rev}" "${repo_patches}" &
			# Limit the number of parallel processes
			while (( $(jobs -r -p | wc -l) >= ${PARALLEL_FETCH} )); do sleep 1; done
		}
	done

	# Wait for all background fetch processes to finish
	wait

	# get freertos-variscite dependencies
	if [ ! -z "${G_FREERTOS_VAR_SRC_DIR}" ]; then
		# get Cortex-M toolchain
		readonly G_CM_GCC_PATH="${G_TOOLS_PATH}/${G_CM_GCC_OUT_DIR}"
		(( `ls ${G_CM_GCC_PATH} 2>/dev/null | wc -l` == 0 )) && {
			pr_info "Get and unpack Cortex-M cross compiler";
			get_remote_file ${G_CM_GCC_LINK} \
				${DEF_SRC_DIR}/${G_CM_GCC_ARCHIVE} \
				${G_CM_GCC_SHA256SUM}
			mkdir -p ${G_TOOLS_PATH}/${G_CM_GCC_OUT_DIR}
			tar -xf ${DEF_SRC_DIR}/${G_CM_GCC_ARCHIVE} --strip-components=1 \
				-C ${G_TOOLS_PATH}/${G_CM_GCC_OUT_DIR}/
		};
	fi

	# get brcm lwb/lbw5 firmware archive
	if [ ! -z ${G_BRCM_FW_SRC_DIR} ]; then
		# get brcm lwb firmware archive
		(( `ls ${G_BRCM_FW_SRC_DIR} 2>/dev/null | wc -l` == 0 )) && {
			# Cleanup
			mkdir -p ${G_BRCM_FW_SRC_DIR}

			pr_info "Get and unpack brcm lwb firmware archive";
			get_remote_file ${G_BRCM_LWB_FW_LINK} \
				${G_BRCM_FW_SRC_DIR}/${G_BRCM_LWB_FW_ARCHIVE} \
				${G_BRCM_LWB_FW_SHA256SUM}
			tar -xf ${G_BRCM_FW_SRC_DIR}/${G_BRCM_LWB_FW_ARCHIVE} \
				-C ${G_BRCM_FW_SRC_DIR}

			pr_info "Get and unpack brcm lwb5 firmware archive";
			get_remote_file ${G_BRCM_LWB5_FW_LINK} \
				${G_BRCM_FW_SRC_DIR}/${G_BRCM_LWB5_FW_ARCHIVE} \
				${G_BRCM_LWB5_FW_SHA256SUM}
			tar -xf ${G_BRCM_FW_SRC_DIR}/${G_BRCM_LWB5_FW_ARCHIVE} \
				-C ${G_BRCM_FW_SRC_DIR}
		};
	fi

	return 0
}

# Build a minimal rootfs as a foundation for all other rootfs
function make_rootfs_base()
{
	make_prepare;

	# build base rootfs
	make_debian_base_rootfs ${G_ROOTFS_DIR}

	# build development rootfs
	run_step "make_debian_dev_rootfs"
}

function cmd_make_rootfs()
{
	run_step "make_rootfs_base"

	# build kernel packages
	cmd_make_kernel_package

	if [ "${MACHINE}" = "imx6ul-var-dart" ] ||
	   [ "${MACHINE}" = "var-som-mx7" ]; then
		# make debian console rootfs
		cd ${G_ROOTFS_DIR}
		make_debian_console_rootfs ${G_ROOTFS_DIR}
		# make imx sdma firmware
		make_imx_sdma_fw ${G_IMX_SDMA_FW_SRC_DIR} ${G_ROOTFS_DIR}
		cd -
	else
		# make debian weston backend rootfs for imx8 family
		cd ${G_ROOTFS_DIR}
		make_debian_weston_rootfs ${G_ROOTFS_DIR}
		cd -
	fi

	# make bcm firmwares
	if [ -d "${G_BRCM_FW_SRC_DIR}" ]; then
		make_brcm_fw ${G_BRCM_FW_SRC_DIR} ${G_ROOTFS_DIR}
	fi

	# make iw612 firmwares
	cmd_make_iw612fw

	# make ethos-u-firmware
	if [ -d "${G_ETHOSU_FIRMWARE_SRC_DIR}" ]; then
		make_ethosu_fw ${G_ETHOSU_FIRMWARE_SRC_DIR} ${G_ROOTFS_DIR}
	fi

	if [ "${MACHINE}" = "imx6ul-var-dart" ] ||
	   [ "${MACHINE}" = "var-som-mx7" ]; then
		# pack to ubi
		make_ubi ${G_ROOTFS_DIR} ${G_TMP_DIR} ${PARAM_OUTPUT_DIR} \
				${G_UBI_FILE_NAME}
		# pack console rootfs
		make_tarball ${UBIFS_ROOTFS_DIR} ${G_CONSOLE_ROOTFS_TARBALL_PATH}
		rm -rf ${UBIFS_ROOTFS_DIR}
	fi

	if [ "${MACHINE}" = "imx6ul-var-dart" ] ||
	   [ "${MACHINE}" = "var-som-mx7" ]; then
		# make debian x11 backend rootfs
		cd ${G_ROOTFS_DIR}
		make_debian_x11_rootfs ${G_ROOTFS_DIR}
		cd -
	fi

	# pack full rootfs
	make_tarball ${G_ROOTFS_DIR} ${G_ROOTFS_TARBALL_PATH}
}

function cmd_make_freertos_variscite()
{
	if [ ! -z "${G_FREERTOS_VAR_SRC_DIR}" ]; then
		make_freertos_variscite ${G_FREERTOS_VAR_SRC_DIR} ${PARAM_OUTPUT_DIR}
	fi
}

function cmd_make_uboot()
{
	make_uboot ${G_UBOOT_SRC_DIR} ${PARAM_OUTPUT_DIR}
}

# Add files to an existing deb package
# $1 -- Path to deb package
# $2 -- Source file path
# $3 -- Dest directory path inside package
function dpkg_add_files()
{
	deb_package="$1"
	src_files="$2"
	dest_files="$3"
	tmp_deb_dir=".dpkg_add_files"

	# Cleanup
	rm -rf ${tmp_deb_dir}
	mkdir -p ${tmp_deb_dir}

	# Verify arguments
	if [ ! -f $deb_package ]; then
		pr_error "dpkg_add_files: deb: Could not find $deb_package"
		exit 1
	fi
	if ! ls -d $src_files >/dev/null 2>&1; then
		pr_error "dpkg_add_files: src: Could not find $src_files"
		exit 1
	fi

	# Unpack original deb
	dpkg-deb -R $deb_package $tmp_deb_dir
	if [ ! -d $tmp_deb_dir/$dest_files ]; then
		pr_error "dpkg_add_files: dest: Could not find $tmp_deb_dir/$dest_files"
		exit 1
	fi

	# Copy files
	cp -r $src_files $tmp_deb_dir/$dest_files

	# Repack new deb
	dpkg-deb -b ${tmp_deb_dir} $deb_package

	# Cleanup
	rm -rf ${tmp_deb_dir}
}

# Kernel header scripts must be compiled using chroot. They currently
# cannot be cross compiled
function kernel_fixup_header_scripts()
{
	# Setup global variables for chroot script
	readonly G_KDIR=/root/linux-${krelease}
	readonly G_KARGS=" \
		ARCH=${ARCH_ARGS} \
		${G_CROSS_COMPILER_JOPTION} \
		${image_extra_args} \
	"

	pr_info "kernel_fixup_header_scripts"

	# Copy kernel source to development rootfs
	if [ ! -d ${G_KDIR} ]; then
		rsync -a --stats --quiet ${G_LINUX_KERNEL_SRC_DIR} ${G_ROOTFS_DEV_DIR}/${G_KDIR}
	fi

	# Build kernel scripts
	run_rootfs_stage "rootfs-stage-kernel-header-fixup" "rootfs: build kernel packages" ${G_ROOTFS_DEV_DIR}

	# Get linux-headers package name
	headers_package=linux-headers-${krelease}_${krelease}-1_${ARCH_ARGS}.deb

	# Update the package with the new scripts
	dpkg_add_files \
		"${DEF_SRC_DIR}/${headers_package}" \
		"${G_ROOTFS_DEV_DIR}${G_KDIR}/kernel/scripts/*" \
		"/usr/src/linux-headers-${krelease}/scripts"
}

function cmd_make_kernel_package()
{
	# Building the kernel package depends on the base rootfs for chroot
	run_step "make_rootfs_base"

	# Build string of common kernel arguments
	if [ ! -z "${UIMAGE_LOADADDR}" ]; then
		image_extra_args="LOADADDR=${UIMAGE_LOADADDR}"
	fi
	kargs=" \
		-C ${G_LINUX_KERNEL_SRC_DIR} \
		ARCH=${ARCH_ARGS} \
		CROSS_COMPILE=${G_CROSS_COMPILER_PATH}/${G_CROSS_COMPILER_PREFIX} \
		${G_CROSS_COMPILER_JOPTION} \
		${image_extra_args} \
	"

	# Clean directory
	make ${kargs} mrproper

	# Make defconfig
	make ${kargs} ${G_LINUX_KERNEL_DEF_CONFIG}

	# Get kernel release
	krelease=$(make ${kargs} kernelrelease | grep -v "directory")

	# Save the name of the final debian package
	kpackage=linux-image-${krelease}_${krelease}-1_${ARCH_ARGS}.deb

	# Check if the package already exists in apt repository
	if [ -f "${G_ROOTFS_DIR}/srv/local-apt-repository/${kpackage}" ]; then
		pr_info "cmd_make_kernel_package: File '${G_ROOTFS_DIR}/srv/local-apt-repository/${kpackage}' exists, skipping"
		return 0
	else
		pr_info "cmd_make_kernel_package: Building ${krelease} packages"
	fi
	clean_step "rootfs_install_kernel"

	# Generate debian package using make bindeb-pkg
	make ${kargs} KBUILD_IMAGE=arch/arm64/boot/${KERNEL_IMAGE_TYPE} bindeb-pkg

	# Cross compile kernel header scripts
	kernel_fixup_header_scripts

	# Cross compile external modules
	if [[ $(type -t make_kernel_modules_ext) == function ]]; then
		tmp_mod_dir="${DEF_SRC_DIR}/.modules"

		# Clean external modules
		rm -rf ${tmp_mod_dir}; mkdir -p ${tmp_mod_dir}
		clean_kernel_modules_ext ${1}

		# Build the modules
		pr_info "Build the external Linux kernel modules"
		make_kernel_modules_ext \
			${G_CROSS_COMPILER_PATH}/${G_CROSS_COMPILER_PREFIX} \
			${G_LINUX_KERNEL_DEF_CONFIG} \
			${G_LINUX_KERNEL_SRC_DIR} \
			"${tmp_mod_dir}"

		# Install the modules
		pr_info "Install the external Linux kernel modules"
		install_kernel_modules_ext \
			${G_CROSS_COMPILER_PATH}/${G_CROSS_COMPILER_PREFIX} \
			${G_LINUX_KERNEL_DEF_CONFIG} \
			${G_LINUX_KERNEL_SRC_DIR} \
			"${tmp_mod_dir}"

		# Add the modules to the linux package
		dpkg_add_files "${DEF_SRC_DIR}/$kpackage" "${tmp_mod_dir}/*" ""

		# Cleanup
		rm -rf ${tmp_mod_dir}
	fi

	# Copy debian packages to apt repository
	mkdir -p ${G_ROOTFS_DIR}/srv/local-apt-repository
	mv ${DEF_SRC_DIR}/*${krelease}* ${G_ROOTFS_DIR}/srv/local-apt-repository/
}

function cmd_make_rfs_ubi() {
	make_ubi ${G_ROOTFS_DIR} ${G_TMP_DIR} ${PARAM_OUTPUT_DIR} \
				${G_UBI_FILE_NAME}
}

function cmd_make_rfs_tar()
{
	# pack rootfs
	make_tarball ${G_ROOTFS_DIR} ${G_ROOTFS_TARBALL_PATH}
}

function cmd_make_sdcard()
{
	if [ "${MACHINE}" = "imx6ul-var-dart" ] ||
	   [ "${MACHINE}" = "var-som-mx7" ]; then
		make_x11_sdcard "${PARAM_BLOCK_DEVICE}" "${PARAM_OUTPUT_DIR}"
	else
		make_weston_sdcard "${PARAM_BLOCK_DEVICE}" "${PARAM_OUTPUT_DIR}"
	fi
}

function cmd_make_sdcard_image()
{
	readonly SDIMAGE_SIZE=3720
	readonly IMAGE_PATH="${PARAM_OUTPUT_DIR}/${PARAM_IMAGE_NAME}.img"

	if [ -z "${PARAM_IMAGE_NAME}" ]; then
		pr_error "Variable PARAM_IMAGE_NAME is empty."
		exit 1
	fi

	if [ -f "${IMAGE_PATH}.zst" ]; then
		pr_error "${IMAGE_PATH}.zst already exist."
		exit 1
	fi

	# Create the image file
	pr_info "Creating ${IMAGE_PATH} (${SDIMAGE_SIZE} MiB)"
	rm -rf ${IMAGE_PATH} ${IMAGE_PATH}.zst
	dd if=/dev/zero of="${IMAGE_PATH}" bs=1M count="${SDIMAGE_SIZE}" > /dev/null 2>&1

	# Attach loopback device to ${IMAGE_PATH}
	pr_info "Attaching ${IMAGE_PATH}"
	losetup -Pf ${IMAGE_PATH}
	LOOP_DEV=$(sudo losetup -a | grep ${PARAM_IMAGE_NAME} | grep : | egrep -o '^[^:]+')

	# Create recovery sd card image on ${LOOP_DEV}
	pr_info "Create recovery SD card image on loop device ${LOOP_DEV}"
	PARAM_BLOCK_DEVICE=${LOOP_DEV}
	cmd_make_sdcard

	# Detach ${LOOP_DEV}
	cleanup_losetup

	# Compress the image
	pr_info "Compressing ${PARAM_IMAGE_NAME}.img to ${PARAM_IMAGE_NAME}.img.zst"
	cd ${PARAM_OUTPUT_DIR}
	zstd -T0 -8 ${PARAM_IMAGE_NAME}.img -o ${PARAM_IMAGE_NAME}.img.zst > /dev/null 2>&1

	cd -  > /dev/null 2>&1
}

function cmd_make_brcmfw()
{
	if [ -d "${G_BRCM_FW_SRC_DIR}" ]; then
		make_brcm_fw ${G_BRCM_FW_SRC_DIR} ${G_ROOTFS_DIR}
	fi
}

function cmd_make_iw612fw()
{
	if [ -d "${G_IW612_FW_SRC_DIR}" ]; then
			make_iw612_fw ${G_ROOTFS_DIR}
	fi
}

function cmd_make_firmware() {
	make_imx_sdma_fw ${G_IMX_SDMA_FW_SRC_DIR} ${G_ROOTFS_DIR}
}

function cmd_make_clean()
{
	# clean U-Boot
	clean_uboot ${G_UBOOT_SRC_DIR}

	# delete tmp dirs and etc
	pr_info "Delete tmp dir ${G_TMP_DIR}"
	rm -rf ${G_TMP_DIR}

	pr_info "Delete rootfs dir ${G_ROOTFS_DIR}"
	rm -rf ${G_ROOTFS_DIR}

	pr_info "Delete rootfs-dev dir ${G_ROOTFS_DEV_DIR}"
	rm -rf $G_ROOTFS_DEV_DIR}

	# Delete state file
	rm -rf ${STEP_FILE}
}

################ main function ################

# test for root access support
[ "$PARAM_CMD" != "deploy" ] && [ "$PARAM_CMD" != "bootloader" ] &&
[ "$PARAM_CMD" != "kernelpackage" ] &&
[ ${EUID} -ne 0 ] && {
	pr_error "this command must be run as root (or sudo/su)"
	exit 1;
};

pr_info "Command: \"$PARAM_CMD\" start..."

make_prepare

case $PARAM_CMD in
	deploy )
		cmd_make_deploy
		;;
	rootfs )
		cmd_make_rootfs
		;;
	bootloader )
		cmd_make_uboot
		;;
	kernelpackage )
		cmd_make_kernel_package
		;;
	brcmfw )
		cmd_make_brcmfw
		;;
	iw612fw )
		cmd_make_iw612fw
		;;
	firmware )
		cmd_make_firmware
		;;

	sdcard )
		cmd_make_sdcard
		;;
	sdimage )
		cmd_make_sdcard_image
		;;
	rubi )
		cmd_make_rfs_ubi
		;;
	rtar )
		cmd_make_rfs_tar
		;;
	freertosvariscite )
		cmd_make_freertos_variscite
		;;
	all )
		cmd_make_uboot  &&
		cmd_make_freertos_variscite &&
		cmd_make_rootfs
		;;
	clean )
		cmd_make_clean
		;;
	* )
		pr_error "Invalid input command: \"${PARAM_CMD}\"";
		;;
esac

echo
pr_info "Command: \"$PARAM_CMD\" end."
echo
