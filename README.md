# geforce-dynbar1-p2p: GPU peer-to-peer for memory-modded GeForce GPUs

NVIDIA's open GPU kernel modules 615.71.09 with a patch series that lets two memory-modded GeForce GPUs copy directly
into each other's memory over PCIe (peer-to-peer, P2P). It builds on the P2P patches of tinygrad, aikitoria, Duanyll
and dingiv (Credits).

The stock driver reports no peer access for most GeForce cards, so CUDA, NCCL and vLLM stage every GPU-to-GPU copy
through host memory. With these modules the copies go card to card.

Verified only on a pair of memory-modded RTX 3080 20GB cards (see Tested on). For the other chips:

- Other GA102 cards get P2P by default but are untested.
- Turing, the other Ampere chips and Ada are opt-in: you run the integrity test on your pair, then turn P2P on per card
  (Opt-in for other chips).

Formerly `3080-20g-p2p`; GitHub redirects the old links.

## Disclaimer

**Use at your own risk.** This project is provided as is, without warranty of any kind, under NVIDIA's dual MIT/GPLv2
licence (see `COPYING`). I am not responsible or liable for any damage, data loss, hardware
failure, instability, downtime or voided warranty that results from using it. This is an experimental kernel driver
patch: it can hang the machine or corrupt memory.

## Tested on

- Two memory-modded RTX 3080 20GB, `10de:2206`, subsystem `10de:146d`, vBIOS `94.02.27.00.14`
- X99 board with one Xeon E5-2696 v4; each card on its own CPU root port, no PCIe switch
- `intel_iommu=on iommu=pt`, ACS left on
- Linux kernel 7.0.14 (Proxmox), NVIDIA driver userspace 615.71.09

If you tried it on other cards or another platform, please file a
[compatibility report](https://github.com/noon-at-cgn/geforce-dynbar1-p2p/issues/new?template=compatibility-report.md)
with the report file of `p2p-check.sh --integrity`.

## Which chips

To see every NVIDIA card and the verdict for each pair, run this (no root needed):

```sh
contrib/p2p-check.sh --pairs
```

The scripts tell the chip from the card's PCI device id and cross-check the architecture with nvidia-smi. NVIDIA gives
each chip a block of ids; the table is in `contrib/chips.sh`, checked against the PCI ID database.

| Chip | Cards, for example | P2P with this driver |
|---|---|---|
| GA102: RTX 3080 20GB (`10de:2206`, 20 GB) | the memory-modded card of Tested on | **verified**, on by default |
| GA102: every other card | RTX 3080, 3080 Ti, 3090, 3090 Ti; RTX A4500-A6000, A10, A40 | on by default, untested: run the integrity test once and please report |
| TU102, TU104, TU106, TU116, TU117 | RTX 20 series, GTX 16 series, Quadro RTX, T4 | opt-in, untested |
| GA103, GA104, GA106, GA107 | RTX 3050-3070 Ti, RTX A2000, A4000 | opt-in, untested |
| AD102, AD103, AD104, AD106, AD107 | RTX 40 series, RTX 6000 Ada, L4, L40 | opt-in, untested |
| GB202, GB203, GB205, GB206, GB207 | RTX 50 series, RTX PRO Blackwell | stock: NVIDIA's own driver offers BAR1 P2P; left as stock |
| GA100, GH100, GB100 and later datacenter chips | A100, H100, B200 | not a target of this patch |

A chip moves from opt-in to on by default (a driver change, in a later release) once passing compatibility reports
come in for it.

### Verdicts

`p2p-check.sh` reports one of these per pair:

| Verdict | Meaning |
|---|---|
| `verified (on, ...)` | Both cards RTX 3080 20GB; P2P is on unless you turn it off. |
| `on by default, untested (...)` | GA102 cards other than the RTX 3080 20GB. The driver turns P2P on, nobody has reported them yet: run `p2p-check.sh --integrity` once and please send a compatibility report. |
| `opted in (on, ...)` | Every card that is not GA102 has `RMDynBar1P2PEnable=1`; please send a compatibility report. |
| `untested (...): run p2p-check.sh --integrity ..., then enable with: p2p-enable.sh --yes <cards>` | An opt-in chip without the key, or a card with static BAR1 (the driver refuses the pair; see below). |
| `off (...)` | A card has `RMDynBar1P2PEnable` set to something other than 1. |
| `stock (...)` | GeForce Blackwell (see below). |
| `not supported (...)` | With the reason (see below). |

A card with static BAR1 shows as `untested`. geforce-bar1-resize sets `RMForceStaticBar1=0` by default
(`DRIVER_OPTION=auto`) only for cards it enlarges through `0x610`. A card that only needed a resize, or whose firmware
already gives it a large BAR1 (stock ReBAR Ampere and Ada), keeps static BAR1 until `driver_option=on` is set for it,
which dynamic BAR1 P2P needs. `p2p-enable.sh` sets it.

For GeForce Blackwell the verdict is `stock`. NVIDIA's own BAR1 P2P on GB20x maps all of VRAM (static BAR1). With
`RMForceStaticBar1=0` from geforce-bar1-resize that route is off, and the check says so (`driver_option=off` for the
card in geforce-bar1-resize keeps static BAR1). This reading of the stock rule comes from the driver source; untested
on Blackwell hardware.

`not supported` comes with the reason. Among them:

- The two cards are of different architectures (Turing, Ampere, Ada): CUDA itself (libcuda) offers no peer access
  between architectures, whatever the kernel driver says.
- BAR1 smaller than VRAM.
- A datacenter or unknown chip.

### Professional and datacenter GA102 boards

Professional and datacenter GA102 boards (RTX A-series, A10, A40) can get P2P from NVIDIA's own driver through its
mailbox protocol. This driver arms every GA102 for the dynamic BAR1 route and turns that mailbox route off.

Such a board therefore loses its stock P2P here unless it meets the dynamic route's conditions (BAR1 at least VRAM,
`RMForceStaticBar1=0`). This is read from the driver source and untested on such boards.

