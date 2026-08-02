#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(process.env.CODEX_STATE_ROOT || path.join(scriptDir, ".."));
const statePath = path.join(root, "docs", "codex", "STATE.json");
const receiptPath = path.join(root, "docs", "codex", "REVIEW_RECEIPTS.jsonl");

function fail(message) {
  process.stderr.write(`codex_state: ${message}\n`);
  process.exitCode = 1;
}

function git(args, allowFailure = false) {
  try {
    return execFileSync("git", ["-C", root, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", allowFailure ? "pipe" : "inherit"]
    }).trimEnd();
  } catch (error) {
    if (allowFailure) {
      return "";
    }
    const detail = error?.stderr?.toString().trim() || error?.message || "unknown git error";
    throw new Error(`git ${args.join(" ")} failed: ${detail}`);
  }
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`cannot read ${path.relative(root, filePath)}: ${error.message}`);
  }
}

function state() {
  return readJson(statePath);
}

function receipts() {
  if (!fs.existsSync(receiptPath)) {
    return [];
  }
  return fs.readFileSync(receiptPath, "utf8")
    .split(/\r?\n/)
    .map((line, index) => ({ line, index: index + 1 }))
    .filter((item) => item.line.trim().length > 0)
    .map((item) => {
      try {
        return { ...JSON.parse(item.line), line: item.index };
      } catch (error) {
        throw new Error(`invalid review receipt at line ${item.index}: ${error.message}`);
      }
    });
}

function sha256(value) {
  return `sha256:${crypto.createHash("sha256").update(value).digest("hex")}`;
}

function planPaths(currentState) {
  if (Array.isArray(currentState.planPaths)) {
    return currentState.planPaths;
  }
  if (typeof currentState.planPath === "string" && currentState.planPath.length > 0) {
    return [currentState.planPath];
  }
  return [];
}

function scopePaths(currentState) {
  const configured = currentState.review?.scope;
  return Array.isArray(configured) ? configured.filter((value) => typeof value === "string" && value.length > 0) : [];
}

function scopeTreeHash(currentState) {
  const scope = scopePaths(currentState);
  if (scope.length === 0) {
    return null;
  }
  const listing = git(["ls-tree", "-r", "--full-tree", "HEAD", "--", ...scope]);
  return sha256(`${JSON.stringify(scope)}\n${listing}\n`);
}

function planHash(currentState) {
  const paths = planPaths(currentState);
  if (paths.length === 0) {
    return null;
  }
  const content = paths.map((relativePath) => {
    const absolutePath = path.resolve(root, relativePath);
    if (!absolutePath.startsWith(`${root}${path.sep}`)) {
      throw new Error(`plan path escapes repository: ${relativePath}`);
    }
    if (!fs.existsSync(absolutePath)) {
      return `${relativePath}\n<MISSING>\n`;
    }
    return `${relativePath}\n${fs.readFileSync(absolutePath, "utf8")}\n`;
  }).join("\n");
  return sha256(content);
}

function canonicalRevision(revision) {
  if (typeof revision !== "string" || revision.length === 0) {
    return "";
  }
  return git(["rev-parse", revision], true) || revision;
}

function statusPaths() {
  const raw = git(["status", "--porcelain=v1", "-z"], true);
  return raw.split("\0").filter(Boolean).map((entry) => entry.slice(3));
}

function isInScope(relativePath, scope) {
  return scope.some((scopePath) => {
    const normalized = scopePath.replaceAll("\\", "/").replace(/\/$/, "");
    const candidate = relativePath.replaceAll("\\", "/");
    return candidate === normalized || candidate.startsWith(`${normalized}/`);
  });
}

