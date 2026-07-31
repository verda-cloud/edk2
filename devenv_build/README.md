# devenv_build

Reproducible build of `OvmfPkg/AmdSev/AmdSevX64.dsc` for SEV-SNP guests that need
a multi-TiB 64-bit PCI aperture (large GPU BARs).

This directory is not part of upstream edk2. It exists on the
`amdsev-large-bars` branch alongside the one-line `PcdUse1GPageTable` fix, and is
kept in a separate commit from that fix so the fix can be cherry-picked or sent
upstream on its own.

## Use

Requires Nix with flakes enabled and `devenv` on `PATH`:

```bash
git submodule update --init --recursive --depth 1   # once, from the repo root
cd devenv_build
devenv shell -- ./build.sh
```

The firmware lands in `devenv_build/out/OVMF.amdsev.<branch>.fd`, and the script
prints its size, sha256, the edk2 describe/commit, and the effective
`PcdUse1GPageTable` value.

Control build, to confirm the PCD is what matters rather than the toolchain:

```bash
devenv shell -- ./build.sh --stock
```

Environment overrides: `EDK2` (checkout to build, defaults to this repo),
`TOOLCHAIN` (default `GCC` — `GCC5` was dropped after edk2-stable202511),
`TARGET` (default `RELEASE`).

## Reproducibility caveats

These inputs are enforced or normalized by `build.sh` because each can silently
change the launch measurement while every functional test still passes:

- **The edk2 tree and required submodules must match Git.** Git already pins
  OpenSSL and BaseTools' Brotli by commit (their URLs are not floating build
  inputs), and the script verifies the required checkouts rather than only
  checking for a file.
- **Build tools and configuration must be clean.** Ignored BaseTools binaries
  and `Conf/*.txt` can survive from an earlier compiler or edk2 revision. The
  script rebuilds BaseTools and generates a private configuration on every run.
- **Firmware builds must be clean.** `build.sh` removes `Build/AmdSev` first. An
  incremental build over a previous run's objects — especially a `--stock` run,
  which compiles the same sources with the opposite PCD — yields a different
  firmware image from a clean build of the same commit.
- **Compiler and assembler paths must be normalized.** GCC records absolute
  paths in DWARF and NASM records its input filename in the ELF string table.
  `GenFw` also sizes CodeView metadata from its input filename before clearing
  it. The metadata size can alter padding in a few SEC/PEI PE images. The script
  maps GCC paths to `/usr/src/edk2` and invokes NASM and `GenFw` with
  workspace-relative paths. Their launchers are recreated under `Build/` on
  every run, including after `git clean -fdx`.

Treat "same commit (including Git-link commits) + same `devenv.lock` + same
build options" as the reproducibility unit. The checkout path is not an input.

## Background

See `docs/build_ovmf_amdsev_large_bars.md` and
`docs/ovmf_large_bars_sev_snp.md` in the cc-dev repository for the failure this
fixes, how it was diagnosed, and how to install and test the resulting firmware.
