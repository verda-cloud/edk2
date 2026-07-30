{ pkgs, ... }:

# Reproducible toolchain for building OvmfPkg/AmdSev/AmdSevX64.dsc with the
# large-BAR fix (see docs/build_ovmf_amdsev_large_bars.md).
#
# devenv.lock pins the exact nixpkgs revision, so the compiler, NASM, iasl and
# Python versions are identical on every machine that checks this directory out.
# That matters more than usual here: the SEV-SNP launch measurement is a hash of
# the firmware image, so a different toolchain produces a different measurement
# and invalidates every pinned expected value.

{
  packages = with pkgs; [
    gnumake
    gcc
    nasm            # assembles the .nasm sources
    acpica-tools    # iasl, for the ACPI tables
    libuuid         # BaseTools links -luuid
    python3         # drives build.py
    bison
    flex
    pkg-config
    git
  ];

  # edk2's tools_def resolves these tools through *_PREFIX variables rather than
  # PATH, and expects a trailing slash.
  env = {
    NASM_PREFIX = "${pkgs.nasm}/bin/";
    IASL_PREFIX = "${pkgs.acpica-tools}/bin/";
    PYTHON_COMMAND = "${pkgs.python3}/bin/python3";

    # nixpkgs' gcc wrapper injects hardening flags by default. They make no
    # sense for freestanding UEFI firmware (which sets its own -mno-red-zone,
    # -fno-builtin and friends), and one of them actively breaks the build:
    # edk2 compiles OpenSSL with -Wno-format, whereupon the injected
    # -Wformat-security emits "ignored without -Wformat" and -Werror turns that
    # into a hard error. Empty disables the whole set.
    NIX_HARDENING_ENABLE = "";
  };

  enterShell = ''
    echo "--- edk2 AmdSev large-BAR build environment"
    gcc --version | head -1
    nasm -v
    ${pkgs.acpica-tools}/bin/iasl -v 2>&1 | grep -i version | head -1
    python3 --version
    echo "--- run ./build.sh to build the firmware"
  '';
}
