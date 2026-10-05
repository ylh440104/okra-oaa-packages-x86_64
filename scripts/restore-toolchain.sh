#!/bin/bash
# restore-toolchain.sh - reuse a previously published cross toolchain.
#
# Building the cross toolchain takes about half an hour. Every run of the
# bootstrap workflow needs it, so the toolchain job publishes it as the
# okra-cross-toolchain artifact and later runs download it again instead of
# rebuilding it.
#
# A published toolchain may only be reused when it would come out identical:
# the run that produced it must have the same scripts/build-cross-toolchain.sh,
# scripts/lib.sh and glibc/gcc/binutils recipes as this commit. That is checked
# with git, so editing the toolchain always forces a rebuild.
#
# Environment:
#   GITHUB_REPOSITORY   owner/name of the repository
#   GITHUB_TOKEN        token with actions:read
#   OKRA_TOOLCHAIN      where to unpack it (default /opt/okra-toolchain)
#   OKRA_REPO_ROOT      repository checkout (default: the script's parent)
#   OKRA_TARGET_TRIPLE  target triple (default x86_64-okra-linux-gnu)
#   OKRA_TOOLCHAIN_PROBE  when 1, only report whether a reusable toolchain
#                       exists, without downloading it
# Return: 0 when a usable toolchain was restored, 1 when one has to be built.
set -uo pipefail

Repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
Token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
ToolchainRoot="${OKRA_TOOLCHAIN:-/opt/okra-toolchain}"
TargetTriple="${OKRA_TARGET_TRIPLE:-x86_64-okra-linux-gnu}"
ScratchDirectory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
ProbeOnly="${OKRA_TOOLCHAIN_PROBE:-0}"

ScriptDirectory="$(cd "$(dirname "$0")" && pwd)"
RepositoryRoot="${OKRA_REPO_ROOT:-$(cd "$ScriptDirectory/.." && pwd)}"
# shellcheck disable=SC1091
. "$RepositoryRoot/scripts/lib.sh"

# Already restored, or left over from an earlier step in the same job.
if [ -x "$ToolchainRoot/cross/bin/$TargetTriple-gcc" ] &&
	[ -f "$ToolchainRoot/okra-sysroot/lib64/ld-linux-x86-64.so.2" ]; then
	echo "== a cross toolchain is already present at $ToolchainRoot"
	exit 0
fi

echo "== looking for a published cross toolchain to reuse"
Candidates=""
# The artifact published by this very run may take a moment to show up in the
# listing, so an empty answer is retried a few times before giving up.
for Attempt in 1 2 3 4 5; do
	Candidates="$(GITHUB_REPOSITORY="$Repository" GITHUB_TOKEN="$Token" \
		bash "$ScriptDirectory/find-toolchain-run.sh")" || {
		echo "could not query the published toolchains" >&2
		exit 1
	}
	[ -n "$Candidates" ] && break
	echo "== no published cross toolchain yet (attempt $Attempt)"
	sleep 15
done

if [ -z "$Candidates" ]; then
	echo "== no published cross toolchain is available"
	exit 1
fi

CurrentCommit="$(git -C "$RepositoryRoot" rev-parse HEAD)"
Inputs=()
while IFS= read -r Input; do
	[ -n "$Input" ] || continue
	Inputs+=("$Input")
done < <(OkraToolchainInputs)

# CompareToolchainInputs() - test whether a published toolchain is still valid.
# @Commit: the commit the published toolchain was built from.
# Return: 0 when none of the toolchain inputs changed since that commit.
CompareToolchainInputs() {
	local Commit="$1"
	git -C "$RepositoryRoot" cat-file -e "$Commit^{commit}" 2>/dev/null || return 1
	if git -C "$RepositoryRoot" diff --quiet "$Commit" "$CurrentCommit" -- "${Inputs[@]}"; then
		return 0
	fi
	return 1
}

# DownloadToolchain() - fetch and unpack the toolchain artifact of a run.
# @RunId: the workflow run id.
# @ArtifactId: the artifact id to download.
# Return: 0 when the toolchain is in place and usable, 1 otherwise.
DownloadToolchain() {
	local RunId="$1" ArtifactId="$2"
	local Archive="$ScratchDirectory/okra-cross-toolchain.zip"

	echo "== downloading the cross toolchain from run $RunId"
	if ! curl -sSL --retry 3 -m 900 \
		-H "Authorization: token $Token" \
		-H 'Accept: application/vnd.github+json' \
		-o "$Archive" \
		"https://api.github.com/repos/$Repository/actions/artifacts/$ArtifactId/zip"; then
		echo "== the download failed" >&2
		return 1
	fi

	local Unpacked="$ScratchDirectory/okra-cross-toolchain"
	rm -rf "$Unpacked"
	mkdir -p "$Unpacked"
	if ! unzip -qo "$Archive" -d "$Unpacked"; then
		echo "== the artifact is not a readable archive" >&2
		return 1
	fi
	rm -f "$Archive"

	local Tarball
	Tarball="$(find "$Unpacked" -maxdepth 1 -name '*.tar.zst' -print -quit)"
	if [ -z "$Tarball" ]; then
		echo "== the artifact holds no toolchain tarball" >&2
		return 1
	fi

	local Checksum="$Tarball.sha256"
	if [ -f "$Checksum" ]; then
		local Expected Actual
		Expected="$(awk '{print $1}' "$Checksum")"
		Actual="$(sha256sum "$Tarball" | awk '{print $1}')"
		if [ "$Expected" != "$Actual" ]; then
			echo "== the toolchain checksum does not match" >&2
			return 1
		fi
		echo "== the toolchain checksum matches"
	fi

	sudo mkdir -p "$(dirname "$ToolchainRoot")"
	sudo rm -rf "$ToolchainRoot"
	sudo tar --zstd -xf "$Tarball" -C "$(dirname "$ToolchainRoot")"
	sudo chown -R "$(id -u):$(id -g)" "$ToolchainRoot"
	rm -rf "$Unpacked"
	return 0
}

while read -r CreatedAt RunId ArtifactId Commit; do
	[ -n "${RunId:-}" ] || continue
	if ! CompareToolchainInputs "$Commit"; then
		echo "== skipping run $RunId: the toolchain inputs changed since $Commit"
		continue
	fi
	if [ "$ProbeOnly" = "1" ]; then
		echo "== run $RunId published a reusable toolchain"
		exit 0
	fi
	if ! DownloadToolchain "$RunId" "$ArtifactId"; then
		continue
	fi
	if [ -x "$ToolchainRoot/cross/bin/$TargetTriple-gcc" ] &&
		[ -f "$ToolchainRoot/okra-sysroot/lib64/ld-linux-x86-64.so.2" ]; then
		echo "== reused the cross toolchain published by run $RunId"
		"$ToolchainRoot/cross/bin/$TargetTriple-gcc" --version | head -1
		exit 0
	fi
	echo "== run $RunId published an incomplete toolchain" >&2
done <<< "$Candidates"

echo "== no published cross toolchain matches this commit"
exit 1