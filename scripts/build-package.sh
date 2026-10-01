#!/bin/bash
# build-package.sh - build one OAA package from a recipe in packages/.
# Usage: scripts/build-package.sh <package>
set -euo pipefail

PackageName="${1:?usage: build-package.sh <package>}"
RepositoryRoot="$(cd "$(dirname "$0")/.." && pwd)"
. "$RepositoryRoot/scripts/lib.sh"

RecipeFile="$RepositoryRoot/packages/${PackageName}.conf"
[ -f "$RecipeFile" ] || { echo "recipe not found: $RecipeFile" >&2; exit 1; }

Name=""
Version=""
Release=1
Namespace=app
Description=""
Url=""
Sha256=""
ArchiveFormat=auto
BuildSystem=autoconf
InstallTarget=install
ConfigureFlags=()
MakeFlags=()
Dependencies=()
ExtraPackages=()
Architecture=""
Abi="OAABI1"
# shellcheck disable=SC1090
. "$RecipeFile"

[ -n "$Name" ] || Name="$PackageName"
[ -n "$Version" ] || { echo "recipe missing Version" >&2; exit 1; }
[ -n "$Url" ] || { echo "recipe missing Url" >&2; exit 1; }
[ -n "$Architecture" ] || Architecture="$(OkraArch)"

WorkRoot="${RUNNER_TEMP:-/tmp}/okra-build/${Name}"
SourceDirectory="$WorkRoot/source"
BuildDirectory="$WorkRoot/build"
InstallRoot="$WorkRoot/install"
PackageDirectory="$WorkRoot/package"
OutputDirectory="$RepositoryRoot/out"
Archive="$WorkRoot/$(basename "${Url%%\?*}")"

rm -rf "$WorkRoot"
mkdir -p "$WorkRoot" "$OutputDirectory"

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"
export LC_ALL=C
export TZ=UTC
export CFLAGS="${CFLAGS:-$(OkraHardeningFlags)}"
export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"
export LDFLAGS="${LDFLAGS:--Wl,-z,relro,-z,now -Wl,-z,noexecstack}"

InstallBuildDependencies
ApplyToolchainEnvironment

echo "== fetching source"
curl -fsSL --http1.1 --retry 5 --retry-delay 3 --retry-all-errors -o "$Archive" "$Url"
SourceSum="$(sha256sum "$Archive" | awk '{print $1}')"
echo "source sha256 $SourceSum"
if [ -n "$Sha256" ] && [ "$Sha256" != "$SourceSum" ]; then
	echo "checksum mismatch for $Archive" >&2
	exit 1
fi

mkdir -p "$SourceDirectory"
case "$ArchiveFormat" in
	lz)    lzip -dc "$Archive" | tar -xf - -C "$SourceDirectory" --strip-components=1 ;;
	plain) cp -f "$Archive" "$SourceDirectory/" ;;
	flat)  tar -xf "$Archive" -C "$SourceDirectory" ;;
	*)     tar -xf "$Archive" -C "$SourceDirectory" --strip-components=1 ;;
esac

if declare -f Build > /dev/null; then
	echo "== custom build"
	Build
else
	mkdir -p "$BuildDirectory"
	cd "$BuildDirectory"
	echo "== configure"
	"$SourceDirectory/configure" --prefix=/usr ${ConfigureFlags[@]+"${ConfigureFlags[@]}"}
	echo "== make"
	make -j"$(nproc)" ${MakeFlags[@]+"${MakeFlags[@]}"}
	echo "== install"
	make DESTDIR="$InstallRoot" ${MakeFlags[@]+"${MakeFlags[@]}"} "$InstallTarget"
fi

if [ "${OKRA_PACKAGE_MODE:-package}" = "toolchain" ]; then
	ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
	echo "== installing build products into $ToolchainRoot"
	mkdir -p "$ToolchainRoot"
	cp -a "$InstallRoot"/. "$ToolchainRoot"/
	echo "== $Name installed into $ToolchainRoot"
	exit 0
