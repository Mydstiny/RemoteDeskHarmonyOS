#!/usr/bin/env sh
set -eu

script_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-state-test.XXXXXX")"
cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$test_root/src" "$test_root/docs/codex"
printf '%s\n' '# current' > "$test_root/docs/codex/CURRENT.md"
printf '%s\n' '# queue' > "$test_root/docs/codex/QUEUE.md"
git -C "$test_root" init -q -b main
git -C "$test_root" config user.name 'Codex State Test'
git -C "$test_root" config user.email 'codex-state-test@example.invalid'
printf '%s\n' 'v1' > "$test_root/src/module.txt"
printf '%s\n' '# test plan' > "$test_root/plan.md"
git -C "$test_root" add src/module.txt plan.md
git -C "$test_root" commit -qm 'test: initialize state fixture'
base="$(git -C "$test_root" rev-parse HEAD)"
base_short="$(git -C "$test_root" rev-parse --short=9 HEAD)"
git -C "$test_root" switch -q -c codex/state-test
printf '%s\n' '{' '  "schema": 1,' '  "task": "state-test",' "  \"base\": \"$base_short\"," '  "head": "",' '  "phase": "test",' '  "planPaths": ["plan.md"],' '  "review": {' '    "status": "ACTIVE",' '    "scope": ["src"]' '  }' '}' > "$test_root/docs/codex/STATE.json"
printf '%s\n' > "$test_root/docs/codex/REVIEW_RECEIPTS.jsonl"
git -C "$test_root" add docs/codex/STATE.json docs/codex/REVIEW_RECEIPTS.jsonl
git -C "$test_root" commit -qm 'test: add state manifest'
printf '%s\n' 'v2' > "$test_root/src/module.txt"
git -C "$test_root" add src/module.txt
git -C "$test_root" commit -qm 'test: change reviewed scope'

run_state() {
  CODEX_STATE_ROOT="$test_root" node "$script_root/codex_state.mjs" "$1"
}

assert_contains() {
  haystack="$1"
  needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) printf '%s\n' "Expected '$needle' in:\n$haystack" >&2; exit 1 ;;
  esac
}

required="$(run_state review-status)"
assert_contains "$required" 'review=REVIEW_REQUIRED'

snapshot="$(run_state snapshot)"
scope_hash="$(printf '%s\n' "$snapshot" | awk -F= '$1 == "scopeTreeHash" { print $2 }')"
plan_hash="$(printf '%s\n' "$snapshot" | awk -F= '$1 == "planHash" { print $2 }')"
head="$(git -C "$test_root" rev-parse HEAD)"
printf '%s\n' "{\"schema\":1,\"receiptId\":\"state-test-pass\",\"task\":\"state-test\",\"status\":\"PASS\",\"reviewedHead\":\"$head\",\"base\":\"$base\",\"scopeTreeHash\":\"$scope_hash\",\"planHash\":\"$plan_hash\",\"findings\":[]}" > "$test_root/docs/codex/REVIEW_RECEIPTS.jsonl"

passed="$(run_state review-status)"
assert_contains "$passed" 'review=SKIP_FULL_REVIEW'

printf '%s\n' 'documentation-only' > "$test_root/docs/note.txt"
git -C "$test_root" add docs/note.txt
git -C "$test_root" commit -qm 'test: documentation-only change'
docs_only="$(run_state review-status)"
assert_contains "$docs_only" 'review=SKIP_FULL_REVIEW'

printf '%s\n' 'v3' > "$test_root/src/module.txt"
git -C "$test_root" add src/module.txt
git -C "$test_root" commit -qm 'test: invalidate reviewed scope'
changed="$(run_state review-status)"
assert_contains "$changed" 'review=REVIEW_REQUIRED'

printf '%s\n' '{"schema":1,"receiptId":"state-test-blocked","task":"state-test","status":"BLOCKED","reviewTaskId":"review-thread-1","reason":"no report"}' > "$test_root/docs/codex/REVIEW_RECEIPTS.jsonl"
blocked="$(run_state review-status)"
assert_contains "$blocked" 'review=RESUME_REVIEW'
assert_contains "$blocked" 'review-task-id=review-thread-1'

validated="$(run_state validate)"
assert_contains "$validated" 'state-validation=PASS'

printf '%s\n' 'Codex state receipt tests passed.'
