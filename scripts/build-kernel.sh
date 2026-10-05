#!/bin/bash
# build-kernel.sh - build the Okra Linux kernel with the Okra toolchain.
#
# This is the step that makes the bootstrap self-hosting in the strict sense.
# The kernel is not compiled by the runner's compiler and not even by the cross
# compiler: it is compiled by the gcc that the bootstrap itself produced, from
# inside an Okra rootfs, with the Okra glibc underneath it.
#
# The rootfs is expected to be ready already (scripts/assemble-rootfs.sh builds
# one). This script never rebuilds the toolchain or the packages: it takes a
# finished rootfs and only builds the kernel in it.
#
# objtool: every x86_64 kernel build prepares objtool, whose sources include
# <gelf.h> from elfutils. The userland does not carry elfutils, so there are two
# ways out and this script takes whichever works:
#
#   1. build elfutils inside the userland with the bootstrapped compiler, which
#      keeps objtool self-hosted and costs the full configuration;
#   2. when that is not possible, switch off every option that selects OBJTOOL
#      and assert it is really gone before starting the long build.
#
# Usage: build-kernel.sh <rootfs-dir> <output-dir>
#
# Environment:
#   OKRA_KERNEL_REPOSITORY  default https://github.com/OkraLinux/KERNEL.git
#   OKRA_KERNEL_REF         branch, tag or commit (default main)
#   OKRA_KERNEL_JOBS        default 4
#   OKRA_ELFUTILS_VERSION   default 0.192
# Return: 0 when a vmlinux was produced, 1 otherwise.
set -euo pipefail

RootfsDirectory="${1:?usage: build-kernel.sh <rootfs-dir> <output-dir>}"
OutputDirectory="${2:?usage: build-kernel.sh <rootfs-dir> <output-dir>}"

KernelRepository="${OKRA_KERNEL_REPOSITORY:-https://github.com/OkraLinux/KERNEL.git}"
KernelRef="${OKRA_KERNEL_REF:-main}"
Jobs="${OKRA_KERNEL_JOBS:-${OKRA_JOBS:-4}}"
ElfutilsVersion="${OKRA_ELFUTILS_VERSION:-0.192}"

[ -x "$RootfsDirectory/usr/bin/gcc" ] || {
	echo "no compiler in $RootfsDirectory; assemble the rootfs first" >&2
	exit 1
}

Scratch="$(mktemp -d)"
# The chroot mounts are taken down even when the build fails, so a failed run
# does not leave the runner's /proc and /dev mounted inside the rootfs.
ChrootMounted=0
Cleanup() {
	if [ "$ChrootMounted" = "1" ]; then
		for Point in dev/pts dev proc sys; do
			umount -lf "$RootfsDirectory/$Point" 2>/dev/null || true
		done
	fi
	rm -rf "$Scratch"
}
trap Cleanup EXIT

echo "== fetching the Okra kernel source"
KernelSource="$Scratch/kernel"
git init -q "$KernelSource"
git -C "$KernelSource" remote add origin "$KernelRepository"
# The kernel tree is huge, so only the requested commit is fetched.
Fetched=0
for Attempt in 1 2 3; do
	if git -C "$KernelSource" fetch -q --depth 1 origin "$KernelRef"; then
		Fetched=1
		break
	fi
	echo "== fetch attempt $Attempt failed"
	sleep 10
done
[ "$Fetched" = "1" ] || { echo "could not fetch $KernelRef" >&2; exit 1; }
git -C "$KernelSource" checkout -q FETCH_HEAD
KernelVersion="$(make -s -C "$KernelSource" kernelversion 2>/dev/null || echo unknown)"
echo "== kernel version $KernelVersion"

echo "== moving the kernel source into the rootfs"
rm -rf "$RootfsDirectory/usr/src/kernel"
mkdir -p "$RootfsDirectory/usr/src"
cp -a "$KernelSource" "$RootfsDirectory/usr/src/kernel"