function currentReview(currentState, includeDelta = true) {
  const task = currentState.task || "unknown";
  const base = canonicalRevision(currentState.base);
  const head = git(["rev-parse", "HEAD"]);
  const scope = scopePaths(currentState);
  const currentScopeHash = scopeTreeHash(currentState);
  const currentPlanHash = planHash(currentState);
  const dirtyScoped = statusPaths().filter((relativePath) => isInScope(relativePath, scope));
  const taskReceipts = receipts().filter((receipt) => receipt.task === task);
  const pass = taskReceipts.find((receipt) =>
    receipt.status === "PASS" &&
    receipt.base === base &&
    receipt.scopeTreeHash === currentScopeHash &&
    receipt.planHash === currentPlanHash
  );
  const blocked = [...taskReceipts].reverse().find((receipt) => receipt.status === "BLOCKED");
  const lines = [];

  lines.push(`review-scope=${scope.length > 0 ? scope.join(",") : "unset"}`);
  lines.push(`review-scope-hash=${currentScopeHash || "unset"}`);
  lines.push(`review-plan-hash=${currentPlanHash || "unset"}`);

  if (dirtyScoped.length > 0) {
    lines.push("review=REVIEW_REQUIRED");
    lines.push("review-reason=uncommitted-scope-changes");
    lines.push(`review-dirty-scope=${dirtyScoped.join(",")}`);
    return lines;
  }

  if (pass) {
    lines.push("review=SKIP_FULL_REVIEW");
    lines.push(`review-receipt=${pass.receiptId || pass.line}`);
    lines.push(`reviewed-head=${pass.reviewedHead || "unknown"}`);
    return lines;
  }

  if (currentState.review?.status === "BLOCKED" || blocked) {
    lines.push("review=RESUME_REVIEW");
    lines.push(`review-task-id=${currentState.review?.taskId || blocked?.reviewTaskId || "unknown"}`);
    lines.push(`review-reason=${currentState.review?.reason || blocked?.reason || "blocked-review"}`);
    return lines;
  }

  lines.push("review=REVIEW_REQUIRED");
  if (scope.length === 0) {
    lines.push("review-reason=review-scope-not-declared");
  } else if (!base) {
    lines.push("review-reason=review-base-not-declared");
  } else if (!currentPlanHash) {
    lines.push("review-reason=plan-path-not-declared");
  } else {
    lines.push("review-reason=no-matching-pass-receipt");
  }

  if (includeDelta) {
    const latestReviewed = [...taskReceipts]
      .reverse()
      .find((receipt) => typeof receipt.reviewedHead === "string" && receipt.reviewedHead.length > 0);
    if (latestReviewed) {
      const delta = git(["diff", "--name-only", `${latestReviewed.reviewedHead}..${head}`, "--", ...scope], true)
        .split(/\r?\n/)
        .filter(Boolean);
      lines.push(`review-delta=${delta.length > 0 ? delta.join(",") : "none"}`);
    }
  }
  return lines;
}

function compactStateLines() {
  const currentPath = path.join(root, "docs", "codex", "CURRENT.md");
  const queuePath = path.join(root, "docs", "codex", "QUEUE.md");
  const currentLines = fs.existsSync(currentPath) ? fs.readFileSync(currentPath, "utf8").split(/\r?\n/).length - 1 : -1;
  const queueLines = fs.existsSync(queuePath) ? fs.readFileSync(queuePath, "utf8").split(/\r?\n/).length - 1 : -1;
  return { currentLines, queueLines };
}

function validateState() {
  const currentState = state();
  const errors = [];
  const limits = compactStateLines();
  if (currentState.schema !== 1) {
    errors.push("STATE.json schema must be 1");
  }
  if (limits.currentLines < 0 || limits.currentLines > 120) {
    errors.push(`CURRENT.md must contain at most 120 lines (found ${limits.currentLines})`);
  }
  if (limits.queueLines < 0 || limits.queueLines > 100) {
    errors.push(`QUEUE.md must contain at most 100 lines (found ${limits.queueLines})`);
  }
  for (const receipt of receipts()) {
    if (receipt.schema !== 1 || typeof receipt.task !== "string" || !["PASS", "BLOCKED"].includes(receipt.status)) {
      errors.push(`invalid receipt schema at line ${receipt.line}`);
    }
  }
  if (errors.length > 0) {
    throw new Error(errors.join("; "));
  }
  return [`state-validation=PASS`, `current-lines=${limits.currentLines}`, `queue-lines=${limits.queueLines}`];
}

