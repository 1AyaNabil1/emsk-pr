#!/usr/bin/env bash
# Tests for emsk-pr. Run from the repo root: bash tests/test.sh
#
# These assert behaviour by executing the scripts, not by reading them. The
# network tests run against a live GitHub repo — $EMSK_PR_TEST_REPO, else the
# repo you run this from — and skip when gh is not logged in. The safety tests
# (which must be silent everywhere) always run.
#
#   /bin/bash tests/test.sh   everything under macOS's bash 3.2: the harness and the scripts
#
# The scripts run under the same bash as this file, unless EMSK_PR_TEST_SHELL says otherwise.

# ok() always succeeds, so `check && ok || bad` never runs both.
# shellcheck disable=SC2015

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../skills/emsk-pr"
SCAN="$SKILL/scan.sh"
GUARD="$SKILL/guard.sh"
SH="${EMSK_PR_TEST_SHELL:-$BASH}"

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
BASE_TOOLS=(bash git dirname tr sed awk date stat cat head sort comm cut grep wc sleep mkdir rmdir mktemp rm mv cp env ssh)
mkbin "$TMPROOT/bin-nojq" "${BASE_TOOLS[@]}"
mkbin "$TMPROOT/bin-nogh" "${BASE_TOOLS[@]}" jq

# A repo with the given remotes: mkrepo <dir> <name>=<url> ...
mkrepo() {
  local dir="$1" spec; shift
  mkdir -p "$dir" && git -C "$dir" init -q 2>/dev/null
  for spec in "$@"; do git -C "$dir" remote add "${spec%%=*}" "${spec#*=}"; done
}
cache_path() { (cd "$1" && EMSK_PR_HOME="$TMPROOT/cache" "$SH" "$SCAN" --cache-path 2>&1); }
# --extract-symbols answers per file; most checks only care about the names.
flat() { jq -c '{added: [.[].added[]], removed: [.[].removed[]], changed: [.[].changed[]], moved: [.[].moved[]]}'; }

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
case "$p" in */acme/shop/*) ok "https remote -> acme/shop" ;; *) bad "https remote -> acme/shop" "got: $p" ;; esac

mkrepo "$TMPROOT/scp" origin=git@github.com:acme/shop.git
p="$(cache_path "$TMPROOT/scp")"
case "$p" in */acme/shop/*) ok "scp-style ssh remote -> acme/shop" ;; *) bad "scp-style ssh remote" "got: $p" ;; esac

mkrepo "$TMPROOT/sshurl" origin=ssh://git@ssh.github.com:443/acme/shop
p="$(cache_path "$TMPROOT/sshurl")"
case "$p" in */acme/shop/*) ok "ssh:// remote on ssh.github.com:443 -> acme/shop" ;; *) bad "ssh:// remote with port" "got: $p" ;; esac

mkrepo "$TMPROOT/token" origin=https://x-access-token:ghs_SECRET123@github.com/acme/shop.git
p="$(cache_path "$TMPROOT/token")"
case "$p" in
  *SECRET*|*x-access-token*) bad "credentials in the remote never reach the cache path" "got: $p" ;;
  */acme/shop/*)             ok "credentials in the remote never reach the cache path" ;;
  *)                         bad "token remote -> acme/shop" "got: $p" ;;
esac

mkrepo "$TMPROOT/fork" origin=https://github.com/me/shop.git upstream=https://github.com/acme/shop.git
p="$(cache_path "$TMPROOT/fork")"
case "$p" in */acme/shop/*) ok "fork: PRs are read from upstream, not origin" ;; *) bad "fork reads upstream" "got: $p" ;; esac

git -C "$TMPROOT/fork" config emsk-pr.remote origin
p="$(cache_path "$TMPROOT/fork")"
case "$p" in */me/shop/*) ok "git config emsk-pr.remote overrides the choice" ;; *) bad "emsk-pr.remote override" "got: $p" ;; esac

mkrepo "$TMPROOT/ghe" origin=https://github.acme-corp.com/team/shop.git
p="$(cache_path "$TMPROOT/ghe")"
[ -z "$p" ] && ok "unknown Enterprise host: silent until configured" \
  || bad "unknown Enterprise host: silent" "got: $p"
git -C "$TMPROOT/ghe" config emsk-pr.hosts "github.acme-corp.com"
p="$(cache_path "$TMPROOT/ghe")"
case "$p" in */github.acme-corp.com/team/shop/*) ok "git config emsk-pr.hosts enables an Enterprise host" ;;
  *) bad "emsk-pr.hosts enables an Enterprise host" "got: $p" ;; esac

# Branch names that flatten to the same string must not share a cache, or one
# branch is warned with the other's files.
git -C "$TMPROOT/gh" checkout -q -b feat/x 2>/dev/null
p1="$(cache_path "$TMPROOT/gh")"
git -C "$TMPROOT/gh" checkout -q -b feat-x 2>/dev/null
p2="$(cache_path "$TMPROOT/gh")"
[ -n "$p1" ] && [ "$p1" != "$p2" ] && ok "feat/x and feat-x get separate caches" \
  || bad "feat/x and feat-x get separate caches" "$p1 vs $p2"

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

sym="$(diff_fixture | "$SH" "$SCAN" --extract-symbols 2>/dev/null | flat)"
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

# Fixtures are written to files and fed in, never heredocs inside $( … ):
# bash 3.2 matches parentheses through a heredoc there, and SQL has open ones.
cat > "$TMPROOT/go_ts.diff" <<'DIFF'
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
go_ts="$("$SH" "$SCAN" --extract-symbols < "$TMPROOT/go_ts.diff" 2>/dev/null | flat)"
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
cat > "$TMPROOT/many.diff" <<'DIFF'
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
many="$("$SH" "$SCAN" --extract-symbols < "$TMPROOT/many.diff" 2>/dev/null | flat)"
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
  | "$SH" "$SCAN" --extract-symbols 2>/dev/null | flat)"
echo "$noise" | jq -e '(.added | length) == 0' >/dev/null 2>&1 \
  && ok "commented-out defs, 'defaults' and 'type =' are not symbols" \
  || bad "commented-out defs are not symbols" "got: $noise"

# SQL names sit behind optional keywords, and a policy name is often a
# quoted sentence. Each of these was once misread.
cat > "$TMPROOT/sql.diff" <<'DIFF'
--- a/schema.sql
+++ b/schema.sql
@@
+create table if not exists widgets (
+CREATE POLICY "Users can read own rows" ON widgets
+CREATE UNIQUE INDEX widgets_sku_idx ON widgets (sku);
+create index concurrently if not exists "Big Idx" on widgets (c);
+CREATE OR REPLACE FUNCTION public.touch_updated_at() RETURNS trigger
+create materialized view "public"."daily stats" as
+create index on widgets (b);
DIFF
sql="$("$SH" "$SCAN" --extract-symbols < "$TMPROOT/sql.diff" 2>/dev/null | flat)"
echo "$sql" | jq -e '.added | sort == (["Big Idx", "Users can read own rows", "public.daily stats",
    "public.touch_updated_at", "widgets", "widgets_sku_idx"] | sort)' >/dev/null 2>&1 \
  && ok "SQL: if-not-exists, quoted, unique, concurrently, qualified and unnamed forms" \
  || bad "SQL names" "got: $sql"

# A function that moved to another file still exists: it must not be reported
# as removed, or Claude is told never to call something it should call.
cat > "$TMPROOT/moved.diff" <<'DIFF'
--- a/utils.py
+++ b/utils.py
@@
-def parse_date(s):
-def really_gone(s):
--- a/dates.py
+++ b/dates.py
@@
+def parse_date(s):
DIFF
moved="$("$SH" "$SCAN" --extract-symbols < "$TMPROOT/moved.diff" 2>/dev/null)"
echo "$moved" | jq -e '.["utils.py"].moved == [{name: "parse_date", to: "dates.py"}]
    and .["utils.py"].removed == ["really_gone"]' >/dev/null 2>&1 \
  && ok "a definition moved to another file is 'moved', not 'removed'" \
  || bad "moved definitions" "got: $moved"

# Methods are not paired across files: two unrelated classes each having `run`
# is not a move, and __init__ says nothing at all. Same for Go receivers.
cat > "$TMPROOT/methods.diff" <<'DIFF'
--- a/a.py
+++ b/a.py
@@
-class Old:
-    def __init__(self):
-    def run(self):
--- a/b.py
+++ b/b.py
@@
+class New:
+    def __init__(self):
+    def run(self):
--- a/s.go
+++ b/s.go
@@
-func (s *Store) Close() error {
--- a/t.go
+++ b/t.go
@@
+func (c *Conn) Close() error {
DIFF
meth="$("$SH" "$SCAN" --extract-symbols < "$TMPROOT/methods.diff" 2>/dev/null)"
echo "$meth" | jq -e '.["a.py"].moved == [] and .["a.py"].removed == ["Old", "run"]
    and .["s.go"].moved == [] and .["s.go"].removed == ["Close"]
    and ([.[][] | .[] | strings | select(startswith("__"))] | length == 0)' >/dev/null 2>&1 \
  && ok "same-named methods in unrelated classes are not 'moved'; __init__ is ignored" \
  || bad "methods are not paired across files" "got: $meth"

# A parenthesised value is not an arrow function; a multi-line parameter list is.
cat > "$TMPROOT/arrow.diff" <<'DIFF'
--- a/x.ts
+++ b/x.ts
@@
+const total = (price * qty)
+export const Card = ({
+const load = async (id: string): Promise<void> => {
+const pick = <T,>(xs: T[]) => xs[0]
DIFF
arrow="$("$SH" "$SCAN" --extract-symbols < "$TMPROOT/arrow.diff" 2>/dev/null | flat)"
echo "$arrow" | jq -e '.added == ["Card", "load", "pick"]' >/dev/null 2>&1 \
  && ok "arrow functions found; const total = (price * qty) is not one" \
  || bad "arrow-function detection" "got: $arrow"

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
                        changed: [range(12) | "changed_symbol_number_\(.)"],
                        moved:   [range(6) | {name: "moved_symbol_\(.)", to: "src/some/other/place.py"}]}},
   conflicts: {checked: true, ours: "working-tree",
               base: {status: "conflict", files: {Makefile: {kind: "content", lines: [10, 200, 3000, 4000]}}},
               prs: ([$open[] | {key: (.number | tostring),
                       value: {status: "conflict", files: {Makefile: {kind: "content", lines: [12, 345, 6789]}}}}]
                     | from_entries)},
   base_drift_on_my_files: ["Makefile"]}' > "$GCACHE/many.json"
ctx="$(guard_with Makefile "$GCACHE/many.json" | jq -r '.hookSpecificOutput.additionalContext // ""')"
# Bytes, not characters, so every platform and locale measures the same.
len="$(printf '%s' "$ctx" | LC_ALL=C wc -c | tr -d ' ')"
[ -n "$ctx" ] && [ "$len" -le 1000 ] \
  && ok "warning stays under 1000 bytes with 18 PRs and 42 symbols ($len)" \
  || bad "warning stays under 1000 bytes" "len=$len"
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
# _legacy_cart_key, adds compute_totals and moves format_price to money.py,
# in a file the branch also edits.
E2E="$TMPROOT/e2e"
mkrepo "$E2E" origin=git@github.com:acme/shop.git
git -C "$E2E" config user.name test && git -C "$E2E" config user.email test@example.com
mkdir -p "$E2E/shop"
printf 'def _legacy_cart_key(a):\n    return a\n\ndef apply_discount(cart):\n    pass\n\ndef format_price(p):\n    return p\n' > "$E2E/shop/cart.py"
printf 'all:\n\ttrue\n\nbuild:\n\techo build\n\ntest:\n\techo test\n' > "$E2E/Makefile"
printf 'RATE = 0.14\n\ndef tax(amount):\n    return amount * RATE\n' > "$E2E/shop/tax.py"
printf 'def old_checkout(cart):\n    return cart\n' > "$E2E/shop/legacy.py"
mkdir -p "$E2E/docs" && : > "$E2E/shop/__init__.py" && printf 'notes\n' > "$E2E/docs/notes.md"
git -C "$E2E" add -A && git -C "$E2E" commit -qm base
git -C "$E2E" branch -M main
BASE_OID="$(git -C "$E2E" rev-parse HEAD)"
# PR #9: drops a key, adds a function, moves format_price out, renames
# tax.py and deletes legacy.py, both of which the branch also edits.
git -C "$E2E" checkout -qb landed
printf 'def apply_discount(cart):\n    pass\n\ndef compute_totals(cart):\n    return cart\n' > "$E2E/shop/cart.py"
printf 'def format_price(p):\n    return p\n' > "$E2E/shop/money.py"
git -C "$E2E" mv shop/tax.py shop/taxes.py && git -C "$E2E" rm -q shop/legacy.py
git -C "$E2E" add -A && git -C "$E2E" commit -qm "drop the legacy key, move format_price"
LANDED_OID="$(git -C "$E2E" rev-parse HEAD)"
# Then a direct push, through no PR: notes change, and an empty __init__.py
# goes while another appears, which git reports as a rename.
mkdir -p "$E2E/pkg" && : > "$E2E/pkg/__init__.py" && git -C "$E2E" rm -q shop/__init__.py
printf 'notes, edited\n' > "$E2E/docs/notes.md"
git -C "$E2E" add -A && git -C "$E2E" commit -qm "direct push"
git -C "$E2E" update-ref refs/remotes/origin/main landed
git -C "$E2E" checkout -q main && git -C "$E2E" branch -qD landed
git -C "$E2E" checkout -qb feat/totals
printf 'def _legacy_cart_key(a):\n    return a\n\ndef apply_discount(cart, code=None):\n    pass\n\ndef format_price(p):\n    return p\n' > "$E2E/shop/cart.py"
printf 'all:\n\tfalse\n\nbuild:\n\techo build\n\ntest:\n\techo test\n' > "$E2E/Makefile"
printf 'RATE = 0.15\n\ndef tax(amount):\n    return amount * RATE\n' > "$E2E/shop/tax.py"
printf 'def old_checkout(cart):\n    return list(cart)\n' > "$E2E/shop/legacy.py"
git -C "$E2E" commit -qam "my change"

# Two teammates' PR heads, cut from main. #11 edits the same Makefile line as
# this branch: a real conflict. #14 edits a line further down: same file,
# no conflict. The commits exist locally; no ref points at them, as after a
# ref-less fetch.
pr_head() { # $1 = the Makefile it commits, printf %b escapes allowed
  git -C "$E2E" checkout -q -b pr-tmp main && printf '%b' "$1" > "$E2E/Makefile" \
    && git -C "$E2E" commit -qam pr && git -C "$E2E" rev-parse HEAD \
    && git -C "$E2E" checkout -q feat/totals && git -C "$E2E" branch -qD pr-tmp
}
PR11_OID="$(pr_head 'all:\n\techo all\n\nbuild:\n\techo build\n\ntest:\n\techo test\n')"
PR14_OID="$(pr_head 'all:\n\ttrue\n\nbuild:\n\techo build\n\ntest:\n\techo tests\n')"

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
 {"number": 11, "title": "Build tweaks\u001b\u0007", "author": {"login": "dev-b", "is_bot": false}, "isDraft": true,
  "baseRefName": "main", "headRefName": "build", "headRefOid": "$PR11_OID", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "**Faster** builds.", "files": [{"path": "Makefile"}]},
 {"number": 12, "title": "Bump lodash", "author": {"login": "dependabot", "is_bot": true}, "isDraft": false,
  "baseRefName": "main", "headRefName": "dependabot/npm/lodash", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "", "files": [{"path": "package.json"}]}
]
JSON
# #14 and #15 change more files than GitHub lists (100). #14's Makefile is the
# 101st, served by the REST fake; #15's REST call fails, so it stays partial.
jq --arg oid "$PR14_OID" '. + [range(14; 16) as $n | {number: $n, title: "Huge refactor \($n)", author: {login: "dev-d", is_bot: false},
          isDraft: false, baseRefName: "main", headRefName: "huge-\($n)", headRepositoryOwner: {login: "acme"},
          headRefOid: (if $n == 14 then $oid else null end),
          updatedAt: "2026-01-01T00:00:00Z", url: "", body: "", changedFiles: (if $n == 14 then 101 else 150 end),
          files: [range(100) | {path: "gen/f\(.).txt"}]}]' "$FAKE/open.json" > "$FAKE/o2" && mv "$FAKE/o2" "$FAKE/open.json"
jq -rn 'range(100) | "gen/f\(.).txt"' > "$FAKE/files-14-1"
echo Makefile > "$FAKE/files-14-2"

# Merged PRs, and which of them the digest may report:
#   #9  into main, not in my branch; files come from local git   -> reported
#   #8  into main, but its commit is already in my branch        -> not reported
#   #7  into another branch entirely                             -> not reported
#   #6  into main, commit not local, merged after my branch point -> reported
#   #5  into main, commit not local, merged long before it       -> not reported
#   #4  this branch's own PR, squash-merged; work carried on      -> not reported
cat > "$FAKE/merged.json" <<JSON
[{"number": 9, "title": "Drop the legacy cart key", "author": {"login": "dev-c"}, "baseRefName": "main",
  "mergedAt": "$NOW", "mergeCommit": {"oid": "$LANDED_OID"}, "url": "", "files": [], "changedFiles": 4},
 {"number": 4, "title": "My earlier round", "author": {"login": "me"}, "baseRefName": "main",
  "headRefName": "feat/totals", "headRepositoryOwner": {"login": "acme"},
  "mergedAt": "2099-01-01T00:00:00Z", "mergeCommit": {"oid": "4444444444444444444444444444444444444444"}, "url": "",
  "files": [{"path": "Makefile"}, {"path": "shop/cart.py"}], "changedFiles": 2},
 {"number": 8, "title": "Already in your branch", "author": {"login": "dev-c"}, "baseRefName": "main",
  "mergedAt": "$NOW", "mergeCommit": {"oid": "$BASE_OID"}, "url": "", "files": [{"path": "Makefile"}], "changedFiles": 1},
 {"number": 7, "title": "Release", "author": {"login": "dev-c"}, "baseRefName": "release",
  "mergedAt": "$NOW", "mergeCommit": {"oid": "1111111111111111111111111111111111111111"}, "url": "", "files": [{"path": "Makefile"}], "changedFiles": 1},
 {"number": 6, "title": "Not fetched yet", "author": {"login": "dev-e"}, "baseRefName": "main",
  "mergedAt": "2099-01-01T00:00:00Z", "mergeCommit": {"oid": "2222222222222222222222222222222222222222"}, "url": "", "files": [{"path": "Makefile"}], "changedFiles": 1},
 {"number": 5, "title": "Ancient history", "author": {"login": "dev-e"}, "baseRefName": "main",
  "mergedAt": "2000-01-01T00:00:00Z", "mergeCommit": {"oid": "3333333333333333333333333333333333333333"}, "url": "", "files": [{"path": "Makefile"}], "changedFiles": 1}]
JSON
cat > "$FAKE/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
  "auth token") exit 0 ;;
  "pr list") [ -n "${EMSK_PR_FAKE_FAIL:-}" ] && { echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1; }
    case "$*" in
      *"--state open"*)   cat "$EMSK_PR_FAKE/open.json" ;;
      *"--state merged"*) cat "$EMSK_PR_FAKE/merged.json" ;;
    esac ;;
  "api --hostname")  # repos/<o>/<r>/pulls/<n>/files?per_page=100&page=<p>, already --jq'd
    for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
    n="${path#*/pulls/}"; n="${n%%/*}"; p="${path##*page=}"
    [ -f "$EMSK_PR_FAKE/files-$n-$p" ] && cat "$EMSK_PR_FAKE/files-$n-$p" || exit 1 ;;
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
[ $rc -eq 0 ] && printf '%s' "$digest" | grep -q 'WHAT IS OPEN (6)' \
  && ok "refresh with a fake gh builds a digest" || bad "refresh builds a digest" "rc=$rc out=<$digest>"
# The cache's age drives both the warm-cache path and this footer; a wrong age
# on one platform means every session start refreshes there.
printf '%s' "$digest" | tail -1 | grep -q 'scanned just now' \
  && ok "the cache's age is read correctly on this platform" || bad "cache age" "got: $(printf '%s' "$digest" | tail -1)"
warm="$(cd "$E2E" && PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" EMSK_PR_HOME="$TMPROOT/e2ecache" \
  "$SH" -x "$SCAN" 2>&1 >/dev/null | grep -c 'gh pr list')"
[ "$warm" = 0 ] && ok "a warm cache is served without calling GitHub" || bad "warm cache skips gh" "gh pr list ran $warm times"
printf '%s' "$digest" | grep -q 'base origin/main' \
  && ok "base taken from this branch's own PR, not the stranger's" || bad "base from own PR" "$(printf '%s' "$digest" | head -1)"
# The lines under one '!!' header, up to the next header or the footer.
section() { printf '%s\n' "$digest" | awk -v h="$1" '/^(!!|WHAT IS OPEN|YOUR STACK|\(emsk-pr)/ { on = (index($0, h) == 1); next } on'; }
# The guard against the e2e repo's cache. EMSK_PR_HOME is pinned too, so a
# missing cache can never send it looking in the real one.
ecache="$(cd "$E2E" && EMSK_PR_HOME="$TMPROOT/e2ecache" "$SH" "$SCAN" --cache-path)"
guard_e2e() {
  printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/%s"}}' "$E2E" "$E2E" "$1" \
  | EMSK_PR_HOME="$TMPROOT/e2ecache" EMSK_PR_CACHE_FILE="$ecache" "$SH" "$GUARD" 2>&1 \
  | jq -r '.hookSpecificOutput.additionalContext // ""'
}
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
printf '%s' "$landed" | grep -q '> moved   format_price -> shop/money.py' \
  && ! printf '%s' "$landed" | grep -- '- removed' | grep -q format_price \
  && ok "a function moved to a file the branch does not touch is 'moved', not 'removed'" \
  || bad "moved across files in a real range" "got: $landed"
merged_sec="$(section '!! MERGED INTO main AFTER YOUR BRANCH POINT')"
printf '%s' "$merged_sec" | grep -q '#9 ' && printf '%s' "$merged_sec" | grep -q 'shop/cart.py' \
  && printf '%s' "$merged_sec" | grep -q 'shop/tax.py' \
  && ok "merged PR not in the branch is listed, its files (old rename paths too) read from local git" \
  || bad "merged PR #9 listed with git-derived files" "got: $merged_sec"
! printf '%s' "$merged_sec" | grep -q '#4 ' \
  && ok "this branch's own merged PR is not a collision" || bad "own merged PR" "got: $merged_sec"
printf '%s' "$landed" | grep -q 'shop/tax.py  (renamed to shop/taxes.py on the base: edit that, not this)' \
  && printf '%s' "$landed" | grep -q 'shop/legacy.py  (deleted on the base)' \
  && ok "a file the base renamed or deleted is listed under its old path, with what happened" \
  || bad "renamed / deleted on base" "got: $landed"
ecache0="$(cd "$E2E" && EMSK_PR_HOME="$TMPROOT/e2ecache" "$SH" "$SCAN" --cache-path)"
jq -e '.base_gone["shop/__init__.py"] == "deleted"' "$ecache0" >/dev/null 2>&1 \
  && ok "an empty file git pairs as a 'rename' is reported as deleted" \
  || bad "empty-file rename" "got: $(jq -c .base_gone "$ecache0")"
! printf '%s' "$digest" | LC_ALL=C grep -q "$(printf '\033')" \
  && ok "control characters in PR titles never reach the digest" || bad "control characters stripped" ""
jq -e '[.open[] | has("body")] | any | not' "$ecache0" >/dev/null 2>&1 \
  && ok "full PR descriptions are not kept in the cache" || bad "body dropped from cache" ""
! printf '%s' "$merged_sec" | grep -q '#8 ' \
  && ok "a merged PR already in the branch is not reported" || bad "#8 already in branch" "got: $merged_sec"
! printf '%s' "$merged_sec" | grep -q '#7 ' \
  && ok "a PR merged into another branch is not reported" || bad "#7 other base" "got: $merged_sec"
printf '%s' "$merged_sec" | grep -q '#6 ' && ! printf '%s' "$merged_sec" | grep -q '#5 ' \
  && ok "commit not local: merge date decides, against the branch point" \
  || bad "date fallback for non-local commits" "got: $merged_sec"
section '!! OPEN PRs THAT TOUCH YOUR FILES' | grep -q '#14 ' \
  && ok "a file past GitHub's 100-file cap is found through the REST list" \
  || bad "REST file list past 100" "got: $(section '!! OPEN PRs THAT TOUCH YOUR FILES')"
printf '%s' "$digest" | grep -q 'file lists incomplete for #15' \
  && ok "a PR whose full file list could not be read is flagged" || bad "partial PR flagged" "got: $digest"

# Trial merges. The base deleted legacy.py and rewrote the top of cart.py, both
# of which this branch edits; #11 edits this branch's Makefile line, #14 a
# different one; #13's head cannot be fetched.
base_cf="$(section '!! YOUR WORK ALREADY CONFLICTS WITH origin/main')"
printf '%s' "$base_cf" | grep -q 'shop/legacy.py \[modify/delete\]' \
  && printf '%s' "$base_cf" | grep -q 'shop/cart.py (~line' \
  && ok "conflicts with the base are found, with where and what kind" \
  || bad "conflicts with the base" "got: $base_cf"
! printf '%s' "$base_cf" | grep -q 'shop/tax.py' \
  && ok "an edit to a file the base renamed carries over: no conflict" || bad "rename merges cleanly" "got: $base_cf"
touch_open="$(section '!! OPEN PRs THAT TOUCH YOUR FILES')"
printf '%s' "$touch_open" | grep -A2 '^  #11 ' | grep -q 'CONFLICTS with your last commit: Makefile (~line 2)' \
  && ok "an open PR editing the same lines is a CONFLICT, with the line" \
  || bad "PR conflict found" "got: $touch_open"
printf '%s' "$touch_open" | grep -A2 '^  #14 ' | grep -q 'merges cleanly with your last commit' \
  && ok "an open PR editing other lines of the same file merges cleanly" \
  || bad "PR clean merge" "got: $touch_open"
printf '%s' "$touch_open" | grep -A2 '^  #13 ' | grep -q 'not checked for conflicts: its head commit could not be fetched' \
  && ok "a PR whose head cannot be fetched says it was not checked" || bad "unchecked PR" "got: $touch_open"
[ "$(printf '%s\n' "$touch_open" | grep -m1 '^  #' | cut -d' ' -f3)" = "#11" ] \
  && ok "conflicting PRs are listed first" || bad "conflicts first" "got: $touch_open"
ctx="$(guard_e2e Makefile)"
printf '%s' "$ctx" | head -1 | grep -q 'has merge CONFLICTS' \
  && printf '%s' "$ctx" | grep -q 'Trial merge with your last commit: CONFLICTS with #11 (~line 2); merges cleanly: #14' \
  && printf '%s' "$ctx" | grep -q 'gh pr diff 11 -- Makefile' \
  && ok "guard leads with the conflict and points at the PR that causes it" \
  || bad "guard conflict lines" "got: $ctx"
ctx="$(guard_e2e shop/legacy.py)"
printf '%s' "$ctx" | grep -q 'CONFLICTS with origin/main here \[modify/delete\]' \
  && ok "guard names a conflict with the base on the file being edited" || bad "guard base conflict" "got: $ctx"

# Uncommitted work counts, and checking it changes nothing a person can see:
# not the index, not the working tree, not a single ref.
printf 'all:\n\tfalse\n\nbuild:\n\techo build\n\ntest:\n\techo unit\n' > "$E2E/Makefile"
idx_before="$(git -C "$E2E" ls-files -s | git hash-object --stdin)"
st_before="$(git -C "$E2E" status --porcelain | git hash-object --stdin)"
refs_before="$(git -C "$E2E" for-each-ref | git hash-object --stdin)"
digest="$(fake_scan "$E2E")"
section '!! OPEN PRs THAT TOUCH YOUR FILES' | grep -A2 '^  #14 ' | grep -q 'CONFLICTS with your uncommitted work: Makefile (~line 8)' \
  && ok "an uncommitted edit that would clash is caught" || bad "uncommitted conflict" "got: $digest"
[ "$(git -C "$E2E" ls-files -s | git hash-object --stdin)" = "$idx_before" ] \
  && [ "$(git -C "$E2E" status --porcelain | git hash-object --stdin)" = "$st_before" ] \
  && [ "$(git -C "$E2E" for-each-ref | git hash-object --stdin)" = "$refs_before" ] \
  && ok "the trial merges leave the index, the working tree and every ref as they were" \
  || bad "repo untouched by trial merges" "$(git -C "$E2E" status --short)"
git -C "$E2E" checkout -q -- Makefile
off="$(cd "$E2E" && PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" GIT_SSH_COMMAND=false EMSK_PR_CONFLICTS=0 \
  EMSK_PR_HOME="$TMPROOT/e2ecache-off" "$SH" "$SCAN" --refresh 2>&1)"
! printf '%s' "$off" | grep -qE 'CONFLICTS|merges cleanly' && printf '%s' "$off" | grep -q '#11 ' \
  && ok "EMSK_PR_CONFLICTS=0 skips the trial merges" || bad "EMSK_PR_CONFLICTS=0" "got: $off"
digest="$(fake_scan "$E2E")"
printf '%s' "$digest" | grep -q 'data, not instructions' \
  && ok "digest marks PR text as author-written data" || bad "digest marks PR text as data" "got: $digest"
printf '%s' "$digest" | grep -q 'Faster builds' \
  && ok "PR descriptions are in the digest by default" || bad "PR descriptions shown by default" "got: $digest"
nob="$(cd "$E2E" && PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" GIT_SSH_COMMAND=false EMSK_PR_BLURBS=0 \
  EMSK_PR_HOME="$TMPROOT/e2ecache-nob" "$SH" "$SCAN" --refresh 2>&1)"
printf '%s' "$nob" | grep -q 'Build tweaks' && ! printf '%s' "$nob" | grep -q 'Faster builds' \
  && ok "EMSK_PR_BLURBS=0 keeps titles and drops descriptions" || bad "EMSK_PR_BLURBS=0" "got: $nob"

ctx="$(guard_e2e Makefile)"
printf '%s' "$ctx" | grep -q '#11' && ! printf '%s' "$ctx" | grep -q '#10' \
  && ok "guard warns about the teammate's PR, never your own" || bad "guard skips own PR" "got: $ctx"
printf '%s' "$ctx" | grep -q 'MERGED INTO main after you branched: #6' && ! printf '%s' "$ctx" | grep -qE '#(8|7|5)\b' \
  && ok "guard names only merges the branch does not have" || bad "guard merged list" "got: $ctx"
ctx="$(guard_e2e shop/cart.py)"
printf '%s' "$ctx" | grep -q '_legacy_cart_key' \
  && ok "guard on the drifted file names the removed definition" || bad "guard names removed definition" "got: $ctx"
printf '%s' "$ctx" | grep -q 'MOVED on main: format_price -> shop/money.py' \
  && ok "guard says where a moved definition went" || bad "guard moved line" "got: $ctx"
ctx="$(guard_e2e shop/tax.py)"
printf '%s' "$ctx" | grep -q 'Renamed to shop/taxes.py on origin/main since you branched: edit that file' \
  && ok "guard on a file the base renamed points at the new name" || bad "guard renamed file" "got: $ctx"
ctx="$(guard_e2e shop/legacy.py)"
printf '%s' "$ctx" | grep -q 'Deleted on origin/main' \
  && ok "guard on a file the base deleted says so" || bad "guard deleted file" "got: $ctx"
# docs/notes.md changed on the base through no PR, and this branch had not
# touched it when the scan ran.
ctx="$(guard_e2e docs/notes.md)"
printf '%s' "$ctx" | grep -q 'Changed on origin/main since you branched' \
  && ok "guard warns on a drifted file first edited after the scan" || bad "guard full drift" "got: $ctx"

# When GitHub refuses, the stale digest comes with gh's own reason, not a guess.
fail="$(cd "$E2E" && PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" EMSK_PR_FAKE_FAIL=1 GIT_SSH_COMMAND=false \
  EMSK_PR_HOME="$TMPROOT/e2ecache" "$SH" "$SCAN" --refresh 2>&1)"
printf '%s' "$fail" | head -1 | grep -q 'could not refresh the PR digest: gh pr list failed: HTTP 401: Bad credentials' \
  && printf '%s' "$fail" | grep -q 'WHAT IS OPEN' \
  && ok "a failed refresh names gh's reason and still serves the last digest" \
  || bad "failed refresh reason" "got: $(printf '%s' "$fail" | head -2)"
leftover=""
for f in "${ecache0%/*}"/*.tmp; do [ -e "$f" ] && leftover="$f"; done
[ -z "$leftover" ] && ok "no temporary files left next to the cache" \
  || bad "no temporary files left next to the cache" "found $leftover"

# A long session: the scan is old by the time of this edit. The guard answers
# at once from the old scan, says so, and starts a refresh in the background.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
touch -t 202001010000 "$ecache"
old="$(mtime "$ecache")"
ctx="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/Makefile"}}' "$E2E" "$E2E" \
  | PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" GIT_SSH_COMMAND=false EMSK_PR_HOME="$TMPROOT/e2ecache" \
    "$SH" "$GUARD" 2>&1 | jq -r '.hookSpecificOutput.additionalContext // ""')"
printf '%s' "$ctx" | grep -q 'a refresh has started' \
  && ok "stale scan: the warning says how old it is" || bad "stale scan noted" "got: $ctx"
i=0; while [ "$(mtime "$ecache")" = "$old" ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(mtime "$ecache")" != "$old" ] \
  && ok "stale scan: the guard refreshed the cache in the background" || bad "background refresh" "cache unchanged"
i=0; while [ -d "${ecache%/*}/refresh.lock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -d "${ecache%/*}/refresh.lock" ] && ok "stale scan: the refresh lock is released" || bad "refresh lock released" ""

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

# A branch checked out mid-session has no scan yet. The first edit on it says
# nothing, and leaves a scan started for the next one.
git -C "$E2E" checkout -qb feat/later
newcache="$(cd "$E2E" && EMSK_PR_HOME="$TMPROOT/e2ecache" "$SH" "$SCAN" --cache-path)"
out="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/Makefile"}}' "$E2E" "$E2E" \
  | PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$FAKE" GIT_SSH_COMMAND=false EMSK_PR_HOME="$TMPROOT/e2ecache" \
    "$SH" "$GUARD" 2>&1)"; rc=$?
[ -z "$out" ] && [ $rc -eq 0 ] && ok "new branch, no scan yet: the first edit is silent" \
  || bad "new branch: first edit silent" "rc=$rc out=<$out>"
i=0; while [ ! -f "$newcache" ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$newcache" ] && ok "new branch: the guard started its first scan in the background" \
  || bad "new branch: background scan" "no cache at $newcache"

echo
echo "== stacked PRs (fake gh, no network) =="

# A three-PR stack onto staging, all mine: #21 feat/a -> staging, #22 feat/b ->
# feat/a, #23 feat/c -> feat/b. feat/a has moved on since feat/b was cut, and
# its new commit touches a line feat/b also changed. Two teammates: #24 on
# staging, and #25 aimed at a release branch whose own history changes a line
# feat/b changes too; #25 itself only touches a line nobody else does.
STK="$TMPROOT/stack"
mkrepo "$STK" origin=git@github.com:acme/shop.git
git -C "$STK" config user.name test && git -C "$STK" config user.email test@example.com
app() { printf 'a = %s\nb = 2\nc = %s\nd = %s\ne = 5\nf = %s\ng = 7\nh = %s\n' "$@" > "$STK/app.py"; }
commit_as() { git -C "$STK" commit -qam "$1" && git -C "$STK" rev-parse HEAD; }
app 1 3 4 6 8; git -C "$STK" add -A && git -C "$STK" commit -qm base && git -C "$STK" branch -M staging
git -C "$STK" checkout -qb feat/a; app 10 3 4 6 8;    A1="$(commit_as "A: a")"
git -C "$STK" checkout -qb feat/b; app 100 30 4 6 8;  B1="$(commit_as "B: a, c")"
git -C "$STK" checkout -qb feat/c; app 100 30 40 6 8; C1="$(commit_as "C: d")"
git -C "$STK" checkout -q feat/a;  app 10 33 4 6 8;   A2="$(commit_as "A: c, after B was cut")"
git -C "$STK" checkout -qb mate staging; app 1 3 4 6 80; M1="$(commit_as "mate: h")"
git -C "$STK" checkout -qb release staging; app 1 99 4 6 8; commit_as "release: c" >/dev/null
git -C "$STK" checkout -qb r25 release; app 1 99 4 60 8; R25="$(commit_as "#25: f")"
for b in staging feat/a feat/b feat/c release; do git -C "$STK" update-ref "refs/remotes/origin/$b" "$b"; done
git -C "$STK" checkout -q feat/b && git -C "$STK" branch -qD mate r25

SFAKE="$TMPROOT/stackgh"; mkdir -p "$SFAKE"
pr() { # number title base head oid author
  printf '{"number": %s, "title": "%s", "author": {"login": "%s", "is_bot": false}, "isDraft": false,
    "baseRefName": "%s", "headRefName": "%s", "headRefOid": "%s", "headRepositoryOwner": {"login": "acme"},
    "updatedAt": "2026-10-08T00:00:00Z", "url": "", "body": "", "files": [{"path": "app.py"}], "changedFiles": 1}' \
    "$1" "$2" "$6" "$3" "$4" "$5"
}
{ echo '['; pr 21 "A" staging feat/a "$A2" me; echo ','; pr 22 "B" feat/a feat/b "$B1" me; echo ',';
  pr 23 "C" feat/b feat/c "$C1" me; echo ','; pr 24 "Mate on h" staging mate "$M1" mate; echo ',';
  pr 25 "Release fix on f" release r25 "$R25" mate2; echo ']'; } > "$SFAKE/open.json"
echo '[]' > "$SFAKE/merged.json"
stack_scan() {
  (cd "$STK" && PATH="$TMPROOT/bin-fake" EMSK_PR_FAKE="$SFAKE" GIT_SSH_COMMAND=false \
     EMSK_PR_HOME="$TMPROOT/stackcache" "$SH" "$SCAN" --refresh 2>&1)
}

digest="$(stack_scan)"
printf '%s' "$digest" | head -1 | grep -q 'branch feat/b · base origin/staging' \
  && ok "a stacked branch is compared with the bottom PR's target, not its parent" \
  || bad "stack base is the root target" "got: $(printf '%s' "$digest" | head -1)"
stk="$(section 'YOUR STACK')"
printf '%s' "$stk" | grep -q '#21  feat/a -> staging  (under this branch)' \
  && printf '%s' "$stk" | grep -q '#22  feat/b  (this branch)' \
  && printf '%s' "$stk" | grep -q '#23  feat/c  (built on this branch)' \
  && ok "the stack is listed bottom first: under, this branch, built on it" || bad "stack listing" "got: $stk"
touch_open="$(section '!! OPEN PRs THAT TOUCH YOUR FILES')"
! printf '%s' "$touch_open" | grep -qE '#2[123] ' \
  && ok "PRs in my own stack are never collisions" || bad "stack PRs not collisions" "got: $touch_open"
printf '%s' "$stk" | grep -q '#21 (feat/a) has 1 commit you do not have: rebase onto it. They CONFLICT with your last commit: app.py (~line 3)' \
  && ok "a parent that moved on is reported, with the conflict its new commit brings" \
  || bad "parent behind + conflict" "got: $stk"
printf '%s' "$touch_open" | grep -A2 '^  #24 ' | grep -q 'merges cleanly' \
  && ok "a teammate on the stack's target is still checked" || bad "teammate on staging" "got: $touch_open"
printf '%s' "$touch_open" | grep -A2 '^  #25 ' | grep -q 'merges cleanly' \
  && ok "a PR aimed at another branch is judged by its own changes, not the gap between branches" \
  || bad "cross-branch PR" "got: $touch_open"
# With a git too old to choose the merge base, it says so rather than guess.
# Every tool but git is linked in; git is a new file of its own. Writing to a
# link instead would write through it into the real git.
mkdir -p "$TMPROOT/bin-oldgit"
for t in "$TMPROOT/bin-fake"/*; do
  [ "${t##*/}" = git ] || ln -sf "$(readlink "$t")" "$TMPROOT/bin-oldgit/${t##*/}"
done
real_git="$(readlink "$TMPROOT/bin-fake/git")"
rm -f "$TMPROOT/bin-oldgit/git"
# shellcheck disable=SC2016  # $1 and $@ belong to the wrapper, not this shell
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "git version 2.39.5"; exit 0; }\nexec "%s" "$@"\n' "$real_git" \
  > "$TMPROOT/bin-oldgit/git" && chmod +x "$TMPROOT/bin-oldgit/git"
