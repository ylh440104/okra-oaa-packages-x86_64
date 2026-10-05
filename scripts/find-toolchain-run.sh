#!/bin/bash
# find-toolchain-run.sh - list the runs that published a reusable toolchain.
#
# Building the cross toolchain takes about half an hour, so it is published as
# the okra-cross-toolchain artifact and later runs reuse it instead of
# rebuilding it. This script lists every still downloadable toolchain, newest
# first, together with the commit it was built from. Callers decide whether a
# candidate is still valid by comparing the toolchain inputs of that commit
# with the current one.
#
# Output: one line per candidate, "created_at run_id artifact_id head_sha".
#
# Environment:
#   GITHUB_REPOSITORY         owner/name of the repository
#   GITHUB_TOKEN              token with actions:read
#   OKRA_TOOLCHAIN_ARTIFACT   artifact name (default okra-cross-toolchain)
# Return: 0 when the listing was read, 1 when the API call failed.
set -uo pipefail

Repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
Token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
ArtifactName="${OKRA_TOOLCHAIN_ARTIFACT:-okra-cross-toolchain}"

Response="$(curl -sS -m 30 \
	-H "Authorization: token $Token" \
	-H 'Accept: application/vnd.github+json' \
	"https://api.github.com/repos/$Repository/actions/artifacts?name=$ArtifactName&per_page=100")" || {
	echo "could not list the $ArtifactName artifacts" >&2
	exit 1
}

printf '%s' "$Response" | python3 -c '
import json, sys

Name = sys.argv[1]
Payload = json.load(sys.stdin)
if not isinstance(Payload, dict) or "artifacts" not in Payload:
    print("unexpected artifact listing: " + json.dumps(Payload)[:200], file=sys.stderr)
    raise SystemExit(1)

Rows = []
for Artifact in Payload["artifacts"]:
    if Artifact.get("name") != Name or Artifact.get("expired"):
        continue
    Run = Artifact.get("workflow_run") or {}
    if not Run.get("id") or not Run.get("head_sha"):
        continue
    Rows.append((Artifact["created_at"], Run["id"], Artifact["id"], Run["head_sha"]))

for Row in sorted(Rows, reverse=True):
    print("%s %s %s %s" % Row)
' "$ArtifactName"