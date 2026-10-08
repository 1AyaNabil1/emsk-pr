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

# GNU first: GNU `stat -f` means file-system status, which prints a report and
# then fails, so a BSD-first chain would read that report as a number.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Run scan.sh --quiet in the background and return at once: the edit is never
# delayed, and the next one sees the new scan. One at a time and at most once a
# minute, so a burst of edits, or a run of edits while offline, does not become
# a burst of scans.
start_refresh() {
  local dir="${CACHE%/*}" lock stamp
  mkdir -p "$dir" 2>/dev/null || return 0
  lock="$dir/refresh.lock"; stamp="$dir/refresh.last"
  [ -f "$stamp" ] && [ $(( $(date +%s) - $(mtime "$stamp") )) -lt 60 ] && return 0
  if [ -d "$lock" ] && [ $(( $(date +%s) - $(mtime "$lock") )) -gt 120 ]; then
    rmdir "$lock" 2>/dev/null   # a refresh that died without cleaning up
  fi
  mkdir "$lock" 2>/dev/null || return 0
  : > "$stamp"
  # Every descriptor redirected, or the hook's caller would wait on the pipe.
  ( cd "$ROOT" && bash "$HERE/scan.sh" --quiet; rmdir "$lock" ) </dev/null >/dev/null 2>&1 &
}

CACHE="${EMSK_PR_CACHE_FILE:-}"
if [ -z "$CACHE" ]; then
  CACHE="$(cd "$ROOT" 2>/dev/null && bash "$HERE/scan.sh" --cache-path 2>/dev/null)" || exit 0
  [ -n "$CACHE" ] || exit 0
  # No scan for this branch yet: it was checked out after the session began.
  # Say nothing this time, and have a scan ready for the next edit.
  [ -f "$CACHE" ] || { start_refresh; exit 0; }
fi
[ -f "$CACHE" ] || exit 0
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
# Past the TTL, answer from what is here and refresh for next time.
TTL="${EMSK_PR_TTL:-1800}"
AGE=$(( $(date +%s) - $(mtime "$CACHE") ))
[ "$AGE" -ge "$TTL" ] && start_refresh

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
  # Every path the base moved, so a file first edited after the scan counts too.
  ((.base_drift // .base_drift_on_my_files // []) | index($f) != null) as $drifted |
  ((.base_gone // {})[$f]) as $gone |
  # Trial merges from the scan: against the base, and against each open PR.
  (.conflicts // {}) as $cf |
  (if $cf.ours == "working-tree" then "your uncommitted work" else "your last commit" end) as $ours |
  (($cf.base // {}).files // {})[$f] as $base_conflict |
  def where: (if (.lines | length) > 0 then " (~line \(.lines[0:3] | map(tostring) | join(", ")))" else "" end)
             + (if .kind != "content" then " [\(.kind)]" else "" end);
  [ $hit.open[] as $n | ($cf.prs // {})[$n | tostring] as $k | select($k != null)
    | if ($k.files[$f] != null) then {n: $n, t: "conflict", w: ($k.files[$f] | where)}
      elif (($k.unsettled // []) | index($f)) != null then {n: $n, t: "unsettled"}
      elif $k.status == "clean" or $k.status == "conflict" then {n: $n, t: "clean"}
      else empty end ] as $trials |
  [$trials[] | select(.t == "conflict")] as $tc |
  ($base_conflict != null or ($tc | length) > 0) as $conflicted |
  # Within my own stack: new commits on the parent, and the PRs built on this
  # branch, against my work on this file. These mean a rebase, not a collision.
  ((($cf.parent // {}).files // {})[$f]) as $pconf |
  [ ($cf.children // {}) | to_entries[] | select(.value.files[$f] != null)
    | {n: .key, w: (.value.files[$f] | where)} ] as $kconf |
  ($pconf != null or ($kconf | length) > 0) as $restack |
  def nums: map("#\(.n)") | some(3);
  if (($hit.open | length) == 0) and (($hit.merged | length) == 0) and ($sym == null)
     and ($drifted | not) and ($restack | not) then
    ""
  else
    ([ if $conflicted then "emsk-pr: \($f) has merge CONFLICTS with other work."
       elif $restack and (($hit.open | length) + ($hit.merged | length)) == 0 then
         "emsk-pr: \($f) will need a rebase within your stack."
       else "emsk-pr: \($f) is contested — other work touches this same file." end ]
     + (if $pconf != null then
          [ "  Your stack parent #\(.stack.parent.number) has new commits that CONFLICT here\($pconf | where): rebase onto it first." ]
        else [] end)
     + (if ($kconf | length) > 0 then
          [ "  Rebasing #\($kconf[0].n), built on this branch, will CONFLICT here\($kconf[0].w)"
            + (if ($kconf | length) > 1 then " (and \($kconf[1:] | map("#\(.n)") | join(", ")))" else "" end) + "." ]
        else [] end)
     + (if $base_conflict != null then
          [ "  CONFLICTS with \($remote)/\(.base) here\($base_conflict | where): merge it in before building on this file." ]
        else [] end)
     # One line for every trial merge on this file: the first conflict gets
     # its lines, the rest are numbers.
     + (if ($trials | length) > 0 then
          [ "  Trial merge with \($ours): "
            + ([ (if ($tc | length) > 0 then "CONFLICTS with #\($tc[0].n)\($tc[0].w)"
                    + (if ($tc | length) > 1 then ", " + ($tc[1:] | nums) else "" end) else empty end),
                 ([$trials[] | select(.t == "clean")] | select(length > 0) | "merges cleanly: " + nums),
                 ([$trials[] | select(.t == "unsettled")] | select(length > 0) | "unsettled: " + nums)
               ] | join("; ")) ]
        else [] end)
     + (if ($hit.open | length) > 0 then
          [ "  OPEN: " + ([ $hit.open[0:2][] as $n
              | (.open[] | select(.number == $n)
                 | "#\($n) \(.title | clip(28)) (@\(who))") ] | join("; "))
            + (if ($hit.open | length) > 2
               then " (+\(($hit.open | length) - 2) more)" else "" end)
          , "  Read it before editing: gh pr diff \($r)\(([$trials[] | select(.t == "conflict") | .n] + $hit.open)[0]) -- \($f)" ]
        else [] end)
     # Merged PRs are numbers only: the symbol lines below already say what
     # changed, so a title here would cost more context than it buys.
     + (if ($hit.merged | length) > 0 then
          [ "  MERGED INTO \(.base) after you branched: "
            + ($hit.merged | map("#\(.)") | some(3))
            + "  (gh pr view \($r)<n>)" ]
        else [] end)
     + (if $gone != null and ($gone | startswith("renamed")) then
          [ "  \($gone | sub("^renamed"; "Renamed")) on \($remote)/\(.base) since you branched: edit that file, not this one." ]
        elif $gone != null then
          [ "  Deleted on \($remote)/\(.base) since you branched: check why before bringing it back." ]
        elif $drifted and $base_conflict == null then
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
           # with a real conflict to report, this is the line that gives way
           + (if ($sym.changed | length) > 0 and ($conflicted | not) then
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
