#!/usr/bin/env bash

set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
guard="$script_dir/../macos_hvigorw.sh"
test_root="$(mktemp -d /private/tmp/remotedesk-hvigor-guard-test.XXXXXX)"
project_root="$test_root/project"
cache_root="$test_root/cache"
fake_hvigor="$test_root/fake-hvigorw"
fake_log="$test_root/fake.log"
fake_child_pid="$test_root/fake-child.pid"
fake_signal_seen="$test_root/fake-signal.seen"
fake_descendant_pid="$test_root/fake-descendant.pid"
fake_find="$test_root/fake-find"
fake_cache_corruption_seen="$test_root/fake-cache-corruption.seen"

cleanup() {
    for pid_file in "$fake_child_pid" "$fake_descendant_pid"; do
        cleanup_pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
        case "$cleanup_pid" in
            ''|*[!0-9]*) ;;
            *) kill -KILL -- "-$cleanup_pid" 2>/dev/null || true ;;
        esac
    done
    rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$project_root/scripts" "$project_root/.hvigor" \
    "$project_root/entry/build" "$project_root/entry/.cxx"
printf '%s\n' old > "$project_root/.hvigor/old-cache"
printf '%s\n' old > "$project_root/entry/build/old-build"
printf '%s\n' old > "$project_root/entry/.cxx/old-cxx"

cat > "$fake_hvigor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REMOTE_DESKTOP_FAKE_HVIGOR_LOG"
if [ -n "${REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION:-}" ] &&
   [[ " $* " != *" clean "* ]] &&
   [ ! -e "$REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_SEEN" ]; then
    : > "$REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_SEEN"
    printf '%s\n' "${REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_MESSAGE:-Failed to read file to buffer: $REMOTE_DESKTOP_BUILD_CACHE_ROOT/build-cache/project/entry/build/generated.ts}" >&2
    exit 9
fi
if [ -n "${REMOTE_DESKTOP_FAKE_HVIGOR_DESCENDANT:-}" ]; then
    printf '%s\n' "${REMOTE_DESKTOP_HVIGOR_PROCESS_GROUP:-$$}" > "$REMOTE_DESKTOP_FAKE_HVIGOR_CHILD_PID"
    (
        trap '' HUP INT TERM
        while :; do sleep 1; done
    ) &
    printf '%s\n' "$!" > "$REMOTE_DESKTOP_FAKE_HVIGOR_DESCENDANT_PID"
    exit "${REMOTE_DESKTOP_FAKE_HVIGOR_STATUS:-0}"
fi
if [ -n "${REMOTE_DESKTOP_FAKE_HVIGOR_HOLD:-}" ]; then
    printf '%s\n' "${REMOTE_DESKTOP_HVIGOR_PROCESS_GROUP:-$$}" > "$REMOTE_DESKTOP_FAKE_HVIGOR_CHILD_PID"
    trap 'printf signal > "$REMOTE_DESKTOP_FAKE_HVIGOR_SIGNAL_SEEN"; sleep 1; exit 143' TERM
    while :; do sleep 1; done
fi
exit "${REMOTE_DESKTOP_FAKE_HVIGOR_STATUS:-0}"
EOF
chmod +x "$fake_hvigor"

cat > "$fake_find" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'simulated File Provider traversal failure' >&2
exit 74
EOF
chmod +x "$fake_find"

run_guard() {
    REMOTE_DESKTOP_PROJECT_ROOT="$project_root" \
    REMOTE_DESKTOP_BUILD_CACHE_ROOT="$cache_root" \
    REMOTE_DESKTOP_REAL_HVIGORW="$fake_hvigor" \
    REMOTE_DESKTOP_FAKE_HVIGOR_LOG="$fake_log" \
    REMOTE_DESKTOP_FAKE_HVIGOR_HOLD="${REMOTE_DESKTOP_FAKE_HVIGOR_HOLD:-}" \
    REMOTE_DESKTOP_FAKE_HVIGOR_DESCENDANT="${REMOTE_DESKTOP_FAKE_HVIGOR_DESCENDANT:-}" \
    REMOTE_DESKTOP_FAKE_HVIGOR_DESCENDANT_PID="$fake_descendant_pid" \
    REMOTE_DESKTOP_FAKE_HVIGOR_CHILD_PID="$fake_child_pid" \
    REMOTE_DESKTOP_FAKE_HVIGOR_SIGNAL_SEEN="$fake_signal_seen" \
    REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION="${REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION:-}" \
    REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_MESSAGE="${REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_MESSAGE:-}" \
    REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_SEEN="$fake_cache_corruption_seen" \
    REMOTE_DESKTOP_FIND_BIN="${REMOTE_DESKTOP_FIND_BIN:-/usr/bin/find}" \
    REMOTE_DESKTOP_GROUP_GRACE_CHECKS="${REMOTE_DESKTOP_GROUP_GRACE_CHECKS:-50}" \
    REMOTE_DESKTOP_GROUP_KILL_CHECKS="${REMOTE_DESKTOP_GROUP_KILL_CHECKS:-20}" \
    REMOTE_DESKTOP_FAKE_HVIGOR_STATUS="${1:-0}" \
        "$guard" "${@:2}"
}

