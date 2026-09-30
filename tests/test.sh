#!/usr/bin/env bash
# Tests for emsk-pr. Run from the repo root: bash tests/test.sh
#
# These assert behaviour by executing the scripts, not by reading them. The
# network tests run against a live GitHub repo — $EMSK_PR_TEST_REPO, else the
# repo you run this from — and skip when gh is not logged in. The safety tests
# (which must be silent everywhere) always run.
#
#   EMSK_PR_TEST_SHELL=/bin/bash bash tests/test.sh   run the scripts under macOS's bash 3.2

# ok() always succeeds, so `check && ok || bad` never runs both.
# shellcheck disable=SC2015

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../skills/emsk-pr"
SCAN="$SKILL/scan.sh"
GUARD="$SKILL/guard.sh"
SH="${EMSK_PR_TEST_SHELL:-bash}"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "${2:-}"; }

# A live repo to test against, if it is a GitHub repo and gh is logged in.
LIVE_REPO=""
CANDIDATE="${EMSK_PR_TEST_REPO:-$PWD}"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if git -C "$CANDIDATE" rev-parse --git-dir >/dev/null 2>&1 &&
     git -C "$CANDIDATE" remote get-url origin 2>/dev/null | grep -q github.com; then
    LIVE_REPO="$(git -C "$CANDIDATE" rev-parse --show-toplevel)"
  fi
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# A PATH holding only the named tools, so a test can take one away (jq, gh)
# regardless of where this machine happens to install it.
mkbin() {
  local dir="$1" t p; shift
  mkdir -p "$dir"
  for t in "$@"; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$dir/$t"
  done
}
BASE_TOOLS=(bash git dirname tr sed awk date stat cat head sort comm cut grep wc sleep mkdir mktemp rm mv ssh)
mkbin "$TMPROOT/bin-nojq" "${BASE_TOOLS[@]}"
mkbin "$TMPROOT/bin-nogh" "${BASE_TOOLS[@]}" jq