echo "== fetching the sources the userland is missing"
# The bootstrapped packages borrowed three libraries from the runner while they
# were built, so the userland has no copy of them and the kernel build trips
# over the gap (perl, which generates lib/oid_registry_data.c, needs
# libcrypt.so.1). They are fetched here and built inside the userland with the
# bootstrapped compiler.
FetchSource() {
	local Name="$1" Url="$2"
	if curl -fsSL --retry 3 -m 300 -o "$Scratch/$Name" "$Url"; then
		cp -f "$Scratch/$Name" "$RootfsDirectory/usr/src/$Name"
		echo "== $Name is available for the userland"
	else
		echo "== $Name could not be fetched" >&2
	fi
}
FetchSource libxcrypt.tar.xz \
	"https://github.com/besser82/libxcrypt/releases/download/v${OKRA_LIBCRYPT_VERSION:-4.4.36}/libxcrypt-${OKRA_LIBCRYPT_VERSION:-4.4.36}.tar.xz"
FetchSource lz4.tar.gz \
	"https://github.com/lz4/lz4/releases/download/v${OKRA_LZ4_VERSION:-1.10.0}/lz4-${OKRA_LZ4_VERSION:-1.10.0}.tar.gz"
FetchSource elfutils.tar.bz2 \
	"https://sourceware.org/elfutils/ftp/$ElfutilsVersion/elfutils-$ElfutilsVersion.tar.bz2"

echo "== entering the Okra rootfs"
for Point in dev dev/pts proc sys; do
	mkdir -p "$RootfsDirectory/$Point"
done
mount --bind /dev "$RootfsDirectory/dev"
mount --bind /dev/pts "$RootfsDirectory/dev/pts"
mount -t proc proc "$RootfsDirectory/proc"
mount -t sysfs sysfs "$RootfsDirectory/sys"
ChrootMounted=1

# The toolchain prefix is deliberately not on PATH: inside the chroot the
# compiler must be the bootstrapped one in /usr/bin, so the build cannot fall
# back to a cross compiler by accident.
cat > "$RootfsDirectory/usr/src/build-kernel.sh" <<'INNER'
#!/bin/bash
# The kernel is built with the compiler inside this rootfs, which is the one the
# bootstrap produced. Nothing here reaches back to the cross toolchain.
set -uo pipefail
cd /usr/src/kernel

echo "== compiler inside the chroot"
command -v gcc
gcc --version | head -1
echo "== the userland"
uname -m
ldd --version 2>/dev/null | head -1 || true

# InstallCryptStub() - give perl a libcrypt.so.1 to load.
#
# libxcrypt's configure needs perl, and perl needs libcrypt.so.1, so the real
# library cannot be built until the tool that builds it can run. The only crypt
# symbol libperl.so.5.40.0 imports is crypt_r@XCRYPT_2.0, so a stub exporting
# exactly that versioned symbol is enough to let perl start. The real library
# replaces the stub as soon as it is installed.
# Return: 0 when the stub is in place.
InstallCryptStub() {
	local SavedDirectory="$PWD"
	cd /usr/src || return 1
	cat > crypt_stub.c <<'STUB'
/* Stand-in for libcrypt.so.1 while libxcrypt is being built. */
struct crypt_data;
char *crypt_r(const char *key, const char *salt, struct crypt_data *data)
{
	(void)key;
	(void)salt;
	(void)data;
	return 0;
}
STUB
	cat > crypt_stub.map <<'MAP'
XCRYPT_2.0 {
	global:
		crypt_r;
	local:
		*;
};
MAP
	if gcc -shared -fPIC -Wl,-soname,libcrypt.so.1 \
		-Wl,--version-script=crypt_stub.map \
		-o /usr/lib/libcrypt.so.1 crypt_stub.c; then
		cd "$SavedDirectory" || return 1
		echo "== a libcrypt stub is in place so perl can run"
		return 0
	fi
	cd "$SavedDirectory" || return 1
	echo "== the libcrypt stub could not be built" >&2
	return 1
}

