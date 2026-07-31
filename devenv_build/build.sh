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
CONF_PATH="$EDK2/Build/AmdSevReproConf"
REPRO_TOOLS="$EDK2/Build/AmdSevReproTools"
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

if ! git diff --quiet --ignore-submodules=all HEAD -- . ':!devenv_build'; then
    echo "error: tracked edk2 files differ from HEAD; commit or stash them first" >&2
    exit 1
fi

if [ "$STOCK" = 1 ]; then
    BASE=$(git describe --tags --abbrev=0)
    echo "[+] --stock: building $BASE instead of $BRANCH"
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

# Grub.inf declares [Binaries] PE32|grub.efi so the file must exist. Ubuntu's
# ovmf-amdsev ships a 0-byte stub, so an empty file matches the distro image
# rather than diverging from it. Building real GRUB would change the firmware
# (and its measurement) and is only needed for firmware-stage LUKS unlock, which
# SEV-SNP does not support anyway.
: > OvmfPkg/AmdSev/Grub/grub.efi

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
rm -rf Build/AmdSev "$CONF_PATH" "$REPRO_TOOLS"
mkdir -p "$CONF_PATH" "$REPRO_TOOLS"
ln -s "$HERE/build.sh" "$REPRO_TOOLS/nasm"
ln -s "$HERE/build.sh" "$REPRO_TOOLS/GenFw"
export NASM_PREFIX="$REPRO_TOOLS/"
export CONF_PATH

set +u
# shellcheck disable=SC1091
source edksetup.sh BaseTools >/dev/null
set -u
export PATH="$REPRO_TOOLS:$PATH"

# Always build from scratch. An incremental build over objects left by a
# previous run -- especially a --stock run, which compiles the same sources with
# the opposite PcdUse1GPageTable value -- produces a firmware image that differs
# byte-for-byte from a clean build of the same commit. Since the image is hashed
# into the SEV-SNP launch measurement, that silently invalidates baselines.
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
