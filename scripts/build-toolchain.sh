#!/bin/bash
# build-toolchain.sh - build the okrapm toolchain and a self-hosting Okra toolchain.
# The source tree of okrapm must already be checked out at $RepositoryRoot/okrapm.
set -euo pipefail

RepositoryRoot="$(cd "$(dirname "$0")/.." && pwd)"
. "$RepositoryRoot/scripts/lib.sh"

ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
export OKRA_TOOLCHAIN="$ToolchainRoot"
OkrapmSource="$RepositoryRoot/okrapm"

RequireTargetHost
[ -d "$OkrapmSource" ] || { echo "okrapm source not found at $OkrapmSource" >&2; exit 1; }

echo "== building okrapm"
cmake -S "$OkrapmSource" -B "$OkrapmSource/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$OkrapmSource/build" -j"$(nproc)"
ctest --test-dir "$OkrapmSource/build" --output-on-failure || true

LunarBinary="$OkrapmSource/build/src/lunar/lunar"
OpsisBinary="$OkrapmSource/build/opsis/opsis"
[ -x "$LunarBinary" ] || { echo "lunar was not built" >&2; exit 1; }
[ -x "$OpsisBinary" ] || { echo "opsis was not built" >&2; exit 1; }

echo "== installing okrapm into $ToolchainRoot"
mkdir -p "$ToolchainRoot/usr/bin" "$ToolchainRoot/usr/lib/okrapm"
install -m 0755 "$LunarBinary" "$ToolchainRoot/usr/bin/lunar"
install -m 0755 "$OpsisBinary" "$ToolchainRoot/usr/bin/opsis"
make -C "$OkrapmSource/oaatools" install PREFIX=/usr DESTDIR="$ToolchainRoot"

export OKRA_OAATOOLS="$ToolchainRoot/usr/bin"
if [ ! -x "$OKRA_OAATOOLS/oaa-build" ]; then
	export OKRA_OAATOOLS="$OkrapmSource/oaatools"
fi
echo "== oaa toolkit at $OKRA_OAATOOLS"

ToolchainPackages=(${OKRA_TOOLCHAIN_PACKAGES:-glibc binutils gcc make bash coreutils})
echo "== self-hosting toolchain order: ${ToolchainPackages[*]}"

for PackageName in "${ToolchainPackages[@]}"; do
	echo "== toolchain package $PackageName"
	OKRA_PACKAGE_MODE=toolchain OKRA_TOOLCHAIN="$ToolchainRoot" \
		"$RepositoryRoot/scripts/build-package.sh" "$PackageName"
done

echo "== toolchain ready"
OkraRunEnvironment
"$ToolchainRoot/usr/bin/lunar" --root "$ToolchainRoot/var/lib/lunar" status || true
find "$ToolchainRoot/usr/bin" -maxdepth 1 -type f -o -type l | head -40