# BuildLibxcrypt() - provide the real libcrypt.so.1.
#
# glibc 2.28 moved crypt out to libxcrypt, and the packages that use crypt
# (perl, shadow, sudo, util-linux) borrowed the runner's copy while they were
# bootstrapped, so the userland has none. perl is what generates
# lib/oid_registry_data.c during the kernel build, so this has to exist.
# Return: 0 when libcrypt.so.1 is present.
BuildLibxcrypt() {
	[ -f /usr/src/libxcrypt.tar.xz ] || return 1
	local SavedDirectory="$PWD"

	echo "== building libxcrypt in the userland"
	# configure runs perl, which cannot start without libcrypt, so the stub
	# bridges the gap.
	if ! perl -e 'exit 0' >/dev/null 2>&1; then
		InstallCryptStub || return 1
	fi

	rm -rf /usr/src/libxcrypt
	mkdir -p /usr/src/libxcrypt
	if tar -xf /usr/src/libxcrypt.tar.xz -C /usr/src/libxcrypt --strip-components=1 &&
		cd /usr/src/libxcrypt; then
		# --enable-obsolete-api=glibc is what produces libcrypt.so.1 with the
		# XCRYPT_2.0 version, which is the interface the bootstrapped packages
		# were linked against.
		if ./configure --prefix=/usr --disable-static --disable-werror \
			--enable-hashes=strong,glibc --enable-obsolete-api=glibc >/dev/null &&
			make -j"${JOBS}"; then
			# The stub has to go before the real library is installed, or the
			# install of the libcrypt.so.1 symlink cannot replace it.
			rm -f /usr/lib/libcrypt.so.1
			if make install; then
				cd "$SavedDirectory" || return 1
				echo "== libcrypt installed"
				ls -la /usr/lib/libcrypt.so* 2>/dev/null || true
				return 0
			fi
		fi
	fi
	cd "$SavedDirectory" || return 1
	echo "== libcrypt could not be built" >&2
	return 1
}

# BuildLz4() - provide liblz4.so.1 for zstd.
# Return: 0 when liblz4.so.1 is present.
BuildLz4() {
	[ -f /usr/src/lz4.tar.gz ] || return 1
	local SavedDirectory="$PWD"
	echo "== building lz4 in the userland"
	rm -rf /usr/src/lz4
	mkdir -p /usr/src/lz4
	if tar -xf /usr/src/lz4.tar.gz -C /usr/src/lz4 --strip-components=1 &&
		cd /usr/src/lz4; then
		if make -j"${JOBS}" -C lib &&
			make -C lib install PREFIX=/usr LIBDIR=/usr/lib; then
			cd "$SavedDirectory" || return 1
			echo "== liblz4 installed"
			ls -la /usr/lib/liblz4.so* 2>/dev/null || true
			return 0
		fi
	fi
	cd "$SavedDirectory" || return 1
	echo "== liblz4 could not be built" >&2
	return 1
}

