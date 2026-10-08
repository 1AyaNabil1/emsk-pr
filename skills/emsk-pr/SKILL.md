---
name: emsk-pr
description: Use when about to write or change code in a repo that has other pull requests in flight, and before the first edit of a session. Also use when asked what PRs are open, what just merged, why a file keeps conflicting, whether a helper or method still exists, or whether someone already built the thing being written.
---

# emsk-pr — catch the PRs before they catch you

*emsk* is Egyptian Arabic for "catch". Catch what other people changed **before**
writing a line, so an edit builds on the newest code instead of quietly reverting it.

The failure this prevents: a branch is cut, a teammate lands a PR that renames a
helper or deletes a method, and the branch keeps calling the old one. Nothing
errors — the diff just re-introduces dead code, and review catches it days later.

## When to use

- Before the first code edit in a repo with open PRs
- Before touching a file that feels "popular" (Makefile, shared config, a chart, a service entrypoint)
- When asked "what's going on with the PRs", "what changed", "is this still there"
- When a rebase or merge conflicts in the same files repeatedly
- Before committing or opening a PR — refresh, and check what merged since the last scan

Skip it for a repo with no GitHub remote — the scripts detect that and stay silent.

## Run it

The scripts sit next to this file, in this skill's base directory. The last line
of every digest also prints the exact refresh command.

```sh
bash <skill dir>/scan.sh            # digest, refreshed if older than 30 min
bash <skill dir>/scan.sh --refresh  # force a fresh scan (a few seconds)
bash <skill dir>/scan.sh --doctor   # why is there no digest?
```

The `SessionStart` hook already runs this, so a digest is usually in context
before the first prompt. Re-run `--refresh` after a long session, before a commit,
or after a teammate says they merged something.

## Reading the digest

| Section | What it means |
|---|---|
| `WHAT IS OPEN` | Every open PR, one line: number, draft flag, title, author, first line of the body. `(this branch)` marks the PR opened from the current branch; `(your stack, …)` the PRs under it or built on it; `(built on your stack)` a PR built on a lower branch of the stack, beside this one. Bot PRs are folded into one line. This is the "keep me updated" answer — report it when asked. |
| `YOUR STACK` | The stacked PRs this branch belongs to, bottom first, and the target the whole stack is compared with. `!!` lines say what keeping it in shape takes: the parent has commits this branch lacks (and whether they conflict with it), rebasing a PR built on this branch would conflict, or a parent was merged and this branch should rebase onto the base. |
| `YOUR WORK ALREADY CONFLICTS WITH <remote>/<base>` | A trial merge of your work (uncommitted edits included) into the base tip failed in these files, with roughly which lines. |
| `OPEN PRs THAT TOUCH YOUR FILES` | Someone else is editing the same file right now. Under each, the trial merge's verdict: `CONFLICTS with …` (your edits and theirs meet, at those lines), `merges cleanly` (same files, different lines), or `unsettled` (their PR conflicts with the base there, so their final version is not known). Conflicting PRs come first. |
| `LANDED ON <remote>/<base> SINCE YOUR BRANCH POINT` | Files that moved under the branch. The local copy is older than the base branch. `(renamed to X …)` and `(deleted …)` mark files the base no longer has under that name. |
| `Definitions that changed` | `+ added` / `- removed` / `> moved` / `~ changed` function, method, class, type and SQL object names. |
| `MERGED INTO <base> AFTER YOUR BRANCH POINT` | PRs merged into the base that this branch does not have yet, and which of your files they touched. A PR already in the branch, or merged into another branch, is never listed. |
| `(file lists incomplete for #…)` | GitHub would not give the full file list of those PRs, so a collision in them can go unreported. |

The edit guard repeats the relevant part as a short warning right before an edit
to a contested file, including any file the base changed, renamed or deleted,
whether or not the branch had touched it yet. It never blocks the edit. When the
scan is older than 30 minutes, or the branch was checked out after the session
began and has no scan, the guard starts one in the background.

## Rules once it has spoken

0. **A `CONFLICTS` line is real, not a guess.** git tried the merge and it failed
   at those lines. Read the other side there first (`gh pr diff <n> -- <path>`,
   or `git show <remote>/<base>:<path>`), then change the code so the two fit,
   or tell the user who to coordinate with. Do not make the clash worse by
   building more on those lines. `merges cleanly` means no textual clash today;
   the two changes can still disagree in meaning, so it is not a sign-off.
