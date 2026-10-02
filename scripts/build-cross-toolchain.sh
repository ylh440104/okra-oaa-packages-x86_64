#!/bin/bash
# build-cross-toolchain.sh - build a self-hosting Okra toolchain.
#
# A host-native build cannot bootstrap Okra. The Okra userland must be linked
# against the Okra glibc, not the host glibc, and pointing the host compiler at
# the Okra headers only produces objects whose headers and libraries disagree.
# The toolchain is therefore built as a cross toolchain for the
# x86_64-okra-linux-gnu target with a sysroot of its own, which is the standard
# way to reach a self-hosting system.
#
# Stages, in order:
#   1. linux headers  -> $OKRA_SYSROOT/usr/include
#   2. binutils       -> $OKRA_CROSS_PREFIX  (x86_64-okra-linux-gnu-ld, -as)
#   3. gcc stage 1    -> $OKRA_CROSS_PREFIX  (C only, no libc, no shared)
#   4. glibc          -> $OKRA_SYSROOT       (built with the stage 1 compiler)
#   5. gcc stage 2    -> $OKRA_CROSS_PREFIX  (C and C++, shared, threads)
#
# Stage 3 has to come before stage 4: glibc needs a compiler, and that compiler
# cannot need glibc. Building only all-gcc and all-target-libgcc with
# --without-headers --with-newlib produces exactly such a compiler.
#
# Layout under $OKRA_TOOLCHAIN (default /opt/okra-toolchain):
#   cross/          cross toolchain prefix
#   okra-sysroot/   target sysroot
#   sources/        downloaded upstream tarballs
#   build/          per-stage build trees
set -euo pipefail

RepositoryRoot="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$RepositoryRoot/scripts/lib.sh"

RequireTargetHost

ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
TargetTriple="${OKRA_TARGET_TRIPLE:-x86_64-okra-linux-gnu}"
TargetArch="$(OkraTargetArch)"
KernelVersion="${OKRA_KERNEL_VERSION:-6.12}"
Jobs="${OKRA_JOBS:-$(nproc)}"

CrossPrefix="$ToolchainRoot/cross"
Sysroot="$ToolchainRoot/okra-sysroot"
SourceCache="$ToolchainRoot/sources"
BuildRoot="$ToolchainRoot/build"

export OKRA_TOOLCHAIN="$ToolchainRoot"
export OKRA_CROSS_PREFIX="$CrossPrefix"
export OKRA_SYSROOT="$Sysroot"
export OKRA_TARGET_TRIPLE="$TargetTriple"

mkdir -p "$CrossPrefix" "$Sysroot" "$SourceCache" "$BuildRoot"

# RecipeVersion() - print the Version of a recipe in packages/.
# @Recipe: recipe name without the .conf suffix.
# Return: 0 and the version, or 1 when the recipe has no Version.
RecipeVersion() {
	local Recipe="$RepositoryRoot/packages/$1.conf"
	[ -f "$Recipe" ] || return 1
	local Value
	Value="$(grep -m1 '^Version=' "$Recipe" | cut -d= -f2- || true)"
	[ -n "$Value" ] || return 1
	printf '%s' "$Value"
}

# RecipeUrl() - print the upstream Url of a recipe in packages/.
# @Recipe: recipe name without the .conf suffix.
# Return: 0 and the url, or 1 when the recipe has no Url.
RecipeUrl() {
	local Recipe="$RepositoryRoot/packages/$1.conf"
	[ -f "$Recipe" ] || return 1
	local Value
	Value="$(grep -m1 '^Url=' "$Recipe" | cut -d= -f2- || true)"
	[ -n "$Value" ] || return 1
	printf '%s' "$Value"
}

# FetchSource() - download an upstream tarball into the source cache.
# @Url: the tarball url.
# Return: 0 and the local path.
FetchSource() {
	local Url="$1"
	local Archive="$SourceCache/$(basename "${Url%%\?*}")"
	if [ ! -f "$Archive" ]; then
		echo "== fetching $(basename "$Archive")"
		curl -fsSL --http1.1 --retry 5 --retry-delay 3 --retry-all-errors -o "$Archive" "$Url"
	fi
	[ -s "$Archive" ] || { echo "empty source archive $Archive" >&2; return 1; }
	printf '%s' "$Archive"
}

# ExtractSource() - unpack a tarball into a clean directory.
# @Archive: the tarball.
# @Destination: the directory to fill. Removed first.
# Return: 0.
ExtractSource() {
	local Archive="$1" Destination="$2"
	rm -rf "$Destination"
	mkdir -p "$Destination"
	tar -xf "$Archive" -C "$Destination" --strip-components=1
}

# ConfigureCross() - run a configure for the target with the Okra sysroot.
# @None. Reads the positional parameters as extra configure arguments.
# Return: 0, or the configure exit status.
ConfigureCross() {
	local BuildTriple
	BuildTriple="$(OkraBuildTriple)"
	"$1" \
		--build="$BuildTriple" \
		--target="$TargetTriple" \
		--prefix="$CrossPrefix" \
		--with-sysroot="$Sysroot" \
		"${@:2}"
}

