#!/bin/bash
# SPDX-License-Identifier: MIT
# Build p2p-integrity (the --integrity test of p2p-check.sh) from p2p-integrity.cu with nvcc. No root needed.
# nvcc: $NVCC, else nvcc on PATH, else the newest /usr/local/cuda*/bin/nvcc. Code for Turing to Ada (sm_75, sm_80,
# sm_86, sm_89, as far as this nvcc knows them) plus PTX, so a newer GPU still runs it. The CUDA runtime is linked
# statically; libcuda.so.1 comes from the installed driver at run time.
# Usage: build.sh [OUTPUT]   (default: p2p-integrity next to this script). Prints the binary's path on the last line.
set -u
export LC_ALL=C
here=$(dirname "$(readlink -f "$0")")
src=$here/p2p-integrity.cu
out=${1:-$here/p2p-integrity}

find_nvcc() {
  local c cands=(/usr/local/cuda-*/bin/nvcc)
  if [ -n "${NVCC:-}" ]; then [ -x "$NVCC" ] && { echo "$NVCC"; return 0; }; echo "NVCC=$NVCC is not executable" >&2; return 1; fi
  command -v nvcc 2>/dev/null && return 0
  [ -x /usr/local/cuda/bin/nvcc ] && { echo /usr/local/cuda/bin/nvcc; return 0; }
  while read -r c; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done < <(printf '%s\n' "${cands[@]}" | sort -rV)
  return 1
}

nvcc=$(find_nvcc) || {
  echo "nvcc not found: install the CUDA toolkit (any version that supports your GPU and driver 615.71.09), or set" \
    "NVCC=/path/to/nvcc" >&2
  exit 2
}
known=$("$nvcc" --list-gpu-arch 2>/dev/null)
gen=() low=
for a in 75 80 86 89; do
  if [ -z "$known" ] || grep -qx "compute_$a" <<<"$known"; then
    gen+=(-gencode "arch=compute_$a,code=sm_$a"); low=${low:-$a}
  fi
done
[ -n "$low" ] || { echo "$nvcc knows none of sm_75 sm_80 sm_86 sm_89" >&2; exit 2; }
gen+=(-gencode "arch=compute_$low,code=compute_$low")
echo "$("$nvcc" --version | tail -1) ($nvcc)"
echo "+ $nvcc -O2 -std=c++17 ${gen[*]} -o $out $src -ldl"
"$nvcc" -O2 -std=c++17 "${gen[@]}" -o "$out" "$src" -ldl || { echo "build failed" >&2; exit 1; }
"$out" --selftest >/dev/null || { echo "$out --selftest failed" >&2; exit 1; }
echo "$out"