# A repo with the given remotes: mkrepo <dir> <name>=<url> ...
mkrepo() {
  local dir="$1" spec; shift
  mkdir -p "$dir" && git -C "$dir" init -q 2>/dev/null
  for spec in "$@"; do git -C "$dir" remote add "${spec%%=*}" "${spec#*=}"; done
}
cache_path() { (cd "$1" && EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" --cache-path 2>&1); }

echo
echo "== silence outside GitHub repos (this hook runs in every project) =="

out="$(cd "$TMPROOT" && EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "non-git dir: silent, exit 0" \
  || bad "non-git dir: silent, exit 0" "rc=$rc out=<$out>"

mkrepo "$TMPROOT/noremote"
out="$(cd "$TMPROOT/noremote" && EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "git repo, no remote: silent, exit 0" \
  || bad "git repo, no remote: silent, exit 0" "rc=$rc out=<$out>"

mkrepo "$TMPROOT/gitlab" origin=https://gitlab.com/x/y.git
out="$(cd "$TMPROOT/gitlab" && EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "non-GitHub remote: silent, exit 0" \
  || bad "non-GitHub remote: silent, exit 0" "rc=$rc out=<$out>"

out="$(cd "$TMPROOT" && PATH="$TMPROOT/bin-nogh" EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "gh not installed, not a repo: silent, exit 0" \
  || bad "gh not installed, not a repo: silent, exit 0" "rc=$rc out=<$out>"

echo
echo "== inside a GitHub repo, a missing tool gets one line, not silence =="

mkrepo "$TMPROOT/gh" origin=https://github.com/acme/shop.git
out="$(cd "$TMPROOT/gh" && PATH="$TMPROOT/bin-nojq" EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$out" | grep -q jq \
  && ok "jq missing: one line naming jq, exit 0" \
  || bad "jq missing: one line naming jq" "rc=$rc out=<$out>"

out="$(cd "$TMPROOT/gh" && PATH="$TMPROOT/bin-nogh" EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$out" | grep -q 'cli.github.com' \
  && ok "gh missing: one line pointing at the GitHub CLI, exit 0" \
  || bad "gh missing: one line pointing at the GitHub CLI" "rc=$rc out=<$out>"

out="$(cd "$TMPROOT/gh" && PATH="$TMPROOT/bin-nogh" EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" --quiet 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "--quiet stays silent even with a tool missing" \
  || bad "--quiet stays silent" "rc=$rc out=<$out>"

out="$(cd "$TMPROOT/gh" && PATH="$TMPROOT/bin-nogh" EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" --doctor 2>&1)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'acme/shop' && printf '%s' "$out" | grep -q 'gh' \
  && ok "--doctor names the repo and the missing gh" \
  || bad "--doctor names the repo and the missing gh" "rc=$rc out=<$out>"

echo
echo "== which remote, which repo (no network: --cache-path only) =="

p="$(cache_path "$TMPROOT/gh")"
case "$p" in */acme-shop/*) ok "https remote -> acme/shop" ;; *) bad "https remote -> acme/shop" "got: $p" ;; esac

mkrepo "$TMPROOT/scp" origin=git@github.com:acme/shop.git
p="$(cache_path "$TMPROOT/scp")"
case "$p" in */acme-shop/*) ok "scp-style ssh remote -> acme/shop" ;; *) bad "scp-style ssh remote" "got: $p" ;; esac

mkrepo "$TMPROOT/sshurl" origin=ssh://git@ssh.github.com:443/acme/shop
p="$(cache_path "$TMPROOT/sshurl")"
case "$p" in */acme-shop/*) ok "ssh:// remote on ssh.github.com:443 -> acme/shop" ;; *) bad "ssh:// remote with port" "got: $p" ;; esac

mkrepo "$TMPROOT/token" origin=https://x-access-token:ghs_SECRET123@github.com/acme/shop.git
p="$(cache_path "$TMPROOT/token")"
case "$p" in
  *SECRET*|*x-access-token*) bad "credentials in the remote never reach the cache path" "got: $p" ;;
  */acme-shop/*)             ok "credentials in the remote never reach the cache path" ;;
  *)                         bad "token remote -> acme/shop" "got: $p" ;;
esac

mkrepo "$TMPROOT/fork" origin=https://github.com/me/shop.git upstream=https://github.com/acme/shop.git
p="$(cache_path "$TMPROOT/fork")"
case "$p" in */acme-shop/*) ok "fork: PRs are read from upstream, not origin" ;; *) bad "fork reads upstream" "got: $p" ;; esac

git -C "$TMPROOT/fork" config emsk-pr.remote origin
p="$(cache_path "$TMPROOT/fork")"
case "$p" in */me-shop/*) ok "git config emsk-pr.remote overrides the choice" ;; *) bad "emsk-pr.remote override" "got: $p" ;; esac

mkrepo "$TMPROOT/ghe" origin=https://github.acme-corp.com/team/shop.git
p="$(cache_path "$TMPROOT/ghe")"
[ -z "$p" ] && ok "unknown Enterprise host: silent until configured" \
  || bad "unknown Enterprise host: silent" "got: $p"
git -C "$TMPROOT/ghe" config emsk-pr.hosts "github.acme-corp.com"
p="$(cache_path "$TMPROOT/ghe")"
case "$p" in */github.acme-corp.com-team-shop/*) ok "git config emsk-pr.hosts enables an Enterprise host" ;;
  *) bad "emsk-pr.hosts enables an Enterprise host" "got: $p" ;; esac

echo
echo "== symbol extraction (the 'which method changed' engine) =="

# A synthetic unified diff:
#   - compute_totals    added   (+ only)
#   - _legacy_cart_key  removed (- only)
#   - apply_discount    changed (both + and -)
diff_fixture() {
cat <<'DIFF'
--- a/shop/cart.py
+++ b/shop/cart.py
@@
-def _legacy_cart_key(a):
-    return a
-def apply_discount(cart):
-    pass
+def apply_discount(cart, code=None):
+    pass
+def compute_totals(cart):
+    return cart
DIFF
}

sym="$(diff_fixture | "$SH" "$SCAN" --extract-symbols 2>/dev/null)"
if [ -z "$sym" ]; then
  bad "extractor produces JSON" "empty output"
else
  echo "$sym" | jq -e . >/dev/null 2>&1 \
    && ok "extractor produces valid JSON" \
    || bad "extractor produces valid JSON" "got: $sym"
  echo "$sym" | jq -e '.added | index("compute_totals")' >/dev/null 2>&1 \
    && ok "added-only symbol reported as added" \
    || bad "added-only symbol reported as added" "got: $sym"
  echo "$sym" | jq -e '.removed | index("_legacy_cart_key")' >/dev/null 2>&1 \
    && ok "removed-only symbol reported as removed" \
    || bad "removed-only symbol reported as removed" "got: $sym"
  echo "$sym" | jq -e '.changed | index("apply_discount")' >/dev/null 2>&1 \
    && ok "symbol on both sides reported as changed, not added+removed" \
    || bad "symbol on both sides reported as changed" "got: $sym"
  echo "$sym" | jq -e '(.added | index("apply_discount")) == null' >/dev/null 2>&1 \
    && ok "a changed symbol is not double-counted as added" \
    || bad "a changed symbol is not double-counted as added" "got: $sym"
fi

go_ts="$(cat <<'DIFF' | "$SH" "$SCAN" --extract-symbols 2>/dev/null
--- a/x.go
+++ b/x.go
@@
+func ResolveWindow(ctx context.Context) error {
-func (s *Store) oldHelper() {}
--- a/y.ts
+++ b/y.ts
@@
+export function buildDigest(rows: Row[]) {
+export const useRadar = () => {
DIFF
)"
echo "$go_ts" | jq -e '.added | index("ResolveWindow")' >/dev/null 2>&1 \
  && ok "Go func recognised" || bad "Go func recognised" "got: $go_ts"
echo "$go_ts" | jq -e '.removed | index("oldHelper")' >/dev/null 2>&1 \
  && ok "Go method on a receiver recognised" || bad "Go method recognised" "got: $go_ts"
echo "$go_ts" | jq -e '.added | index("buildDigest")' >/dev/null 2>&1 \
  && ok "TS export function recognised" || bad "TS export function recognised" "got: $go_ts"
echo "$go_ts" | jq -e '.added | index("useRadar")' >/dev/null 2>&1 \
  && ok "TS arrow const recognised" || bad "TS arrow const recognised" "got: $go_ts"

# One definition per language, each behind the modifiers that language puts
# in front of its names.
many="$(cat <<'DIFF' | "$SH" "$SCAN" --extract-symbols 2>/dev/null
--- a/lib.rs
+++ b/lib.rs
@@
+pub(crate) async fn load_config(path: &Path) -> Result<Config> {
+pub struct Settings {
-impl Settings {
--- a/app.rb
+++ b/app.rb
@@
+  def self.build(attrs)
+module Billing
--- a/Api.kt
+++ b/Api.kt
@@
+suspend fun <T> Client.fetchAll(): List<T> {
+enum class Status { OK }
+data class Invoice(val id: String)
--- a/View.swift
+++ b/View.swift
@@
+@MainActor public func render() {
+protocol Renderable {
--- a/OrderService.java
+++ b/OrderService.java
@@
+public final class OrderService {
--- a/Handler.php
+++ b/Handler.php
@@
+    public static function handle($req) {
--- a/Invoice.cs
+++ b/Invoice.cs
@@
+public sealed record InvoiceLine(string Sku);
--- a/index.ts
+++ b/index.ts
@@
+export default async function main() {
+export interface Props {
+export default class extends Base {
DIFF
)"
for want in load_config Settings build Billing fetchAll Status Invoice render Renderable \
            OrderService handle InvoiceLine main Props; do
  echo "$many" | jq -e --arg w "$want" '.added | index($w)' >/dev/null 2>&1 \
    || { bad "multi-language definitions recognised" "missing $want in: $many"; want=FAIL; break; }
done
[ "$want" = FAIL ] || ok "Rust, Ruby, Kotlin, Swift, Java, PHP, C# and TS definitions recognised"
echo "$many" | jq -e '[.added[] | select(. == "extends" or . == "class" or . == "self" or . == "Client")] | length == 0' \
  >/dev/null 2>&1 && ok "modifiers, receivers and anonymous classes are not taken for names" \
  || bad "no keyword or receiver taken for a name" "got: $many"
echo "$many" | jq -e '.removed | length == 0' >/dev/null 2>&1 \
  && ok "an impl block is not a removed definition" || bad "impl is not a definition" "got: $many"

noise="$(printf -- '--- a/z.py\n+++ b/z.py\n@@\n+# def commented_out(x):\n+    total = defaults + 1\n+    type = "x"\n' \
  | "$SH" "$SCAN" --extract-symbols 2>/dev/null)"
echo "$noise" | jq -e '(.added | length) == 0' >/dev/null 2>&1 \
  && ok "commented-out defs, 'defaults' and 'type =' are not symbols" \
  || bad "commented-out defs are not symbols" "got: $noise"

echo
echo "== guard: the before-every-edit check =="

GCACHE="$TMPROOT/guardcache/fixture"
mkdir -p "$GCACHE"
cat > "$GCACHE/cache.json" <<'JSON'
{
  "repo": "acme/shop", "branch": "feat/x", "base": "main", "remote": "origin",
  "by_file": {
    "Makefile": {"open": [412, 398], "merged": []},
    "shop/cart.py": {"open": [], "merged": [377]}
  },
  "open":   [{"number": 412, "title": "Rework checkout totals", "author": {"login": "dev-a"}, "isDraft": true},
             {"number": 398, "title": "Move tax rules into config", "author": {"login": "dev-b"}, "isDraft": false}],
  "merged": [{"number": 377, "title": "Drop the legacy cart key", "author": {"login": "dev-c"}, "mergedAt": "2026-09-17T00:00:00Z"}],
  "symbols": {"shop/cart.py": {"added": ["compute_totals"], "removed": ["_legacy_cart_key"], "changed": []}}
}
JSON

guard_with() { # $1 = repo-relative path, $2 = cache file (default: the fixture)
  printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/%s"}}' \
    "$TMPROOT/repo" "$TMPROOT/repo" "$1" \
  | EMSK_PR_CACHE_FILE="${2:-$GCACHE/cache.json}" EMSK_PR_REPO_ROOT="$TMPROOT/repo" "$SH" "$GUARD" 2>&1
}

out="$(guard_with Makefile)"
if [ -z "$out" ]; then
  bad "colliding file produces a warning" "empty output"
else
  echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1 \
    && ok "warning is valid PreToolUse hook JSON" \
    || bad "warning is valid PreToolUse hook JSON" "got: $out"
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("412")' >/dev/null 2>&1 \
    && ok "warning names the colliding open PR" \
    || bad "warning names the colliding open PR" "got: $out"
  echo "$out" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null 2>&1 \
    && ok "warning never denies the edit" \
    || bad "warning never denies the edit" "got: $out"
fi

out="$(guard_with shop/cart.py)"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("_legacy_cart_key")' >/dev/null 2>&1 \
  && ok "warning names symbols a merged PR removed" \
  || bad "warning names removed symbols" "got: $out"

out="$(guard_with README.md)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "untouched file: silent, exit 0" \
  || bad "untouched file: silent, exit 0" "rc=$rc out=<$out>"

out="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/x/Makefile"}}' \
  | EMSK_PR_CACHE_FILE="$TMPROOT/nope.json" "$SH" "$GUARD" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "no cache yet: silent, exit 0" \
  || bad "no cache yet: silent, exit 0" "rc=$rc out=<$out>"

out="$(printf 'not json at all' | "$SH" "$GUARD" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "garbage on stdin: silent, exit 0" \
  || bad "garbage on stdin: silent, exit 0" "rc=$rc out=<$out>"

out="$(printf '' | "$SH" "$GUARD" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "empty stdin: silent, exit 0" \
  || bad "empty stdin: silent, exit 0" "rc=$rc out=<$out>"

# In a fork the PRs live on upstream, so the commands the warning suggests must
# name that remote and that repo, or they point at the wrong place.
jq '. + {remote: "upstream", gh_repo_flag: "-R acme/shop ", base_drift_on_my_files: ["Makefile"]}' \
  "$GCACHE/cache.json" > "$GCACHE/fork.json"
ctx="$(guard_with Makefile "$GCACHE/fork.json" | jq -r '.hookSpecificOutput.additionalContext // ""')"
printf '%s' "$ctx" | grep -q 'gh pr diff -R acme/shop 412' \
  && ok "fork: the suggested gh command names the upstream repo" \
  || bad "fork: gh command names the upstream repo" "got: $ctx"
printf '%s' "$ctx" | grep -q 'git show upstream/main:Makefile' \
  && ok "fork: the suggested git show reads upstream's base" \
  || bad "fork: git show reads upstream's base" "got: $ctx"

# A popular file can be in a dozen PRs. The warning runs before EVERY edit, so
# it must stay short or it floods the context it is meant to inform.
# Titles are as long as real ones, or the cap looks fine on short data.
jq -n '
  "feat(observability): add a metrics volume, 31-day retention, and a config toggle" as $long |
  [range(9) | {number: (900 + .), title: "\($long) \(.)", author: {login: "developer\(.)"}, isDraft: false}] as $open |
  [range(9) | {number: (800 + .), title: "\($long) \(.)", author: {login: "developer\(.)"}, mergedAt: "2026-09-17T00:00:00Z"}] as $merged |
  {repo: "acme/shop", branch: "feat/x", base: "main",
   by_file: {Makefile: {open: [$open[].number], merged: [$merged[].number]}},
   open: $open, merged: $merged,
   symbols: {Makefile: {added:   [range(12) | "added_symbol_number_\(.)"],
                        removed: [range(12) | "removed_symbol_number_\(.)"],
                        changed: [range(12) | "changed_symbol_number_\(.)"]}},
   base_drift_on_my_files: ["Makefile"]}' > "$GCACHE/many.json"
ctx="$(guard_with Makefile "$GCACHE/many.json" | jq -r '.hookSpecificOutput.additionalContext // ""')"
[ -n "$ctx" ] && [ "${#ctx}" -le 1000 ] \
  && ok "warning stays under 1000 chars with 18 PRs and 36 symbols (${#ctx})" \
  || bad "warning stays under 1000 chars" "len=${#ctx}"
echo "$ctx" | grep -q 'more' \
  && ok "truncated warning says how many more there are" \
  || bad "truncated warning says how many more" "got: ${ctx:0:300}"
# Truncation must never drop the removed-symbol warning entirely — that line is
# the whole reason the guard exists.
echo "$ctx" | grep -q 'removed_symbol_number_0' \
  && ok "removed symbols survive truncation" \
  || bad "removed symbols survive truncation" "got: ${ctx:0:300}"

# A cache whose author is a bare string instead of gh's object must still warn.
# A shape surprise should degrade the wording, never silence the warning.
jq '.open |= map(.author = .author.login)' "$GCACHE/cache.json" > "$GCACHE/odd.json"
out="$(guard_with Makefile "$GCACHE/odd.json")"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("412")' >/dev/null 2>&1 \
  && ok "odd author shape still warns" || bad "odd author shape still warns" "got: $out"

echo
echo "== full refresh against a fake gh (no network) =="

# A branch cut from main, then main moves under it: a merged PR drops
# _legacy_cart_key and adds compute_totals in a file the branch also edits.
E2E="$TMPROOT/e2e"
mkrepo "$E2E" origin=git@github.com:acme/shop.git
git -C "$E2E" config user.name test && git -C "$E2E" config user.email test@example.com
mkdir -p "$E2E/shop"
printf 'def _legacy_cart_key(a):\n    return a\n\ndef apply_discount(cart):\n    pass\n' > "$E2E/shop/cart.py"
printf 'all:\n\ttrue\n' > "$E2E/Makefile"
git -C "$E2E" add -A && git -C "$E2E" commit -qm base
git -C "$E2E" branch -M main
git -C "$E2E" checkout -qb landed
printf 'def apply_discount(cart):\n    pass\n\ndef compute_totals(cart):\n    return cart\n' > "$E2E/shop/cart.py"
git -C "$E2E" commit -qam "drop the legacy key"
git -C "$E2E" update-ref refs/remotes/origin/main landed
git -C "$E2E" checkout -q main && git -C "$E2E" branch -qD landed
git -C "$E2E" checkout -qb feat/totals
printf 'def _legacy_cart_key(a):\n    return a\n\ndef apply_discount(cart, code=None):\n    pass\n' > "$E2E/shop/cart.py"
printf 'all:\n\tfalse\n' > "$E2E/Makefile"
git -C "$E2E" commit -qam "my change"

FAKE="$TMPROOT/fakegh"
mkdir -p "$FAKE"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# #10 is this branch's own PR. #11 is a teammate on Makefile. #13 is a stranger's
# fork PR from a branch that happens to share this branch's name. #12 is a bot.
# The stranger's PR comes first, so picking the base by branch name alone would
# pick theirs.
cat > "$FAKE/open.json" <<JSON
[
 {"number": 13, "title": "Same branch name, different fork", "author": {"login": "stranger", "is_bot": false}, "isDraft": false,
  "baseRefName": "release", "headRefName": "feat/totals", "headRepositoryOwner": {"login": "stranger"},
  "updatedAt": "$NOW", "url": "", "body": "", "files": [{"path": "shop/cart.py"}]},
 {"number": 10, "title": "Totals rework", "author": {"login": "me", "is_bot": false}, "isDraft": false,
  "baseRefName": "main", "headRefName": "feat/totals", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "Mine.", "files": [{"path": "shop/cart.py"}, {"path": "Makefile"}]},
 {"number": 11, "title": "Build tweaks", "author": {"login": "dev-b", "is_bot": false}, "isDraft": true,
  "baseRefName": "main", "headRefName": "build", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "**Faster** builds.", "files": [{"path": "Makefile"}]},
 {"number": 12, "title": "Bump lodash", "author": {"login": "dependabot", "is_bot": true}, "isDraft": false,
  "baseRefName": "main", "headRefName": "dependabot/npm/lodash", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "", "files": [{"path": "package.json"}]}
]
JSON
cat > "$FAKE/merged.json" <<JSON
[{"number": 9, "title": "Drop the legacy cart key", "author": {"login": "dev-c"}, "baseRefName": "main",
  "mergedAt": "$NOW", "url": "", "files": [{"path": "shop/cart.py"}]}]
JSON
cat > "$FAKE/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
  "auth token") exit 0 ;;
  "pr list") case "$*" in
      *"--state open"*)   cat "$EMSK_PR_FAKE/open.json" ;;
      *"--state merged"*) cat "$EMSK_PR_FAKE/merged.json" ;;
    esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE/gh"
mkbin "$TMPROOT/bin-fake" "${BASE_TOOLS[@]}" jq
ln -sf "$FAKE/gh" "$TMPROOT/bin-fake/gh"

fake_scan() { # $1 = repo; a failing ssh makes the fetch fail at once, offline
  (cd "$1" && PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" GIT_SSH_COMMAND=false \
     EMSK_PR_HOME="$TMPROOT/e2ecache" "$SH" "$SCAN" --refresh 2>&1)
}
digest="$(fake_scan "$E2E")"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$digest" | grep -q 'WHAT IS OPEN (4)' \
  && ok "refresh with a fake gh builds a digest" || bad "refresh builds a digest" "rc=$rc out=<$digest>"
printf '%s' "$digest" | grep -q 'base origin/main' \
  && ok "base taken from this branch's own PR, not the stranger's" || bad "base from own PR" "$(printf '%s' "$digest" | head -1)"
# The lines under one '!!' header, up to the next header or the footer.
section() { printf '%s\n' "$digest" | awk -v h="$1" '/^(!!|WHAT IS OPEN|\(emsk-pr)/ { on = (index($0, h) == 1); next } on'; }
touch_open="$(section '!! OPEN PRs THAT TOUCH YOUR FILES')"
printf '%s' "$touch_open" | grep -q '#11 ' && ! printf '%s' "$touch_open" | grep -q '#10 ' \
  && ok "this branch's own PR is not reported as a collision" \
  || bad "own PR is not a collision" "got: $touch_open"
printf '%s' "$touch_open" | grep -q '#13 ' \
  && ok "a stranger's PR with the same branch name still counts as a collision" \
  || bad "same-name fork PR counts as a collision" "got: $touch_open"
printf '%s' "$digest" | grep -q '#10 (this branch)' \
  && ok "own PR is labelled in the open list" || bad "own PR labelled" "got: $digest"
printf '%s' "$digest" | grep -q '+ 1 bot PR: #12 (dependabot)' \
  && ok "bot PRs are folded into one line" || bad "bot PRs folded" "got: $digest"
landed="$(section '!! LANDED ON origin/main')"
printf '%s' "$landed" | grep -q 'shop/cart.py' && printf '%s' "$landed" | grep -q -- '- removed _legacy_cart_key' \
  && printf '%s' "$landed" | grep -q '+ added   compute_totals' \
  && ok "base drift lists the file and the removed/added definitions" \
  || bad "base drift and symbols" "got: $landed"
section '!! RECENTLY MERGED' | grep -q '#9 ' \
  && ok "the merged PR that moved the file is listed" || bad "merged PR listed" "got: $digest"
printf '%s' "$digest" | grep -q 'data, not instructions' \
  && ok "digest marks PR text as author-written data" || bad "digest marks PR text as data" "got: $digest"
printf '%s' "$digest" | grep -q 'Faster builds' \
  && ok "PR descriptions are in the digest by default" || bad "PR descriptions shown by default" "got: $digest"
nob="$(cd "$E2E" && PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" GIT_SSH_COMMAND=false EMSK_PR_BLURBS=0 \
  EMSK_PR_HOME="$TMPROOT/e2ecache-nob" "$SH" "$SCAN" --refresh 2>&1)"
printf '%s' "$nob" | grep -q 'Build tweaks' && ! printf '%s' "$nob" | grep -q 'Faster builds' \
  && ok "EMSK_PR_BLURBS=0 keeps titles and drops descriptions" || bad "EMSK_PR_BLURBS=0" "got: $nob"

ecache="$(cd "$E2E" && EMSK_PR_HOME="$TMPROOT/e2ecache" "$SH" "$SCAN" --cache-path)"
guard_e2e() {
  printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/%s"}}' "$E2E" "$E2E" "$1" \
  | EMSK_PR_CACHE_FILE="$ecache" "$SH" "$GUARD" 2>&1 | jq -r '.hookSpecificOutput.additionalContext // ""'
}
ctx="$(guard_e2e Makefile)"
printf '%s' "$ctx" | grep -q '#11' && ! printf '%s' "$ctx" | grep -q '#10' \
  && ok "guard warns about the teammate's PR, never your own" || bad "guard skips own PR" "got: $ctx"
ctx="$(guard_e2e shop/cart.py)"
printf '%s' "$ctx" | grep -q '_legacy_cart_key' \
  && ok "guard on the drifted file names the removed definition" || bad "guard names removed definition" "got: $ctx"

# The same branch in a fork: origin is mine, PRs live on upstream, and my PR's
# head is in my fork. It must still be recognised as mine.
git -C "$E2E" remote set-url origin git@github.com:me/shop.git
git -C "$E2E" remote add upstream git@github.com:acme/shop.git
git -C "$E2E" update-ref refs/remotes/upstream/main refs/remotes/origin/main
jq 'map(if .number == 10 then .headRepositoryOwner.login = "me" else . end)' "$FAKE/open.json" > "$FAKE/o2" \
  && mv "$FAKE/o2" "$FAKE/open.json"
digest="$(fake_scan "$E2E")"
touch_open="$(section '!! OPEN PRs THAT TOUCH YOUR FILES')"
printf '%s' "$digest" | grep -q 'base upstream/main' && ! printf '%s' "$touch_open" | grep -q '#10 ' \
  && ok "fork: reads upstream and still knows which PR is yours" \
  || bad "fork: upstream + own PR" "got: $digest"
printf '%s' "$touch_open" | grep -q 'gh pr diff -R acme/shop ' \
  && ok "fork: digest's gh commands name the upstream repo" || bad "fork: digest gh -R" "got: $touch_open"

echo
echo "== live scan against a real repo =="

if [ -z "$LIVE_REPO" ]; then
  skip "live scan" "no GitHub repo at $CANDIDATE with gh logged in"
else
  LCACHE="$TMPROOT/live"
  start=$(date +%s)
  out="$(cd "$LIVE_REPO" && EMSK_PR_HOME="$LCACHE" "$SH" "$SCAN" --refresh 2>&1)"; rc=$?
  elapsed=$(( $(date +%s) - start ))

  [ $rc -eq 0 ] && ok "live scan exits 0" || bad "live scan exits 0" "rc=$rc out=<$out>"
  [ $elapsed -le 25 ] && ok "live scan finishes in ${elapsed}s (budget 25s)" \
    || bad "live scan within budget" "took ${elapsed}s"

  cfile="$(find "$LCACHE" -name cache.json | head -1)"
  if [ -n "$cfile" ] && jq -e . "$cfile" >/dev/null 2>&1; then
    ok "cache.json written and is valid JSON"
    jq -e '.open | type == "array"' "$cfile" >/dev/null 2>&1 \
      && ok "cache lists open PRs ($(jq '.open | length' "$cfile"))" || bad "cache lists open PRs" ""
    jq -e '.base | length > 0' "$cfile" >/dev/null 2>&1 \
      && ok "base branch detected ($(jq -r .base "$cfile"))" || bad "base branch detected" ""
    jq -e '.by_file | type == "object"' "$cfile" >/dev/null 2>&1 \
      && ok "by_file index present (guard depends on it)" || bad "by_file index present" ""
    if jq -e '.open | length > 0' "$cfile" >/dev/null 2>&1; then
      jq -e '[.open[] | select(has("files"))] | length > 0' "$cfile" >/dev/null 2>&1 \
        && ok "open PRs carry their file lists" || bad "open PRs carry file lists" ""
    else
      skip "open PRs carry their file lists" "the repo has no open PRs"
    fi
  else
    bad "cache.json written and is valid JSON" "no parseable cache at $cfile"
  fi

  echo "$out" | grep -q 'WHAT IS OPEN' && ok "digest has an open-PR section" \
    || bad "digest has an open-PR section" "got: ${out:0:200}"
  echo "$out" | tail -1 | grep -q 'scan.sh" --refresh' && ok "digest ends with the exact refresh command" \
    || bad "digest ends with the refresh command" "got: $(echo "$out" | tail -1)"

  # A '!!' header with no rows under it means a jq expression died silently.
  # Printing a heading over nothing is worse than printing nothing at all.
  empty_hdr="$(printf '%s\n' "$out" | awk '
    /^!!/ { if (hdr != "" && rows == 0) print hdr; hdr = $0; rows = 0; next }
    /^ +[^ ]/ { if (hdr != "") rows++ }
    END { if (hdr != "" && rows == 0) print hdr }')"
  [ -z "$empty_hdr" ] && ok "no section header is left empty" \
    || bad "no section header is left empty" "empty: $empty_hdr"

  # Blurbs go into context on every session; keep them from running away.
  long="$(printf '%s\n' "$out" | sed '$d' | awk 'length > 200 { c++ } END { print c+0 }')"
  [ "$long" -eq 0 ] && ok "no digest line exceeds 200 chars" \
    || bad "no digest line exceeds 200 chars" "$long over-long lines"

  printf '%s\n' "$out" | grep -q '\*\*' \
    && bad "blurbs are stripped of markdown" "found ** in digest" \
    || ok "blurbs are stripped of markdown"

  # The cached path must work with no network at all: gh taken off PATH.
  out2="$(cd "$LIVE_REPO" && PATH="$TMPROOT/bin-nogh" EMSK_PR_HOME="$LCACHE" "$SH" "$SCAN" 2>&1)"; rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out2" | grep -q 'WHAT IS OPEN' && ok "warm cache serves a digest with gh unavailable" \
    || bad "warm cache serves a digest offline" "rc=$rc out=<${out2:0:200}>"

  # A stale cache is still better than nothing when gh cannot be used.
  out3="$(cd "$LIVE_REPO" && PATH="$TMPROOT/bin-nogh" EMSK_PR_TTL=0 EMSK_PR_HOME="$LCACHE" "$SH" "$SCAN" 2>&1)"; rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out3" | grep -q 'WHAT IS OPEN' && ok "stale cache still served when gh is unavailable" \
    || bad "stale cache served when gh is unavailable" "rc=$rc out=<${out3:0:200}>"

  start=$(date +%s)
  (cd "$LIVE_REPO" && PATH="$TMPROOT/bin-nogh" EMSK_PR_HOME="$LCACHE" "$SH" "$SCAN" >/dev/null 2>&1)
  warm=$(( $(date +%s) - start ))
  [ $warm -le 2 ] && ok "warm read is ${warm}s (budget 2s)" \
    || bad "warm read is fast" "took ${warm}s"
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