## Requirements

- A BAR1 at least as large as VRAM on each card, from
  [geforce-bar1-resize](https://github.com/noon-at-cgn/geforce-bar1-resize), with `RMForceStaticBar1=0` set for each
  card (its `zz-geforce-bar1-resize.conf`). The NVIDIA driver must load from the root file system. Some cards need
  `driver_option=on` for this (see below).
- NVIDIA userspace (libcuda, nvidia-smi) of exactly 615.71.09, and a stock 615.71.09 kernel module for the fallback.
- The GSP firmware of 615.71.09 for your cards' chip family (see below).
- Kernel headers for the running kernel, `make` and the compiler the kernel was built with.
- IOMMU off, or in passthrough mode (`iommu=pt`).
- Secure Boot off, or the modules signed with a key the machine trusts.
- For the integrity test: the CUDA toolkit (`nvcc`, any version that supports your GPU and driver 615.71.09; see
  below).

### Cards that already list their BAR1 size

By default geforce-bar1-resize sets `RMForceStaticBar1=0` only for cards it enlarges through `0x610`. A card that
already lists its size (e.g. a stock-ReBAR RTX 3090) keeps static BAR1 and gets no P2P.

Set `driver_option=on` for such a card (or `DRIVER_OPTION=on`) in `/etc/geforce-bar1-resize.conf`, run this command,
then reboot:

```sh
sudo geforce-bar1-resize driver-option --write
```

`p2p-enable.sh` sets `driver_option=on` and the opt-in key (`keys=`) there and runs that command.

### GSP firmware

The GSP firmware of 615.71.09 goes in `/lib/firmware/nvidia/615.71.09/`:

| Chips | Files |
|---|---|
| GA10x and Ada | `gsp_ga10x.bin` and `ucodes_ga10x.bin` |
| Turing | `gsp_tu10x.bin` and `ucodes_tu10x.bin` |

They may also sit below another directory the kernel's firmware loader searches, also as `.xz` or `.zst`. They are in
the `firmware/` directory of NVIDIA's `.run`, which its installer copies there.

Without them RM init fails on every GPU; `p2p-load.sh` and `p2p-install.sh` refuse before changing anything.

### CUDA toolkit

The integrity test was built with CUDA 13.0. CUDA 12.8 fails on glibc 2.41's math headers (`cospi`/`sinpi` exception
specification), so on such a system use a newer toolkit.

## Results

P2P on against P2P off (no peer access, copies staged through host memory) on the machine above.

### Copies and NCCL