# BuildLibelf() - compile elfutils inside the userland.
#
# objtool includes <gelf.h>, so libelf has to exist for the full configuration.
# Building it here with the bootstrapped compiler keeps objtool self-hosted
# instead of borrowing a library from the runner.
# Return: 0 when libelf is usable.
BuildLibelf() {
	[ -f /usr/src/elfutils.tar.bz2 ] || return 1
	echo "== building elfutils in the userland"
	rm -rf /usr/src/elfutils
	mkdir -p /usr/src/elfutils
	tar -xf /usr/src/elfutils.tar.bz2 -C /usr/src/elfutils --strip-components=1 || return 1
	cd /usr/src/elfutils || return 1
	# This tree promotes warnings to errors and the bootstrapped gcc is newer
	# than the one elfutils 0.192 was tested with, so -Wno-error is passed.
	export CFLAGS="-O2 -Wno-error"
	export CXXFLAGS="$CFLAGS"
	./configure --prefix=/usr --disable-werror --disable-debuginfod \
		--disable-libdebuginfod --disable-nls --without-zstd --without-bzlib \
		--without-lzma || return 1
	# Only libelf is needed, because objtool links -lelf. Building the whole
	# tree would also compile libdw, libasm, the command line tools and a
	# disassembler backend per architecture. libcpu is one of those and its
	# riscv_disasm.c does not compile under -Werror with this compiler, which
	# is what made the whole-tree build fail.
	# libeu comes first because elfutils' own build order puts it there.
	LibelfBuilt=1
	make -C lib -j"${JOBS}" || LibelfBuilt=0
	if [ "$LibelfBuilt" = "1" ]; then
		make -C libelf -j"${JOBS}" || LibelfBuilt=0
	fi
	if [ "$LibelfBuilt" != "1" ]; then
		echo "== libelf could not be built" >&2
		cd /usr/src/kernel || return 1
		return 1
	fi
	make -C libelf install || {
		cd /usr/src/kernel || return 1
		return 1
	}
	# Insurance: objtool only needs the headers and -lelf, so if the install
	# did not place them, they are copied straight from the source tree.
	for Header in libelf.h gelf.h nlist.h; do
		if [ ! -f "/usr/include/$Header" ] && [ -f "/usr/src/elfutils/libelf/$Header" ]; then
			echo "== installing $Header from the source tree"
			install -m 0644 "/usr/src/elfutils/libelf/$Header" "/usr/include/$Header" || true
		fi
	done
	cd /usr/src/kernel || return 1
	# The linker has to find it without a ldconfig run.
	if [ ! -e /usr/lib/libelf.so ]; then
		local Soname
		Soname="$(ls /usr/lib/libelf.so.* 2>/dev/null | head -1)"
		[ -n "$Soname" ] && ln -sfn "$Soname" /usr/lib/libelf.so
	fi
	echo "== libelf installed"
	ls -la /usr/lib/libelf.so* /usr/include/gelf.h 2>/dev/null || true
	return 0
}

# HasLibelf() - test whether the userland can link objtool.
HasLibelf() {
	for Candidate in /usr/lib/libelf.so /usr/lib/libelf.a /usr/lib64/libelf.so /lib64/libelf.so; do
		[ -e "$Candidate" ] && return 0
	done
	return 1
}

# DisableObjtool() - drop every option that makes the build need objtool.
#
# This is the fallback for when libelf cannot be produced. The list is every
# option that selects OBJTOOL in this tree:
#
#   UNWINDER_ORC          default y on x86_64
#   STACK_VALIDATION      needs UNWINDER_FRAME_POINTER, so the frame pointer
#                         unwinder must not be forced on either
#   NOINSTR_VALIDATION    default y
#   X86_KERNEL_IBT        default y
#   MITIGATION_RETHUNK    default y on x86_64
#   MITIGATION_RETPOLINE  default y
#   KCOV                  off by default, disabled for completeness
#
# Losing them costs ORC stack traces, IBT and the return thunks. The kernel
# still builds and boots.
DisableObjtool() {
	./scripts/config \
		--disable CONFIG_UNWINDER_ORC \
		--disable CONFIG_STACK_VALIDATION \
		--disable CONFIG_NOINSTR_VALIDATION \
		--disable CONFIG_X86_KERNEL_IBT \
		--disable CONFIG_MITIGATION_RETHUNK \
		--disable CONFIG_MITIGATION_RETPOLINE \
		--disable CONFIG_KCOV
}

# AssertNoObjtool() - fail before the long build when objtool is still needed.
# This turns a forty minute blind run into an immediate answer.
AssertNoObjtool() {
	if ! grep -q '^CONFIG_OBJTOOL=y' .config; then
		echo "== CONFIG_OBJTOOL is off; objtool will not be built"
		return 0
	fi
	echo "== CONFIG_OBJTOOL is still on; these selectors are enabled:" >&2
	grep -E '^CONFIG_(UNWINDER_ORC|STACK_VALIDATION|NOINSTR_VALIDATION|X86_KERNEL_IBT|MITIGATION_RETHUNK|MITIGATION_RETPOLINE|KCOV)=y' .config >&2 || true
	return 1
}

