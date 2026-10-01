# Okra OAA packages (x86_64)

OkraLinux x86_64 base packages rebuilt with the **current okrapm toolchain**.

The packages published by `OkraLinux/oaa-packages` were produced with an older
packaging path: they carry no `abi` field and were packed with a hand-rolled
`tar` invocation. The current okrapm declares **OAABI 1** as the userspace binary
contract and ships `oaa-build` plus the OPSIS direct-package machinery, so those
old archives are no longer installable.

This repository rebuilds the same recipe set against the current toolchain:

* every archive is packed by `okrapm/oaatools/oaa-build`;
* every `meta.yaml` declares `architecture: x86_64` and `abi: OAABI1`;
* the host tools a recipe needs are installed by the recipe itself;
* sources are never checked in — each package is compiled from its upstream
  tarball inside GitHub Actions.

## Layout

| Path | Purpose |
| --- | --- |
| `packages/*.conf` | One recipe per package: `Name`, `Version`, `Url`, `Dependencies`, optional `ConfigureFlags`, `MakeFlags`, `ExtraPackages` and `Build()`. |
| `scripts/lib.sh` | Shared helpers: architecture detection, host dependency install, toolchain environment. |
| `scripts/build-package.sh` | Builds one recipe into `<name>-<version>-<release>.<arch>.oaa`. |
| `scripts/build-toolchain.sh` | Builds okrapm and installs a self-hosting Okra toolchain (glibc, binutils, gcc, make, bash, coreutils). |
| `out/<name>/` | Committed metadata only: the `.sha256` sidecar and the `.sources` record. |
| `.github/workflows/build-packages.yml` | CI: one matrix job per recipe, then publish. |
| `.github/workflows/bootstrap-toolchain.yml` | CI: builds the self-hosting toolchain and caches it. |

## Building

Locally, with a checkout of okrapm next to this repository:

```bash
git clone --depth 1 https://github.com/OkraLinux/okrapm.git okrapm
OKRA_OAATOOLS="$PWD/okrapm/oaatools" ./scripts/build-package.sh grep
```

`OKRA_OAATOOLS` may be omitted when `okrapm/oaatools/oaa-build` exists either at
`./okrapm/oaatools` or `../okrapm/oaatools`.

Recipes are plain shell. Anything a recipe does not define falls back to the
generic autoconf path:

```
configure --prefix=/usr <ConfigureFlags>
make -j$(nproc) <MakeFlags>
make DESTDIR=$InstallRoot <MakeFlags> install
```

A recipe that defines `Build()` owns the whole build and must install into
`$InstallRoot`. The available variables are `SourceDirectory`, `BuildDirectory`,
`InstallRoot`, `WorkRoot`, `Archive`, `CFLAGS`, `CXXFLAGS` and `LDFLAGS`.

## Cross builds

`scripts/build-package.sh` installs each package into a scratch directory and
then packages that directory. To build the self-hosting toolchain instead, set
`OKRA_PACKAGE_MODE=toolchain`: the same build products are installed into
`OKRA_TOOLCHAIN` (default `/opt/okra-toolchain`) and nothing is packed. That
directory is then put ahead of the host toolchain by
`ApplyToolchainEnvironment()`, so `gcc`, `make` and friends resolve to the Okra
build while the packages are compiled. `scripts/build-toolchain.sh` drives the
whole order: okrapm first, then glibc, binutils, gcc, make, bash, coreutils.

## Publishing

A push to `main` that touches `packages/` or `scripts/` fans out into one matrix
job per recipe. Each job builds, verifies and inspects its archive, uploads it as
a workflow artifact, then a final job refreshes the committed checksums and
uploads every `.oaa` to the `packages` release of this repository.

Manual runs accept a single package name:

```
Actions -> Build OAA packages -> Run workflow -> package: grep
```

## Notes

* `upgradle` is the current system baseline command in Lunar; `upgrade` is only
  the familiar spelling.
* Recipes keep the upstream OkraLinux namespace conventions (`GNU.*` for GNU
  packages, `app.*` otherwise) so the dependency graph resolves the same way.
* The `files:` list in each `meta.yaml` is generated from the staged payload,
  which is what `lunar remove` walks when it uninstalls a package.
