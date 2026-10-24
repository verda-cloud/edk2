#!/usr/bin/env bash
# Build OvmfPkg/IntelTdx/IntelTdxX64.dsc (the TDVF, firmware for Intel TDX
# guests) with the same devenv-pinned toolchain as build.sh.
#
# The Intel counterpart of build.sh, kept as a separate file so the AmdSev script
# whose output is already pinned in production stays untouched. The
# reproducibility machinery (clean-tree and submodule checks, private Conf/,
# path-normalising nasm/GenFw launchers, clean BaseTools) is identical.
#
# This script lives in devenv_build/ inside the edk2 tree, so by default it builds
# the checkout it is part of. Run it inside the devenv shell:
#     cd devenv_build && devenv shell -- ./build-inteltdx.sh
#
# Produces devenv_build/out/OVMF.inteltdx.<branch>.fd (4 MiB).
#
# No source change is needed: SECURE_BOOT_ENABLE is already FALSE upstream.
# Ubuntu's OVMF.inteltdx.ms.fd is this same platform built with
# -D SECURE_BOOT_ENABLE=TRUE and vendor keys enrolled, which makes the firmware
# reject an unsigned direct-boot kernel (-kernel/-initrd), fall back to GRUB and
# put the guest kernel into lockdown. The defines are passed explicitly so the
# measured image (the MRTD) does not depend on an upstream default.
#
# Override EDK2 to build a different checkout with this same pinned toolchain.
set -euo pipefail

# Symlinks named nasm and GenFw point back to this script. Dispatch those tool
# invocations before resolving the normal build-script location.
case "${0##*/}" in
    nasm) REAL_TOOL_VAR=REAL_NASM ;;
    GenFw) REAL_TOOL_VAR=REAL_GENFW ;;
    *) REAL_TOOL_VAR= ;;
esac
if [ -n "$REAL_TOOL_VAR" ]; then
    REAL_TOOL="${!REAL_TOOL_VAR:-}"
    [ -n "$REAL_TOOL" ] || { echo "error: $REAL_TOOL_VAR is not set" >&2; exit 1; }
    : "${WORKSPACE:?WORKSPACE must be set by edksetup.sh}"
    ARGS=()
    for ARG in "$@"; do
        # Both tools embed input arguments in intermediate binary metadata.
        ARG="${ARG//"$WORKSPACE/"/}"
        ARGS+=("$ARG")
    done
    cd "$WORKSPACE"
    exec "$REAL_TOOL" "${ARGS[@]}"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDK2="${EDK2:-$(cd "$HERE/.." && pwd)}"
OUT="$HERE/out"
TOOLCHAIN="${TOOLCHAIN:-GCC}"   # edk2-stable202605 dropped the GCC5 tag
TARGET="${TARGET:-RELEASE}"
CONF_PATH="$EDK2/Build/IntelTdxReproConf"
REPRO_TOOLS="$EDK2/Build/IntelTdxReproTools"
DSC=OvmfPkg/IntelTdx/IntelTdxX64.dsc

