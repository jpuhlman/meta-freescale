inherit kernel-uboot uboot-sign

python __anonymous () {
    kerneltypes = d.getVar('KERNEL_IMAGETYPES') or ""
    if 'itbImage' in kerneltypes.split():
        depends = d.getVar("DEPENDS")
        depends = "%s u-boot-mkimage-native dtc-native" % depends
        d.setVar("DEPENDS", depends)

        if d.getVar("UBOOT_ARCH") == "x86":
            replacementtype = "bzImage"
        else:
            replacementtype = "vmlinux"

        # Override KERNEL_IMAGETYPE_FOR_MAKE variable, which is internal
        # to kernel.bbclass . We have to override it, since we pack zImage
        # (at least for now) into the fitImage .
        typeformake = d.getVar("KERNEL_IMAGETYPE_FOR_MAKE") or ""
        if 'itbImage' in typeformake.split():
            d.setVar('KERNEL_IMAGETYPE_FOR_MAKE', typeformake.replace('itbImage', replacementtype))

        image = d.getVar('INITRAMFS_IMAGE')
        if image:
            d.appendVarFlag('do_assemble_fitimage_initramfs', 'depends', ' ${INITRAMFS_IMAGE}:do_image_complete')
            def extraimage_getdepends(task):
                deps = ""
                for dep in (d.getVar('EXTRA_IMAGEDEPENDS') or "").split():
                    deps += " %s:%s" % (dep, task)
                return deps

            d.appendVarFlag('do_image', 'depends', extraimage_getdepends('do_populate_lic'))
            d.appendVarFlag('do_image_complete', 'depends', extraimage_getdepends('do_populate_sysroot'))

        # Verified boot will sign the fitImage and append the public key to
        # U-Boot dtb. We ensure the U-Boot dtb is deployed before assembling
        # the fitImage:
        if d.getVar('UBOOT_SIGN_ENABLE') == "1":
            uboot_pn = d.getVar('PREFERRED_PROVIDER_u-boot') or 'u-boot'
            d.appendVarFlag('do_assemble_fitimage', 'depends', ' %s:do_deploy' % uboot_pn)
}

# Options for the device tree compiler passed to mkimage '-D' feature:
UBOOT_MKIMAGE_DTCOPTS ??= ""

#
# Emit the fitImage ITS header
#
# $1 ... .its filename
fitimage_emit_fit_header() {
	cat << EOF >> ${1}
/dts-v1/;

/ {
        description = "U-Boot fitImage for ${DISTRO_NAME}/${PV}/${MACHINE}";
        #address-cells = <1>;
EOF
}

#
# Emit the fitImage section bits
#
# $1 ... .its filename
# $2 ... Section bit type: imagestart - image section start
#                          confstart  - configuration section start
#                          sectend    - section end
#                          fitend     - fitimage end
#
fitimage_emit_section_maint() {
	case $2 in
	imagestart)
		cat << EOF >> ${1}

        images {
EOF
	;;
	confstart)
		cat << EOF >> ${1}

        configurations {
EOF
	;;
	sectend)
		cat << EOF >> ${1}
	};
EOF
	;;
	fitend)
		cat << EOF >> ${1}
};
EOF
	;;
	esac
}

#
# Emit the fitImage ITS kernel section
#
# $1 ... .its filename
# $2 ... Image counter
# $3 ... Path to kernel image
# $4 ... Compression type
fitimage_emit_section_kernel() {

	kernel_csum="sha1"

	ENTRYPOINT=${UBOOT_ENTRYPOINT}
	if [ -n "${UBOOT_ENTRYSYMBOL}" ]; then
		ENTRYPOINT=`${HOST_PREFIX}nm ${S}/vmlinux | \
			awk '$4=="${UBOOT_ENTRYSYMBOL}" {print $2}'`
	fi

	cat << EOF >> ${1}
                kernel@${2} {
                        description = "Linux kernel";
                        data = /incbin/("${3}");
                        type = "kernel";
                        arch = "${UBOOT_ARCH}";
                        os = "linux";
                        compression = "${4}";
                        load = <${UBOOT_LOADADDRESS}>;
                        entry = <${ENTRYPOINT}>;
                        hash@1 {
                                algo = "${kernel_csum}";
                        };
                };
EOF
}

