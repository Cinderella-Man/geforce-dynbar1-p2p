# shellcheck shell=bash disable=SC2034
# Settings read by every script in this directory. Edit this file, or set the variables in the environment.

# PCI addresses of the cards, as `lspci -D -d 10de:2206` prints them, for example "0000:01:00.0 0000:02:00.0".
# Each card must already have its 32 GiB BAR1 and RMForceStaticBar1=0 (geforce-bar1-resize).
GPUS=${GPUS:-}

# The kernel-open directory of your build: the five .ko files and the SHA256SUMS you wrote right after the build.
OUT=${OUT:-}

# Kernel the modules are built for and installed into; driver version the build must report.
KVER=${KVER:-$(uname -r)}
VER=${VER:-615.71.09}

# P2P switch (registry key RMDynBar1P2PEnable, read per card; no global NVreg_RegistryDwords is ever written).
# This file belongs to the old entry points in contrib/3080-20g/, kept for one release; move to contrib/config.sh.
#   "" or 1  driver default here: on for a pair of GA102 cards that passes the driver's checks. (In contrib/config.sh
#            1 now means RMDynBar1P2PEnable=1 for every card, the trial load of the opt-in; with this file the
#            scripts treat 1 as the default and say so.)
#   0        off: RMDynBar1P2PEnable=0 after each card's RMForceStaticBar1=0 in the per-device line. For the boot
#            install, set keys=RMDynBar1P2PEnable=0; per card in /etc/geforce-bar1-resize.conf (or add it to its
#            zz-geforce-bar1-resize.conf, which it keeps; zz-nvidia-static-bar1.conf on a 3080-20gb-rebar install).
P2P_ENABLE=${P2P_ENABLE:-}

# Optional. vtconsole bind file of a framebuffer console that sits on one of the cards, for example
# /sys/class/vtconsole/vtcon1/bind. It is unbound while the modules change and bound again afterwards.
VTCON=${VTCON:-}

# Optional. Commands that stop and restart every program using the GPUs (services, containers, monitors).
# The load and rollback scripts refuse to unload while a process still holds /dev/nvidia* or /dev/dri/*.
DRAIN_CMD=${DRAIN_CMD:-}
RESTORE_CMD=${RESTORE_CMD:-}

# Optional. Other nvidia options you keep in /etc/modprobe.d, repeated for the insmod loads of p2p-load.sh and
# p2p-rollback.sh (insmod does not read /etc/modprobe.d). p2p-install.sh does not write them.
EXTRA_NVIDIA_OPTS=${EXTRA_NVIDIA_OPTS:-}
