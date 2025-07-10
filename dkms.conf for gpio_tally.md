# dkms.conf for gpio_tally kernel module
# This file is used by DKMS to build and install the module on different kernel versions.

PACKAGE_NAME="gpio_tally"
# PACKAGE_VERSION should ideally match the MODULE_VERSION in gpio_tally.c
PACKAGE_VERSION="2.4" 

# CLEAN specifies the command to clean up build artifacts
CLEAN="make clean"

# MAKE specifies the command to build the module
# KERNELDIR points to the kernel source tree for the currently running kernel
# M=$(PWD) tells make to look for source files in the current directory
MAKE[0]="make KERNELDIR=/lib/modules/${kernelver}/build M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build"

# BUILT_MODULE_NAME specifies the name of the compiled kernel module file (without .ko)
BUILT_MODULE_NAME[0]="gpio_tally"

# DEST_MODULE_LOCATION specifies where the module should be installed in the kernel module tree
# /kernel/drivers/misc is a common location for miscellaneous drivers
DEST_MODULE_LOCATION[0]="/kernel/drivers/misc"

# AUTOINSTALL="yes" tells DKMS to automatically build and install this module
# whenever a new kernel is installed or updated.
AUTOINSTALL="yes"

# Optional: If your module is only compatible with specific kernel versions,
# you can uncomment and adjust BUILD_EXCLUSIVE_KERNEL.
# For broader compatibility, leave it commented or remove it.
# BUILD_EXCLUSIVE_KERNEL="^5\.10"