#
# Emit the fitImage ITS DTB section
#
# $1 ... .its filename
# $2 ... Image counter
# $3 ... Path to DTB image
fitimage_emit_section_dtb() {

	dtb_csum="sha1"

        if [ -n "${DTB_LOAD}" ]; then
            dtb_loadline="load = <${DTB_LOAD}>;"
        fi

	cat << EOF >> ${1}
                fdt@${2} {
                        description = "Flattened Device Tree blob";
                        data = /incbin/("${3}");
                        type = "flat_dt";
                        arch = "${UBOOT_ARCH}";
                        compression = "none";
                        ${dtb_loadline}
                        hash@1 {
                                algo = "${dtb_csum}";
                        };
                };
EOF
}

#
# Emit the fitImage ITS setup section
#
# $1 ... .its filename
# $2 ... Image counter
# $3 ... Path to setup image
fitimage_emit_section_setup() {

	setup_csum="sha1"

	cat << EOF >> ${1}
                setup@${2} {
                        description = "Linux setup.bin";
                        data = /incbin/("${3}");
                        type = "x86_setup";
                        arch = "${UBOOT_ARCH}";
                        os = "linux";
                        compression = "none";
                        load = <0x00090000>;
                        entry = <0x00090000>;
                        hash@1 {
                                algo = "${setup_csum}";
                        };
                };
EOF
}

#
# Emit the fitImage ITS ramdisk section
#
# $1 ... .its filename
# $2 ... Image counter
# $3 ... Path to ramdisk image
fitimage_emit_section_ramdisk() {

	ramdisk_csum="sha1"
	ramdisk_ctype="none"
	ramdisk_loadline=""
	ramdisk_entryline=""

	if [ -n "${UBOOT_RD_LOADADDRESS}" ]; then
		ramdisk_loadline="load = <${UBOOT_RD_LOADADDRESS}>;"
	fi
	if [ -n "${UBOOT_RD_ENTRYPOINT}" ]; then
		ramdisk_entryline="entry = <${UBOOT_RD_ENTRYPOINT}>;"
	fi

	case $3 in
		*.gz)
			ramdisk_ctype="gzip"
			;;
		*.bz2)
			ramdisk_ctype="bzip2"
			;;
		*.lzma)
			ramdisk_ctype="lzma"
			;;
		*.lzo)
			ramdisk_ctype="lzo"
			;;
		*.lz4)
			ramdisk_ctype="lz4"
			;;
	esac

	cat << EOF >> ${1}
                ramdisk@${2} {
                        description = "${INITRAMFS_IMAGE}";
                        data = /incbin/("${3}");
                        type = "ramdisk";
                        arch = "${UBOOT_ARCH}";
                        os = "linux";
                        compression = "${ramdisk_ctype}";
                        ${ramdisk_loadline}
                        ${ramdisk_entryline}
                        hash@1 {
                                algo = "${ramdisk_csum}";
                        };
                };
EOF
}

#
# Emit the fitImage ITS configuration section
#
# $1 ... .its filename
# $2 ... Linux kernel ID
# $3 ... DTB image name
# $4 ... ramdisk ID
# $5 ... config ID
# $6 ... default flag
fitimage_emit_section_config() {

	conf_csum="sha1"
	if [ -n "${UBOOT_SIGN_ENABLE}" ] ; then
		conf_sign_keyname="${UBOOT_SIGN_KEYNAME}"
	fi

	# Test if we have any DTBs at all
	conf_desc="Linux kernel"
	kernel_line="kernel = \"kernel@${2}\";"
	fdt_line=""
	ramdisk_line=""
	setup_line=""
	default_line=""

	if [ -n "${3}" ]; then
		conf_desc="${conf_desc}, FDT blob"
		fdt_line="fdt = \"fdt@${3}\";"
	fi

	if [ -n "${4}" ]; then
		conf_desc="${conf_desc}, ramdisk"
		ramdisk_line="ramdisk = \"ramdisk@${4}\";"
	fi

	if [ -n "${5}" ]; then
		conf_desc="${conf_desc}, setup"
		setup_line="setup = \"setup@${5}\";"
	fi

	if [ "${6}" = "1" ]; then
		default_line="default = \"conf@${3}\";"
	fi

	cat << EOF >> ${1}
                ${default_line}
                conf@${3} {
			description = "${6} ${conf_desc}";
			${kernel_line}
			${fdt_line}
			${ramdisk_line}
			${setup_line}
                        hash@1 {
                                algo = "${conf_csum}";
                        };
EOF

	if [ ! -z "${conf_sign_keyname}" ] ; then

		sign_line="sign-images = \"kernel\""

		if [ -n "${3}" ]; then
			sign_line="${sign_line}, \"fdt\""
		fi

		if [ -n "${4}" ]; then
			sign_line="${sign_line}, \"ramdisk\""
		fi

		if [ -n "${5}" ]; then
			sign_line="${sign_line}, \"setup\""
		fi

		sign_line="${sign_line};"

		cat << EOF >> ${1}
                        signature@1 {
                                algo = "${conf_csum},rsa2048";
                                key-name-hint = "${conf_sign_keyname}";
				${sign_line}
                        };
EOF
	fi

	cat << EOF >> ${1}
                };
EOF
}

