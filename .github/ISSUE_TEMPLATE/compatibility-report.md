---
name: Compatibility report
about: Report whether GPU-to-GPU P2P works on your cards and platform
title: "[compat] <chip> <cards> <board/CPU> <kernel> PASS|FAIL"
labels: compatibility
---

<!-- Remove serial numbers, GPU UUIDs, hostnames and IP addresses before posting. -->

## Integrity test

Attach `/var/lib/geforce-dynbar1-p2p/reports/<time>/report.txt` from `sudo contrib/p2p-check.sh --integrity` (README,
Integrity test), or paste it below. Please send it also when it failed. For an opt-in chip, run it on the trial load
(`sudo env P2P_ENABLE=1 contrib/p2p-load.sh --yes`, README, Opt-in for other chips); a GA102 card other than the RTX
3080 20GB has P2P on by default and is tested as loaded.

```
paste report.txt here if you do not attach it
```

- Result per pair (`PASS integrity A <-> B` / `FAIL ...` / `NOT RUN ...`):
- `--max-mib` used, if not the default:

## Cards

- Chip and verdict per pair (`contrib/p2p-check.sh --pairs`):
- Model, board vendor and VRAM of each card:
- IDs (`lspci -Dnn -d 10de::0300`):
- Memory-modded or stock:
- vBIOS version (`nvidia-smi -q | grep -i vbios`):
- geforce-bar1-resize installed, BAR1 ≥ VRAM on every card (`nvidia-smi -q -d MEMORY`)? yes / no

## Platform

- Motherboard and CPU:
- How the cards connect (CPU root ports, chipset, PCIe switch):
- PCIe generation and width per card (`nvidia-smi -q` or `lspci -vv` LnkSta):
- IOMMU mode (kernel command line, e.g. `intel_iommu=on iommu=pt`):
- ACS state, if known:
- Kernel and distribution:
- Bare metal, VM passthrough, or LXC / containers:

## Driver

- Userspace driver version (must be 615.71.09):
- How the modules were loaded (by hand with `p2p-load.sh`, `P2P_ENABLE=1` or not; boot install with `p2p-install.sh`;
  `p2p-enable.sh` for the opt-in):
- CUDA toolkit (`nvcc --version`) used to build the integrity test:
- Secure Boot on or off (module signing?):

## Results

```
paste the full output of: sudo contrib/p2p-check.sh   (after a reboot with the boot install, if you have one)
```

Optional:
- `p2pBandwidthLatencyTest` or nvbandwidth numbers:
- NCCL test numbers (nccl-tests, with `NCCL_P2P_LEVEL`):
- Workload results with P2P on and off, same settings (engine, model, tensor parallel size, prompt length):

## Errors

- Xid, AER or DMAR lines in `dmesg`:
- `DynBar1P2P:` lines in `dmesg`:

## Notes