old="$(cd "$STK" && PATH="$TMPROOT/bin-oldgit" EMSK_PR_FAKE="$SFAKE" GIT_SSH_COMMAND=false \
  EMSK_PR_HOME="$TMPROOT/stackcache-old" "$SH" "$SCAN" --refresh 2>&1)"
printf '%s\n' "$old" | grep -A2 '^  #25 ' | grep -q 'not checked for conflicts: it targets release, and comparing across branches needs git 2.40' \
  && printf '%s\n' "$old" | grep -A2 '^  #24 ' | grep -q 'merges cleanly' \
  && ok "with git 2.39, a PR aimed at another branch is marked unchecked, the rest still checked" \
  || bad "cross-branch PR on old git" "got: $old"

# An uncommitted edit to a line feat/c changes: rebasing #23 will now conflict.
app 100 30 44 6 8
digest="$(stack_scan)"
section 'YOUR STACK' | grep -q '!! rebasing #23 onto your uncommitted work will CONFLICT: app.py (~line 4)' \
  && ok "work that would make the PR built on this branch conflict is caught" || bad "child restack conflict" "got: $(section 'YOUR STACK')"
scache="$(cd "$STK" && EMSK_PR_HOME="$TMPROOT/stackcache" "$SH" "$SCAN" --cache-path)"
ctx="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/app.py"}}' "$STK" "$STK" \
  | EMSK_PR_HOME="$TMPROOT/stackcache" EMSK_PR_CACHE_FILE="$scache" "$SH" "$GUARD" 2>&1 \
  | jq -r '.hookSpecificOutput.additionalContext // ""')"
