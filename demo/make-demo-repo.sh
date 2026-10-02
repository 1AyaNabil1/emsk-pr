#!/usr/bin/env bash
# Builds a throwaway repo and a fake `gh` for recording the README demo.
# Nothing touches GitHub: the "remote" is a name, PR data is canned JSON, and
# PR heads are local commits, as after emsk-pr's own ref-less fetch.
#
#   bash demo/make-demo-repo.sh [dir]      # default: /tmp/emsk-pr-demo
#
# It prints the command that starts Claude Code inside the demo.
set -euo pipefail

DEMO="${1:-/tmp/emsk-pr-demo}"
rm -rf "$DEMO" && mkdir -p "$DEMO/bin" "$DEMO/fake" "$DEMO/cache"
R="$DEMO/shop"
git init -q "$R" && cd "$R"
git config user.name "you" && git config user.email "you@example.com"
git remote add origin git@github.com:acme/shop.git
mkdir -p shop

# main, when you cut your branch
cat > shop/cart.py <<'PY'
def _legacy_cart_key(cart):
    return cart["id"]


def format_price(amount):
    return f"${amount:,.2f}"


def apply_discount(cart):
    total = sum(item["price"] for item in cart["items"])
    return total
PY
printf 'test:\n\tpython -m pytest -q\n' > Makefile
git add -A && git commit -qm "Initial shop" && git branch -M main

# PR #9 by dev-c, merged into main after your branch point: format_price moves
# to shop/money.py, the legacy key goes, compute_totals arrives.
git checkout -qb landed
cat > shop/money.py <<'PY'
def format_price(amount, currency="USD"):
    symbol = {"USD": "$", "EGP": "E£"}.get(currency, "")
    return f"{symbol}{amount:,.2f}"
PY
cat > shop/cart.py <<'PY'
def compute_totals(cart):
    return sum(item["price"] * item.get("qty", 1) for item in cart["items"])


def apply_discount(cart):
    total = sum(item["price"] for item in cart["items"])
    return total
PY
git add -A && git commit -qm "Move money helpers to shop/money.py"
LANDED="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$LANDED"
git checkout -q main && git branch -qD landed

# PR #11 by dev-b, still open: rewrites apply_discount, the function you are
# about to change.
git checkout -qb pr-11
cat > shop/cart.py <<'PY'
def _legacy_cart_key(cart):
    return cart["id"]


def format_price(amount):
    return f"${amount:,.2f}"


def apply_discount(cart, code=None):
    total = sum(item["price"] for item in cart["items"])
    if code == "WELCOME10":
        total *= 0.9
    return round(total, 2)
PY
git commit -qam "Coupon codes in apply_discount"
PR11="$(git rev-parse HEAD)"
git checkout -q main && git branch -qD pr-11

# Your branch, with one commit of your own: it documents apply_discount, the
# function PR #11 rewrites, in the file PR #9 changed on main.
git checkout -qb feat/student-discount
printf '# Shop\n\nStudent discount: 15%% off with a valid student ID.\n' > README.md
cat > shop/cart.py <<'PY'
def _legacy_cart_key(cart):
    return cart["id"]


def format_price(amount):
    return f"${amount:,.2f}"


def apply_discount(cart):
    """Cart total. Students will get 15% off (see README)."""
    total = sum(item["price"] for item in cart["items"])
    return total
PY
git add -A && git commit -qm "Document the student discount"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$DEMO/fake/open.json" <<JSON
[
 {"number": 10, "title": "Student discount", "author": {"login": "you", "is_bot": false}, "isDraft": true,
  "baseRefName": "main", "headRefName": "feat/student-discount", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "15% off for students.", "files": [{"path": "README.md"}, {"path": "shop/cart.py"}]},
 {"number": 11, "title": "Coupon codes at checkout", "author": {"login": "dev-b", "is_bot": false}, "isDraft": false,
  "baseRefName": "main", "headRefName": "coupons", "headRefOid": "$PR11", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "Adds WELCOME10 to apply_discount.", "files": [{"path": "shop/cart.py"}]},
 {"number": 12, "title": "Bump pytest from 8.3 to 8.4", "author": {"login": "dependabot", "is_bot": true}, "isDraft": false,
  "baseRefName": "main", "headRefName": "dependabot/pip/pytest", "headRepositoryOwner": {"login": "acme"},
  "updatedAt": "$NOW", "url": "", "body": "", "files": [{"path": "requirements.txt"}]}
]
JSON
cat > "$DEMO/fake/merged.json" <<JSON
[{"number": 9, "title": "Move money helpers to shop/money.py", "author": {"login": "dev-c"}, "baseRefName": "main",
  "mergedAt": "$NOW", "mergeCommit": {"oid": "$LANDED"}, "url": "", "files": [], "changedFiles": 2}]
JSON
printf '%s\n' "$PR11" > "$DEMO/fake/head-11"

cat > "$DEMO/bin/gh" <<'SH'
#!/bin/sh
# Fake gh: answers what emsk-pr asks, plus `gh pr diff N` for Claude.
case "$1 $2" in
  "auth token"|"auth status") exit 0 ;;
  "pr list")
    case "$*" in
      *"--state open"*)   cat "$EMSK_PR_FAKE/open.json" ;;
      *"--state merged"*) cat "$EMSK_PR_FAKE/merged.json" ;;
    esac ;;
  "pr diff")
    head="$(cat "$EMSK_PR_FAKE/head-$3" 2>/dev/null)" || { echo "no such PR: $3" >&2; exit 1; }
    shift 3; [ "${1:-}" = "--" ] && shift
    git diff "$(git merge-base main "$head")" "$head" -- "$@" ;;
  "pr view")
    jq -r --argjson n "$3" '.[] | select(.number == $n)
      | "#\(.number) \(.title)\nauthor: @\(.author.login)\nbase: \(.baseRefName)\n\n\(.body // "")"' \
      "$EMSK_PR_FAKE/open.json" "$EMSK_PR_FAKE/merged.json" | grep . || { echo "no such PR: $3" >&2; exit 1; } ;;
  *) echo "gh (demo): not available offline: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$DEMO/bin/gh"

cat > "$DEMO/start.sh" <<SH
#!/bin/sh
cd "$R"
export PATH="$DEMO/bin:\$PATH" EMSK_PR_FAKE="$DEMO/fake" EMSK_PR_HOME="$DEMO/cache" GIT_SSH_COMMAND=false
exec claude "\$@"
SH
chmod +x "$DEMO/start.sh"

echo "Demo repo ready: $R (branch feat/student-discount)"
echo "Start Claude Code in it with:  $DEMO/start.sh"