run_guard 0 assembleHap --no-daemon
[ -L "$project_root/.hvigor" ]
[ -L "$project_root/entry/build" ]
[ -L "$project_root/entry/.cxx" ]
[ "$(readlink "$project_root/.hvigor")" = "$cache_root/build-cache/project/.hvigor" ]
[ "$(readlink "$project_root/entry/build")" = "$cache_root/build-cache/project/entry/build" ]
[ "$(readlink "$project_root/entry/.cxx")" = "$cache_root/entry-cxx" ]
[ ! -f "$cache_root/last-build.incomplete" ]
grep -F 'assembleHap --no-daemon -p build-cache-dir=' "$fake_log" >/dev/null
find "$project_root/.remotedesk-build-quarantine" -type f -name old-cache | grep . >/dev/null
find "$project_root/.remotedesk-build-quarantine" -type f -name old-build | grep . >/dev/null
find "$project_root/.remotedesk-build-quarantine" -type f -name old-cxx | grep . >/dev/null

if run_guard 9 assembleHap --no-daemon; then
    printf '%s\n' 'expected failing fake build' >&2
    exit 1
fi
[ -f "$cache_root/last-build.incomplete" ]

run_guard 0 assembleHap --no-daemon
[ ! -f "$cache_root/last-build.incomplete" ]
tail -n 1 "$fake_log" | grep -F 'assembleHap --no-daemon' >/dev/null

rm -f "$fake_cache_corruption_seen"
REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION=1 run_guard 0 assembleHap --no-daemon
[ -f "$fake_cache_corruption_seen" ]
[ ! -f "$cache_root/last-build.incomplete" ]
tail -n 2 "$fake_log" | grep -F 'assembleHap --no-daemon' | [ "$(wc -l | tr -d ' ')" -eq 2 ]
find "$cache_root/quarantine" -maxdepth 1 -type d \
    -name 'generated-build-cache-*' | grep . >/dev/null
find "$cache_root/quarantine" -maxdepth 1 -type d \
    -name 'generated-native-cache-*' | grep . >/dev/null

rm -f "$fake_cache_corruption_seen"
REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION=1 \
REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_MESSAGE="hvigor ERROR: 10310009 ArkTS: INTERNAL ERROR
Error Message: Failed to find module info. Failed to find module info with '$project_root/entry/build/default/generated/r/default/ResourceTable.ts' from the context information." \
    run_guard 0 assembleHap --no-daemon
[ -f "$fake_cache_corruption_seen" ]
[ ! -f "$cache_root/last-build.incomplete" ]
tail -n 2 "$fake_log" | grep -F 'assembleHap --no-daemon' | [ "$(wc -l | tr -d ' ')" -eq 2 ]

rm -f "$fake_cache_corruption_seen"
REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION=1 \
REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_MESSAGE="Failed to find the incremental input file: $cache_root/build-cache/project/entry/build/default/intermediates/stripped_native_libs/default." \
    run_guard 0 assembleHap --no-daemon
[ -f "$fake_cache_corruption_seen" ]
[ ! -f "$cache_root/last-build.incomplete" ]
tail -n 2 "$fake_log" | grep -F 'assembleHap --no-daemon' | [ "$(wc -l | tr -d ' ')" -eq 2 ]

rm -f "$fake_cache_corruption_seen"
REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION=1 \
REMOTE_DESKTOP_FAKE_HVIGOR_CACHE_CORRUPTION_MESSAGE='Error Message: --pack-info-path is not a file.' \
    run_guard 0 assembleHap --no-daemon
[ -f "$fake_cache_corruption_seen" ]
[ ! -f "$cache_root/last-build.incomplete" ]
tail -n 2 "$fake_log" | grep -F 'assembleHap --no-daemon' | [ "$(wc -l | tr -d ' ')" -eq 2 ]

log_lines_before_find_failure="$(wc -l < "$fake_log" | tr -d ' ')"
if REMOTE_DESKTOP_FIND_BIN="$fake_find" run_guard 0 assembleHap --no-daemon >/dev/null 2>&1; then
    printf '%s\n' 'expected find failure to stop build' >&2
    exit 1
fi
[ "$(wc -l < "$fake_log" | tr -d ' ')" = "$log_lines_before_find_failure" ]

