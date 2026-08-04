# devenv_build

Reproducible build of `OvmfPkg/AmdSev/AmdSevX64.dsc` for SEV-SNP guests that need
a multi-TiB 64-bit PCI aperture (large GPU BARs).

This directory is not part of upstream edk2. It exists on the
`amdsev-large-bars` branch alongside the one-line `PcdUse1GPageTable` fix, and is
kept in a separate commit from that fix so the fix can be cherry-picked or sent
upstream on its own. PCD means **Platform Configuration Database**, edk2's
mechanism for defining platform configuration values used during the build or
at runtime. `PcdUse1GPageTable` is one such value.

## One-time prerequisites

### Nix and devenv

Reproducibility comes from `devenv`, which needs Nix. **The Nix installer needs
root**, so run it yourself:

```bash
# Multi-user install; creates /nix, a systemd daemon and a _nixbld group.
sh <(curl -L https://nixos.org/nix/install) --daemon
```

Open a new shell after installation because the installer edits the shell
profile. Flakes are disabled by default, and `nix profile` needs them, so enable
them for your user first; this step does not need root:

```bash
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' > ~/.config/nix/nix.conf
```

Without that setting, Nix reports
`error: experimental Nix feature 'flakes' is disabled`. Then install `devenv`:

```bash
nix profile add nixpkgs#devenv     # "install" is a deprecated alias for "add"
devenv version
```

Installing from `nixpkgs#devenv` uses the default `cache.nixos.org`. This matters
because a stock multi-user installation lists only root as a trusted user, so
devenv's own Cachix substituter would be ignored.

For a rootless alternative, `nix-portable` avoids a system-wide Nix installation
at the cost of being a less commonly used path:

```bash
mkdir -p ~/bin
curl -L -o ~/bin/nix-portable \
  https://github.com/DavHau/nix-portable/releases/latest/download/nix-portable-x86_64
chmod +x ~/bin/nix-portable
cd devenv_build
~/bin/nix-portable nix run --accept-flake-config \
  github:cachix/devenv/latest -- shell
```

## Use

Clone the repository in the branch `amdsev-large-bars`:
```bash
git clone https://github.com/verda-cloud/edk2.git -b amdsev-large-bars
cd edk2
```

From the repository root:

```bash
git submodule update --init --recursive --depth 1   # once, from the repo root
cd devenv_build
devenv shell -- ./build.sh
```

The firmware lands in `devenv_build/out/OVMF.amdsev.<branch>.fd`, and the script
prints its size, sha256, the edk2 describe/commit, and the effective
`PcdUse1GPageTable` value.


## CI

`.github/workflows/amdsev-large-bars-build.yml` runs the same two commands on
`ubuntu-latest` for every push and pull request against `amdsev-large-bars`, and
on demand via *Actions → AmdSev large-BAR firmware → Run workflow*, where
`stock` and the build target are inputs. It installs Nix and `devenv` exactly as
the prerequisites above describe, initialises only the two submodules `build.sh`
verifies, uploads the `.fd` plus a `SHA256SUMS` as a build artefact, and prints
the size, sha256, edk2 describe/commit and `devenv.lock` hash in the run summary
so a measurement can be traced back to its inputs.

The workflow deliberately has no `paths:` filter: the image hashes into the
SEV-SNP launch measurement and depends on most of the tree, so filtering would
skip real changes. Because a GitHub-hosted runner is a different machine from a
developer's, a differing sha256 between CI and a local build is a reproducibility
regression worth investigating rather than expected noise.

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
