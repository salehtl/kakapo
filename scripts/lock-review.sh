#!/usr/bin/env bash
# Markdown review of a flake.lock bump, for the weekly bump PR
# (.github/workflows/update-flake-lock.yml posts it as a comment).
#
#   scripts/lock-review.sh <old flake.lock> <new flake.lock> <old system> <new system>
#
# Deterministic: it reports what moved (inputs, then package versions sorted
# by the kakapo-update skill's scripts) and flags what needs a human look.
# It does not read changelogs or judge risk; that is the kakapo-update
# skill's job on the host, where the closure can also be guarded-tested.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
skill=$here/claude/skills/kakapo-update/scripts
old_lock=$1 new_lock=$2 old_sys=$3 new_sys=$4

inputs=$(python3 -I "$skill/lock-diff.py" "$old_lock" "$new_lock" 2>&1)
inputs_rc=$?
versions=$(python3 -I "$skill/version-jumps.py" "$old_sys" "$new_sys" 2>&1)
versions_rc=$?

flags=()
[ "$inputs_rc" -eq 0 ] || flags+=("**An input changed its source, or lock-diff failed (exit $inputs_rc).** Do not merge before you know why.")
[ "$versions_rc" -eq 0 ] || flags+=("version-jumps failed (exit $versions_rc); read the closure diff by hand.")
grep -qiE '^ *(immich|postgresql)' <<<"$(sed -n '/^WATCHED/,/^MAJOR/p' <<<"$versions")" &&
  flags+=("Immich or PostgreSQL changes: they migrate data on start and cannot downgrade. Confirm a fresh Immich dump before the deploy.")
grep -qE '^(kernel|initrd): differs' <<<"$versions" &&
  flags+=("The kernel or initrd changes: a reboot is needed to run it.")

echo "## Automated lock review"
echo
if [ ${#flags[@]} -eq 0 ]; then
  echo "No automatic flags. Still read the WATCHED list before merging."
else
  printf -- '- %s\n' "${flags[@]}"
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