# ConfigureFull() - the configuration that keeps every hardening feature.
ConfigureFull() {
	make defconfig || return 1
	./scripts/config \
		--enable CONFIG_VIRTIO \
		--enable CONFIG_VIRTIO_PCI \
		--enable CONFIG_VIRTIO_BLK \
		--enable CONFIG_VIRTIO_NET \
		--enable CONFIG_BLK_DEV_INITRD \
		--enable CONFIG_DEVTMPFS \
		--enable CONFIG_DEVTMPFS_MOUNT
	# An empty key list keeps the build from looking for certificates the
	# userland does not carry.
	./scripts/config \
		--set-str CONFIG_SYSTEM_TRUSTED_KEYS "" \
		--set-str CONFIG_SYSTEM_REVOCATION_KEYS ""
	make olddefconfig || return 1
	if grep -q '^CONFIG_OBJTOOL=y' .config; then
		HasLibelf || return 1
	fi
	return 0
}

# ConfigureNoObjtool() - the fallback, with the objtool based features off.
ConfigureNoObjtool() {
	make defconfig || return 1
	./scripts/config \
		--enable CONFIG_VIRTIO \
		--enable CONFIG_VIRTIO_PCI \
		--enable CONFIG_VIRTIO_BLK \
		--enable CONFIG_VIRTIO_NET \
		--enable CONFIG_BLK_DEV_INITRD \
		--enable CONFIG_DEVTMPFS \
		--enable CONFIG_DEVTMPFS_MOUNT \
		--set-str CONFIG_SYSTEM_TRUSTED_KEYS "" \
		--set-str CONFIG_SYSTEM_REVOCATION_KEYS ""
	DisableObjtool
	make olddefconfig || return 1
	AssertNoObjtool || return 1
}

Build() {
	echo "== configuration: $1"
	"$1" || return 1
	echo "== building vmlinux"
	make -j"${JOBS}" vmlinux || return 1
	echo "== building the bzImage"
	make -j"${JOBS}" bzImage || return 1
	return 0
}

# The missing libraries are built first, because the kernel build runs perl and
# zstd, and both are broken without them. Each builder restores the working
# directory on every path, so the kernel tree is entered once more afterwards.
cd /usr/src/kernel || exit 1

HasSoname() {
	local Name="$1"
	for Directory in /usr/lib /lib /lib64 /usr/lib64; do
		[ -e "$Directory/$Name" ] && return 0
	done
	return 1
}

if ! HasSoname libcrypt.so.1; then
	BuildLibxcrypt || echo "== libcrypt is still missing" >&2
fi
if ! HasSoname liblz4.so.1; then
	BuildLz4 || echo "== liblz4 is still missing" >&2
fi

cd /usr/src/kernel || exit 1

# The full configuration is the one worth having, so libelf is built for it.
if ! HasLibelf; then
	BuildLibelf || echo "== libelf could not be built; objtool will be switched off" >&2
	# BuildLibelf changes directory, so the kernel tree is entered again
	# unconditionally. Without this a failed libelf build leaves the shell in
	# the elfutils tree and every later make fails with
	# "No rule to make target 'defconfig'".
	cd /usr/src/kernel || exit 1
fi

# AuditTools() - report every library the build tools cannot resolve.
#
# The bootstrap let some packages link against libraries that only existed on
# the runner, so the userland has gaps. This lists all of them at once, before
# the long build, instead of discovering one gap per forty minute run.
# Return: 0 when the tools the kernel build depends on are all resolvable.
AuditTools() {
	local Missing=0 Tool Gaps
	echo "== auditing the build tools"
	for Tool in /usr/bin/perl /usr/bin/zstd /usr/bin/python3 /usr/bin/gcc \
		/usr/bin/make /usr/bin/bash /usr/bin/gawk /usr/bin/sed /usr/bin/ld \
		/usr/bin/tar /usr/bin/xz /usr/bin/gzip /usr/bin/bison /usr/bin/flex \
		/usr/bin/pkgconf /usr/bin/objdump /usr/bin/ar /usr/bin/nm; do
		[ -x "$Tool" ] || continue
		Gaps="$(ldd "$Tool" 2>/dev/null | awk '/not found/ {print $1}' | sort -u | tr '\n' ' ')"
		if [ -n "$Gaps" ]; then
			echo "!! $(basename "$Tool") cannot find: $Gaps"
			Missing=$((Missing + 1))
		fi
	done
	if [ "$Missing" -eq 0 ]; then
		echo "== every build tool resolves its libraries"
		return 0
	fi
	echo "== $Missing build tools have unresolved libraries" >&2
	# perl generates lib/oid_registry_data.c and zstd compresses the image, so a
	# gap in either of them is fatal whatever the configuration is.
	local Fatal=0
	for Tool in /usr/bin/perl /usr/bin/zstd; do
		[ -x "$Tool" ] || continue
		Gaps="$(ldd "$Tool" 2>/dev/null | awk '/not found/ {print $1}')"
		if [ -n "$Gaps" ]; then
			echo "!! $(basename "$Tool") is required by the build and is broken: $Gaps" >&2
			Fatal=1
		fi
	done
	return "$Fatal"
}

