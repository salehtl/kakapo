#!/usr/bin/env bash
# kakapo's CI, run on kakapo itself. It replaces .github/workflows/check.yml
# (removed 2026-10-27: a cold GitHub runner took 30-40 min, mostly compiling
# the NVIDIA driver, which this host's store already has). It runs the same
# two jobs on one pushed commit and posts their result as the `check` and
# `build` commit statuses that the master ruleset requires.
#
#   ci-local.sh <pr number>   # the PR's head commit
#   ci-local.sh <sha>         # any pushed commit (deploy.sh runs it on master)
#
# check: `nix flake lock --no-update-lock-file` (a lock that needs updating
#        breaks the 04:00 upgrade silently, as ae89d66 did from 2026-06-01 to
#        2026-10-03), then `nix flake check`.
# build: the kakapo toplevel. `nix flake check` only evaluates it, so this is
#        the step that catches compile failures and bad hashes.
#
# It builds a fresh clone of the exact commit on GitHub, never a working tree,
# so a status always describes pushed code. Run the installed copy
# (~/.claude/skills/kakapo-change/scripts/ci-local.sh, from deployed master),
# not a PR's: a PR could otherwise change the script that passes it.
#
# Exit codes: 0 both passed; 1 check failed; 2 build failed (check passed);
# 3 the commit or PR is not one to run (fork, closed, unknown); 64 usage.
set -uo pipefail
repo=salehtl/kakapo
usage() { echo "usage: ci-local.sh <pr number | sha>" >&2; exit 64; }
arg=${1:-}
[ $# -eq 1 ] || usage

say() { printf '%s\t%s\n' "$1" "$2"; }

if [[ $arg =~ ^[0-9]{1,6}$ ]]; then
  # The repo is public. Never run a fork's code on the house's DNS server.
  facts=$(gh pr view "$arg" --repo "$repo" --json state,isCrossRepository,headRepositoryOwner,headRefOid \
    --jq '"\(.state) \(.isCrossRepository) \(.headRepositoryOwner.login) \(.headRefOid)"') ||
    { say FAIL "cannot read PR #$arg"; exit 3; }
  read -r state cross owner sha <<<"$facts"
  [ "$state" = OPEN ] || { say FAIL "#$arg is $state"; exit 3; }
  if [ "$cross" != false ] || [ "$owner" != salehtl ]; then
    say FAIL "#$arg is from a fork ($owner): not run here"
    exit 3
  fi
elif [[ $arg =~ ^[0-9a-f]{7,40}$ ]]; then
  sha=$(gh api "repos/$repo/commits/$arg" --jq .sha 2>/dev/null) || { say FAIL "unknown commit $arg"; exit 3; }
else
  usage
fi
say OK "commit $sha"

host=$(hostname)
status() {
  gh api --silent "repos/$repo/statuses/$sha" -f state="$2" -f context="$1" \
    -f description="$3 (local on $host)" ||
    say WARN "could not post the $1 status"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
src=$tmp/src
if ! { git init -q "$src" &&
  git -C "$src" fetch -q --depth 1 "https://github.com/$repo.git" "$sha" &&
  git -C "$src" checkout -q --detach FETCH_HEAD; }; then
  say FAIL "cannot fetch $sha"
  exit 3
fi

status check pending "running"
status build pending "waiting for check"

top=nixosConfigurations.kakapo.config.system.build.toplevel
run() {
  local log=$1
  shift
  if (cd "$src" && nice -n 10 "$@") >"$tmp/$log" 2>&1; then return 0; fi
  echo "---- last lines of $log"
  tail -40 "$tmp/$log"
  echo "----"
  return 1
}

if ! run lock.log nix flake lock --no-update-lock-file; then
  status check failure "flake.lock is out of sync with flake.nix"
  status build failure "not run: check failed"
  say FAIL "check: flake.lock is out of sync with flake.nix"
  exit 1
fi
if ! run flake-check.log nix flake check --print-build-logs; then
  status check failure "nix flake check failed"
  status build failure "not run: check failed"
  say FAIL "check: nix flake check failed"
  exit 1
fi
status check success "lock in sync, nix flake check passed"
say OK "check"

status build pending "building the toplevel"
if ! run build.log nix build --print-build-logs --no-link --print-out-paths ".#$top"; then
  status build failure "toplevel build failed"
  say FAIL "build: toplevel build failed"
  exit 2
fi
out=$(cd "$src" && nix build --no-link --print-out-paths ".#$top")
status build success "toplevel built: ${out#/nix/store/}"
say OK "build $out"
say PASS "$sha"
