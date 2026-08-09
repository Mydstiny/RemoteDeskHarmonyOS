#!/usr/bin/env bash

# Run one exact Hypium outer scope and make the repository's result contract
# authoritative.  aa test itself may return 0 for an invalid class selector;
# this wrapper deliberately treats that output as a failure.

set -u

usage() {
    cat <<'USAGE'
Usage:
  scripts/run_focused_ohos_test.sh --device TARGET --scope OUTER --expected-count N [options]
  scripts/run_focused_ohos_test.sh --input LOG --scope OUTER --expected-count N

Options:
  --device TARGET       HDC target used to run aa test.
  --input LOG            Validate an existing aa/Hypium log instead of running HDC.
  --scope OUTER          Exact expected Hypium outer scope name.
  --expected-count N     Exact expected passing test count; must be positive.
  --log PATH             Save command output at PATH (default: temporary log).
  --bundle NAME          Bundle name (default: com.example.remotedesktop).
  --module NAME          Test module (default: entry_test).
  --runner NAME          Test runner (default: OpenHarmonyTestRunner).
USAGE
}

device=''
input_log=''
scope=''
expected_count=''
log_path=''
bundle='com.example.remotedesktop'
module='entry_test'
runner='OpenHarmonyTestRunner'

while [ "$#" -gt 0 ]; do
    case "$1" in
        --device)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            device="$2"
            shift 2
            ;;
        --input)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            input_log="$2"
            shift 2
            ;;
        --scope)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            scope="$2"
            shift 2
            ;;
        --expected-count)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            expected_count="$2"
            shift 2
            ;;
        --log)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            log_path="$2"
            shift 2
            ;;
        --bundle)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            bundle="$2"
            shift 2
            ;;
        --module)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            module="$2"
            shift 2
            ;;
        --runner)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            runner="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ -z "$scope" ] || [ -z "$expected_count" ]; then
    printf '%s\n' '--scope and --expected-count are required.' >&2
    usage >&2
    exit 64
fi

case "$scope" in
    ''|*[!A-Za-z0-9_.-]*)
        printf 'Invalid scope characters: %s\n' "$scope" >&2
        exit 64
        ;;
esac
case "$expected_count" in
    ''|*[!0-9]*)
        printf 'Expected count must be a positive integer: %s\n' "$expected_count" >&2
        exit 64
        ;;
esac
if [ "$expected_count" -le 0 ]; then
    printf 'Expected count must be positive: %s\n' "$expected_count" >&2
    exit 64
fi

if [ -n "$input_log" ] && [ -n "$device" ]; then
    printf '%s\n' '--input and --device are mutually exclusive.' >&2
    exit 64
fi
if [ -z "$input_log" ] && [ -z "$device" ]; then
    printf '%s\n' 'One of --input or --device is required.' >&2
    exit 64
fi

command_rc=0
if [ -n "$input_log" ]; then
    if [ ! -f "$input_log" ]; then
        printf 'Input log does not exist: %s\n' "$input_log" >&2
        exit 66
    fi
    log_path="$input_log"
else
    if [ -z "${HDC_BIN:-}" ]; then
        HDC_BIN="$(command -v hdc 2>/dev/null || true)"
    fi
    if [ -z "$HDC_BIN" ] || [ ! -x "$HDC_BIN" ]; then
        printf '%s\n' 'hdc is unavailable; source scripts/macos_env.sh or set HDC_BIN.' >&2
        exit 69
    fi
    if [ -z "$log_path" ]; then
        log_path="$(mktemp -t rustdesk-focused-ohos.XXXXXX)"
    fi
    "$HDC_BIN" -t "$device" shell \
        "aa test -b $bundle -m $module -s unittest $runner -s class $scope -w 60000" \
        >"$log_path" 2>&1
    command_rc=$?
fi

