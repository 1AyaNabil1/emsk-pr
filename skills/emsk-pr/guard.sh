#!/usr/bin/env bash
# emsk-pr guard: the cheap check that runs before every Edit/Write.
#
# Reads the PreToolUse hook payload on stdin, looks the target file up in the
# cache scan.sh already built, and warns if someone else is touching that same
# file. It never calls the network and never blocks an edit — worst case it
# prints nothing and exits 0.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat 2>/dev/null)" || exit 0
[ -n "$PAYLOAD" ] || exit 0
printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1 || exit 0

FILE="$(printf '%s' "$PAYLOAD" | jq -r '
  .tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -n "$FILE" ] || exit 0

CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

ROOT="${EMSK_PR_REPO_ROOT:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
fi
[ -n "$ROOT" ] || exit 0

CACHE="${EMSK_PR_CACHE_FILE:-}"
if [ -z "$CACHE" ]; then
  CACHE="$(cd "$ROOT" 2>/dev/null && bash "$HERE/scan.sh" --cache-path 2>/dev/null)" || exit 0
fi
[ -n "$CACHE" ] && [ -f "$CACHE" ] || exit 0
jq -e . "$CACHE" >/dev/null 2>&1 || exit 0

# Path as the cache stores it: relative to the repo root. git reports the root
# with symlinks resolved, while the edit may name the file through one (a
# symlinked project folder, or /var vs /private/var on macOS), so fall back to
# comparing physical paths.
case "$FILE" in
  "$ROOT"/*) REL="${FILE#"$ROOT"/}" ;;
  *)
    PHYS_ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)"
    PHYS_DIR="$(cd "$(dirname "$FILE")" 2>/dev/null && pwd -P)"
    [ -n "$PHYS_ROOT" ] && [ -n "$PHYS_DIR" ] || exit 0
    case "$PHYS_DIR/" in
      "$PHYS_ROOT"/*) REL="${PHYS_DIR#"$PHYS_ROOT"}/${FILE##*/}"; REL="${REL#/}" ;;
      *) exit 0 ;;
    esac
    ;;
esac
[ -n "$REL" ] || exit 0

# The scan runs at session start, so a long session edits against an old one.
# Past the TTL, start a refresh in the background and answer from what is here:
# this edit is never delayed, and the next one sees the new scan. A lock keeps a
# burst of edits from starting a burst of refreshes.
TTL="${EMSK_PR_TTL:-1800}"
# GNU first: GNU `stat -f` means file-system status, which prints a report and
# then fails, so a BSD-first chain would read that report as a number.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
AGE=$(( $(date +%s) - $(mtime "$CACHE") ))
if [ "$AGE" -ge "$TTL" ]; then
  LOCK="${CACHE%/*}/refresh.lock"
  if [ -d "$LOCK" ] && [ $(( $(date +%s) - $(mtime "$LOCK") )) -gt 120 ]; then
    rmdir "$LOCK" 2>/dev/null   # a refresh that died without cleaning up
  fi
  if mkdir "$LOCK" 2>/dev/null; then
    # Every descriptor redirected, or the hook's caller would wait on the pipe.
    ( cd "$ROOT" && bash "$HERE/scan.sh" --quiet; rmdir "$LOCK" ) </dev/null >/dev/null 2>&1 &
  fi
fi

MSG="$(jq -r --arg f "$REL" --argjson age "$AGE" --argjson ttl "$TTL" '
  # gh returns author as an object; tolerate a bare string so a malformed cache
  # degrades the wording instead of swallowing the whole warning.
  def who: if (.author | type) == "object" then (.author.login // "?")
           else (.author // "?") end;
  # This runs before every edit, so it is capped: a popular file can sit in a
  # dozen PRs, and a warning nobody can read is a warning nobody reads.
  def clip($n): if length > $n then .[0: $n - 1] + "…" else . end;
  def some($n): if (length > $n) then
                  (.[0:$n] | join(", ")) + " (+\(length - $n) more)"
                else join(", ") end;
  (.remote // "origin") as $remote |
  (.gh_repo_flag // "") as $r |
  (.by_file[$f] // {open: [], merged: []}) as $hit |
  (.symbols[$f] // null) as $sym |
  ((.base_drift_on_my_files // []) | index($f) != null) as $drifted |
  if (($hit.open | length) == 0) and (($hit.merged | length) == 0) and ($sym == null) then
    ""
  else
    ([ "emsk-pr: \($f) is contested — other work touches this same file."
     ]
     + (if ($hit.open | length) > 0 then
          [ "  OPEN: " + ([ $hit.open[0:2][] as $n
              | (.open[] | select(.number == $n)
                 | "#\($n) \(.title | clip(32)) (@\(who))") ] | join("; "))
            + (if ($hit.open | length) > 2
               then " (+\(($hit.open | length) - 2) more)" else "" end)
          , "  Read it before editing: gh pr diff \($r)\($hit.open[0]) -- \($f)" ]
        else [] end)
     # Merged PRs are numbers only: the symbol lines below already say what
     # changed, so a title here would cost more context than it buys.
     + (if ($hit.merged | length) > 0 then
          [ "  MERGED INTO \(.base) after you branched: "
            + ($hit.merged | map("#\(.)") | some(3))
            + "  (gh pr view \($r)<n>)" ]
        else [] end)
     + (if $drifted then
          [ "  Changed on \($remote)/\(.base) since you branched; your copy is older: git show \($remote)/\(.base):\($f)" ]
        else [] end)
     # Removed names get the most room: re-adding one is the failure this
     # whole tool exists to prevent.
     + (if $sym != null then
          ([]
           + (if ($sym.removed | length) > 0 then
                [ "  REMOVED on \(.base): " + ($sym.removed | some(5))
                  + "  <- do not bring back" ] else [] end)
           + (if (($sym.moved // []) | length) > 0 then
                [ "  MOVED on \(.base): " + ($sym.moved | map("\(.name) -> \(.to)") | some(2))
                  + "  <- still exist, use them there" ] else [] end)
           + (if ($sym.added | length) > 0 then
                [ "  NEW on \(.base): " + ($sym.added | some(3)) + "  <- use these" ] else [] end)
           + (if ($sym.changed | length) > 0 then
                [ "  CHANGED on \(.base): " + ($sym.changed | some(3)) ] else [] end))
        else [] end)
     + (if $age >= $ttl then
          [ "  (from a scan \($age / 3600 | floor)h\($age % 3600 / 60 | floor)m old; a refresh has started)" ]
        else [] end)
    ) | join("\n")
  end' "$CACHE" 2>/dev/null)"

[ -n "$MSG" ] || exit 0

jq -n --arg m "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $m
  }
}'
exit 0
