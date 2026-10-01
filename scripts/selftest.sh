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

echo
if [ "$Failures" -eq 0 ]; then
	echo "all checks passed"
else
	echo "$Failures check(s) failed"
	exit 1
fi