function statusLines() {
  const currentState = state();
  const validation = validateState();
  const branch = git(["branch", "--show-current"]);
  const head = git(["rev-parse", "--short=9", "HEAD"]);
  const main = git(["rev-parse", "--short=9", "main"]);
  const originMain = git(["rev-parse", "--short=9", "origin/main"], true) || "unavailable";
  const relative = git(["rev-list", "--left-right", "--count", "main...HEAD"])
    .split(/\s+/)
    .map((value) => Number(value));
  const status = statusPaths();
  const worktrees = git(["worktree", "list", "--porcelain"])
    .split(/\r?\n/)
    .filter((line) => line.startsWith("worktree ")).length;
  const activeBranches = git(["for-each-ref", "--format=%(refname:short)", "refs/heads/codex"])
    .split(/\r?\n/)
    .filter(Boolean)
    .filter((candidate) => Number(git(["rev-list", "--count", `main..${candidate}`])) > 0);
  const stateHead = String(currentState.head || "");
  const stateHeadMatch = stateHead.length === 0 || head.startsWith(stateHead) || git(["rev-parse", "HEAD"]).startsWith(stateHead);
  const stateBranch = String(currentState.branch || "");
  const stateBranchMatch = stateBranch.length === 0 || stateBranch === branch;
  const compact = compactStateLines();

  return [
    `workspace=${root}`,
    `task=${currentState.task || "unset"}`,
    `phase=${currentState.phase || "unset"}`,
    `branch=${branch || "detached"}`,
    `head=${head}`,
    `main=${main}`,
    `origin_main=${originMain}`,
    `relative-to-main=ahead:${relative[1] || 0} behind:${relative[0] || 0}`,
    `changes=${status.length}`,
    `worktrees=${worktrees}`,
    `active-branches=${activeBranches.length > 0 ? activeBranches.join(",") : "none"}`,
    `state-head=${stateHead || "unset"}`,
    `state-head-match=${stateHeadMatch}`,
    `state-branch=${stateBranch || "unset"}`,
    `state-branch-match=${stateBranchMatch}`,
    `state-review=${currentState.review?.status || "unset"}`,
    `current-lines=${compact.currentLines}`,
    `queue-lines=${compact.queueLines}`,
    validation[0],
    ...currentReview(currentState),
    "read=docs/codex/CURRENT.md docs/codex/QUEUE.md",
    "history=docs/codex/archive/2026-08/README.md"
  ];
}

function snapshotLines() {
  const currentState = state();
  return [
    `task=${currentState.task || "unset"}`,
    `base=${currentState.base || "unset"}`,
    `head=${git(["rev-parse", "HEAD"])}`,
    `scopeTreeHash=${scopeTreeHash(currentState) || "unset"}`,
    `planHash=${planHash(currentState) || "unset"}`
  ];
}

try {
  const action = process.argv[2] || "status";
  if (action === "status" || action === "bootstrap") {
    for (const line of statusLines()) {
      process.stdout.write(`${line}\n`);
    }
    if (action === "bootstrap") {
      process.stdout.write("startup=compact\n");
      process.stdout.write("rule=do-not-read-archive-unless-state-links-it\n");
    }
  } else if (action === "review-status") {
    for (const line of currentReview(state())) {
      process.stdout.write(`${line}\n`);
    }
  } else if (action === "snapshot") {
    for (const line of snapshotLines()) {
      process.stdout.write(`${line}\n`);
    }
  } else if (action === "validate") {
    for (const line of validateState()) {
      process.stdout.write(`${line}\n`);
    }
  } else {
    fail(`unknown action '${action}'; use status, bootstrap, review-status, snapshot, or validate`);
  }
} catch (error) {
  fail(error.message || String(error));
}