fi

echo "== assembling package"
mkdir -p "$PackageDirectory/rootfs" "$PackageDirectory/scripts"
cp -a "$InstallRoot"/. "$PackageDirectory/rootfs"/
find "$PackageDirectory" -name '.l2s.*' -delete
find "$PackageDirectory/rootfs" -name '*.la' -delete

InstalledSize="$(du -sm "$PackageDirectory/rootfs" | cut -f1)"

DependencyList=()
for Dependency in ${Dependencies[@]+"${Dependencies[@]}"}; do
	DependencyNamespace=""
	DependencyRecipe="$RepositoryRoot/packages/${Dependency}.conf"
	if [ -f "$DependencyRecipe" ]; then
		DependencyNamespace="$(grep -m1 '^Namespace=' "$DependencyRecipe" | cut -d= -f2- || true)"
	fi
	case "$Dependency" in
		*.*) DependencyList+=("$Dependency") ;;
		"")  ;;
		*)   DependencyList+=("${DependencyNamespace:-app}.${Dependency}") ;;
	esac
done

{
	echo "name: $Name"
	echo "namespace: $Namespace"
	echo "version: $Version"
	echo "release: $Release"
	echo "description: \"$Description\""
	echo "architecture: $Architecture"
	if [ -n "$Abi" ]; then
		echo "abi: $Abi"
	fi
	echo "maintainer: \"ylh440104 <ylh440104@users.noreply.github.com>\""
	echo "installed_size: $InstalledSize"
	if [ "${#DependencyList[@]}" -gt 0 ]; then
		echo "dependencies:"
		for Dependency in "${DependencyList[@]}"; do
			echo "  - $Dependency"
		done
	else
		echo "dependencies: []"
	fi
	echo "files:"
	if [ -n "$(BuildFileList "$PackageDirectory")" ]; then
		while IFS= read -r ListedFile; do
			[ -n "$ListedFile" ] || continue
			echo "  - $ListedFile"
		done < <(BuildFileList "$PackageDirectory")
	else
		echo "  - /"
	fi
} > "$PackageDirectory/meta.yaml"

echo "== meta.yaml"
cat "$PackageDirectory/meta.yaml"

OaaToolsDirectory="${OKRA_OAATOOLS:-}"
if [ -z "$OaaToolsDirectory" ]; then
	for Candidate in "$RepositoryRoot/okrapm/oaatools" "$RepositoryRoot/../okrapm/oaatools"; do
		if [ -x "$Candidate/oaa-build" ]; then
			OaaToolsDirectory="$Candidate"
			break
		fi
	done
fi
[ -n "$OaaToolsDirectory" ] || { echo "cannot locate the oaa toolkit; set OKRA_OAATOOLS" >&2; exit 1; }

ArchiveName="${Name}-${Version}-${Release}.${Architecture}.oaa"
ArtifactDirectory="${RUNNER_TEMP:-/tmp}/okra-artifacts/$Name"
rm -rf "$ArtifactDirectory"
mkdir -p "$ArtifactDirectory"

echo "== packing with $OaaToolsDirectory/oaa-build"
"$OaaToolsDirectory/oaa-build" "$PackageDirectory" -o "$ArtifactDirectory/$ArchiveName"

MetadataOutput="$OutputDirectory/$Name"
rm -rf "$MetadataOutput"
mkdir -p "$MetadataOutput"
cp -f "$ArtifactDirectory/$ArchiveName.sha256" "$MetadataOutput/"
echo "${SourceSum}  ${Url}" > "$MetadataOutput/${Name}-${Version}-${Release}.sources"
echo "${SourceSum}  ${Url}" > "$ArtifactDirectory/${Name}-${Version}-${Release}.sources"

echo "== built $ArchiveName"
cat "$ArtifactDirectory/$ArchiveName.sha256"