REMOTE_DESKTOP_PROJECT_ROOT="$project_root" \
REMOTE_DESKTOP_BUILD_CACHE_ROOT="$cache_root" \
REMOTE_DESKTOP_REAL_HVIGORW="$fake_hvigor" \
REMOTE_DESKTOP_FAKE_HVIGOR_LOG="$fake_log" \
REMOTE_DESKTOP_FAKE_HVIGOR_HOLD=1 \
REMOTE_DESKTOP_FAKE_HVIGOR_CHILD_PID="$fake_child_pid" \
REMOTE_DESKTOP_FAKE_HVIGOR_SIGNAL_SEEN="$fake_signal_seen" \
REMOTE_DESKTOP_FAKE_HVIGOR_STATUS=0 \
    "$guard" assembleHap --no-daemon &
guard_pid=$!
wait_checks=0
while [ ! -s "$fake_child_pid" ] && [ "$wait_checks" -lt 100 ]; do
    sleep 0.05
    wait_checks=$((wait_checks + 1))
done
[ -s "$fake_child_pid" ]
child_pid="$(sed -n '1p' "$fake_child_pid")"
kill -TERM "$guard_pid"
wait_checks=0
while [ ! -e "$fake_signal_seen" ] && [ "$wait_checks" -lt 100 ]; do
    sleep 0.05
    wait_checks=$((wait_checks + 1))
done
[ -e "$fake_signal_seen" ]
[ -d "$cache_root/build.lock" ]
if wait "$guard_pid"; then
    printf '%s\n' 'expected signalled guard to fail' >&2
    exit 1
else
    guard_status=$?
fi
[ "$guard_status" -eq 143 ]
if kill -0 "$child_pid" 2>/dev/null; then
    printf '%s\n' 'signalled Hvigor child survived wrapper shutdown' >&2
    exit 1
fi
[ ! -e "$cache_root/build.lock" ]
[ -e "$cache_root/last-build.incomplete" ]
run_guard 0 assembleHap --no-daemon
[ ! -e "$cache_root/last-build.incomplete" ]

if REMOTE_DESKTOP_FAKE_HVIGOR_DESCENDANT=1 \
    REMOTE_DESKTOP_GROUP_GRACE_CHECKS=5 \
    REMOTE_DESKTOP_GROUP_KILL_CHECKS=10 \
    run_guard 9 assembleHap --no-daemon; then
    printf '%s\n' 'expected live descendant to fail guarded build' >&2
    exit 1
fi
[ -s "$fake_descendant_pid" ]
descendant_pid="$(sed -n '1p' "$fake_descendant_pid")"
if kill -0 "$descendant_pid" 2>/dev/null; then
    printf '%s\n' 'Hvigor descendant survived process-group cleanup' >&2
    exit 1
fi
[ ! -e "$cache_root/build.lock" ]
[ -e "$cache_root/last-build.incomplete" ]
run_guard 0 assembleHap --no-daemon
[ ! -e "$cache_root/last-build.incomplete" ]

rm -f "$fake_child_pid" "$fake_signal_seen"
REMOTE_DESKTOP_PROJECT_ROOT="$project_root" \
REMOTE_DESKTOP_BUILD_CACHE_ROOT="$cache_root" \
REMOTE_DESKTOP_REAL_HVIGORW="$fake_hvigor" \
REMOTE_DESKTOP_FAKE_HVIGOR_LOG="$fake_log" \
REMOTE_DESKTOP_FAKE_HVIGOR_HOLD=1 \
REMOTE_DESKTOP_FAKE_HVIGOR_CHILD_PID="$fake_child_pid" \
REMOTE_DESKTOP_FAKE_HVIGOR_SIGNAL_SEEN="$fake_signal_seen" \
REMOTE_DESKTOP_FAKE_HVIGOR_STATUS=0 \
    "$guard" assembleHap --no-daemon &
killed_guard_pid=$!
wait_checks=0
while [ ! -s "$fake_child_pid" ] && [ "$wait_checks" -lt 100 ]; do
    sleep 0.05
    wait_checks=$((wait_checks + 1))
done
[ -s "$fake_child_pid" ]
killed_child_pgid="$(sed -n '1p' "$fake_child_pid")"
kill -KILL "$killed_guard_pid"
if wait "$killed_guard_pid"; then
    printf '%s\n' 'expected SIGKILL guard to fail' >&2
    exit 1
fi
if run_guard 0 assembleHap --no-daemon; then
    printf '%s\n' 'expected live orphan process group to retain build lock' >&2
    exit 1
else
    locked_status=$?
fi
[ "$locked_status" -eq 75 ]
kill -KILL -- "-$killed_child_pgid" 2>/dev/null || true
wait_checks=0
while kill -0 -- "-$killed_child_pgid" 2>/dev/null && [ "$wait_checks" -lt 100 ]; do
    sleep 0.05
    wait_checks=$((wait_checks + 1))
done
if kill -0 -- "-$killed_child_pgid" 2>/dev/null; then
    printf '%s\n' 'unable to stop orphan test process group' >&2
    exit 1
fi
run_guard 0 assembleHap --no-daemon
[ ! -e "$cache_root/last-build.incomplete" ]

printf '%s\n' 'macos_hvigor_guard: PASS'
