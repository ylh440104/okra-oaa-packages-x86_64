#!/bin/bash
# selftest.sh - exercise the architecture guards without building anything.
# Run from the repository root: scripts/selftest.sh
set -euo pipefail

RepositoryRoot="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$RepositoryRoot/scripts/lib.sh"

Scratch="$(mktemp -d)"
trap 'rm -rf "$Scratch"' EXIT

Failures=0

# ExpectSuccess() - run a command and require exit status 0.
# @Label: text printed before the result.
# @Command: the command to run.
# Return: 0 when the command succeeded, 1 otherwise.
ExpectSuccess() {
	local Label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		echo "ok   $Label"
	else
		echo "FAIL $Label (expected success)"
		Failures=$((Failures + 1))
	fi
}

# ExpectFailure() - run a command and require a non-zero exit status.
# @Label: text printed before the result.
# @Command: the command to run.
# Return: 0 when the command failed, 1 otherwise.
ExpectFailure() {
	local Label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		echo "FAIL $Label (expected failure)"
		Failures=$((Failures + 1))
	else
		echo "ok   $Label"
	fi
}

# FixtureElf() - write a minimal but valid ELF header with a given machine.
# @Path: where to write the file.
# @Machine: the e_machine value as a little endian hex byte pair, e.g. 3e00.
# Return: 0.
FixtureElf() {
	printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00' > "$1"
	printf "$2" >> "$1"
	printf '\x01\x00\x00\x00' >> "$1"
}

echo "== architecture identity"
HostArch="$(OkraHostArch)"
TargetArch="$(OkraTargetArch)"
echo "host:   $HostArch"
echo "target: $TargetArch"
[ "$TargetArch" = "x86_64" ] || { echo "FAIL target arch is $TargetArch"; Failures=$((Failures + 1)); }
[ "$(ElfMachineForArch x86_64)" = "62" ] || { echo "FAIL x86_64 machine"; Failures=$((Failures + 1)); }
[ "$(ElfMachineForArch aarch64)" = "183" ] || { echo "FAIL aarch64 machine"; Failures=$((Failures + 1)); }
[ "$(ElfMachineForArch riscv64)" = "243" ] || { echo "FAIL riscv64 machine"; Failures=$((Failures + 1)); }
ExpectFailure "unknown architecture is rejected" ElfMachineForArch sparc64

echo "== ELF guard"
mkdir -p "$Scratch/amd64/usr/bin" "$Scratch/arm64/usr/bin" "$Scratch/plain/usr/bin"
FixtureElf "$Scratch/amd64/usr/bin/tool" '\x3e\x00'
FixtureElf "$Scratch/arm64/usr/bin/tool" '\xb7\x00'
printf 'not an elf\n' > "$Scratch/plain/usr/bin/data.txt"
cp "$Scratch/amd64/usr/bin/tool" "$Scratch/plain/usr/bin/tool"

ExpectSuccess "x86_64 payload accepted as x86_64" VerifyElfArchitecture "$Scratch/amd64" x86_64
ExpectFailure "aarch64 payload rejected as x86_64" VerifyElfArchitecture "$Scratch/arm64" x86_64
ExpectSuccess "aarch64 payload accepted as aarch64" VerifyElfArchitecture "$Scratch/arm64" aarch64
ExpectSuccess "non-ELF files are ignored" VerifyElfArchitecture "$Scratch/plain" x86_64

echo "== host guard"
if [ "$HostArch" = "x86_64" ]; then
	ExpectSuccess "target host accepted" RequireTargetHost
else
	ExpectFailure "foreign host refused" RequireTargetHost
	OKRA_CROSS_COMPILE=1 ExpectSuccess "cross compile override accepted" RequireTargetHost
fi

echo "== toolchain reuse"
# The list of toolchain inputs decides whether a published toolchain may be
# reused. It must not be empty, must name the toolchain script, and must not
# accidentally include the workflow itself (which changes far more often).
InputFile="$RepositoryRoot/scripts/toolchain-inputs.txt"
Inputs=""
if [ -f "$InputFile" ]; then
	Inputs="$(cat "$InputFile")"
else
	echo "FAIL toolchain input list is missing: $InputFile"
	Failures=$((Failures + 1))
fi
[ -n "$Inputs" ] || { echo "FAIL toolchain inputs are empty"; Failures=$((Failures + 1)); }
case "$Inputs" in
	*scripts/build-cross-toolchain.sh*) echo "ok   toolchain inputs name the toolchain script" ;;
	*) echo "FAIL toolchain inputs omit the toolchain script"; Failures=$((Failures + 1)) ;;
esac
case "$Inputs" in
	*.github/workflows/*) echo "FAIL toolchain inputs include the workflow"; Failures=$((Failures + 1)) ;;
	*) echo "ok   toolchain inputs exclude the workflow" ;;
esac
while IFS= read -r Input; do
	[ -n "$Input" ] || continue
	if [ -f "$RepositoryRoot/$Input" ]; then
		echo "ok   toolchain input exists: $Input"
	else
		echo "FAIL toolchain input is missing: $Input"
		Failures=$((Failures + 1))
	fi
done <<< "$Inputs"

# The reuse decision is a plain git comparison, so it can be exercised offline.
if command -v git >/dev/null 2>&1; then
	ReuseRepo="$Scratch/reuse"
	mkdir -p "$ReuseRepo/scripts" "$ReuseRepo/packages"
	git -C "$ReuseRepo" init -q
	git -C "$ReuseRepo" config user.email selftest@example.com
	git -C "$ReuseRepo" config user.name selftest
	printf 'one\n' > "$ReuseRepo/scripts/build-cross-toolchain.sh"
	printf 'x\n' > "$ReuseRepo/packages/glibc.conf"
	git -C "$ReuseRepo" add -A
	git -C "$ReuseRepo" commit -qm first
	First="$(git -C "$ReuseRepo" rev-parse HEAD)"
	printf 'two\n' > "$ReuseRepo/scripts/build-cross-toolchain.sh"
	git -C "$ReuseRepo" commit -qam second
	Second="$(git -C "$ReuseRepo" rev-parse HEAD)"
	if git -C "$ReuseRepo" diff --quiet "$First" "$Second" -- scripts/build-cross-toolchain.sh packages/glibc.conf; then
		echo "FAIL a changed toolchain input was not detected"
		Failures=$((Failures + 1))
	else
		echo "ok   a changed toolchain input invalidates the published toolchain"
	fi
	printf 'x\n' > "$ReuseRepo/packages/gcc.conf"
	git -C "$ReuseRepo" add -A
	git -C "$ReuseRepo" commit -qm unrelated
	Unrelated="$(git -C "$ReuseRepo" rev-parse HEAD)"
	if git -C "$ReuseRepo" diff --quiet "$Second" "$Unrelated" -- scripts/build-cross-toolchain.sh packages/glibc.conf; then
		echo "ok   an unrelated commit keeps the published toolchain valid"
	else
		echo "FAIL an unrelated commit invalidated the published toolchain"
		Failures=$((Failures + 1))
	fi
fi

echo
if [ "$Failures" -eq 0 ]; then
	echo "all checks passed"
else
	echo "$Failures check(s) failed"
	exit 1
fi