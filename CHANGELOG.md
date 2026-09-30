# Changelog

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
