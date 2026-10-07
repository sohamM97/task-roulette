---
name: merge-check
description: Check CI & reviews, then merge PR. Use when the user wants to merge a PR.
---

# Merge Pull Request

Merge the current branch's PR after verifying CI and review comments.

**Arguments:** `$ARGUMENTS` (optional: PR number. If not provided, detect from current branch.)

## Workflow

### Phase 1: Checks (run in background)

1. Identify the PR — use `$ARGUMENTS` if provided, otherwise run `gh pr view --json number` from the current branch.
1a. **Check whether the Claude review workflow is even enabled** before relying on it. Run `gh workflow list --all | grep -i claude`. If `Claude Code Review` shows `disabled_manually` (or the `claude-review` check never appears in `gh pr checks` for this PR), then the **Claude** AI review is **OFF**: do NOT wait for a `claude-review` check. Report clearly that "Claude AI review is disabled — this PR will not get a Claude review" so the user can decide whether that's acceptable.
    - **CRITICAL — read Codex's verdict from its summary comment, not from silence.** Codex (`chatgpt-codex-connector[bot]`) keeps one **"Codex Review Summary"** comment on the PR, in `issues/{number}/comments`, whose body starts with `<!-- codex-pull-request-review-summary -->`. Codex edits it in place each time it reviews, so check its `updated_at`. It holds a table row with the review **Status** (`Running` or `Completed`) and the **Commit** short SHA reviewed. Codex also reacts on the PR itself (`gh api repos/{owner}/{repo}/issues/{number}/reactions`): 👀 while a review runs, 👍 once every review finished with no findings. Seen on PR #84 (2026-10-06). Read the verdict like this:
      - **Clean:** the summary shows **Completed** for the PR's **current head commit** (compare it with `gh pr view {number} --json headRefOid`), there are no Codex inline comments or review bodies, and there's a 👍 reaction. Report it as "Codex reviewed `<sha>` with no findings". That is a real review, so it counts as a clean review result in Phase 2.
      - **Findings:** Codex posts inline comments in `pulls/{number}/comments` and/or review bodies in `pulls/{number}/reviews`. Address them per the rules below.
      - **Still running:** the summary shows **Running**, or the 👀 reaction is there with no 👍 yet. Keep polling. Don't report a verdict.
      - **Stale:** the summary's Commit is an **older** commit than the head (a fix was pushed after the last review). Treat the head as not yet reviewed and keep polling for the new round.
      - **Over its usage limit:** a plain comment from `chatgpt-codex-connector[bot]` in `issues/{number}/comments` that starts "You have reached your Codex usage limits for code reviews". It has no summary marker, no table and no reaction, and Codex posts nothing else for that push. Stop polling as soon as it appears and report "Codex is over its usage limit and did not review this PR". Seen on PR #87 (2026-10-07).
      - **No summary comment at all** after the ~5-minute poll: Codex never ran, is still starting, or the comment format changed. This case is still ambiguous, so **ASK THE USER to check Codex Cloud** at **chatgpt.com/codex/cloud** (note the `/cloud` suffix). Never present a missing summary as either "clean" or "never reviewed". On PR #80, empty endpoints were wrongly reported as "no automated review at all".
      - Check-runs and commit statuses carry no Codex entry, so there is no check to wait on.
    - **CRITICAL: Claude being disabled does NOT mean skip the Review comments agent.** `codex` (chatgpt-codex-connector[bot]) is an **independent** reviewer that posts comments **asynchronously without a `gh pr checks` entry** — so "check for it if its check is present" is not enough; there is no check to wait on. **Always run the Review comments agent** (per step 2) to poll the comment endpoints for Codex (and any other bot). The only difference when Claude is disabled: the agent does NOT wait on the `claude-review` check first — it polls the comment endpoints directly for **~5 minutes** (10 polls at 30s) before concluding nothing arrived. Codex typically posts within a few minutes of the push. Do NOT report "no review comments" until that 5-minute poll has elapsed.
