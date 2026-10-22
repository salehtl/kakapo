#!/usr/bin/env bash
# Read-only: find the hasala commit to release to kakapo QA, and say how.
#
#   pick-release.sh            # the newest releasable main commit (what hasala-release.yml picks)
#   pick-release.sh <sha>      # judge one named commit instead
#
# Prints "key<TAB>value" lines on stdout:
#   pinned   the hasala rev on kakapo master (what 04:00 deploys)
#   running  the hasalad store path the host runs now
#   target   the full sha to release ("none" if nothing to release)
#   checks   gate/vuln/secrets/nixos-vm conclusions on target
#   review   true when target changes a migration or the module (no auto-merge)
#   file     each migration/module file that triggers review (0..n lines)
#   commit   each commit between pinned and target that changes what kakapo runs
#   pr       the open hasala-release PR: "<number> <pinned rev in it>" or "none"
#   pr_other each other open kakapo PR that edits the hasala pin (0..n lines)
#   run      each hasala-release workflow run not yet completed (0..n lines)
# Exit: 0 releasable; 3 nothing to release; 4 checks not all green yet;
#       1 bad input (not on main, not after the pin).
# jq is not on kakapo: gh --jq only. Clones hasala blob-less into $TMPDIR.
set -euo pipefail
kakapo=salehtl/kakapo
hasala=salehtl/hasala
paths=(server ':!server/oracle' infra/qa/nix ':!infra/qa/nix/tests' flake.nix flake.lock)

pinned=$(gh api "repos/$kakapo/contents/flake.nix" --jq .content | base64 -d |
  grep -oP 'github:salehtl/hasala/\K[0-9a-f]{40}')
printf 'pinned\t%s\n' "$pinned"
printf 'running\t%s\n' "$(systemctl show -p ExecStart --value hasalad.service 2>/dev/null |
  grep -o '/nix/store/[^ ;]*hasalad[^ ;/]*' | head -1 || echo unknown)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone --quiet --filter=blob:none "https://github.com/$hasala.git" "$work/h"
cd "$work/h"

if [ $# -ge 1 ]; then
  target=$(git rev-parse --verify --quiet "$1^{commit}") || { echo "unknown commit $1" >&2; exit 1; }
  git merge-base --is-ancestor "$target" origin/main || { echo "$1 is not on hasala main" >&2; exit 1; }
  git merge-base --is-ancestor "$pinned" "$target" || { echo "$1 is not after the pin $pinned (a downgrade)" >&2; exit 1; }
else
  target=$(git log -1 --format=%H "$pinned..origin/main" -- "${paths[@]}")
fi
if [ -z "$target" ] || [ "$target" = "$pinned" ]; then
  printf 'target\tnone\n'
  exit 3
fi
printf 'target\t%s\n' "$target"

checks=$(gh api "repos/$hasala/commits/$target/check-runs?per_page=100" \
  --jq '[.check_runs[] | select(.name | test("^(gate|vuln|secrets|nixos-vm)$")) | "\(.name)=\(.conclusion // .status)"] | unique | join(" ")')
printf 'checks\t%s\n' "${checks:-none}"

review=$(git diff --name-only "$pinned" "$target" -- server/internal/pg/migrations/ infra/qa/nix ':!infra/qa/nix/tests')
if [ -n "$review" ]; then printf 'review\ttrue\n'; else printf 'review\tfalse\n'; fi
while read -r f; do [ -n "$f" ] && printf 'file\t%s\n' "$f"; done <<<"$review"
git log --format='commit%x09%h %s' "$pinned..$target" -- "${paths[@]}"

pr=$(gh pr list --repo "$kakapo" --head hasala-release --state open --json number --jq '.[0].number // ""')
if [ -n "$pr" ]; then
  rev=$(gh pr diff "$pr" --repo "$kakapo" | grep -oP '^\+.*github:salehtl/hasala/\K[0-9a-f]{40}' | head -1)
  printf 'pr\t%s %s\n' "$pr" "${rev:-?}"
else
  printf 'pr\tnone\n'
fi
gh run list --repo "$kakapo" --workflow hasala-release.yml --limit 5 --json databaseId,status,event,createdAt \
  --jq '.[] | select(.status != "completed") | "run\t\(.databaseId) \(.status) \(.event) \(.createdAt)"'
gh pr list --repo "$kakapo" --state open --json number,headRefName,files \
  --jq '.[] | select(.headRefName != "hasala-release") | select(any(.files[]; .path == "flake.nix")) | "pr_other\t\(.number) \(.headRefName)"'

ok=$(grep -o '=success' <<<"$checks" | wc -l)
[ "$ok" -eq 4 ] || exit 4