# BuildKernelHeaders() - install the Linux UAPI headers into the sysroot.
# @None. Uses OKRA_KERNEL_VERSION, default 6.12.
# Return: 0.
BuildKernelHeaders() {
	local Archive Directory Url
	Url="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KernelVersion}.tar.xz"
	echo "== stage 1: linux $KernelVersion headers"
	Archive="$(FetchSource "$Url")"
	Directory="$BuildRoot/linux-headers"
	ExtractSource "$Archive" "$Directory"
	make -C "$Directory" headers_install INSTALL_HDR_PATH="$Sysroot/usr"
	[ -d "$Sysroot/usr/include/linux" ] || { echo "kernel headers were not installed" >&2; return 1; }
}

# BuildBinutils() - build the cross binutils.
# @None. Uses the binutils recipe version.
# Return: 0.
BuildBinutils() {
	local Archive Directory Version
	Version="$(RecipeVersion binutils)" || { echo "no binutils recipe" >&2; return 1; }
	echo "== stage 2: binutils $Version for $TargetTriple"
	Archive="$(FetchSource "$(RecipeUrl binutils)")"
	Directory="$BuildRoot/binutils"
	ExtractSource "$Archive" "$Directory/source"
	mkdir -p "$Directory/build"
	cd "$Directory/build"
	ConfigureCross "$Directory/source/configure" \
		--disable-nls \
		--disable-werror \
		--disable-gdb \
		--disable-sim \
		--disable-gprofng \
		--enable-shared \
		--disable-multilib
	make -j"$Jobs"
	make install
	[ -x "$CrossPrefix/bin/$TargetTriple-ld" ] || { echo "cross ld was not installed" >&2; return 1; }
}

# BuildGccStage1() - build the bootstrap C compiler.
# @None. Uses the gcc recipe version.
# The stage 1 compiler is deliberately freestanding: no headers, no shared
# libraries, no C++, no threads. It exists to build glibc.
# Return: 0.
BuildGccStage1() {
	local Archive Directory Version
	Version="$(RecipeVersion gcc)" || { echo "no gcc recipe" >&2; return 1; }
	echo "== stage 3: gcc $Version stage 1 (bootstrap C compiler)"
	Archive="$(FetchSource "$(RecipeUrl gcc)")"
	Directory="$BuildRoot/gcc-stage1"
	ExtractSource "$Archive" "$Directory/source"
	mkdir -p "$Directory/build"
	cd "$Directory/build"
	ConfigureCross "$Directory/source/configure" \
		--enable-languages=c \
		--without-headers \
		--with-newlib \
		--disable-shared \
		--disable-threads \
		--disable-libssp \
		--disable-libgomp \
		--disable-libatomic \
		--disable-libquadmath \
		--disable-decimal-float \
		--disable-libsanitizer \
		--disable-libvtv \
		--disable-libstdcxx \
		--disable-libcc1 \
		--disable-nls \
		--disable-multilib \
		--disable-bootstrap
	make -j"$Jobs" all-gcc
	make -j"$Jobs" all-target-libgcc
	make install-gcc
	make install-target-libgcc
	[ -x "$CrossPrefix/bin/$TargetTriple-gcc" ] || { echo "stage 1 gcc was not installed" >&2; return 1; }
}

# BuildGlibc() - build the Okra glibc with the stage 1 compiler.
# @None. Uses the glibc recipe version and its configure options.
# Return: 0.
BuildGlibc() {
	local Archive Directory Version
	Version="$(RecipeVersion glibc)" || { echo "no glibc recipe" >&2; return 1; }
	echo "== stage 4: glibc $Version into $Sysroot"
	Archive="$(FetchSource "$(RecipeUrl glibc)")"
	Directory="$BuildRoot/glibc"
	ExtractSource "$Archive" "$Directory/source"
	mkdir -p "$Directory/build"
	cd "$Directory/build"
	echo 'rootscheme: unix' > configparms
	# glibc wants a host triple, not a target triple, and the compiler that
	# matches it. CC is pinned so the stage 1 compiler is used even when a
	# native compiler is also on PATH.
	CC="$CrossPrefix/bin/$TargetTriple-gcc" \
	"$Directory/source/configure" \
		--build="$(OkraBuildTriple)" \
		--host="$TargetTriple" \
		--prefix=/usr \
		--with-binutils="$CrossPrefix/bin" \
		--with-headers="$Sysroot/usr/include" \
		--enable-kernel=5.10 \
		--disable-werror \
		--without-gd \
		--disable-nscd
	make -j"$Jobs"
	make install install_root="$Sysroot"
	[ -f "$Sysroot/usr/lib/libc.so.6" ] || { echo "glibc was not installed into the sysroot" >&2; return 1; }
	[ -f "$Sysroot/lib64/ld-linux-x86-64.so.2" ] || { echo "the Okra dynamic loader is missing" >&2; return 1; }
}

