#!/bin/bash
# assemble-rootfs.sh - turn a bootstrapped sysroot into a chrootable rootfs.
#
# The bootstrap installs every self-hosted package into the toolchain sysroot,
# so that tree already is the Okra userland: glibc from the toolchain stage plus
# all 70 packages on top of it. This script takes a copy of that tree and adds
# what a Unix system needs but no package provides - the usual top level
# directories, /bin/sh, the account files - and then checks that the result can
# actually stand on its own.
#
# It does not build or install anything. Run it on a rootfs that already holds
# /usr/bin/gcc and /lib64/ld-linux-x86-64.so.2.
#
# Usage: assemble-rootfs.sh <rootfs-dir>
# Return: 0 when the rootfs is ready to chroot into, 1 otherwise.
set -euo pipefail

RootfsDirectory="${1:?usage: assemble-rootfs.sh <rootfs-dir>}"
[ -d "$RootfsDirectory" ] || { echo "no rootfs at $RootfsDirectory" >&2; exit 1; }

echo "== filling in the directories a system needs"
mkdir -p "$RootfsDirectory"/{bin,sbin,etc,var,tmp,proc,sys,dev,run,root,home,boot,usr/src}

# The packages install under /usr. A Unix system is still expected to answer to
# /bin and /sbin, and /bin/sh is what configure scripts and make recipes call.
for Directory in bin sbin; do
	if [ -d "$RootfsDirectory/usr/$Directory" ]; then
		cp -a --remove-destination "$RootfsDirectory/usr/$Directory/." "$RootfsDirectory/$Directory"/
	fi
done

if [ ! -e "$RootfsDirectory/bin/sh" ]; then
	if [ -x "$RootfsDirectory/usr/bin/bash" ]; then
		ln -sfn /usr/bin/bash "$RootfsDirectory/bin/sh"
	elif [ -x "$RootfsDirectory/bin/bash" ]; then
		ln -sfn /bin/bash "$RootfsDirectory/bin/sh"
	fi
fi

echo "== writing the account and resolver files"
cat > "$RootfsDirectory/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/:/bin/false
EOF
cat > "$RootfsDirectory/etc/group" <<'EOF'
root:x:0:
wheel:x:10:
nobody:x:65534:
EOF
printf 'okra\n' > "$RootfsDirectory/etc/hostname"
# The kernel build resolves nothing, but git and wget inside the chroot do.
cp -f /etc/resolv.conf "$RootfsDirectory/etc/resolv.conf" 2>/dev/null || \
	printf 'nameserver 8.8.8.8\n' > "$RootfsDirectory/etc/resolv.conf"
: > "$RootfsDirectory/etc/ld.so.cache"

echo "== checking the rootfs can stand on its own"
Failures=0
for Required in \
	"lib64/ld-linux-x86-64.so.2" \
	"usr/lib/libc.so.6" \
	"usr/bin/bash" \
	"usr/bin/gcc" \
	"usr/bin/ld" \
	"usr/bin/make" \
	"bin/sh"; do
	if [ -e "$RootfsDirectory/$Required" ]; then
		echo "ok   $Required"
	else
		echo "FAIL $Required is missing"
		Failures=$((Failures + 1))
	fi
done
[ "$Failures" -eq 0 ] || {
	echo "$Failures required files are missing from the rootfs" >&2
	exit 1
}

# The loader has to be the Okra one, not something left over from the runner.
Loader="$RootfsDirectory/lib64/ld-linux-x86-64.so.2"
Machine="$(od -An -N2 -j18 -tu2 "$Loader" | tr -d ' ')"
[ "$Machine" = "62" ] || {
	echo "the loader is not an x86_64 ELF (e_machine=$Machine)" >&2
	exit 1
}
echo "ok   the loader is an x86_64 ELF"

# Every ELF the packages brought in has to be x86_64 as well.
echo "== checking the payload"
Bad="$(find "$RootfsDirectory/usr/bin" "$RootfsDirectory/usr/sbin" "$RootfsDirectory/usr/lib" \
	-type f -print0 2>/dev/null | \
	while IFS= read -r -d '' Found; do
		[ "$(od -An -N4 -tx1 "$Found" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] || continue
		[ "$(od -An -N2 -j18 -tu2 "$Found" 2>/dev/null | tr -d ' ')" = "62" ] || echo "$Found"
	done | head -5)"
[ -z "$Bad" ] || { echo "these files are not x86_64 ELF:" >&2; echo "$Bad" >&2; exit 1; }
echo "ok   every ELF under /usr is x86_64"

echo "== rootfs ready at $RootfsDirectory"
du -sh "$RootfsDirectory"
echo "== programs available"
ls "$RootfsDirectory/usr/bin" | wc -l