# Changelog

## 1.3.0 — 2026-10-01

Real conflicts, not just shared files.

- For each open PR that shares a file with the branch, and for the base when it
  moved under the branch, the merge is tried with `git merge-tree`, against
  uncommitted edits too. The digest says `CONFLICTS` (with roughly which lines
  and what kind, such as modify/delete) or `merges cleanly`, and lists
  conflicting PRs first. The guard leads with the conflict for the file being
  edited and points at the PR that causes it.
- Both sides are replayed onto the base tip before they are compared, so a PR
  that is merely behind the base is not reported as conflicting with you. Files
  where that PR conflicts with the base are marked `unsettled` instead.
- Nothing visible changes in the repo: PR heads are fetched without a ref or
  `FETCH_HEAD`, the working tree is snapshotted through a scratch index, and
  `merge-tree` writes nothing but objects.
- Needs git 2.38 or newer; `--doctor` says whether it is on. `EMSK_PR_CONFLICTS=0`
  turns it off.

## 1.2.0 — 2026-10-01

From an audit of 1.1.0.

- Your own PR, once squash-merged, no longer counts as a collision when you keep
  working on the branch.
- A file the base renamed or deleted is now caught. Plain `git diff --name-only`
  and `gh pr list` only name a rename's new path, so editing the old one was
  silent. The digest and the guard now say "renamed to …" or "deleted". An empty
  file that git pairs as a rename (every empty `__init__.py` looks the same) is
  reported as deleted.
- The guard warns on any file the base changed, not only the ones the branch had
  touched when the scan ran.
- The first edit on a branch checked out mid-session starts that branch's scan
  in the background; the guard used to stay silent until the next session.
  Background scans run at most once a minute.
- A failed refresh says why, using gh's own error (bad credentials, rate limit,
  timeout, a gh too old for a field), and labels the digest it falls back to.
- Cache and digest are written by renaming into place, so a parallel scan or
  the guard never reads half a file.
- Cache layout is now `<owner>/<repo>/<branch>` with `%`-encoded branch names, so
  `feat/x` and `feat-x` no longer share a cache. Old `<owner-repo>` directories
  under `~/.claude/emsk-pr/` are unused and safe to delete.
- Methods with the same name in unrelated classes (`run`, `Close`) are no longer
  reported as moved, and `__init__`-style names are ignored.
- `const total = (price * qty)` is no longer taken for an arrow function.
- Control characters in PR titles and descriptions are stripped; full PR
  descriptions are no longer kept in the cache (a quarter of its size).
- The digest's drifted-file list says how many it left out past 20.
- README: Windows is marked untested.

## 1.1.0 — 2026-09-30

Fewer false alarms and fewer missed ones.

- A merged PR is reported only if it went into your base branch and its merge
  commit is not in your branch yet. Release merges into another branch, and
  merges you already have, no longer warn. The 7-day look-back is gone
  (`EMSK_PR_FLOOR_DAYS` is removed).
- Merged PRs are fetched for your base branch since your branch point, instead
  of the last 40 across every branch. `EMSK_PR_MERGED_LIMIT` now defaults to 100.
- PRs over GitHub's 100-file cap get their full file list, from the REST API or,
  for merged PRs, local git. PRs still incomplete are named in the digest.
  New: `EMSK_PR_FILE_PAGES`.
- A definition that moved to another file is reported as `> moved` with its new
  file, not as removed.
- SQL names: `if not exists`, quoted names (policy names with spaces),
  `unique` / `concurrently` / `materialized`, and schema-qualified names are read
  correctly; an unnamed `create index on …` is no longer taken for a name.
- The edit guard starts a background refresh when the scan is older than the
  TTL, and says how old the scan behind its warning is.
- Fixed on Linux: the cache's age was misread, so every session start refreshed
  and the digest's "scanned … ago" was wrong.
- The session-start hook's timeout is now 55 seconds.

## 1.0.0 — 2026-09-30

First public release, packaged as a Claude Code plugin.

- Session-start digest of open and recently merged PRs, the files that moved on
  the base branch, and the definitions added, removed or changed in them.
- Before-edit warning for files another PR is touching. It never blocks an edit.
- Forks: PRs are read from `upstream`, and your own PR is recognised by its fork.
- The PR opened from the current branch is labelled and never reported as a collision.
- Bot PRs are folded into one line.
- GitHub Enterprise hosts via `git config emsk-pr.hosts`, and ssh host aliases
  resolved from `~/.ssh/config`.
- `--doctor` explains why there is no digest. Inside a GitHub repo, a missing
  `jq` or `gh` gets a one-line hint instead of silence.
- Definition tracking for Rust, Ruby, Kotlin, Swift, Java, C#, PHP and Scala,
  alongside Python, Go, TypeScript/JavaScript, Svelte, Vue and SQL.
- PR text is labelled as author-written data; `EMSK_PR_BLURBS=0` drops descriptions.