# BuildGccStage2() - build the full cross compiler.
# @None. Uses the gcc recipe version.
# This stage links against the Okra glibc, so it needs stage 4 to be done.
# Return: 0.
BuildGccStage2() {
	local Archive Directory Version
	Version="$(RecipeVersion gcc)" || { echo "no gcc recipe" >&2; return 1; }
	echo "== stage 5: gcc $Version stage 2 (C and C++ against the Okra glibc)"
	Archive="$(FetchSource "$(RecipeUrl gcc)")"
	Directory="$BuildRoot/gcc-stage2"
	ExtractSource "$Archive" "$Directory/source"
	mkdir -p "$Directory/build"
	cd "$Directory/build"
	ConfigureCross "$Directory/source/configure" \
		--enable-languages=c,c++ \
		--enable-shared \
		--enable-threads=posix \
		--enable-__cxa_atexit \
		--enable-clocale=gnu \
		--enable-libstdcxx-time=yes \
		--disable-libssp \
		--disable-libsanitizer \
		--disable-libvtv \
		--disable-nls \
		--disable-multilib \
		--disable-bootstrap
	make -j"$Jobs"
	make install
	[ -x "$CrossPrefix/bin/$TargetTriple-g++" ] || { echo "stage 2 g++ was not installed" >&2; return 1; }
}

# OkraLibraryPath() - print the library search path inside the Okra sysroot.
# @None.
# Return: 0 and a colon separated path.
OkraLibraryPath() {
	printf '%s' "$Sysroot/usr/lib:$Sysroot/lib64:$Sysroot/lib"
}

# VerifyToolchain() - prove the toolchain builds runnable Okra binaries.
# @None.
# Compiles a C and a C++ program, checks both are x86_64 ELF objects, and runs
# both on the Okra glibc through the Okra dynamic loader. A toolchain that
# cannot run its own output is not a toolchain.
# Return: 0 when every check passes, 1 otherwise.
VerifyToolchain() {
	local Scratch Cc Cxx Loader Output
	Scratch="$BuildRoot/verify"
	Cc="$CrossPrefix/bin/$TargetTriple-gcc"
	Cxx="$CrossPrefix/bin/$TargetTriple-g++"
	Loader="$(OkraDynamicLoader)" || { echo "no Okra dynamic loader found" >&2; return 1; }

	rm -rf "$Scratch"
	mkdir -p "$Scratch"

	printf '#include <stdio.h>\nint main(void) { printf("ok\\n"); return 0; }\n' > "$Scratch/HelloC.c"
	"$Cc" -o "$Scratch/HelloC" "$Scratch/HelloC.c"

	printf '#include <iostream>\nint main() { std::cout << "ok" << std::endl; return 0; }\n' > "$Scratch/HelloCxx.cpp"
	"$Cxx" -o "$Scratch/HelloCxx" "$Scratch/HelloCxx.cpp"

	VerifyElfArchitecture "$Scratch" "$TargetArch"

	Output="$("$Loader" --library-path "$(OkraLibraryPath)" "$Scratch/HelloC")"
	[ "$Output" = "ok" ] || { echo "the C hello world printed '$Output', expected 'ok'" >&2; return 1; }
	echo "== C hello world runs on the Okra glibc"

	Output="$("$Loader" --library-path "$(OkraLibraryPath)" "$Scratch/HelloCxx")"
	[ "$Output" = "ok" ] || { echo "the C++ hello world printed '$Output', expected 'ok'" >&2; return 1; }
	echo "== C++ hello world runs on the Okra glibc"

	return 0
}

# VerifySysroot() - prove every ELF that glibc installed is the target arch.
# @None.
# Return: 0 when every object matches, 1 otherwise.
VerifySysroot() {
	echo "== verifying the Okra sysroot"
	VerifyElfArchitecture "$Sysroot" "$TargetArch"
}

# WriteToolchainRecord() - record what the toolchain is and what it targets.
# @None.
# Return: 0.
WriteToolchainRecord() {
	local Record="$ToolchainRoot/okra-toolchain.build"
	{
		echo "target_triple: $TargetTriple"
		echo "target_arch: $TargetArch"
		echo "host_arch: $(OkraHostArch)"
		echo "host_uname: $(uname -srm)"
		echo "elf_machine: $(ElfMachineForArch "$TargetArch")"
		echo "kernel_headers: $KernelVersion"
		echo "binutils_version: $(RecipeVersion binutils)"
		echo "gcc_version: $(RecipeVersion gcc)"
		echo "glibc_version: $(RecipeVersion glibc)"
		echo "cross_prefix: $CrossPrefix"
		echo "sysroot: $Sysroot"
	} > "$Record"
	cat "$Record"
}

echo "== self-hosting Okra toolchain"
echo "target triple: $TargetTriple"
echo "cross prefix:  $CrossPrefix"
echo "sysroot:       $Sysroot"
echo "jobs:          $Jobs"

BuildKernelHeaders
BuildBinutils
BuildGccStage1
BuildGlibc
BuildGccStage2

VerifySysroot
VerifyToolchain

echo "== toolchain ready"
"$CrossPrefix/bin/$TargetTriple-gcc" --version | head -1
WriteToolchainRecord
echo "== done"