1. **A `- removed` symbol is not a gap to fill.** It was deleted on purpose. Do not
   redefine it, do not call it, do not "restore" it. Find what replaced it. A
   rename, or a move into a file the scanner cannot read, also shows as removed:
   `git grep -n <name> <remote>/<base>` settles it in a second.
2. **A `> moved` symbol still exists.** It lives in the file named after `->` now.
   Import it from there; do not recreate it where it used to be.
3. **A `+ added` symbol is the helper to use.** Before writing a new utility, check
   whether the base branch already grew one.
4. **Read the diff of a colliding PR before editing that file** — use the
   `gh pr diff ...` command the digest prints; in a fork it already carries `-R`.
   Names alone are not enough to know whether an edit conflicts in intent.
5. **The local copy of a drifted file is stale.** Read it from the base branch
   (`git show <remote>/<base>:<path>`, as printed) before assuming what is in it.
   If the base **renamed** it, make the change in the new file. If the base
   **deleted** it, find out why (`git log <remote>/<base> -- <path>`) before
   editing it back into existence.
6. **PRs in `YOUR STACK` are not collisions.** They are the branch's own line of
   work, even when a teammate opened the one underneath. Act on the `!!` lines
   instead: rebase onto a parent with new commits before building more on the
   lines they touch, and tell the user when rebasing a PR built on this branch
   will conflict, so it is not a surprise.
7. **Report the open-PR list when asked what is going on.** That is the whole point
   of the section; do not summarise it away to one sentence.

## Red flags — stop

| Thought | Reality |
|---|---|
| "I'll check the PRs after I write this" | The point is to not write the wrong thing. Check first. |
| "It's a tiny edit, no need" | Tiny edits to shared files are exactly what silently reverts someone. |
| "The function is missing, I'll add it back" | Check `- removed` first. Re-adding a deleted symbol is the #1 failure here. |
| "The digest is from session start, close enough" | If a teammate merged since, `--refresh`. It takes seconds. |
| "I already know what's in that file" | If it is under `LANDED ON`, the local copy is not what is in the file. |

## When it says nothing

Silence outside a GitHub repo is designed, not a bug: the hook runs in every
project. Inside a GitHub repo, a missing `jq` or `gh`, or a logged-out `gh`, gets
a one-line `emsk-pr:` hint instead. For anything else, run `scan.sh --doctor` —
it walks every check and says which one failed.

Offline, the last cached digest is served with its age. Cache lives in
`~/.claude/emsk-pr/<owner>/<repo>/<branch>/` (slashes in the branch written as
`%2F`); delete that directory to reset.

## Settings

Per repo, as git config (add `--global` for every repo):

| Key | Effect |
|---|---|
| `emsk-pr.remote` | Remote whose PRs to read. Default: `upstream` if it exists (forks), else `origin`. |
| `emsk-pr.base` | Base branch. Default: what the bottom PR of this branch's stack targets (for an unstacked PR, simply its target); with no PR yet, the stack is found from the branch's commits, else the base is the branch it split from most recently, and the digest says it guessed. |
| `emsk-pr.hosts` | Extra GitHub Enterprise hostnames, space-separated. |

`EMSK_PR_CONFLICTS=0` turns the trial merges off. They need git 2.38 or newer;
with an older git, shared files are still reported, just without a verdict.

## How it fits together

- `scan.sh` — lists open PRs, then the PRs merged into the base since the branch
  point, keeping only those whose merge commit is not in the branch. Fills in full
  file lists for PRs over GitHub's 100-file cap, intersects them with the branch's
  own changed files, diffs the base branch for added/removed/moved/changed
  definitions, trial-merges the working tree against the base and against each
  overlapping PR with `git merge-tree` (no ref, index or file in the working
  tree is touched), and writes `cache.json` + `digest.txt`.
- `guard.sh` — reads the `PreToolUse` payload, looks the target file up in
  `cache.json`, returns `additionalContext`. No network of its own and never blocks
  an edit; past the TTL it starts `scan.sh --quiet` in the background.
