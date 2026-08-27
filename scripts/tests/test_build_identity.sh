#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
generator="$project_root/entry/src/main/cpp/cmake/GenerateBuildIdentity.cmake"
test_root="$(mktemp -d /private/tmp/remotedesktop-build-identity.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

repo="$test_root/repo"
output="$test_root/generated/remotedesk_build_identity.h"
fallback="$test_root/generated/fallback.h"
git init -q "$repo"
git -C "$repo" config user.name RemoteDesktop-Test
git -C "$repo" config user.email remotedesktop-test@example.invalid
printf '%s\n' first > "$repo/revision.txt"
git -C "$repo" add revision.txt
git -C "$repo" commit -qm first

cmake -DREMOTEDESK_SOURCE_ROOT="$repo" -DREMOTEDESK_OUTPUT_FILE="$output" \
  -P "$generator"
first_sha="$(git -C "$repo" rev-parse --short=12 HEAD)"
rg -q -F "#define REMOTEDESK_GIT_SHORT_SHA \"$first_sha\"" "$output"

printf '%s\n' second > "$repo/revision.txt"
git -C "$repo" add revision.txt
git -C "$repo" commit -qm second
cmake -DREMOTEDESK_SOURCE_ROOT="$repo" -DREMOTEDESK_OUTPUT_FILE="$output" \
  -P "$generator"
second_sha="$(git -C "$repo" rev-parse --short=12 HEAD)"
test "$first_sha" != "$second_sha"
rg -q -F "#define REMOTEDESK_GIT_SHORT_SHA \"$second_sha\"" "$output"
if rg -q -F "$first_sha" "$output"; then
  printf '%s\n' 'stale build identity remained after HEAD changed' >&2
  exit 1
fi

mkdir "$test_root/not-a-repository"
cmake -DREMOTEDESK_SOURCE_ROOT="$test_root/not-a-repository" \
  -DREMOTEDESK_OUTPUT_FILE="$fallback" -P "$generator"
rg -q -F '#define REMOTEDESK_GIT_SHORT_SHA "unknown"' "$fallback"
printf '%s\n' 'RemoteDesktop build identity tests passed.'
