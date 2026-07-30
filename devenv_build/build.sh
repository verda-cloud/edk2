#!/usr/bin/env bash
# Build OvmfPkg/AmdSev/AmdSevX64.dsc with a toolchain pinned by devenv.
#
# This script lives in devenv_build/ inside the edk2 tree, so by default it builds
# the checkout it is part of. Run it inside the devenv shell:
#     cd devenv_build && devenv shell -- ./build.sh
#
# Produces devenv_build/out/OVMF.amdsev.<branch>.fd. Pass --stock to build with
# PcdUse1GPageTable forced back to the upstream default, which is useful as a
# control: it should hang above a 512 GiB 64-bit PCI aperture where the patched
# build does not.
#
# Override EDK2 to build a different checkout with this same pinned toolchain.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDK2="${EDK2:-$(cd "$HERE/.." && pwd)}"
OUT="$HERE/out"
TOOLCHAIN="${TOOLCHAIN:-GCC}"   # edk2-stable202605 dropped the GCC5 tag
TARGET="${TARGET:-RELEASE}"
STOCK=0
[ "${1:-}" = "--stock" ] && STOCK=1

if ! command -v nasm >/dev/null; then
    echo "error: nasm not found. Run this inside 'devenv shell' (see devenv.nix)." >&2
    exit 1
fi

cd "$EDK2"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
DESC=$(git describe --tags --always)
echo "[+] edk2 $DESC on branch $BRANCH"

if [ "$STOCK" = 1 ]; then
    BASE=$(git describe --tags --abbrev=0)
    echo "[+] --stock: building $BASE instead of $BRANCH"
fi

# Submodules must be present; CryptoPkg/openssl in particular.
if [ ! -f CryptoPkg/Library/OpensslLib/openssl/README.md ]; then
    echo "error: submodules not initialised. Run:" >&2
    echo "  git -C $EDK2 submodule update --init --recursive --depth 1" >&2
    exit 1
fi

# Grub.inf declares [Binaries] PE32|grub.efi so the file must exist. Ubuntu's
# ovmf-amdsev ships a 0-byte stub, so an empty file matches the distro image
# rather than diverging from it. Building real GRUB would change the firmware
# (and its measurement) and is only needed for firmware-stage LUKS unlock, which
# SEV-SNP does not support anyway.
: > OvmfPkg/AmdSev/Grub/grub.efi

# EfiRom trips -Werror=discarded-qualifiers on newer gcc. It builds option ROMs
# and is unused by the firmware build; every tool that is used builds cleanly.
echo "[+] BaseTools"
make -C BaseTools EXTRA_OPTFLAGS="-Wno-error" -j"$(nproc)" >/tmp/edk2_basetools.log 2>&1 || {
    echo "BaseTools build failed, tail of /tmp/edk2_basetools.log:" >&2
    tail -25 /tmp/edk2_basetools.log >&2
    exit 1
}

set +u
# shellcheck disable=SC1091
source edksetup.sh BaseTools >/dev/null
set -u

# Always build from scratch. An incremental build over objects left by a
# previous run -- especially a --stock run, which compiles the same sources with
# the opposite PcdUse1GPageTable value -- produces a firmware image that differs
# byte-for-byte from a clean build of the same commit. Since the image is hashed
# into the SEV-SNP launch measurement, that silently invalidates baselines.
echo "[+] removing previous build output"
rm -rf Build/AmdSev

echo "[+] building AmdSevX64 ($TARGET, $TOOLCHAIN)"
BUILD_ARGS=(-a X64 -t "$TOOLCHAIN" -p OvmfPkg/AmdSev/AmdSevX64.dsc -b "$TARGET" -n "$(nproc)")
if [ "$STOCK" = 1 ]; then
    # Override the DSC back to the upstream default without touching the tree.
    BUILD_ARGS+=(--pcd gEfiMdeModulePkgTokenSpaceGuid.PcdUse1GPageTable=FALSE)
fi
build "${BUILD_ARGS[@]}"

FV="Build/AmdSev/${TARGET}_${TOOLCHAIN}/FV/OVMF.fd"
[ -f "$FV" ] || { echo "error: expected artefact $FV not found" >&2; exit 1; }

mkdir -p "$OUT"
if [ "$STOCK" = 1 ]; then
    DEST="$OUT/OVMF.amdsev.stock.fd"
else
    DEST="$OUT/OVMF.amdsev.${BRANCH}.fd"
fi
cp "$FV" "$DEST"

echo
echo "[+] $DEST"
echo "    size   $(stat -c%s "$DEST") bytes"
echo "    sha256 $(sha256sum "$DEST" | cut -d' ' -f1)"
echo "    edk2   $DESC ($(git rev-parse --short HEAD))"
# Report the value actually compiled in, which is not the DSC text when --stock
# has overridden it on the command line.
if [ "$STOCK" = 1 ]; then
    echo "    PcdUse1GPageTable: FALSE (forced via --pcd, upstream default)"
elif grep -q "PcdUse1GPageTable|TRUE" OvmfPkg/AmdSev/AmdSevX64.dsc; then
    echo "    PcdUse1GPageTable: TRUE (from DSC)"
else
    echo "    PcdUse1GPageTable: FALSE (not set in DSC)"
fi
