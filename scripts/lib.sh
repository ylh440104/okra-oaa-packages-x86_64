#!/bin/bash
# lib.sh - shared helpers for the OkraLinux OAA package builders.
# Sourced by build-package.sh and build-toolchain.sh.

RepositoryRoot="${RepositoryRoot:?RepositoryRoot must be set}"

# OkraArch() - print the Okra architecture name for this build.
# @None
# Return: 0. Prints x86_64, aarch64 or riscv64.
OkraArch() {
	case "$(uname -m)" in
		x86_64|amd64)  printf '%s' x86_64 ;;
		aarch64|arm64) printf '%s' aarch64 ;;
		riscv64)       printf '%s' riscv64 ;;
		*)             uname -m ;;
	esac
}

# InstallBuildDependencies() - install the host tools a recipe asks for.
# @None. Reads ExtraPackages from the calling environment.
# Return: 0 when nothing to do or apt succeeded, non-zero when apt failed.
InstallBuildDependencies() {
	if [ "${#ExtraPackages[@]}" -eq 0 ]; then
		return 0
	fi
	echo "== installing host packages: ${ExtraPackages[*]}"
	sudo apt-get install -y --no-install-recommends "${ExtraPackages[@]}"
}

# ApplyToolchainEnvironment() - put the Okra toolchain ahead of the host one.
# @None. Uses OKRA_TOOLCHAIN, default /opt/okra-toolchain.
# Return: 0. Warns and keeps the host compiler when no toolchain is present.
ApplyToolchainEnvironment() {
	local ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
	if [ ! -d "$ToolchainRoot/usr/bin" ]; then
		echo "!! no toolchain at $ToolchainRoot, using the host compiler" >&2
		return 0
	fi
	export OKRA_TOOLCHAIN="$ToolchainRoot"
	export PATH="$ToolchainRoot/usr/bin:$PATH"
	export CPATH="$ToolchainRoot/usr/include${CPATH:+:$CPATH}"
	export LIBRARY_PATH="$ToolchainRoot/usr/lib:$ToolchainRoot/usr/lib64:$ToolchainRoot/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}"
	export LD_LIBRARY_PATH="$ToolchainRoot/usr/lib:$ToolchainRoot/usr/lib64:$ToolchainRoot/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	local GccDirectory=""
	if [ -d "$ToolchainRoot/usr/lib/gcc" ]; then
		GccDirectory="$(find "$ToolchainRoot/usr/lib/gcc" -maxdepth 2 -mindepth 2 -type d 2>/dev/null | head -1 || true)"
	fi
	if [ -n "$GccDirectory" ]; then
		export LIBRARY_PATH="$GccDirectory:$LIBRARY_PATH"
		export LD_LIBRARY_PATH="$GccDirectory:$LD_LIBRARY_PATH"
	fi
	return 0
}

# BuildFileList() - list the packaged payload paths for meta.yaml.
# @PackageDirectory: staged package directory holding rootfs/.
# Return: 0. Prints one /-prefixed path per line.
BuildFileList() {
	local PackageDirectory="$1"
	local SearchDirectory Target FoundFile
	for SearchDirectory in usr/bin usr/sbin usr/lib usr/lib64 usr/libexec lib lib64 sbin bin; do
		Target="$PackageDirectory/rootfs/$SearchDirectory"
		[ -d "$Target" ] || continue
		while IFS= read -r FoundFile; do
			printf '/%s/%s\n' "$SearchDirectory" "$FoundFile"
		done < <(cd "$Target" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\n' | sort)
	done
}