result_line="$(grep 'OHOS_REPORT_RESULT:' "$log_path" | tail -1 || true)"
code_line="$(grep 'OHOS_REPORT_CODE:' "$log_path" | tail -1 || true)"
finished_line="$(grep 'TestFinished-ResultCode:' "$log_path" | tail -1 || true)"
result_stats="$(printf '%s\n' "$result_line" | sed -nE \
    's/.*Tests run: ([0-9]+), Failure: ([0-9]+), Error: ([0-9]+), Pass: ([0-9]+), Ignore: ([0-9]+).*/\1 \2 \3 \4 \5/p' | tail -1)"
report_code="$(printf '%s\n' "$code_line" | sed -nE 's/.*OHOS_REPORT_CODE:[[:space:]]*(-?[0-9]+).*/\1/p' | tail -1)"
finished_code="$(printf '%s\n' "$finished_line" | sed -nE 's/.*TestFinished-ResultCode:[[:space:]]*(-?[0-9]+).*/\1/p' | tail -1)"

outer_seen="$(awk -v needle="OHOS_REPORT_STATUS: class=$scope" '
    index($0, needle) == 0 { next }
    { rest = substr($0, index($0, needle) + length(needle)); if (rest ~ /^[[:space:]]*$/) { print "yes"; exit } }
' "$log_path")"

failure_reason=''
set_failure() {
    if [ -z "$failure_reason" ]; then
        failure_reason="$1"
    fi
}
if [ "$command_rc" -ne 0 ]; then
    set_failure "hdc/aa command exit=$command_rc"
fi
if grep -Eiq 'this param class:.*invalid|invalid[[:space:]]+class|class.*invalid' "$log_path"; then
    set_failure 'invalid class selector reported by aa test'
fi
if grep -Eiq 'App died|app died' "$log_path"; then
    set_failure 'test application died'
fi
if [ "$outer_seen" != 'yes' ]; then
    set_failure 'expected exact outer scope was not reported'
fi
if [ -z "$result_stats" ]; then
    set_failure 'OHOS_REPORT_RESULT is missing or unparsable'
fi
if [ -z "$report_code" ]; then
    set_failure 'OHOS_REPORT_CODE is missing or unparsable'
fi
if [ -z "$finished_code" ]; then
    set_failure 'TestFinished-ResultCode is missing or unparsable'
fi

if [ -n "$result_stats" ]; then
    read -r tests_run failures errors passes ignores <<EOF
$result_stats
EOF
    if [ "$tests_run" -eq 0 ] && [ "$failures" -eq 0 ] && [ "$errors" -eq 0 ] && [ "$passes" -eq 0 ]; then
        set_failure 'zero-test result (0/0) is never a pass'
    elif [ "$tests_run" -ne "$expected_count" ] || [ "$passes" -ne "$expected_count" ] || \
         [ "$failures" -ne 0 ] || [ "$errors" -ne 0 ] || [ "$ignores" -ne 0 ]; then
        set_failure "result count mismatch: run=$tests_run pass=$passes fail=$failures error=$errors ignore=$ignores expected=$expected_count"
    fi
else
    tests_run='-'
    failures='-'
    errors='-'
    passes='-'
    ignores='-'
fi

if [ "$report_code" != '0' ]; then
    set_failure "OHOS_REPORT_CODE=$report_code"
fi
if [ "$finished_code" != '0' ]; then
    set_failure "TestFinished-ResultCode=$finished_code"
fi

printf 'focused_wrapper scope=%s expected=%s run=%s pass=%s fail=%s error=%s ignore=%s report_code=%s finished_code=%s log=%s\n' \
    "$scope" "$expected_count" "$tests_run" "$passes" "$failures" "$errors" "$ignores" \
    "${report_code:--}" "${finished_code:--}" "$log_path"

if [ -n "$failure_reason" ]; then
    printf 'focused_wrapper FAIL: %s\n' "$failure_reason" >&2
    exit 1
fi

printf '%s\n' 'focused_wrapper PASS'
exit 0
