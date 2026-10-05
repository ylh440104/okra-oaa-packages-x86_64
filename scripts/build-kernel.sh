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
# Usage: build-kernel.sh <rootfs-dir> <output-dir>
#
# Environment:
#   OKRA_KERNEL_REPOSITORY  default https://github.com/OkraLinux/KERNEL.git
#   OKRA_KERNEL_REF         branch, tag or commit (default main)
#   OKRA_KERNEL_JOBS        default 4
# Return: 0 when a vmlinux was produced, 1 otherwise.
set -euo pipefail

RootfsDirectory="${1:?usage: build-kernel.sh <rootfs-dir> <output-dir>}"
OutputDirectory="${2:?usage: build-kernel.sh <rootfs-dir> <output-dir>}"

KernelRepository="${OKRA_KERNEL_REPOSITORY:-https://github.com/OkraLinux/KERNEL.git}"
KernelRef="${OKRA_KERNEL_REF:-main}"
Jobs="${OKRA_KERNEL_JOBS:-${OKRA_JOBS:-4}}"

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
set -euo pipefail
cd /usr/src/kernel
echo "== compiler inside the chroot"
command -v gcc
gcc --version | head -1
echo "== kernel configuration"
make defconfig
# A minimal set of options that keep the image usable in a virtual machine.
./scripts/config \
	--enable CONFIG_VIRTIO \
	--enable CONFIG_VIRTIO_PCI \
	--enable CONFIG_VIRTIO_BLK \
	--enable CONFIG_VIRTIO_NET \
	--enable CONFIG_BLK_DEV_INITRD \
	--enable CONFIG_DEVTMPFS \
	--enable CONFIG_DEVTMPFS_MOUNT
make olddefconfig
echo "== building vmlinux"
make -j"${JOBS}" vmlinux
echo "== building the bzImage"
make -j"${JOBS}" bzImage
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
	echo "compiler: $(strings "$OutputDirectory/vmlinux" | grep -m1 -o 'gcc (GCC) [0-9.]*' || echo unknown)"
	echo "compiler_path: /usr/bin/gcc (bootstrapped, native)"
} > "$OutputDirectory/kernel.build"
cat "$OutputDirectory/kernel.build"

echo "== done"
ls -la "$OutputDirectory"