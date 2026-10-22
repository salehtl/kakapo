#!/usr/bin/env bash
# Read-only pre-merge gate for one kakapo PR. Prints the head SHA on stdout
# when the PR may be merged; otherwise prints why on stderr and exits non-zero.
#
#   head=$(scripts/pr-gate.sh 21) &&
#     gh pr merge 21 --repo salehtl/kakapo --squash --match-head-commit "$head"
#
# Exit codes: 0 ready; 1 wrong state (closed, draft, not on master, conflict,
# or a fork PR: the repo is public, so a stranger's PR can have green CI);
# 2 a required check failed or is missing; 8 a check is pending or GitHub has
# not computed mergeability yet (wait, then re-run).
# It never merges, comments or changes anything. jq is not installed on
# kakapo, so this uses gh's built-in --jq.
set -euo pipefail
n=${1:?usage: pr-gate.sh <pr number>}
repo=salehtl/kakapo

# One API call; one "key<TAB>value" line per fact. A check run has
# status/conclusion; a commit status (posted by update-flake-lock.yml and
# hasala-release.yml) has state.
facts=$(gh pr view "$n" --repo "$repo" \
  --json state,isDraft,baseRefName,headRefOid,mergeable,title,statusCheckRollup,isCrossRepository,headRepositoryOwner,author \
  --jq '"state\t\(.state)", "draft\t\(.isDraft)", "base\t\(.baseRefName)",
        "fork\t\(.isCrossRepository)", "owner\t\(.headRepositoryOwner.login)",
        "author\t\(.author.login)",
        "head\t\(.headRefOid)", "mergeable\t\(.mergeable)", "title\t\(.title)",
        (.statusCheckRollup[] | "check:\(.name // .context)\t\((.conclusion // "") as $c
          | if $c != "" then $c else (.state // .status // "") end | ascii_upcase)")')
get() { awk -F'\t' -v k="$1" '$1 == k { v = $2 } END { print v }' <<<"$facts"; }
# Every value for a key, one per line (a check name can appear more than once).
all() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' <<<"$facts"; }

[ "$(get state)" = OPEN ] || { echo "#$n is $(get state), not OPEN" >&2; exit 1; }
[ "$(get draft)" = false ] || { echo "#$n is a draft" >&2; exit 1; }
[ "$(get base)" = master ] || { echo "#$n targets $(get base), not master" >&2; exit 1; }
if [ "$(get fork)" != false ] || [ "$(get owner)" != salehtl ]; then
  echo "#$n is from a fork ($(get owner)/..., author $(get author)): only Saleh can name it" >&2
  exit 1
fi
case "$(get mergeable)" in
  MERGEABLE) ;;
  UNKNOWN) echo "#$n: GitHub has not computed mergeability yet; re-run shortly" >&2; exit 8 ;;
  *) echo "#$n is $(get mergeable) with master: rebase it first" >&2; exit 1 ;;
esac

# The master ruleset requires exactly these two (.github/workflows/check.yml).
# Every entry with that name must be SUCCESS: a failed duplicate (a check run
# and a commit status, say) blocks, whichever is listed last.
rc=0
for name in check build; do
  sts=$(all "check:$name")
  [ -n "$sts" ] || sts=MISSING
  while read -r st; do
    case "$st" in
      SUCCESS) echo "$name: pass" >&2 ;;
      PENDING | QUEUED | IN_PROGRESS | EXPECTED | WAITING | REQUESTED)
        echo "$name: pending" >&2
        [ "$rc" -eq 2 ] || rc=8
        ;;
      *) echo "$name: $st" >&2; rc=2 ;;
    esac
  done <<<"$sts"
done
[ "$rc" -eq 0 ] || exit "$rc"
echo "#$n ready: $(get title)" >&2
get head
