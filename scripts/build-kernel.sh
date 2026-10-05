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

echo "== fetching elfutils so objtool can be self-hosted"
ElfutilsUrl="https://sourceware.org/elfutils/ftp/$ElfutilsVersion/elfutils-$ElfutilsVersion.tar.bz2"
if curl -fsSL --retry 3 -m 300 -o "$Scratch/elfutils.tar.bz2" "$ElfutilsUrl"; then
	cp -f "$Scratch/elfutils.tar.bz2" "$RootfsDirectory/usr/src/elfutils.tar.bz2"
	echo "== elfutils $ElfutilsVersion is available for the userland"
else
	echo "== elfutils could not be fetched; objtool will be switched off" >&2
fi

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
	./configure --prefix=/usr --disable-debuginfod --disable-libdebuginfod \
		--disable-nls --without-zstd --without-bzlib --without-lzma || return 1
	make -j"${JOBS}" || return 1
	make install || return 1
	cd /usr/src/kernel || return 1
	# The linker has to find it without a ldconfig run.
	if [ ! -e /usr/lib/libelf.so ]; then
		local Soname
		Soname="$(ls /usr/lib/libelf.so.* 2>/dev/null | head -1)"
		[ -n "$Soname" ] && ln -sfn "$Soname" /usr/lib/libelf.so
	fi
	echo "== libelf installed"
	ls -la /usr/lib/libelf.so* 2>/dev/null || true
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

# The full configuration is the one worth having, so libelf is built for it.
if ! HasLibelf; then
	BuildLibelf || echo "== elfutils could not be built; objtool will be switched off" >&2
fi

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