printf '%s' "$ctx" | grep -q 'Rebasing #23, built on this branch, will CONFLICT here (~line 4)' \
  && printf '%s' "$ctx" | grep -q 'Your stack parent #21 has new commits that CONFLICT here (~line 3)' \
  && ! printf '%s' "$ctx" | grep -q 'OPEN: .*#2[123]' \
  && ok "the guard names rebases within the stack, and no stack PR as a collision" \
  || bad "guard on a stacked branch" "got: $ctx"
git -C "$STK" checkout -q -- app.py

# From the bottom: what is built on it is mine too, and its rebase is foreseen.
git -C "$STK" checkout -q feat/a
digest="$(stack_scan)"
stk="$(section 'YOUR STACK')"
printf '%s' "$stk" | grep -q '#22  feat/b  (built on this branch)' && printf '%s' "$stk" | grep -q '#23  feat/c  (built on this branch)' \
  && printf '%s' "$stk" | grep -q '!! rebasing #22 onto your last commit will CONFLICT: app.py (~line 3)' \
  && ! section '!! OPEN PRs THAT TOUCH YOUR FILES' | grep -qE '#2[23] ' \
  && ok "the bottom of a stack lists what is built on it, and the rebase it now needs" \
  || bad "bottom of the stack" "got: $digest"