#
# Assemble fitImage
#
# $1 ... .its filename
# $2 ... fitImage name
# $3 ... include ramdisk
fitimage_assemble() {
	kernelcount=1
	dtbcount=""
	DTBS=""
	ramdiskcount=${3}
	setupcount=""
	rm -f ${1} arch/${ARCH}/boot/${2}

	fitimage_emit_fit_header ${1}

	#
	# Step 1: Prepare a kernel image section.
	#
	fitimage_emit_section_maint ${1} imagestart

	uboot_prep_kimage
	fitimage_emit_section_kernel ${1} "${kernelcount}" linux.bin "${linux_comp}"

	#
	# Step 2: Prepare a DTB image section
	#
	if [ -n "${KERNEL_DEVICETREE}" ]; then
		dtbcount=1
		for DTB in ${KERNEL_DEVICETREE}; do
			if echo ${DTB} | grep -q '/dts/'; then
				bbwarn "${DTB} contains the full path to the the dts file, but only the dtb name should be used."
				DTB=`basename ${DTB} | sed 's,\.dts$,.dtb,g'`
			fi
			DTB_PATH="arch/${ARCH}/boot/dts/${DTB}"
                        DTB=`basename ${DTB}`
			if [ ! -e "${DTB_PATH}" ]; then
				DTB_PATH="arch/${ARCH}/boot/${DTB}"
			fi

			DTBS="${DTBS} ${DTB}"
			fitimage_emit_section_dtb ${1} ${DTB} ${DTB_PATH}
		done
	fi

	#
	# Step 3: Prepare a setup section. (For x86)
	#
	if [ -e arch/${ARCH}/boot/setup.bin ]; then
		setupcount=1
		fitimage_emit_section_setup ${1} "${setupcount}" arch/${ARCH}/boot/setup.bin
	fi

	#
	# Step 4: Prepare a ramdisk section.
	#
	if [ "x${ramdiskcount}" = "x1" ] ; then
		# Find and use the first initramfs image archive type we find
		for img in cpio.lz4 cpio.lzo cpio.lzma cpio.zst cpio.xz cpio.gz ext2.gz cpio; do
			initramfs_path="${DEPLOY_DIR_IMAGE}/${INITRAMFS_IMAGE_NAME}.${img}"
			echo "Using $initramfs_path"
			if [ -e "${initramfs_path}" ]; then
				fitimage_emit_section_ramdisk ${1} "${ramdiskcount}" "${initramfs_path}"
				break
			fi
		done
	fi

	fitimage_emit_section_maint ${1} sectend

	# Force the first Kernel and DTB in the default config
	kernelcount=1
	if [ -n "${dtbcount}" ]; then
		dtbcount=1
	fi

	#
	# Step 5: Prepare a configurations section
	#
	fitimage_emit_section_maint ${1} confstart

	if [ -n "${DTBS}" ]; then
		i=1
		for DTB in ${DTBS}; do
			fitimage_emit_section_config ${1} "${kernelcount}" "${DTB}" "${ramdiskcount}" "${setupcount}" "`expr ${i} = ${dtbcount}`"
			i=`expr ${i} + 1`
		done
	fi

	fitimage_emit_section_maint ${1} sectend

	fitimage_emit_section_maint ${1} fitend

	#
	# Step 6: Assemble the image
	#
	uboot-mkimage \
		${@'-D "${UBOOT_MKIMAGE_DTCOPTS}"' if len('${UBOOT_MKIMAGE_DTCOPTS}') else ''} \
		-f ${1} \
		arch/${ARCH}/boot/${2}

	#
	# Step 7: Sign the image and add public key to U-Boot dtb
	#
	if [ "x${UBOOT_SIGN_ENABLE}" = "x1" ] ; then
		uboot-mkimage \
			${@'-D "${UBOOT_MKIMAGE_DTCOPTS}"' if len('${UBOOT_MKIMAGE_DTCOPTS}') else ''} \
			-F -k "${UBOOT_SIGN_KEYDIR}" \
			-K "${DEPLOY_DIR_IMAGE}/${UBOOT_DTB_BINARY}" \
			-r arch/${ARCH}/boot/${2}
	fi
}

