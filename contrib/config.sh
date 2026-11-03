# shellcheck shell=bash disable=SC2034
# Settings read by every script in this directory. Edit this file, set the variables in the environment, or point
# P2P_CONFIG at another file.

# PCI addresses of the cards, as `lspci -D -d 10de::0300` prints them, for example "0000:01:00.0 0000:02:00.0".
# Each card must already have a BAR1 at least as large as its VRAM and RMForceStaticBar1=0 (geforce-bar1-resize; for
# a card it does not enlarge through 0x610 that takes driver_option=on, which p2p-enable.sh sets).
# `p2p-check.sh --pairs` lists every NVIDIA card with its chip and the verdict for each pair.
GPUS=${GPUS:-}

# The kernel-open directory of your build: the five .ko files and the SHA256SUMS you wrote right after the build.
OUT=${OUT:-}

# Kernel the modules are built for and installed into; driver version the build must report.
KVER=${KVER:-$(uname -r)}
VER=${VER:-615.71.09}

# P2P switch (registry key RMDynBar1P2PEnable, read per card; no global NVreg_RegistryDwords is ever written).
#   ""  driver default: on for a pair of GA102 cards; other chips only where RMDynBar1P2PEnable=1 is set for the card
#       (the boot install takes it from geforce-bar1-resize's option file, see p2p-enable.sh)
#   1   on: RMDynBar1P2PEnable=1 after each card's RMForceStaticBar1=0 when p2p-load.sh loads the build; the trial
#       load for chips that are not verified yet (README, Opt-in). The checks then want the key at 1 for every card.
#   0   off: RMDynBar1P2PEnable=0 after each card's RMForceStaticBar1=0. For the boot install, set
#       keys=RMDynBar1P2PEnable=0; per card in /etc/geforce-bar1-resize.conf (or add it to its
#       zz-geforce-bar1-resize.conf, which it keeps; zz-nvidia-static-bar1.conf on a 3080-20gb-rebar install).
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