# A branch with no PR yet, cut from feat/b: its stack is found from its commits.
git -C "$STK" checkout -q -b feat/d feat/b; app 100 30 4 6 8; printf 'e2 = 50\n' >> "$STK/app.py"; commit_as "D" >/dev/null
digest="$(stack_scan)"
printf '%s' "$digest" | grep -q 'this branch has no PR yet; its stack was found from its commits' \
  && section 'YOUR STACK' | grep -q '#22  feat/b -> feat/a  (under this branch)' \
  && printf '%s' "$digest" | head -1 | grep -q 'base origin/staging' \
  && ok "a branch with no PR is placed in its stack by its commits" || bad "inferred stack" "got: $digest"
# #23 is built on feat/b too: beside this branch. It is still checked, from
# feat/b where both start, so it neither hides nor gets blamed for feat/b.
printf '%s' "$digest" | grep -q '#23 (built on your stack)  C' \
  && section '!! OPEN PRs THAT TOUCH YOUR FILES' | grep -A2 '^  #23 ' | grep -q 'merges cleanly' \
  && ! section '!! OPEN PRs THAT TOUCH YOUR FILES' | grep -A3 '^  #23 ' | grep -q 'unsettled' \
  && ok "a PR beside this branch in the stack is labelled and compared from their shared branch" \
  || bad "sibling in the stack" "got: $digest"

