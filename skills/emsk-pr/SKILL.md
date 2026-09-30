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
| `WHAT IS OPEN` | Every open PR, one line: number, draft flag, title, author, first line of the body. `(this branch)` marks the PR opened from the current branch. Bot PRs are folded into one line. This is the "keep me updated" answer — report it when asked. |
| `OPEN PRs THAT TOUCH YOUR FILES` | Someone else is editing the same file right now. Merge pain is coming. |
| `LANDED ON <remote>/<base> SINCE YOUR BRANCH POINT` | Files that moved under the branch. The local copy is older than the base branch. |
| `Definitions that changed` | `+ added` / `- removed` / `> moved` / `~ changed` function, method, class, type and SQL object names. |
| `MERGED INTO <base> AFTER YOUR BRANCH POINT` | PRs merged into the base that this branch does not have yet, and which of your files they touched. A PR already in the branch, or merged into another branch, is never listed. |
| `(file lists incomplete for #…)` | GitHub would not give the full file list of those PRs, so a collision in them can go unreported. |

The edit guard repeats the relevant part as a short warning right before an edit
to a contested file. It never blocks the edit. When the scan is older than 30
minutes, the guard says so and starts a fresh scan in the background.

## Rules once it has spoken

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
6. **Report the open-PR list when asked what is going on.** That is the whole point
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
`~/.claude/emsk-pr/<owner-repo>/<branch>/`; delete that directory to reset.

## Settings

Per repo, as git config (add `--global` for every repo):

| Key | Effect |
|---|---|
| `emsk-pr.remote` | Remote whose PRs to read. Default: `upstream` if it exists (forks), else `origin`. |
| `emsk-pr.base` | Base branch. Default: what this branch's PR targets, else what most merged PRs target, else the default branch. |
| `emsk-pr.hosts` | Extra GitHub Enterprise hostnames, space-separated. |

## How it fits together

- `scan.sh` — lists open PRs, then the PRs merged into the base since the branch
  point, keeping only those whose merge commit is not in the branch. Fills in full
  file lists for PRs over GitHub's 100-file cap, intersects them with the branch's
  own changed files, diffs the base branch for added/removed/moved/changed
  definitions, and writes `cache.json` + `digest.txt`.
- `guard.sh` — reads the `PreToolUse` payload, looks the target file up in
  `cache.json`, returns `additionalContext`. No network of its own and never blocks
  an edit; past the TTL it starts `scan.sh --quiet` in the background.