if [ $# -gt 0 ]; then
    echo "error: build-inteltdx.sh takes no arguments (--stock is an AmdSev control build)" >&2
    exit 1
fi

if ! command -v nasm >/dev/null; then
    echo "error: nasm not found. Run this inside 'devenv shell' (see devenv.nix)." >&2
    exit 1
fi

cd "$EDK2"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
DESC=$(git describe --tags --always)
echo "[+] edk2 $DESC on branch $BRANCH"

if ! git diff --quiet --ignore-submodules=all HEAD -- . ':!devenv_build'; then
    echo "error: tracked edk2 files differ from HEAD; commit or stash them first" >&2
    exit 1
fi

# A submodule URL can move, but the superproject records the exact commit. Check
# the submodules consumed by this build instead of merely checking for a file.
REQUIRED_SUBMODULES=(
    BaseTools/Source/C/BrotliCompress/brotli
    CryptoPkg/Library/OpensslLib/openssl
)
for SUBMODULE in "${REQUIRED_SUBMODULES[@]}"; do
    EXPECTED=$(git ls-tree HEAD "$SUBMODULE" | awk '{print $3}')
    ACTUAL=$(git -C "$SUBMODULE" rev-parse HEAD 2>/dev/null || true)
    if [ -z "$EXPECTED" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "error: $SUBMODULE is not at the commit recorded by edk2" >&2
        echo "  expected: ${EXPECTED:-missing gitlink}" >&2
        echo "  actual:   ${ACTUAL:-not initialised}" >&2
        echo "Run:" >&2
        echo "  git -C $EDK2 submodule update --init --recursive --depth 1" >&2
        exit 1
    fi
    if [ -n "$(git -C "$SUBMODULE" status --porcelain --untracked-files=all)" ]; then
        echo "error: $SUBMODULE contains uncommitted or untracked files" >&2
        exit 1
    fi
done

# Do not reuse ignored BaseTools binaries from a previous shell or compiler.
# EfiRom trips -Werror=discarded-qualifiers on newer gcc. It builds option ROMs
# and is unused by the firmware build; every tool that is used builds cleanly.
echo "[+] BaseTools"
# Normalize paths embedded in BaseTools themselves as well as in the firmware.
export NIX_CFLAGS_COMPILE="${NIX_CFLAGS_COMPILE:-} -ffile-prefix-map=$EDK2=/usr/src/edk2"
make -C BaseTools clean >/tmp/edk2_basetools_clean.log 2>&1
make -C BaseTools EXTRA_OPTFLAGS="-Wno-error" -j"$(nproc)" >/tmp/edk2_basetools.log 2>&1 || {
    echo "BaseTools build failed, tail of /tmp/edk2_basetools.log:" >&2
    tail -25 /tmp/edk2_basetools.log >&2
    exit 1
}

# NASM records its input argument in the ELF string table and has no equivalent
# prefix-map option. The launcher passes workspace paths as relative paths.
export REAL_NASM
REAL_NASM=$(command -v nasm)

# GenFw also uses its input filename while laying out PE debug metadata. Its
# --zero pass clears that metadata but does not undo path-dependent padding.
export REAL_GENFW="$EDK2/BaseTools/Source/C/bin/GenFw"

# Use freshly generated configuration rather than an ignored WORKSPACE/Conf
# directory which may have been created by another edk2 revision or toolchain.
echo "[+] removing previous build output and configuration"
rm -rf Build/IntelTdx "$CONF_PATH" "$REPRO_TOOLS"
mkdir -p "$CONF_PATH" "$REPRO_TOOLS"
ln -s "$HERE/build-inteltdx.sh" "$REPRO_TOOLS/nasm"
ln -s "$HERE/build-inteltdx.sh" "$REPRO_TOOLS/GenFw"
export NASM_PREFIX="$REPRO_TOOLS/"
export CONF_PATH

set +u
# shellcheck disable=SC1091
source edksetup.sh BaseTools >/dev/null
set -u
export PATH="$REPRO_TOOLS:$PATH"

# Always build from scratch. An incremental build over objects left by a
# previous run produces a firmware image that can differ byte-for-byte from a
# clean build of the same commit. Since the image is the TDX MRTD, that silently
# invalidates every pinned measurement.
#
# Defines: no Secure Boot (the upstream default, stated explicitly), no built-in
# UEFI shell (as in Ubuntu's build), 4 MiB image (the size libvirt already loads
# from /usr/local/share/ovmf/OVMF.inteltdx.fd). PcdUse1GPageTable is TRUE in
# this platform upstream, and the RTMR/CCEL measurement driver (TdTcg2Dxe) is
# built unconditionally. The TPM2 and network/HTTP-boot defines Ubuntu adds are
# deliberately left out: guests boot directly from -kernel/-initrd, and every
# extra driver is more measured code.
echo "[+] building IntelTdxX64 ($TARGET, $TOOLCHAIN)"
build -a X64 -t "$TOOLCHAIN" -p "$DSC" -b "$TARGET" -n "$(nproc)" \
    -D SECURE_BOOT_ENABLE=FALSE -D BUILD_SHELL=FALSE -D FD_SIZE_4MB

FV="Build/IntelTdx/${TARGET}_${TOOLCHAIN}/FV/OVMF.fd"
[ -f "$FV" ] || { echo "error: expected artefact $FV not found" >&2; exit 1; }

mkdir -p "$OUT"
DEST="$OUT/OVMF.inteltdx.${BRANCH}.fd"
cp "$FV" "$DEST"

echo
echo "[+] $DEST"
echo "    size   $(stat -c%s "$DEST") bytes"
echo "    sha256 $(sha256sum "$DEST" | cut -d' ' -f1)"
echo "    edk2   $DESC ($(git rev-parse --short HEAD))"
echo "    SECURE_BOOT_ENABLE: FALSE (passed on the command line; upstream default)"
echo "    BUILD_SHELL:        FALSE"
if grep -q "PcdUse1GPageTable|TRUE" "$DSC"; then
    echo "    PcdUse1GPageTable:  TRUE (from DSC)"
else
    echo "    PcdUse1GPageTable:  FALSE (not set in DSC)"
fi