# A branch cut from staging, no PR: its base is guessed, and the digest says so.
git -C "$STK" checkout -q -b solo staging; app 1 3 4 6 8; printf 'z = 1\n' >> "$STK/app.py"; commit_as "solo" >/dev/null
digest="$(stack_scan)"
printf '%s' "$digest" | head -1 | grep -q 'base origin/staging' \
  && printf '%s' "$digest" | grep -q 'base guessed from git history; pin it with: git config emsk-pr.base' \
  && ! printf '%s' "$digest" | grep -q 'YOUR STACK' \
  && ok "an unstacked branch with no PR gets staging as a labelled guess, not a PR branch" \
  || bad "guessed base" "got: $(printf '%s' "$digest" | head -3)"

# #21 is squash-merged: staging gets one new commit with its change, GitHub
# retargets #22 to staging, and feat/b still carries #21's original commit.
git -C "$STK" checkout -q -b squash staging; app 10 3 4 6 8; SQ="$(commit_as "Squash of #21")"
git -C "$STK" update-ref refs/remotes/origin/staging "$SQ"; git -C "$STK" checkout -q feat/b; git -C "$STK" branch -qD squash
{ echo '['; pr 22 "B" staging feat/b "$B1" me; echo ','; pr 23 "C" feat/b feat/c "$C1" me; echo ']'; } > "$SFAKE/open.json"
printf '[{"number": 21, "title": "A", "author": {"login": "me"}, "baseRefName": "staging", "headRefName": "feat/a",
  "headRefOid": "%s", "mergedAt": "2099-01-01T00:00:00Z", "mergeCommit": {"oid": "%s"}, "url": "",
  "files": [{"path": "app.py"}], "changedFiles": 1}]' "$A1" "$SQ" > "$SFAKE/merged.json"
digest="$(stack_scan)"
printf '%s' "$digest" | grep -q '#21 (feat/a), which this branch is built on, was merged into staging: rebase onto origin/staging' \
  && ! section '!! MERGED INTO staging AFTER YOUR BRANCH POINT' | grep -q '#21 ' \
  && ok "a squash-merged parent is a rebase to do, not someone else's merge" || bad "absorbed parent" "got: $digest"

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