| Measurement | P2P on | P2P off |
|---|---|---|
| `p2pBandwidthLatencyTest` unidirectional | 10.27 GB/s | 5.78 GB/s |
| `p2pBandwidthLatencyTest` bidirectional | 19.33 GB/s | 8.66 GB/s |
| P2P write latency | 0.99 µs | 13.6 µs |
| NCCL `all_reduce` bus bandwidth, 1 GiB | 9.33 GB/s | 7.33 GB/s |
| NCCL `all_gather` / `reduce_scatter`, 1 GiB | 8.84 / 8.56 GB/s (about 1.45x) | 6.06 / 5.96 GB/s |
| NCCL `all_reduce` latency, 8 B to 32 KiB | 15-17 µs (1-2 µs slower) | 13-15 µs |

- Correctness: 29/29 byte-exact cases (64 KiB to 1 GiB, `cudaMalloc` and `cuMem`, offsets, both directions, realloc
  stress); a 51-minute soak with vLLM serving (3365 byte-exact runs) and 20 `kill -9` during peer copies: no failures,
  no kernel errors.
- P2P reads are about 10x slower than writes here (10.3 vs 0.99 µs), which matters for software that reads over P2P.

### vLLM

vLLM tensor parallel 2 (HyperQwen upstream, vLLM 0.31), 1 stream. Each cell is prefill / decode tok/s:

| Prompt | base (P2P off) | nccl (NCCL P2P) | car (NCCL P2P + custom all-reduce) |
|---|---|---|---|
| 8k | 2062 / 133.0 | 2273 / 138.3 (+10 % / +4 %) | 2265 / 148.7 (+10 % / +12 %) |
| 32k | 1927 / 120.0 | 2113 / 158.0 (+10 % / +32 %) | 2100 / 157.1 (+9 % / +31 %) |
| 128k | 1478 / 133.2 | 1575 / 132.4 (+7 % / -1 %) | 1577 / 144.3 (+7 % / +8 %) |

With two streams, aggregate decode is +5-7 %. TTFT, the 2-stream rows and the setup are in
[results/hyperqwen-long-context.md](results/hyperqwen-long-context.md).

## How it works

The tinygrad-style patches use a *static* BAR1: the whole of VRAM is mapped into BAR1 up front, and peers write
through that mapping. Static BAR1 counts host-visible memory twice and leaves only about half of VRAM host-visible
(measured on the RTX 3080 20GB: about 10 of 20 GB; see geforce-bar1-resize).

This series uses *dynamic* BAR1 instead. Each allocation a peer accesses gets its own window in the owner's BAR1 when
it is mapped, and the window is removed when it is unmapped. Nothing maps all of VRAM, so with `RMForceStaticBar1=0`
all of VRAM stays host-visible.

### When P2P is on

P2P is on by default for pairs of GA102 GPUs (detected by chip family). Other chips use the route only with
`RMDynBar1P2PEnable=1`, read per card. Pairs with no such GPU, and static-BAR1 pairs that stock NVIDIA supports, behave
as stock.

Like every consumer P2P patch, on a card with the route on (GA102, or opted in) it skips NVIDIA's chipset, topology and
host checks. Tested only on X99 / Xeon E5 v4, two CPU root ports, no switch, `iommu=pt`.

### When a pair is refused

A pair is refused when either card:

- is not GA102 and not enabled by the key,
- has `RMDynBar1P2PEnable` set to anything but 1 (the off switch),
- has static BAR1 active (no `RMForceStaticBar1=0`),
- has BAR1 smaller than VRAM,
- or has a non-zero `nv_dynbar1_calib`/`nv_dynbar1_delta`.

It is also refused when `RMForceP2PType`/`RMPcieP2PType` excludes BAR1 P2P.

A refused pair gets no peer access (`cudaDeviceCanAccessPeer` 0, copies staged through the host). The kernel log gets
rate-limited `DynBar1P2P:` error lines naming the card and the reason.

### Changes on top of dingiv's branch

On top of dingiv's dynamic BAR1 branch, this repository adds:

- Managed (UVM) and HMM memory never use a BAR1 peer; their peer copies take the host path, backed by a zeroed sink
  and proven by the read-only counters `uvm_bar1_gate_pairs` and `uvm_bar1_gate_trips` (must stay 0).
- The debug knobs `nv_dynbar1_calib`/`nv_dynbar1_delta` are read-only (non-zero refuses every window), and peer
  windows that are not 2 MiB aligned in BAR1 are refused.
