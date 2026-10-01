#!/bin/bash
# lib.sh - shared helpers for the OkraLinux OAA package builders.
# Sourced by build-package.sh and build-toolchain.sh.

RepositoryRoot="${RepositoryRoot:?RepositoryRoot must be set}"

# OkraTargetArch() - print the architecture these packages are built for.
# @None. Reads OKRA_TARGET_ARCH, default x86_64. This is a declared constant on
# purpose: the target architecture is never inferred from the build host, so a
# package can never end up labelled with an architecture it was not built for.
# Return: 0. Prints x86_64, aarch64 or riscv64.
OkraTargetArch() {
	printf '%s' "${OKRA_TARGET_ARCH:-x86_64}"
}

# OkraHostArch() - print the architecture of the machine running the build.
# @None.
# Return: 0. Prints the Okra spelling of the uname machine name.
OkraHostArch() {
	case "$(uname -m)" in
		amd64) printf '%s' x86_64 ;;
		arm64) printf '%s' aarch64 ;;
		*)     uname -m ;;
	esac
}

# RequireTargetHost() - refuse to label foreign binaries as the target arch.
# @None. OKRA_CROSS_COMPILE=1 downgrades the refusal to a warning.
# Return: 0 when the host matches the target, non-zero otherwise.
RequireTargetHost() {
	local Target Host
	Target="$(OkraTargetArch)"
	Host="$(OkraHostArch)"
	if [ "$Host" = "$Target" ]; then
		echo "== target $Target on host $Host"
		return 0
	fi
	if [ "${OKRA_CROSS_COMPILE:-0}" = "1" ]; then
		echo "!! cross compiling $Target on $Host"
		return 0
	fi
	echo "this repository produces $Target packages; the build host is $Host" >&2
	echo "refusing to label $Host binaries as $Target" >&2
	echo "run on a $Target host, or set OKRA_CROSS_COMPILE=1 with a $Target toolchain" >&2
	return 1
}

# OkraHardeningFlags() - print the default CFLAGS used for every package.
# @None. Set OKRA_NO_FORMAT_HARDENING=1 to drop -Werror=format-security, which
# upstream trees such as GCC's bundled libcpp do not build cleanly under.
# Return: 0. Prints the flag list on one line.
OkraHardeningFlags() {
	local Flags="-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-plt -Wformat"
	if [ "${OKRA_NO_FORMAT_HARDENING:-0}" != "1" ]; then
		Flags="$Flags -Werror=format-security"
	fi
	printf '%s' "$Flags"
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
# Only compile and link search paths are exported. LD_LIBRARY_PATH is
# deliberately left alone: pointing the host's make, gcc or ld at the freshly
# built Okra glibc makes them load a foreign libc and die with SIGSEGV.
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
	local GccDirectory=""
	if [ -d "$ToolchainRoot/usr/lib/gcc" ]; then
		GccDirectory="$(find "$ToolchainRoot/usr/lib/gcc" -maxdepth 2 -mindepth 2 -type d 2>/dev/null | head -1 || true)"
	fi
	if [ -n "$GccDirectory" ]; then
		export LIBRARY_PATH="$GccDirectory:$LIBRARY_PATH"
	fi
	return 0
}

# OkraRunEnvironment() - load the Okra runtime for executing Okra binaries.
# @None. Uses OKRA_TOOLCHAIN.
# Sets LD_LIBRARY_PATH for one command, so an Okra binary can be run without
# exposing the host's own tools to the Okra glibc.
# Return: 0.
OkraRunEnvironment() {
	local ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
	export LD_LIBRARY_PATH="$ToolchainRoot/usr/lib:$ToolchainRoot/usr/lib64:$ToolchainRoot/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	return 0
}

# OkraDynamicLoader() - print the path of the Okra dynamic loader.
# @None. Uses OKRA_TOOLCHAIN.
# Return: 0 and the loader path, or 1 when the toolchain has no loader yet.
OkraDynamicLoader() {
	local ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
	local Loader=""
	if [ -d "$ToolchainRoot" ]; then
		Loader="$(find "$ToolchainRoot" -maxdepth 3 -name 'ld-linux-x86-64.so.2' -type f 2>/dev/null | head -1 || true)"
	fi
	[ -n "$Loader" ] || return 1
	printf '%s' "$Loader"
}

# ElfMachineForArch() - print the ELF e_machine value expected for an arch.
# @Architecture: x86_64, aarch64 or riscv64.
# Return: 0 and the decimal machine value, or 1 for an unknown architecture.
ElfMachineForArch() {
	case "$1" in
		x86_64)  printf '%s' 62 ;;
		aarch64) printf '%s' 183 ;;
		riscv64) printf '%s' 243 ;;
		*)       return 1 ;;
	esac
}

# VerifyElfArchitecture() - prove every ELF in the payload matches the target.
# @Rootfs: the staged rootfs directory of the package.
# @Architecture: the architecture declared in meta.yaml.
# Every regular file is inspected. Anything whose magic starts with \x7fELF is
# checked for 64-bit class, little endian data and the expected e_machine. A
# single mismatch fails the build, so a package can never claim an architecture
# that its payload does not actually target.
# Return: 0 when every ELF matches, 1 otherwise.
VerifyElfArchitecture() {
	local Rootfs="$1" Architecture="$2"
	local Expected Magic Class Data Machine Relative Found=0
	Expected="$(ElfMachineForArch "$Architecture")" || {
		echo "unknown target architecture $Architecture" >&2
		return 1
	}
	while IFS= read -r -d '' Found; do
		Magic="$(od -An -N4 -tx1 "$Found" 2>/dev/null | tr -d ' \n')"
		[ "$Magic" = "7f454c46" ] || continue
		Class="$(od -An -N1 -j4 -tu1 "$Found" 2>/dev/null | tr -d ' ')"
		Data="$(od -An -N1 -j5 -tu1 "$Found" 2>/dev/null | tr -d ' ')"
		Machine="$(od -An -N2 -j18 -tu2 "$Found" 2>/dev/null | tr -d ' ')"
		Relative="${Found#"$Rootfs"/}"
		if [ "$Class" != "2" ] || [ "$Data" != "1" ] || [ "$Machine" != "$Expected" ]; then
			echo "ELF check failed: $Relative class=$Class data=$Data machine=$Machine expected=$Expected" >&2
			return 1
		fi
	done < <(find "$Rootfs" -type f -print0)
	echo "== every ELF in the payload is $Architecture (e_machine=$Expected)"
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