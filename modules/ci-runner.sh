#!/usr/bin/env bash
# kakapo-ci: start CI as soon as a commit is pushed, instead of when an agent
# remembers to run ci-local.sh. Before 2026-11-22 the wait between a push and
# the first `check` status was 67 s at the median and 30 min at p95, while the
# run itself took 35-40 s: waiting was the whole cost.
#
# Every POLL seconds it reads the open PRs and master's head in one GraphQL
# call. A head commit with no `check` status, or one whose local run went
# quiet (pending for more than STALE seconds: the run was killed), gets
# ci-local.sh. ci-local.sh does every safety check itself (open PR, not a
# fork, exact pushed commit); this loop only decides when to call it.
#
# When a PR's head moves, the run on its old head is killed: its result
# could never gate a merge. At most MAX runs go at once; nix builds what they
# share once.
#
# It never retries a finished run. A red result stays red until a new push or
# a manual ci-local.sh.
set -uo pipefail
: "${CI_LOCAL:?}" "${POLL:=8}" "${MAX:=3}" "${STALE:=900}" "${GIVE_UP:=40}"
repo_owner=salehtl repo_name=kakapo

declare -A running=() # key (pr number or "master") -> "sha pid"
fails=0

query='query($o:String!,$n:String!){repository(owner:$o,name:$n){
  pullRequests(states:OPEN,first:50){nodes{number isCrossRepository
    headRepositoryOwner{login} headRefOid
    commits(last:1){nodes{commit{status{contexts{context state createdAt description}}}}}}}
  defaultBranchRef{target{... on Commit{oid
    status{contexts{context state createdAt description}}}}}}}'

# One line per candidate: key sha needs-run(0/1)
candidates() {
  jq -r --argjson now "$(date +%s)" --argjson stale "$STALE" '
    def needs(ctx):
      ([ctx[]? | select(.context == "check")]) as $c
      | if ($c | length) == 0 then 1
        elif ($c | all(.state == "PENDING"
              and (.description // "" | test("\\(local on "))
              and ($now - (.createdAt | fromdateiso8601)) > $stale)) then 1
        else 0 end;
    .data.repository as $r
    | ($r.pullRequests.nodes[]
       | select(.isCrossRepository == false and .headRepositoryOwner.login == "salehtl")
       | "\(.number) \(.headRefOid) \(needs(.commits.nodes[0].commit.status.contexts // []))"),
      ($r.defaultBranchRef.target
       | "master \(.oid) \(needs(.status.contexts // []))")'
}

reap() {
  local k sha pid
  for k in "${!running[@]}"; do
    read -r sha pid <<<"${running[$k]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      echo "$k ${sha:0:7}: ci-local.sh exited $?"
      unset "running[$k]"
    fi
  done
}

cancel() { # key reason
  local sha pid
  read -r sha pid <<<"${running[$1]}"
  echo "$1 ${sha:0:7}: cancelled: $2"
  kill -TERM -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  unset "running[$1]"
}

trap 'for k in "${!running[@]}"; do cancel "$k" "service stopped"; done; exit 0' TERM INT

while :; do
  reap
  if ! out=$(gh api graphql -f query="$query" -f o=$repo_owner -f n=$repo_name 2>&1); then
    fails=$((fails + 1))
    echo "GitHub query failed ($fails in a row): ${out:0:300}" >&2
    # A short network blip is normal; ten minutes of nothing is a fault.
    [ "$fails" -ge "$GIVE_UP" ] && { echo "giving up after $fails failed polls" >&2; exit 1; }
    sleep "$POLL"
    continue
  fi
  fails=0
  open=" "
  while read -r key sha need; do
    [ -n "$key" ] || continue
    open+="$key "
    if [ -n "${running[$key]:-}" ]; then
      [ "${running[$key]%% *}" = "$sha" ] && continue
      cancel "$key" "new head ${sha:0:7}"
    fi
    [ "$need" = 1 ] || continue
    [ "${#running[@]}" -lt "$MAX" ] || continue
    echo "$key ${sha:0:7}: starting ci-local.sh"
    # Own process group, so a cancel also stops its nix children.
    # A background job of a non-interactive shell is not a group leader, so
    # setsid execs in place: $! is the new session and process group.
    setsid "$CI_LOCAL" "$sha" > >(sed -u "s/^/$key ${sha:0:7}: /") 2>&1 &
    running[$key]="$sha $!"
  done < <(printf '%s' "$out" | candidates)
  # A PR closed or merged mid-run: its result no longer matters.
  for k in "${!running[@]}"; do
    [[ $open == *" $k "* ]] || cancel "$k" "PR closed or merged"
  done
  sleep "$POLL"
done