- The second RM mapping route (`NVOS46_FLAGS_P2P`) is refused for a peer without static BAR1, counted in
  `nv_dynbar1_rm_p2p_refused` with a rate-limited log line.
- Teardown and lock fixes: peer windows are drained before the UVM device is freed, under the API lock; a duplicated
  handle's window is freed on every path; a failed lock acquisition never unlocks; the OOM path releases its locks.
- Defaults: no mailbox fallback without a mailbox; the hugepage pin fast path is off (`nv_hugetlb_pin_fast_path`);
  `NVreg_EnableResizableBar` defaults to 0 as in stock; P2P on by default on GA102 with the refusals above.
- GPUs are probed in PCI bus order, as in the proprietary build, so GPU numbering and the console card stay put.

## Build and install

### Build

```sh
git clone https://github.com/noon-at-cgn/geforce-dynbar1-p2p && cd geforce-dynbar1-p2p
make modules -j"$(nproc)"
(cd kernel-open && sha256sum nvidia*.ko > SHA256SUMS)    # the pins the scripts check
```

### Configure

The scripts are in `contrib/`. In `contrib/config.sh`, set:

- `OUT`: the full path of `kernel-open`.
- `GPUS`: the card addresses from `lspci -Dnn -d 10de::0300`, separated by spaces inside one pair of quotes, never
  commas.

For example:

```sh
GPUS="0000:01:00.0 0000:02:00.0"
```

Only 4-digit PCI domains work: cards behind Intel VMD, whose domains look like `10000:`, are not supported. `GPUS`
lists only GA102 cards or cards of an opt-in chip; the scripts refuse the others and say why.

Unlike `GPUS`, the driver's per-device line separates with semicolons (`pci=<address>;RMForceStaticBar1=0;` per
card). geforce-bar1-resize writes it (`driver_option=on` for cards it does not enlarge through `0x610`).

About the scripts:

- Every program using the GPUs must be stopped first (or set `DRAIN_CMD` and `RESTORE_CMD`).
- Each script that changes something takes `--dry-run` (print the plan, change nothing) or `--yes`.
- `p2p-load.sh` and `p2p-install.sh` refuse any `.ko` of the build that does not match `SHA256SUMS`.

### Load by hand

Nothing is installed this way; a reboot loads what modprobe resolves.

```sh
sudo contrib/p2p-load.sh --yes       # from stock or this build: insmods the build with the options below
sudo contrib/p2p-check.sh            # read-only; exit status = number of FAIL lines
sudo contrib/p2p-rollback.sh --yes   # stock without a reboot (by path if a boot install exists; it stays)
sudo contrib/p2p-rollback.sh --yes --to-installed   # reload the boot install instead
```

Module options used (the per-card string is the one geforce-bar1-resize writes):

```
nvidia      NVreg_RegistryDwordsPerDevice="pci=0000:01:00.0;RMForceStaticBar1=0;pci=0000:02:00.0;RMForceStaticBar1=0;" NVreg_EnableResizableBar=0
nvidia_uvm  uvm_disable_hmm=1
```

All tests ran with `uvm_disable_hmm=1`.

### Turn P2P off

To turn P2P off, add `RMDynBar1P2PEnable=0;` after each card's `RMForceStaticBar1=0;` in the `nvidia` options line
above. Never set the global `NVreg_RegistryDwords`.

`P2P_ENABLE=0` in `config.sh` applies to both setups: without it the checks fail on a card that has
`RMDynBar1P2PEnable=0`. The boot install also needs the per-card entry:

| Setup | What to set |
|---|---|
| Load by hand | `P2P_ENABLE=0` in `config.sh` |
| Boot install | `P2P_ENABLE=0` in `config.sh`, and `[<address>]="keys=RMDynBar1P2PEnable=0;"` per card in the `CARD` list of `/etc/geforce-bar1-resize.conf` (or a hand edit of `zz-geforce-bar1-resize.conf`, which geforce-bar1-resize keeps when it rewrites the file) |

The driver then repeats a rate-limited `... (P2P off)` line, as expected. `P2P_ENABLE=1` writes
`RMDynBar1P2PEnable=1;` instead (the trial load of the opt-in).

### Boot install

Verified on one boot on the tested platform.

```sh
sudo contrib/p2p-install.sh --yes    # for the running kernel only
sudo reboot
sudo contrib/p2p-check.sh
```

