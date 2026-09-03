#!/usr/bin/env bash

set -u
umask 077

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_root="${REMOTE_DESKTOP_PROJECT_ROOT:-$(CDPATH= cd -- "$script_dir/.." && pwd)}"
real_hvigorw="${REMOTE_DESKTOP_REAL_HVIGORW:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"

if [ ! -x "$real_hvigorw" ]; then
    printf 'RemoteDesk Hvigor guard: executable not found: %s\n' "$real_hvigorw" >&2
    exit 127
fi

# The project is pinned for offline availability, so normal DevEco and shell
# builds must use its native .hvigor, entry/.cxx, entry/build, and build paths.
# External-cache isolation remains available only as an explicit opt-in for a
# workspace that is still managed by a File Provider.
if [ -z "${REMOTE_DESKTOP_BUILD_CACHE_ROOT:-}" ]; then
    exec "$real_hvigorw" "$@"
fi

local_root="$REMOTE_DESKTOP_BUILD_CACHE_ROOT"

case "$local_root" in
    /*) ;;
    *)
        printf 'RemoteDesk Hvigor guard: cache root must be absolute: %s\n' "$local_root" >&2
        exit 2
        ;;
esac
if [ "$local_root" = "/" ] || [ "$local_root" = "$project_root" ]; then
    printf 'RemoteDesk Hvigor guard: refusing unsafe cache root: %s\n' "$local_root" >&2
    exit 2
fi
if [ -L "$local_root" ]; then
    printf 'RemoteDesk Hvigor guard: refusing symlink cache root: %s\n' "$local_root" >&2
    exit 2
fi

mkdir -p "$local_root" "$local_root/quarantine" || exit 1
local_owner="$(stat -f '%u' "$local_root" 2>/dev/null || true)"
if [ "$local_owner" != "$(id -u)" ]; then
    printf 'RemoteDesk Hvigor guard: cache root is not owned by current user: %s\n' \
        "$local_root" >&2
    exit 2
fi
chmod 700 "$local_root" "$local_root/quarantine" || exit 1
official_build_cache="$local_root/build-cache"
official_project_cache="$official_build_cache/$(basename -- "$project_root")"
mkdir -p "$official_build_cache" "$official_project_cache"

# Keep abandoned generated directories on the project volume. Moving a
# dataless File Provider tree into /private/tmp forces macOS to download every
# file before the cross-volume move can finish, which makes a build look hung.
# A same-volume rename is atomic and does not read the evicted contents.
project_quarantine_root="$project_root/.remotedesk-build-quarantine"
mkdir -p "$project_quarantine_root"
chmod 700 "$project_quarantine_root" || exit 1

quarantine_local_path() {
    source_path="$1"
    label="$2"
    stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    destination="$local_root/quarantine/$label-$stamp"
    mv "$source_path" "$destination"
    printf 'RemoteDesk Hvigor guard: moved cloud-managed %s to %s\n' \
        "$source_path" "$destination"
}

quarantine_generated_path() {
    source_path="$1"
    label="$2"
    stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    destination="$project_quarantine_root/$label-$stamp"
    mv "$source_path" "$destination"
    printf 'RemoteDesk Hvigor guard: isolated cloud-managed %s at %s\n' \
        "$source_path" "$destination"
}

prepare_local_link() {
    link_path="$1"
    target_path="$2"
    label="$3"
    mkdir -p "$(dirname -- "$link_path")" "$(dirname -- "$target_path")"
    if [ -L "$link_path" ]; then
        current_target="$(readlink "$link_path")"
        if [ "$current_target" != "$target_path" ]; then
            printf 'RemoteDesk Hvigor guard: refusing foreign symlink %s -> %s\n' \
                "$link_path" "$current_target" >&2
            return 1
        fi
        mkdir -p "$target_path"
        return 0
    fi
    if [ -e "$link_path" ]; then
        quarantine_generated_path "$link_path" "$label"
    fi
    mkdir -p "$target_path"
    ln -s "$target_path" "$link_path"
    if [ ! -L "$link_path" ] || [ "$(readlink "$link_path")" != "$target_path" ]; then
        printf 'RemoteDesk Hvigor guard: failed to install build symlink %s -> %s\n' \
            "$link_path" "$target_path" >&2
        return 1
    fi
}

upgrade_managed_link() {
    generated_path="$1"
    legacy_target="$2"
    if [ -L "$generated_path" ]; then
        current_target="$(readlink "$generated_path")"
        if [ "$current_target" = "$legacy_target" ]; then
            rm -f "$generated_path"
        fi
    fi
}

prepare_build_layout() {
    # Hvigor/ArkTS requires buildDir to be configured through its own model;
    # replacing entry/build with a symlink alone leaves ResourceTable.ts outside
    # the compiler's module context. build-cache-dir moves both .hvigor and
    # module outputs through the supported path model. The matching symlinks are
    # retained only as stable conventional paths for DevEco reports and tooling.
    upgrade_managed_link "$project_root/.hvigor" "$local_root/hvigor"
    upgrade_managed_link "$project_root/entry/build" "$local_root/entry-build"
    prepare_local_link "$project_root/.hvigor" "$official_project_cache/.hvigor" "hvigor" || return 1
    prepare_local_link "$project_root/entry/build" "$official_project_cache/entry/build" "entry-build" || return 1
    prepare_local_link "$project_root/entry/.cxx" "$local_root/entry-cxx" "entry-cxx" || return 1
}

publish_conventional_entry_outputs() {
    # Hvigor may replace entry/build with a real directory even when its
    # supported build-cache-dir is active. Keep compilation caches off the
    # cloud-managed project volume, but publish the final output tree back to
    # the conventional DevEco location so IDE actions and release tooling can
    # always find entry/build/default/outputs after a successful package task.
    output_source=""
    project_output_root="$project_root/entry/build/default/outputs"
    cached_output_root="$official_project_cache/entry/build/default/outputs"
    if [ -d "$project_output_root" ]; then
        output_source="$project_output_root"
    elif [ -d "$cached_output_root" ]; then
        output_source="$cached_output_root"
    fi

    publish_stage=""
    if [ -n "$output_source" ]; then
        publish_stage="$(mktemp -d "$local_root/published-entry-build.XXXXXX")" || return 1
        mkdir -p "$publish_stage/default/outputs" || return 1
        if ! cp -R "$output_source/." "$publish_stage/default/outputs/"; then
            quarantine_local_path "$publish_stage" "failed-output-publication" || true
            return 1
        fi
    fi

    prepare_build_layout || return 1
    if [ -z "$publish_stage" ]; then
        return 0
    fi

    if [ ! -L "$project_root/entry/build" ]; then
        printf 'RemoteDesk Hvigor guard: expected managed entry/build link before publication\n' >&2
        quarantine_local_path "$publish_stage" "failed-output-publication" || true
        return 1
    fi
    rm -f "$project_root/entry/build" || return 1
    if ! mv "$publish_stage" "$project_root/entry/build"; then
        prepare_build_layout || true
        return 1
    fi
    printf 'RemoteDesk Hvigor guard: published build outputs at %s\n' \
        "$project_root/entry/build/default/outputs"
}

materialize_project_inputs() {
    dataless_list="$(mktemp "$local_root/dataless-inputs.XXXXXX")" || return 1
    find_error="$(mktemp "$local_root/dataless-find-errors.XXXXXX")" || {
        rm -f "$dataless_list"
        return 1
    }
    find_bin="${REMOTE_DESKTOP_FIND_BIN:-/usr/bin/find}"
    "$find_bin" "$project_root" -xdev \
        \( -path "$project_root/.git" -o -path "$project_root/.hvigor" -o \
           -path "$project_root/entry/build" -o -path "$project_root/entry/.cxx" -o \
           -path "$project_quarantine_root" \) -prune -o \
        -type f -flags +dataless -print0 > "$dataless_list" 2> "$find_error"
    find_status=$?
    if [ "$find_status" -ne 0 ]; then
        printf 'RemoteDesk Hvigor guard: unable to enumerate cloud-evicted inputs (status=%s)\n' \
            "$find_status" >&2
        sed -n '1,40p' "$find_error" >&2
        rm -f "$dataless_list" "$find_error"
        return 1
    fi
    rm -f "$find_error"
    if [ -s "$dataless_list" ]; then
        input_count="$(tr -cd '\000' < "$dataless_list" | wc -c | tr -d ' ')"
        printf 'RemoteDesk Hvigor guard: materializing %s cloud-evicted build inputs\n' \
            "$input_count"
        if ! xargs -0 -n 1 -P 8 shasum < "$dataless_list" >/dev/null; then
            rm -f "$dataless_list"
            printf 'RemoteDesk Hvigor guard: failed to materialize all build inputs\n' >&2
            return 1
        fi
    fi
    rm -f "$dataless_list"
}

lock_dir="$local_root/build.lock"

valid_process_id() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 1 ] ;;
    esac
}

valid_counter() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

process_target_alive_or_inaccessible() {
    process_target="$1"
    process_probe_message="$(kill -0 -- "$process_target" 2>&1)"
    process_probe_status=$?
    if [ "$process_probe_status" -eq 0 ]; then
        return 0
    fi
    # Codex and other macOS sandboxes can return EPERM while the process is
    # alive. Treat an inaccessible owner as live; stealing that lock would let
    # a clean/build invocation delete another Hvigor process's inputs.
    case "$process_probe_message" in
        *'Operation not permitted'*|*'operation not permitted'*|\
        *'Permission denied'*|*'permission denied'*) return 0 ;;
    esac
    return 1
}

process_group_alive() {
    group_id="${1:-}"
    valid_process_id "$group_id" || return 1
    process_target_alive_or_inaccessible "-$group_id"
}

lock_has_live_owner() {
    recorded_wrapper="$(sed -n '1p' "$lock_dir/wrapper.pid" 2>/dev/null || true)"
    recorded_group="$(sed -n '1p' "$lock_dir/child.pgid" 2>/dev/null || true)"
    if valid_process_id "$recorded_wrapper" &&
       process_target_alive_or_inaccessible "$recorded_wrapper"; then
        return 0
    fi
    if valid_process_id "$recorded_group" && {
        process_target_alive_or_inaccessible "$recorded_group" ||
        process_group_alive "$recorded_group"
    }; then
        return 0
    fi
    return 1
}

write_lock_value() {
    destination_path="$1"
    value="$2"
    temporary_path="$destination_path.tmp.$$"
    printf '%s\n' "$value" > "$temporary_path" || return 1
    mv "$temporary_path" "$destination_path"
}

if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ -e "$lock_dir/spawn.pending" ]; then
        pending_checks=0
        while ! lock_has_live_owner && [ "$pending_checks" -lt 50 ]; do
            sleep 0.1
            pending_checks=$((pending_checks + 1))
        done
    fi
    if lock_has_live_owner; then
        owner_pid="$(sed -n '1p' "$lock_dir/wrapper.pid" 2>/dev/null || true)"
        owner_pgid="$(sed -n '1p' "$lock_dir/child.pgid" 2>/dev/null || true)"
        printf 'RemoteDesk Hvigor guard: another build is active (wrapper=%s pgid=%s)\n' \
            "${owner_pid:-unknown}" "${owner_pgid:-pending}" >&2
        exit 75
    fi
    quarantine_local_path "$lock_dir" "stale-build-lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        printf 'RemoteDesk Hvigor guard: unable to acquire build lock\n' >&2
        exit 75
    fi
fi
write_lock_value "$lock_dir/wrapper.pid" "$$" || exit 1
rm -f "$lock_dir/child.pgid" "$lock_dir/spawn.pending"
lock_release_allowed=1

release_lock() {
    if [ "$lock_release_allowed" -eq 1 ]; then
        rm -f "$lock_dir/wrapper.pid" "$lock_dir/child.pgid" "$lock_dir/spawn.pending"
        rmdir "$lock_dir" 2>/dev/null || true
    else
        printf 'RemoteDesk Hvigor guard: retaining build lock for live child process group\n' >&2
    fi
}
trap release_lock EXIT
active_child_pid=""
group_grace_checks="${REMOTE_DESKTOP_GROUP_GRACE_CHECKS:-50}"
group_kill_checks="${REMOTE_DESKTOP_GROUP_KILL_CHECKS:-20}"
if ! valid_counter "$group_grace_checks" || ! valid_counter "$group_kill_checks"; then
    printf 'RemoteDesk Hvigor guard: invalid process-group wait configuration\n' >&2
    exit 2
fi

wait_for_process_group_exit() {
    group_id="$1"
    maximum_checks="$2"
    group_checks=0
    while process_group_alive "$group_id" && [ "$group_checks" -lt "$maximum_checks" ]; do
        sleep 0.1
        group_checks=$((group_checks + 1))
    done
    ! process_group_alive "$group_id"
}

terminate_process_group() {
    group_id="$1"
    signal_name="$2"
    if process_group_alive "$group_id"; then
        kill -s "$signal_name" -- "-$group_id" 2>/dev/null || true
    elif process_target_alive_or_inaccessible "$group_id"; then
        kill -s "$signal_name" "$group_id" 2>/dev/null || true
    fi
    if ! wait_for_process_group_exit "$group_id" "$group_grace_checks"; then
        kill -KILL -- "-$group_id" 2>/dev/null || kill -KILL "$group_id" 2>/dev/null || true
        wait_for_process_group_exit "$group_id" "$group_kill_checks" || return 1
    fi
}

stop_active_child() {
    signal_name="$1"
    exit_status="$2"
    child_pid="$active_child_pid"
    if valid_process_id "$child_pid"; then
        terminate_process_group "$child_pid" "$signal_name" || true
        wait "$child_pid" 2>/dev/null || true
        if process_group_alive "$child_pid"; then
            terminate_process_group "$child_pid" KILL || true
        fi
        if process_group_alive "$child_pid"; then
            lock_release_allowed=0
        else
            lock_release_allowed=1
        fi
    fi
    active_child_pid=""
    exit "$exit_status"
}

run_hvigor() {
    : > "$lock_dir/spawn.pending" || return 1
    lock_release_allowed=0
    perl -MPOSIX -e \
        'my $meta = shift @ARGV; my $capture = shift @ARGV; my $session = POSIX::setsid(); defined($session) or die "setsid failed: $!\n"; my $tmp = "$meta.$$"; open(my $fh, ">", $tmp) or die "open $tmp failed: $!\n"; print {$fh} "$$\n"; close($fh) or die "close $tmp failed: $!\n"; rename($tmp, $meta) or die "rename $tmp failed: $!\n"; $ENV{REMOTE_DESKTOP_HVIGOR_PROCESS_GROUP} = $$; if (length($capture)) { open(my $log, ">", $capture) or die "open capture failed: $!\n"; open(STDOUT, ">&", $log) or die "redirect stdout failed: $!\n"; open(STDERR, ">&", $log) or die "redirect stderr failed: $!\n"; } exec @ARGV; die "exec failed: $!\n";' \
        -- "$lock_dir/child.pgid" "${build_capture_log:-}" \
        "$real_hvigorw" "$@" &
    active_child_pid=$!
    write_lock_value "$lock_dir/child.pgid" "$active_child_pid" || {
        terminate_process_group "$active_child_pid" TERM || true
        wait "$active_child_pid" 2>/dev/null || true
        return 1
    }
    rm -f "$lock_dir/spawn.pending"
    if wait "$active_child_pid"; then
        child_status=0
    else
        child_status=$?
    fi
    orphaned_group=0
    if ! wait_for_process_group_exit "$active_child_pid" "$group_grace_checks"; then
        orphaned_group=1
        terminate_process_group "$active_child_pid" TERM || true
    fi
    if process_group_alive "$active_child_pid"; then
        lock_release_allowed=0
    else
        lock_release_allowed=1
        rm -f "$lock_dir/child.pgid"
    fi
    active_child_pid=""
    if [ "$orphaned_group" -ne 0 ]; then
        printf 'RemoteDesk Hvigor guard: Hvigor exited with live descendant processes\n' >&2
        return 75
    fi
    return "$child_status"
}

trap 'stop_active_child HUP 129' HUP
trap 'stop_active_child INT 130' INT
trap 'stop_active_child TERM 143' TERM

if ! prepare_build_layout || ! materialize_project_inputs || ! prepare_build_layout; then
    exit 1
fi

generated_cache_failure() {
    capture_path="$1"
    if grep -F 'ArkTS: INTERNAL ERROR' "$capture_path" >/dev/null 2>&1 &&
       grep -F 'Failed to find module info' "$capture_path" >/dev/null 2>&1 &&
       grep -F 'ResourceTable.ts' "$capture_path" >/dev/null 2>&1 && {
           grep -F "$project_root/entry/build" "$capture_path" >/dev/null 2>&1 ||
           grep -F "$official_project_cache/entry/build" "$capture_path" >/dev/null 2>&1
       }; then
        return 0
    fi
    if grep -F 'Failed to read file to buffer' "$capture_path" >/dev/null 2>&1 &&
       grep -F "$official_build_cache" "$capture_path" >/dev/null 2>&1; then
        return 0
    fi
    if grep -F 'Failed to find the incremental input file:' "$capture_path" >/dev/null 2>&1 &&
       grep -F "$official_build_cache" "$capture_path" >/dev/null 2>&1; then
        return 0
    fi
    if grep -F -- '--pack-info-path is not a file' "$capture_path" >/dev/null 2>&1; then
        return 0
    fi
    if grep -F 'CMakeDetermineCXXCompiler.cmake' "$capture_path" >/dev/null 2>&1 &&
       grep -F 'No such file or directory' "$capture_path" >/dev/null 2>&1 &&
       grep -F "$project_root/entry/.cxx" "$capture_path" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

reset_generated_caches() {
    reset_stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    if [ -d "$official_project_cache" ] && [ ! -L "$official_project_cache" ]; then
        mv "$official_project_cache" \
            "$local_root/quarantine/generated-build-cache-$reset_stamp" || return 1
    fi
    if [ -d "$local_root/entry-cxx" ] && [ ! -L "$local_root/entry-cxx" ]; then
        mv "$local_root/entry-cxx" \
            "$local_root/quarantine/generated-native-cache-$reset_stamp" || return 1
    fi
    mkdir -p "$official_project_cache" || return 1
    prepare_build_layout || return 1
    materialize_project_inputs || return 1
    prepare_build_layout
}

incomplete_marker="$local_root/last-build.incomplete"
requested_clean=0
for argument in "$@"; do
    case "$argument" in
        clean|*:clean|*@clean) requested_clean=1 ;;
    esac
done

if [ -f "$incomplete_marker" ] && [ "$requested_clean" -eq 0 ]; then
    printf 'RemoteDesk Hvigor guard: previous build was incomplete; isolating generated caches\n'
    if ! reset_generated_caches; then
        printf 'RemoteDesk Hvigor guard: generated cache isolation failed\n' >&2
        exit 1
    fi
    rm -f "$incomplete_marker"
fi

printf 'pid=%s\nstarted=%s\n' "$$" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$incomplete_marker"
build_capture_log="$(mktemp "$local_root/hvigor-output.XXXXXX")" || exit 1
if run_hvigor "$@" -p "build-cache-dir=$official_build_cache"; then
    build_status=0
else
    build_status=$?
fi
if [ -s "$build_capture_log" ]; then
    cat "$build_capture_log"
fi

# Hvigor can retain incremental declarations for generated inputs that another
# interrupted or legacy build no longer contains. Recover only from the exact
# generated-cache signatures above. The cache is moved aside (not deleted), a
# fresh supported build-cache layout is installed, and the original invocation
# is retried once. Source/type errors are never retried.
if [ "$build_status" -ne 0 ] && [ "$requested_clean" -eq 0 ] &&
   generated_cache_failure "$build_capture_log"; then
    printf 'RemoteDesk Hvigor guard: generated cache is inconsistent; isolating it and retrying once\n'
    if reset_generated_caches; then
        : > "$build_capture_log"
        if run_hvigor "$@" -p "build-cache-dir=$official_build_cache"; then
            build_status=0
        else
            build_status=$?
        fi
        if [ -s "$build_capture_log" ]; then
            cat "$build_capture_log"
        fi
    fi
fi
rm -f "$build_capture_log"
build_capture_log=""
if [ "$build_status" -eq 0 ]; then
    rm -f "$incomplete_marker"
    printf 'RemoteDesk Hvigor guard: build outputs at %s\n' "$official_build_cache"
    if ! publish_conventional_entry_outputs; then
        printf 'RemoteDesk Hvigor guard: failed to publish conventional build outputs\n' >&2
        build_status=1
        prepare_build_layout || true
    fi
else
    prepare_build_layout || build_status=1
fi
exit "$build_status"
