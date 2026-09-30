# Changelog

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