The installer:

1. backs up to `/var/backups/p2p-modules/`,
2. copies the modules to `/lib/modules/<kernel>/updates/p2p/`,
3. writes `/etc/depmod.d/p2p.conf` (one `override` per module, this kernel only) and
   `/etc/modprobe.d/zz-nvidia-p2p.conf`,
4. runs `depmod`.

Stock modules stay in place; other kernels boot stock. The installer refuses if the initramfs holds nvidia.

### Fallback to stock

One command, then reboot:

```sh
sudo contrib/p2p-fallback.sh --yes
```

`--live` also swaps the running driver. If the P2P kernel does not come up, boot another kernel and run it with
`KVER=<P2P kernel>`.

### If something fails

If the kernel log shows `RmInitAdapter failed` or `init failed during probe` right after `nvidia.ko` is loaded,
`p2p-load.sh` unloads it at once, loads nothing else and goes back to stock. If it cannot unload it, it stops as
below.

`p2p-rollback.sh` checks its own load of `nvidia.ko` the same way. It stops in these cases:

- RM init fails with that driver too: it unloads it, loads nothing else and stops.
- A load fails: it stops the same way.
- It refuses before it loads anything, after `p2p-load.sh` handed over with no nvidia module loaded: it stops the same
  way. With one loaded, it resumes udev and leaves the modules as they are.

Before it lets udev run the events it held back, it writes `/run/modprobe.d/zz-p2p-stop-nvidia.conf`. That file
blocks every nvidia module so that no udev rule loads the failing driver again. Then it reports what `lsmod` shows; if
nvidia could not be unloaded, it says the modules are still loaded: reboot now.

The block is in `/run`, so it is gone after a reboot. The next boot loads the same driver (what modprobe resolves; the
message names it), which fails the same way unless the cause, e.g. missing GSP firmware, is fixed first.

To retry without a reboot once it is fixed, remove the block by hand:

```sh
sudo rm /run/modprobe.d/zz-p2p-stop-nvidia.conf
```

### Old paths

The scripts were in `contrib/3080-20g/` up to this release. `contrib/3080-20g/p2p-*.sh` still work for this one
release: each runs the script of the same name in `contrib/` with the settings of `contrib/3080-20g/config.sh`
(unless `P2P_CONFIG` is set) and prints a note.

`contrib/3080-20g/common.sh`, which geforce-bar1-resize's tests source, loads `contrib/common.sh` the same way. Move
your settings to `contrib/config.sh`; the old directory goes in the next release.

`P2P_ENABLE=1` used to mean the driver default. In `contrib/config.sh` it now writes `RMDynBar1P2PEnable=1` for every
card and the checks want it (leave it empty for the default). Read from `contrib/3080-20g/config.sh`, 1 keeps its old
meaning for this release, with a note.

## Opt-in for other chips

This is for:

- a pair of Turing, Ampere (not GA102) or Ada cards, or a GA102 card paired with another Ampere chip;
- steps 1-3 also for a GA102 pair that says "on by default, untested" (step 4 then only matters for a card with static
  BAR1).

Before you start, have geforce-bar1-resize in place (BAR1 at least VRAM), the build and `SHA256SUMS` as above, and the
GPUs otherwise idle. The trial load of step 2 passes `RMForceStaticBar1=0` itself, so it works before
`driver_option=on` is set.

### Steps

```sh
contrib/p2p-check.sh --pairs                          # 1. chips and verdicts: the pair should say "untested"
sudo env P2P_ENABLE=1 contrib/p2p-load.sh --yes       # 2. trial load with RMDynBar1P2PEnable=1 per card; nothing persisted
sudo contrib/p2p-check.sh --integrity                 # 3. the check plus the integrity test of every pair
sudo contrib/p2p-enable.sh --yes 0000:01:00.0 0000:02:00.0   # 4. after a PASS: key and driver_option=on from the next boot
sudo contrib/p2p-install.sh --yes && sudo reboot      # 5. boot install, if not done yet
sudo contrib/p2p-check.sh                             # 6. the pair says "opted in (on, ...)"
```

Then please send a compatibility report with the report file of step 3 (also when it failed).

If step 3 fails, this returns to stock; nothing was persisted:

```sh
sudo contrib/p2p-rollback.sh --yes
```