2. Launch **two background agents in parallel** (always both — even when Claude review is disabled per 1a, the Review comments agent still polls for the independent Codex bot):
   - **CI agent:** Run `gh pr checks` and wait for **all checks that are actually present** to pass (e.g. `analyze-and-test`, `claude-review` if enabled, and any others). Only wait for `claude-review` if it appears in the checks list — if the Claude review workflow is disabled (per step 1a) it will never appear, so do NOT block on it. If any check is still pending, poll every 30 seconds (up to **30 minutes** — `claude-review` can take 25+ minutes on large PRs). If a check fails, stop and report the failure. Checks with status `skipping` can be ignored. **Note:** `claude-review` and `codex` are independent review bots — do NOT conflate them. `claude-review` is a GitHub Actions check that posts comments; `codex` (chatgpt-codex-connector[bot]) is a separate bot. One being over quota does NOT mean the other won't run.
   - **Review comments agent:** If the `claude-review` check is present (Claude review enabled), first wait for it to complete (poll `gh pr checks {number}` every 30 seconds until `claude-review` shows `pass` or `fail` — up to **30 minutes**), then check the endpoints below. **If Claude review is disabled (no `claude-review` check, per 1a), do NOT wait on it** — poll the three comment endpoints directly every 30 seconds for **~5 minutes (10 polls)** to catch the independent Codex bot, which posts comments without any `gh pr checks` entry. In both cases, check all three comment endpoints for comments from **any bot** (Codex, Claude, or other reviewers) **on this specific PR number only** — do NOT look at GitHub Actions run history or other PRs:
     - `gh api repos/{owner}/{repo}/issues/{number}/comments` — where Codex keeps its "Codex Review Summary" comment (read its Status and Commit per 1a; the agent may stop polling early once it shows **Completed** for the head commit) and Claude posts review bodies
     - `gh api repos/{owner}/{repo}/pulls/{number}/comments` — inline review comments (both Codex and Claude post here)
     - `gh api repos/{owner}/{repo}/pulls/{number}/reviews` — review bodies
     After reading the endpoints, if no `claude[bot]` comments are found yet, poll these endpoints 3 more times at 30-second intervals (claude-review may post comments slightly after the CI check completes). Rules:
     - If a bot comment says its **quota or usage limit is reached**, stop polling and report it straight away, quoting the comment. That bot will not review this push, so there is nothing left to wait for.
     - If any reviewer has **bugfix or actionable comments** (look for P0/P1/P2 labels, specific code suggestions, or bug reports), address them by default — fix the issues, commit, and push. Only ask the user if the fix is unclear or contentious.
     - **If `claude-review` shows `pass` but NO comments were posted on any endpoint, do NOT assume the review was clean — the job exits 0 even when the review errored internally.** Verify the run logs first: get the job id from `gh pr checks {number}`, then `gh run view --job=<jobId> --log` and find the streamed `{"type":"result", ...}` block.
       - If it shows `"is_error": true` (often `"num_turns": 1`, a ~2s duration), the review **did not actually run** — e.g. an expired `CLAUDE_CODE_OAUTH_TOKEN`, a rate limit, or an overload — and posted nothing. Report this as **"review errored / did not run"**, distinct from a clean pass: the PR was NOT reviewed. Note: `total_cost_usd: 0` is normal under OAuth/subscription auth, so cost alone is NOT the signal — rely on `is_error`.
       - If it shows `"is_error": false` and/or `"No buffered inline comments"`, it was a genuine **clean review** — no action needed.
     - If there are **no comments** after the CI check completed and polling AND the logs confirm a clean review, note this so the user can still check manually if they want.
     - **CRITICAL:** Do NOT conclude "no review comments" while `claude-review` CI is still pending or running. The review comments are posted by the CI job — they cannot exist until the job finishes.

