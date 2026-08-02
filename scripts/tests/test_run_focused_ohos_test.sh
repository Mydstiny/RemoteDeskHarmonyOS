#!/usr/bin/env bash

set -u

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
wrapper="$repo_root/scripts/run_focused_ohos_test.sh"
fixtures="$script_dir/fixtures"
failures=0

expect_pass() {
    if "$@" >/tmp/rustdesk-focused-wrapper-test.out 2>&1; then
        return 0
    fi
    cat /tmp/rustdesk-focused-wrapper-test.out >&2
    printf 'unexpected wrapper failure: %s\n' "$*" >&2
    failures=$((failures + 1))
}

expect_fail() {
    if "$@" >/tmp/rustdesk-focused-wrapper-test.out 2>&1; then
        cat /tmp/rustdesk-focused-wrapper-test.out >&2
        printf 'unexpected wrapper pass: %s\n' "$*" >&2
        failures=$((failures + 1))
    fi
}

expect_pass "$wrapper" --input "$fixtures/focused_pass.log" \
    --scope RemoteOverlayViewportPolicy_contract --expected-count 7
expect_fail "$wrapper" --input "$fixtures/focused_fail.log" \
    --scope RustDeskProAddressBookPolicy --expected-count 8
expect_fail "$wrapper" --input "$fixtures/focused_invalid.log" \
    --scope totally-random-scope --expected-count 1
expect_fail "$wrapper" --input "$fixtures/focused_zero.log" \
    --scope RemoteOverlayViewportPolicy_contract --expected-count 7
expect_fail "$wrapper" --input "$fixtures/focused_app_died.log" \
    --scope NativeCallbackEntryIntegration --expected-count 1

if [ -n "${FOCUSED_DEVICE:-}" ]; then
    expect_fail "$wrapper" --device "$FOCUSED_DEVICE" \
        --scope totally-random-scope --expected-count 1 \
        --log /tmp/rustdesk-focused-wrapper-real-invalid.log
    expect_pass "$wrapper" --device "$FOCUSED_DEVICE" \
        --scope RemoteOverlayViewportPolicy_contract --expected-count 7 \
        --log /tmp/rustdesk-focused-wrapper-real-pass.log
else
    printf '%s\n' 'real device checks skipped: set FOCUSED_DEVICE=<hdc-target>'
fi

if [ "$failures" -ne 0 ]; then
    printf 'focused wrapper fixture failures=%s\n' "$failures" >&2
    exit 1
fi

printf '%s\n' 'focused wrapper fixture checks passed'