The gate is per card, not per pair: a PASS of card C with card D lets `p2p-enable.sh` enable C, also for use with
another card E.

Turning a GA102 card back on that you turned off through `keys=` (`p2p-enable.sh --yes <card>`) also needs a PASS (or
`--skip-integrity`). An `RMDynBar1P2PEnable` you added by hand to `zz-geforce-bar1-resize.conf` has to be removed
there, by hand.

### What p2p-enable.sh changes

`p2p-enable.sh` works through geforce-bar1-resize's per-card entry in `/etc/geforce-bar1-resize.conf` (no second
modprobe.d file). It sets:

- `keys=RMDynBar1P2PEnable=1;` for an opt-in chip (not for GA102, which is on by default);
- `driver_option=on` for every card that has no `RMForceStaticBar1=0` in what modprobe reads (resize-only cards and
  cards whose firmware BAR1 is already large; geforce-bar1-resize's default `auto` keeps their static BAR1).

Then it runs `geforce-bar1-resize driver-option --write`, which writes `zz-geforce-bar1-resize.conf`. Along the way it:

- writes an address entry with `ids=`, so a different card that later sits at that address is not touched;
- keeps the other settings of the entry the card used before;
- checks the result with `geforce-bar1-resize driver-option --print` before it writes anything (a card outside
  geforce-bar1-resize's scope stops here);
- backs up the config and the option file to `/var/backups/geforce-dynbar1-p2p/`;
- checks both the key and `RMForceStaticBar1=0` in what modprobe reads afterwards, and puts both files back if
  `--write` or that check fails.

It refuses:

- a card without a PASS of step 3 recorded for it with the nvidia build that boots (the boot install, else the build
  in `OUT`);
- a BAR1 smaller than VRAM;
- Blackwell, datacenter and unknown chips (GeForce Blackwell keeps static BAR1 and NVIDIA's own P2P).

A PASS is recorded only when the check in step 3 had no FAIL line. `--skip-integrity` enables anyway, at your own
risk.

### Undo, or set it by hand

`p2p-enable.sh --yes --undo <cards>` removes the `RMDynBar1P2PEnable=1` it set (it records those cards in
`/var/lib/geforce-dynbar1-p2p/enabled`). A key you set yourself, `=0` (P2P off) or `=1`, stays, and `driver_option=on`
stays (it only keeps all of VRAM host-visible).

By hand: add `driver_option=on` and `keys=RMDynBar1P2PEnable=1;` to the card's entry in the `CARD` list, then run:

```sh
sudo geforce-bar1-resize driver-option --write
```

### Reports wanted: RTX 2080 Ti 22GB and RTX 4090 48GB

The opt-in route is untested on every chip: the integrity test can find a broken route, it cannot prove a working one.
Two memory-modded cards are the reason the opt-in exists, and neither has been tested with this driver yet. Reports
are wanted, PASS or FAIL:

| Card | Chip | BAR1 | GSP firmware |
|---|---|---|---|
| RTX 2080 Ti 22GB | TU102 | a 32 GiB BAR1 | `gsp_tu10x.bin` and `ucodes_tu10x.bin` |
| RTX 4090 48GB | AD102 | a 64 GiB BAR1 | `gsp_ga10x.bin` and `ucodes_ga10x.bin` |

Both need:

- a BAR1 at least as large as VRAM (geforce-bar1-resize can set it; its route on TU102 and AD102 is untested);
- `RMForceStaticBar1=0` for the card (with a BAR1 that large the driver otherwise turns static BAR1 on, and the verdict
  says `static BAR1 on <card>`);
- the GSP firmware above from the 615.71.09 userspace;
- `RMDynBar1P2PEnable=1`, which `p2p-enable.sh` sets after an integrity PASS (steps 2-4).

### Duanyll's RTX 4090 48GB runs

For the RTX 4090 48GB, Duanyll's notes in [`docs/48g-4090-p2p/`](docs/48g-4090-p2p/) record their own runs of the
per-allocation dynamic BAR1 route this driver builds on ("Method 3").

Their 595.71.05 build ran on 8 cards with a 32 GB BAR1 each, with checked peer copies at 22.7 GB/s and NCCL
`all_reduce` at 20.4 GB/s. The results are in [`method3-test-results.md`](docs/48g-4090-p2p/method3-test-results.md),
the raw logs in [`hw-logs-2026-07/`](docs/48g-4090-p2p/hw-logs-2026-07/).

Their 615.71.09 port was only compiled, not run ([`615-port.md`](docs/48g-4090-p2p/615-port.md)).

These are their results, not this driver's. This driver refuses a BAR1 smaller than VRAM, so it gives that 32 GB
setup no P2P and needs the 64 GiB BAR1.

## Integrity test

This runs the read-only check, then for each pair in `GPUS` the CUDA program `contrib/integrity/p2p-integrity`:

```sh
sudo contrib/p2p-check.sh --integrity [--max-mib N]
```

The program is built from `p2p-integrity.cu` by `contrib/integrity/build.sh` on first use (`nvcc` from `NVCC`, `PATH`
or `/usr/local/cuda*`). Run the test with nothing else on the GPUs and a way to reboot the machine (see Time limits
and hangs).

### Output and report

Each pair gets `PASS integrity A <-> B (max-mib N, C cases)` or `FAIL ...`. With `RMDynBar1P2PEnable=0` for the cards
(P2P off) the test reports `NO_P2P` and copies nothing.

The default run is 264 cases (2112 transfers, about 1.4 TiB moved) and allocates up to `--max-mib` on each card. On
the two cards of Tested on it took about 3.7 minutes (219 s, 1403.6 GiB copied; bandwidth 10.27 GB/s each way,
19.4 GB/s both ways). That is well inside the default limits below, which leave room for slower links and chips.

The whole output, with a short system summary (kernel, IOMMU options, CPU, board, PCIe paths and links, nvidia-smi
topology; no serial numbers or GPU UUIDs), goes to `/var/lib/geforce-dynbar1-p2p/reports/<time>/report.txt`. Attach
that file to the compatibility report. Check it for paths and names before posting.

Each PASS is recorded in `/var/lib/geforce-dynbar1-p2p/integrity-pass` with the size and the number of cases.
`p2p-enable.sh` accepts only a PASS of the full default run (`--max-mib` 4096 or more, 264 cases or more). That number
is absolute: a card whose free memory cannot hold the 4 GiB size (6 GB cards, or a card in use) skips it and stays
below 264 cases. It can be enabled only with `--skip-integrity`, after a PASS at the sizes it can hold.

### What it tests

1. Peer access must be offered both ways (`cudaDeviceCanAccessPeer` and the P2P access attribute) and enabled.
   Otherwise the driver would stage copies through host memory and nothing is tested (`NO_P2P`; for an untested pair,
   do the trial load first).
2. Each GPU first checks its own fill and compare kernels against the host.
3. The copy cases below.
4. Then the copy bandwidth: 256 MiB x 20 in each direction and both ways at once, with the copied data checked.

The copy cases cover `cudaMalloc` and `cuMemCreate`/`cuMemMap` memory with:

- sizes from 4 KiB through the 2 MiB window edges, 64 MiB and 256 MiB to 1, 2 and 4 GiB (`--max-mib`, default 4096);
- each size twice: the whole buffer, and a range whose ends are not 2 MiB aligned (8-byte granular), with guard bands
  below and above it;
- six patterns: random, zeros, ones, 0x55/0xAA, address, walking one;
- both directions, four transfers each (table).

| Transfer | What it does |
|---|---|
| *push* | peer copy on the source GPU, a peer write |
| *pull* | peer copy on the destination GPU, a peer read |
| *store* | a kernel writes the peer's buffer through the peer pointer |
| *load* | a kernel reads and compares the peer's buffer |

The destination starts as the complement of the pattern. Afterwards every 64-bit word is compared on its GPU (the
guard bands must be unchanged), plus 4 KiB at each end and edge on the host. A canary buffer on each GPU catches stray
writes outside the tested buffers.

### When a pair FAILs

The test sees only the two cards of the pair (`CUDA_VISIBLE_DEVICES` set to their UUIDs, which are not printed). The
pair FAILs:

- when no case ran, or a size up to 1 GiB was skipped for lack of free memory (stop other GPU programs);
- on new kernel-log lines during the test: Xid and `DynBar1P2P:` lines that name one of its two cards (other GPUs in
  the machine do not count), and any AER, DMAR or `RmInitAdapter` line;
- on a change of `nvidia_uvm.uvm_bar1_gate_trips` or `nvidia.nv_dynbar1_rm_p2p_refused`;
- when it runs out of time (below).

### Time limits and hangs

| Limit | Default | Override with |
|---|---|---|
| Each transfer and compare | 120 s + `--max-mib`/64 s | `INTEGRITY_OP_TIMEOUT` |
| The whole pair | 1200 s + `--max-mib`/2 s | `INTEGRITY_TIMEOUT` |

A hung peer transfer ends in `FAIL integrity A <-> B: timed out` and the last kernel-log lines, not in a hang. No
further pair is tested in that run (reboot first).

A hang inside the kernel driver itself (the test process stuck in the kernel, state `D` in `ps`) cannot be timed out.
Then neither the test's own limit (exit 4) nor the outer `timeout` can end it, `--integrity` hangs too, and only a
reboot frees the GPUs.

## Tests

Run the script tests as a normal user. Nothing in them needs a GPU.

```sh
tests/contrib/run.sh
```

It runs the scripts against a fake sysfs tree, a fake `/lib/firmware` and stand-ins for nvidia-smi, modprobe, insmod,
rmmod, modinfo, dmesg and geforce-bar1-resize. It covers:

- the chip table (against `pci.ids` when one is found, `PCI_IDS=`);
- pair verdicts, and the `card_ok` texts geforce-bar1-resize's own tests rely on;
- `p2p-check.sh` (`--pairs`, the check, `--integrity` with a stand-in test binary) and `p2p-enable.sh`;
- the `p2p-load.sh` plan, and the GSP firmware check of `p2p-load.sh` and `p2p-install.sh`;
- a load whose RM init fails and a normal load;
- the old entry points, the build script, and shellcheck.

With `nvcc` present it also compiles `p2p-integrity.cu` and runs its host-only `--selftest`.

## NCCL and vLLM settings

- For GPUs on separate CPU root ports set `NCCL_P2P_LEVEL=PHB` (or `SYS`); the log then shows `via P2P`, not `via SHM`.
- vLLM's custom all-reduce needs P2P. On vLLM 0.31 it added 8-12 % single-stream decode at 8k and 128k with no prefill
  cost; measure on your vLLM version.
- `VLLM_SKIP_P2P_CHECK` defaults to 1: vLLM trusts `cudaDeviceCanAccessPeer`, so custom all-reduce follows the driver.

## Known behaviour

- Freeing a buffer while a peer copy into it is pending kills that process's CUDA context (Xid 31), as stock does.
- Two `unixCallVideoBIOS ... vesa call failed` lines per `nvidia_drm` unload are benign (stock open modules too).
- nvidia-smi *BAR1 Used* grows when peer access maps a peer's allocations; when BAR1 is full, new peer mappings fail.

## Not tested

- Every card but the RTX 3080 20GB (other GA102 cards on by default, other chips opt-in), other boards, CPUs, PCIe
  switches, mixed-chip pairs, more than two GPUs, driver versions, kernels; Windows.
- GPU or root-port reset while peer windows are open; soaks longer than those above; more than one boot.

## Credits

- [NVIDIA open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules): the driver (`README.NVIDIA.md`).
- [tinygrad](https://github.com/tinygrad/open-gpu-kernel-modules): the original consumer P2P patch over static BAR1,
  2024 ([README](https://github.com/tinygrad/open-gpu-kernel-modules/blob/550.54.15-p2p/README.md)).
- [aikitoria](https://github.com/aikitoria/open-gpu-kernel-modules): ports to newer drivers, NVLink and mixed-generation
  BAR1 P2P, faster hugepage registration ([615.71.09-p2p README](https://github.com/aikitoria/open-gpu-kernel-modules/blob/615.71.09-p2p/README.md)).
- [Duanyll](https://github.com/Duanyll/open-gpu-kernel-modules): dynamic BAR1 P2P ("Method 3", per-allocation windows
  for BAR1 smaller than VRAM) on 615.71.09 with DKMS packaging ([README](https://github.com/Duanyll/open-gpu-kernel-modules/blob/615.71.09-p2p-48g/README.md)).
- [dingiv](https://github.com/dingiv/open-gpu-kernel-modules): the RTX 3080 20GB fixes (2 MiB window placement), mixed
  static/dynamic pairs, `nv_dynbar1_reserve_mb`, and the test documentation in `docs/20g-3080-p2p/` of this tree.

## Licence

NVIDIA's dual MIT/GPLv2 licence, unchanged; see `COPYING`.