AuditTools || exit 1

if Build ConfigureFull; then
	echo "== the kernel built with objtool"
elif Build ConfigureNoObjtool; then
	echo "== the kernel built without objtool"
else
	echo "== the kernel could not be built at all" >&2
	exit 1
fi
echo "== kernel build finished"
INNER
chmod +x "$RootfsDirectory/usr/src/build-kernel.sh"

chroot "$RootfsDirectory" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root TERM=dumb LC_ALL=C TZ=UTC \
	JOBS="$Jobs" \
	/bin/bash /usr/src/build-kernel.sh

echo "== collecting the kernel"
mkdir -p "$OutputDirectory"
cp -f "$RootfsDirectory/usr/src/kernel/vmlinux" "$OutputDirectory/" 2>/dev/null || true
cp -f "$RootfsDirectory/usr/src/kernel/System.map" "$OutputDirectory/" 2>/dev/null || true
cp -f "$RootfsDirectory/usr/src/kernel/.config" "$OutputDirectory/kernel.config" 2>/dev/null || true
for Candidate in arch/x86/boot/bzImage arch/x86/boot/compressed/vmlinux; do
	if [ -f "$RootfsDirectory/usr/src/kernel/$Candidate" ]; then
		cp -f "$RootfsDirectory/usr/src/kernel/$Candidate" "$OutputDirectory/"
	fi
done

echo "== checking what came out"
Failures=0
for Produced in vmlinux System.map kernel.config; do
	if [ -s "$OutputDirectory/$Produced" ]; then
		echo "ok   $Produced ($(stat -c '%s' "$OutputDirectory/$Produced") bytes)"
	else
		echo "FAIL $Produced was not produced"
		Failures=$((Failures + 1))
	fi
done
[ "$Failures" -eq 0 ] || { echo "$Failures kernel outputs are missing" >&2; exit 1; }

# The kernel is an x86_64 ELF, which proves it was built for the target.
Machine="$(od -An -N2 -j18 -tu2 "$OutputDirectory/vmlinux" | tr -d ' ')"
[ "$Machine" = "62" ] || { echo "vmlinux is not an x86_64 ELF (e_machine=$Machine)" >&2; exit 1; }
echo "ok   vmlinux is an x86_64 ELF"

# The compiler recorded in the image is the one from inside the rootfs.
Compiler="$(strings "$OutputDirectory/vmlinux" | grep -m1 -o 'gcc (GCC) [0-9.]*' || true)"
echo "ok   the image records: ${Compiler:-no compiler string}"

{
	echo "kernel_version: $KernelVersion"
	echo "kernel_ref: $KernelRef"
	echo "kernel_repository: $KernelRepository"
	echo "target_arch: x86_64"
	echo "elf_machine: 62"
	echo "rootfs: $RootfsDirectory"
	echo "objtool: $(grep -q '^CONFIG_OBJTOOL=y' "$OutputDirectory/kernel.config" && echo enabled || echo disabled)"
	echo "compiler: ${Compiler:-unknown}"
	echo "compiler_path: /usr/bin/gcc (bootstrapped, native)"
} > "$OutputDirectory/kernel.build"
cat "$OutputDirectory/kernel.build"

echo "== done"
ls -la "$OutputDirectory"