do_assemble_fitimage() {
	if echo ${KERNEL_IMAGETYPES} | grep -wq "itbImage"; then
		cd ${B}
		fitimage_assemble itb-image.its itbImage
	fi
}

addtask assemble_fitimage before do_install after do_compile

do_assemble_fitimage_initramfs() {
	if echo ${KERNEL_IMAGETYPES} | grep -wq "itbImage" && \
		test -n "${INITRAMFS_IMAGE}" ; then
		cd ${B}
		fitimage_assemble itb-image-${INITRAMFS_IMAGE}.its itbImage-${INITRAMFS_IMAGE} 1
	fi
}

addtask assemble_fitimage_initramfs before do_deploy after do_install


kernel_do_deploy[vardepsexclude] = "DATETIME"
kernel_do_deploy:append() {
	# Update deploy directory
	if echo ${KERNEL_IMAGETYPES} | grep -wq "itbImage"; then
		cd ${B}
		echo "Copying fit-image.its source file..."
		its_base_name="itbImage-its-${PV}-${PR}-${MACHINE}-${DATETIME}"
		its_symlink_name=itbImage-its-${MACHINE}
		install -m 0644 itb-image.its ${DEPLOYDIR}/${its_base_name}.its
		linux_bin_base_name="itbImage-linux.bin-${PV}-${PR}-${MACHINE}-${DATETIME}"
		linux_bin_symlink_name=itbImage-linux.bin-${MACHINE}
		install -m 0644 linux.bin ${DEPLOYDIR}/${linux_bin_base_name}.bin

		if [ -n "${INITRAMFS_IMAGE}" ]; then
			echo "Copying fit-image-${INITRAMFS_IMAGE}.its source file..."
			its_initramfs_base_name="itbImage-its-${INITRAMFS_IMAGE_NAME}-${PV}-${PR}-${DATETIME}"
			its_initramfs_symlink_name=itbImage-its-${INITRAMFS_IMAGE_NAME}
			install -m 0644 itb-image-${INITRAMFS_IMAGE}.its ${DEPLOYDIR}/${its_initramfs_base_name}.its
			fit_initramfs_base_name="itbImage-${INITRAMFS_IMAGE_NAME}-${PV}-${PR}-${DATETIME}"
			fit_initramfs_symlink_name=itbImage-${INITRAMFS_IMAGE_NAME}
			install -m 0644 arch/${ARCH}/boot/itbImage-${INITRAMFS_IMAGE} ${DEPLOYDIR}/${fit_initramfs_base_name}.bin
		fi

		cd ${DEPLOYDIR}
		ln -sf ${its_base_name}.its ${its_symlink_name}.its
		ln -sf ${linux_bin_base_name}.bin ${linux_bin_symlink_name}.bin

		if [ -n "${INITRAMFS_IMAGE}" ]; then
			ln -sf ${its_initramfs_base_name}.its ${its_initramfs_symlink_name}.its
			ln -sf ${fit_initramfs_base_name}.bin ${fit_initramfs_symlink_name}.bin
		fi
	fi
}
