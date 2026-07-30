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

Both of these were established by measurement, and both silently change the
launch measurement while every functional test still passes:

- **Builds must be clean.** `build.sh` removes `Build/AmdSev` first. An
  incremental build over a previous run's objects — especially a `--stock` run,
  which compiles the same sources with the opposite PCD — yields a different
  firmware image from a clean build of the same commit.
- **The image embeds absolute build paths.** Clean builds are deterministic for a
  given checkout path, but the same commit built at a different path produces
  different bytes. `devenv` pins the toolchain; it cannot pin the path. To have
  several machines agree on a measurement, build at a fixed canonical path inside
  a container or chroot rather than in a per-user home directory.

Treat "same commit + same `devenv.lock` + same absolute path" as the
reproducibility unit.

## Background

See `docs/build_ovmf_amdsev_large_bars.md` and
`docs/ovmf_large_bars_sev_snp.md` in the cc-dev repository for the failure this
fixes, how it was diagnosed, and how to install and test the resulting firmware.
