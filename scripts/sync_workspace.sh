#!/usr/bin/env sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
action="${1:-status}"
. "$root/scripts/resolve_powershell.sh"

git_at() {
  git -C "$root" "$@"
}

fail() {
  printf '%s\n' "sync_workspace: $*" >&2
  exit 1
}

require_clean_main() {
  branch="$(git_at branch --show-current)"
  [ "$branch" = "main" ] || fail "sync must start from main; current branch is '$branch'"
  [ -z "$(git_at status --porcelain)" ] || fail 'local changes exist; commit them on the task branch or move them aside intentionally before syncing'
}

sync_public_main() {
  require_clean_main
  git_at fetch --prune origin
  if [ "$(git_at rev-parse main)" != "$(git_at rev-parse origin/main)" ]; then
    git_at pull --ff-only origin main
  fi
  git_at submodule update --init --recursive
  printf 'Synchronized main with origin/main at %s.\n' "$(git_at rev-parse --short=9 main)"
  if [ -f "$root/docs/codex/CURRENT.md" ]; then
    printf '%s\n' 'Shared state: docs/codex/CURRENT.md' 'Shared queue: docs/codex/QUEUE.md'
  fi
}

active_branches() {
  git_at for-each-ref --format='%(refname:short)' refs/heads/codex |
    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      if [ "$(git_at rev-list --count "main..$branch")" -gt 0 ]; then
        printf '%s\n' "$branch"
      fi
    done
}

require_pwsh() {
  if powershell_cmd="$(resolve_powershell_command 2>/dev/null)"; then
    printf '%s\n' "$powershell_cmd"
  else
    fail 'PowerShell 7 (pwsh) is required for the open-source compliance gate; install it before finish-check or push'
  fi
}

case "$action" in
  status)
    printf '%s\n' "workspace=$root" "branch=$(git_at branch --show-current)" "head=$(git_at rev-parse --short=9 HEAD)" "main=$(git_at rev-parse --short=9 main)" "origin_main=$(git_at rev-parse --short=9 origin/main)"
    printf '%s\n' "changes=$(git_at status --porcelain | wc -l | tr -d ' ')" "worktrees=$(git_at worktree list --porcelain | awk '/^worktree / { count++ } END { print count + 0 }')"
    active="$(active_branches || true)"
    [ -n "$active" ] && printf 'active-branches=%s\n' "$(printf '%s' "$active" | tr '\n' ',')" || printf '%s\n' 'active-branches=none'
    ;;
  sync)
    sync_public_main
    ;;
  start)
    task="${2:-}"
    case "$task" in
      ''|*[!a-z0-9-]*) fail 'task must be lowercase kebab-case' ;;
    esac
    [ "${#task}" -ge 3 ] && [ "${#task}" -le 61 ] || fail 'task must be between 3 and 61 characters'
    sync_public_main
    active="$(active_branches || true)"
    [ -z "$active" ] || fail "unfinished task branches exist: $(printf '%s' "$active" | tr '\n' ' ')"
    git_at switch -c "codex/$task"
    printf 'Started codex/%s. Update docs/codex/CURRENT.md before implementation.\n' "$task"
    ;;
  doctor)
    errors=0
    [ "$(git_at config --get core.hooksPath || true)" = '.githooks' ] || { printf '%s\n' 'ERROR: core.hooksPath must be .githooks' >&2; errors=1; }
    [ "$(git_at rev-parse main)" = "$(git_at rev-parse origin/main)" ] || { printf '%s\n' 'ERROR: main does not match origin/main' >&2; errors=1; }
    worktrees="$(git_at worktree list --porcelain | awk '/^worktree / { count++ } END { print count + 0 }')"
    [ "$worktrees" -eq 1 ] || { printf '%s\n' "ERROR: expected one persistent worktree, found $worktrees" >&2; errors=1; }
    active="$(active_branches || true)"
    [ -z "$active" ] || { printf '%s\n' "ERROR: unfinished task branches exist: $active" >&2; errors=1; }
    [ "$errors" -eq 0 ] || exit 1
    printf '%s\n' 'Workflow doctor passed.'
    ;;
  finish-check)
    branch="$(git_at branch --show-current)"
    [ "$branch" != 'main' ] && [ -n "$branch" ] || fail 'no feature branch is active'
    [ -z "$(git_at status --porcelain)" ] || fail 'commit or intentionally move working-tree changes before finishing'
    git_at merge-base --is-ancestor main HEAD || fail 'feature branch is not based on main'
    git_at rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 || fail 'feature branch has no upstream; push it before finishing'
    pwsh_cmd="$(require_pwsh)"
    "$pwsh_cmd" -NoProfile -File "$root/scripts/verify_open_source_release.ps1" -Mode Light -RepositoryRoot "$root"
    printf 'Finish check passed for %s -> main.\n' "$branch"
    ;;
  *)
    fail "unknown action '$action'; use status, sync, start <task>, doctor, or finish-check"
    ;;
esac