Both agents MUST run in parallel (launched in a single message with two Agent tool calls). **Report results as they arrive** — don't wait for both to finish. If any reviewer has actionable comments, address them immediately (even if CI is still pending — CI will re-run after the fix push anyway). Only proceed to Phase 2 once both are resolved.

**IMPORTANT: When reporting agent results, verify current state first.** Background agents return point-in-time snapshots that may be stale by the time you present them. Before reporting, run `gh pr checks <number>` to get live status — do NOT relay an agent's "still pending" if the check has since completed.

### Phase 2: Merge (foreground, needs user)

4. Report the Phase 1 results (CI status, any review comments found/addressed). Always use **live status** from `gh pr checks`, not cached agent output.
5. If CI failed, stop — do NOT merge.
6. If there were unresolved review comments, ask the user what to do.
7. If bot reviewers only posted a **quota-exceeded** message (no actual review), treat it the same as "no actionable comments" — proceed to merge without asking.
8. If **no comments arrived at all** after polling, tell the user and **wait for explicit confirmation** before merging. Do NOT run the merge command until the user says to proceed — they may want to check manually first.
   - **A Codex summary showing Completed for the head commit (per 1a) is an automated review:** treat it as a clean review result (step 7), not as "no review", even when Claude review is disabled.
   - **If the Claude review is disabled or errored AND Codex has no Completed summary for the head commit, there is NO automated review of this PR.** State that plainly (don't imply it was reviewed and clean), then **recommend a manual review — `/review <PR#>` in a fresh session — before merging.** Give a rationale tuned to the change: strongly suggest it when the changeset is large (10+ files or 200+ lines), touches architectural patterns (providers, DB schema, sync flow), is security-sensitive, or has complex logic; for small/focused or well-tested changes, note they can merge directly. Wait for explicit confirmation before merging, since only CI + the user's own testing have vetted the change. **Do NOT recommend `/review` when claude-review actually ran successfully** (a genuine clean review, or one whose comments you've already addressed) — that's redundant.
9. **Merge:** Only after user confirms (or after clean/quota-only review result). Run `gh pr merge --merge --delete-branch` (not squash, not rebase). This deletes the remote branch after merge. The guard-pr-merge hook will ask the user for confirmation — that's expected.
10. **Cleanup:** Switch back to `main`, pull latest, and delete the local branch (`git branch -d <branch>`). Note: `--delete-branch` already deletes the local branch if the merge fast-forwards — use `git branch -d` only if the branch still exists (ignore errors if already deleted).
11. Report the merge result.

## Rules

- Do NOT merge if CI has failed.
- Do NOT skip the review comment check — always wait or ask.
- **After you push a fix for review comments, WAIT for a re-review — the review is not "done" after one round.** Codex (and Claude, if enabled) **re-reviews each push**, so a fix commit can trigger a **new** round of comments (possibly on the fix itself). Do NOT treat the first round as final and do NOT merge straight after pushing a fix. After committing + pushing fixes, re-run the review-comments poll (Phase 1 step 2 — ~5 min / 10 polls of the three comment endpoints on the **new** head commit for Codex, or wait on `claude-review` if enabled) **and** re-check CI on the new commit.
- **Do NOT loop on Codex indefinitely — it may never come back "clean."** Codex re-reviews every push and often keeps surfacing fresh nitpicks/P2s round after round, so "keep fixing until no new actionable comments" can run forever. Bound it: poll ~5 min for the new round after a fix push; if a new actionable comment arrives, you may address it **once or twice**, but once rounds show **diminishing returns** (new comments are minor/nitpicky, contentious, or conflict with an explicit user decision), **STOP auto-looping and ask the user what to do.** Offer to let them **review the Codex thread directly in the browser** (the PR's "Codex Review" comments / chatgpt.com/codex/cloud) and decide whether to address, defer (log a TODO), or merge as-is. Never silently merge over unaddressed actionable comments, and never keep fix-looping without checking in.
- Do NOT force merge or use `--admin`.
- Phase 1 MUST run in background so the user can do other work while waiting.
