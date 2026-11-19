#!/usr/bin/env bash
# Markdown review of a flake.lock bump, for the weekly bump PR
# (.github/workflows/update-flake-lock.yml posts it as a comment).
#
#   scripts/lock-review.sh <old flake.lock> <new flake.lock> <old system> <new system> [hold file]
#
# Deterministic: it reports what moved (inputs, then package versions sorted
# by the kakapo-update skill's scripts) and flags what needs a human look.
# It does not read changelogs or judge risk; that is the kakapo-update
# skill's job on the host, where the closure can also be guarded-tested.
#
# Since 2026-11-19 the bump PR merges itself unless a flag says to hold it.
# With a fifth argument, the reasons to hold (one per line) are written to
# that file, which is empty when the bump may merge. Holds: an input changed
# its source, a review script failed, or Immich or PostgreSQL moved (they
# migrate data and cannot go back). A kernel change does not hold: it is only
# flagged, since activation does not load a kernel and almost every nixpkgs
# bump moves it.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
skill=$here/claude/skills/kakapo-update/scripts
old_lock=$1 new_lock=$2 old_sys=$3 new_sys=$4 hold_file=${5:-/dev/null}

inputs=$(python3 -I "$skill/lock-diff.py" "$old_lock" "$new_lock" 2>&1)
inputs_rc=$?
versions=$(python3 -I "$skill/version-jumps.py" "$old_sys" "$new_sys" 2>&1)
versions_rc=$?

flags=()
holds=()
[ "$inputs_rc" -eq 0 ] || {
  flags+=("**An input changed its source, or lock-diff failed (exit $inputs_rc).** Do not merge before you know why.")
  holds+=("an input changed its source, or lock-diff failed")
}
[ "$versions_rc" -eq 0 ] || {
  flags+=("version-jumps failed (exit $versions_rc); read the closure diff by hand.")
  holds+=("version-jumps failed")
}
grep -qiE '^ *(immich|postgresql)' <<<"$(sed -n '/^WATCHED/,/^MAJOR/p' <<<"$versions")" && {
  flags+=("Immich or PostgreSQL changes: they migrate data on start and cannot downgrade. Confirm a fresh Immich dump before the deploy.")
  holds+=("Immich or PostgreSQL changes")
}
grep -qE '^(kernel|initrd): differs' <<<"$versions" &&
  flags+=("The kernel or initrd changes: a reboot is needed to run it.")

if [ ${#holds[@]} -eq 0 ]; then : >"$hold_file"; else printf '%s\n' "${holds[@]}" >"$hold_file"; fi

echo "## Automated lock review"
echo
if [ ${#flags[@]} -eq 0 ]; then
  echo "No automatic flags."
else
  printf -- '- %s\n' "${flags[@]}"
fi
echo
if [ ${#holds[@]} -eq 0 ]; then
  echo "**Merges itself** once \`check\` and \`build\` are reported. It deploys at 04:00 through the guarded upgrade."
else
  reasons=$(printf '%s; ' "${holds[@]}")
  echo "**Held for Saleh** (\`needs-review\`, auto-merge off): ${reasons%; }."
fi
echo
echo "### Inputs"
echo '```'
echo "$inputs"
echo '```'
echo
echo "### Versions (\`nix store diff-closures\`, sorted)"
echo '```'
echo "$versions" | head -c 50000
echo '```'
echo
echo "For changelogs, migrations and a guarded test on kakapo, ask Claude on the host to review this PR (\`kakapo-update\` skill)."
