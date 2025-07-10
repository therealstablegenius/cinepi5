# Makefile for gpio_tally kernel module

# obj-m specifies the object files that will be compiled into a module (.ko)
# The module will be named gpio_tally.ko
obj-m += gpio_tally.o

# 'all' is the default target. It calls the kernel's build system.
# -C $(KERNELDIR) changes directory to the kernel source tree
# M=$(PWD) tells the kernel build system where our module source is located
all:
	make -C $(KERNELDIR) M=$(PWD) modules

# 'clean' target. It calls the kernel's clean system.
clean:
	make -C $(KERNELDIR) M=$(PWD) clean
