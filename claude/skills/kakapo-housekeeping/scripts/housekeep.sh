#!/usr/bin/env bash
# kakapo housekeeping: finds disposable state on the host and general chores.
# The flake owns configuration; this only removes state that can be rebuilt or
# downloaded again, and it never edits configuration.
#
# Output: one tab-separated line per finding, then one summary line:
#
#   CLEAN\t<area>\t<size>\t<detail>   safe: --apply removes it
#   ASK\t<area>\t<size>\t<path>       removed only when Saleh names it (--remove)
#   KEPT\t<area>\t<reason>\t<path>    looked disposable, but is protected
#   CHORE\t<name>\t<detail>           needs a person, a PR or another skill
#   INFO\t<name>\t<detail>            for the report; nothing to do
#   REMOVED\t<area>\t<size>\t<detail> (--apply, --remove)
#   FAILED\t<area>\t<detail>          (--apply, --remove)
#   SUMMARY\t<mode>\tclean=N ask=N kept=N chore=N removed=N failed=N
#
# Exit code: 0 done, 1 something failed or was refused, 64 usage.
#
# Usage:
#   housekeep.sh [--offline] [--list] [--only area,area]   read-only scan
#   housekeep.sh --apply [--offline] [--only area,area]    remove CLEAN items
#   housekeep.sh --remove [--discard-git] PATH...          remove named items
#     --offline      skip what needs GitHub
#     --list         print every CLEAN item, not only each area's total
#     --discard-git  let --remove delete a repo with unpushed work
#
# Host facts used here (keep in sync with the flake):
#   /tmp ages at 10 days (q /tmp in tmpfiles.d/tmp.conf), TMP_DAYS matches it
#   declared OCI images and units    modules/services/grampsweb.nix
#   generation policy 30 d, keep 4   modules/base.nix prune-system-generations
#   shared caches: "unless the user asks"  modules/claude-projects.md section 8
set -u
export LC_ALL=C
# A scan must not touch what it inspects: git status would refresh an old
# clone's index and make the clone look recently used.
export GIT_OPTIONAL_LOCKS=0

AREAS="tmp caches docker etc_nixos nix_store strays projects var_lib drift git_hygiene generations"
TMP_DAYS=10
CACHE_DAYS=14
PROJECT_IDLE_DAYS=14
ASK_MIN_KB=$((100 * 1024))
REPO=salehtl/kakapo
DECLARED_IMAGE_REPOS="ghcr.io/gramps-project/grampsweb valkey/valkey"
DECLARED_CONTAINER_RE='^grampsweb(-celery|-redis)?$'
DECLARED_UNITS="docker-grampsweb.service docker-grampsweb-celery.service docker-grampsweb-redis.service"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# The self-test points these at fixtures; nothing else sets them.
HOME_DIR=${HOUSEKEEP_HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}
TMP_ROOT=${HOUSEKEEP_TMP:-/tmp}
ME=$(id -un)

# Regenerable caches --apply may clear when cold. Weights and Nix's eval cache
# are not here on purpose: one is slow to fetch, the other is in constant use.
CACHES=(
  .cache/go-build .cache/golangci-lint .cache/gopls .cache/uv .cache/pip
  .cache/pnpm .cache/yarn .cache/grype .cache/vulnix .cache/treefmt
  .npm/_cacache .npm/_npx .bun/install/cache go/pkg/mod .cargo/registry
)
# Home entries that belong there; everything else at the top level is a stray.
HOME_KNOWN=" .bash_history .bash_profile .bashrc .profile .bun .cache .cargo .claude .claude.json .config .direnv .docker .gitconfig .gnupg .lesshst .local .nix-defexpr .nix-profile .npm .nv .pki .rustup .ssh .terminfo .viminfo go src "

mode=scan offline=0 list=0 discard_git=0 only=""
remove_paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) mode=apply ;;
    --remove) mode=remove ;;
    --offline) offline=1 ;;
    --list) list=1 ;;
    --discard-git) discard_git=1 ;;
    --only) only=${2:-}; shift ;;
    -*) echo "unknown argument: $1" >&2; exit 64 ;;
    *)
      [ "$mode" = remove ] || { echo "a path needs --remove: $1" >&2; exit 64; }
      remove_paths+=("$1")
      ;;
  esac
  shift
done
if [ "$(id -u)" = 0 ]; then
  echo "run as the normal user, not root: ownership checks depend on it" >&2
  exit 64
fi
if [ "$mode" = remove ] && [ "${#remove_paths[@]}" -eq 0 ]; then
  echo "--remove needs at least one path" >&2
  exit 64
fi
for a in ${only//,/ }; do
  case " $AREAS " in
    *" $a "*) ;;
    *) echo "unknown area: $a (areas: $AREAS)" >&2; exit 64 ;;
  esac
done
want() { [ -z "$only" ] || case ",$only," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

n_clean=0 n_ask=0 n_kept=0 n_chore=0 n_removed=0 n_failed=0
emit() { printf '%s' "$1"; shift; printf '\t%s' "$@"; printf '\n'; }
ask() { n_ask=$((n_ask + 1)); emit ASK "$@"; }
kept() { n_kept=$((n_kept + 1)); emit KEPT "$@"; }
chore() { n_chore=$((n_chore + 1)); emit CHORE "$@"; }
info() { emit INFO "$@"; }
failed() { n_failed=$((n_failed + 1)); emit FAILED "$@"; }

size_kb() { du -sk -- "$1" 2>/dev/null | awk '{print $1+0; f=1} END{if(!f)print 0}'; }
human() { awk -v k="$1" 'BEGIN{if(k>=1048576)printf "%.1fG",k/1048576;else if(k>=1024)printf "%.0fM",k/1024;else printf "%dK",k}'; }
date_of() { date -d "@${1%.*}" +%F 2>/dev/null; }

# Nothing under PATH changed in the last N days (ctime also catches a move).
quiet_for() {
  local minutes=$(($2 * 1440))
  [ -z "$(find "$1" \( -mmin -"$minutes" -o -cmin -"$minutes" \) -print -quit 2>/dev/null)" ]
}
# As quiet_for, but also not read: a content cache is read far more than written.
cold_for() {
  local minutes=$(($2 * 1440))
  [ -z "$(find "$1" -type f \( -amin -"$minutes" -o -mmin -"$minutes" \) -print -quit 2>/dev/null)" ]
}

# Paths live processes hold: cwd and open files always; for a scan also their
# arguments and environment (a dev shell's TMPDIR is in use while its shell
# lives). --remove skips those two, because the caller's own command line names
# the path it was asked to remove.
open_paths=""
collect_open_paths() {
  local p pid
  open_paths=$(
    for p in /proc/[0-9]*; do
      pid=${p#/proc/}
      [ "$pid" = "$$" ] && continue
      readlink "$p/cwd" 2>/dev/null
      find "$p/fd" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null
      if [ "$1" = deep ]; then
        { tr '\0' '\n' <"$p/cmdline"; } 2>/dev/null
        { tr '\0' '\n' <"$p/environ"; } 2>/dev/null
      fi
    done | grep -oE "(${TMP_ROOT}|${HOME_DIR})/[^ :=,\"']+" | sort -u
  )
}
in_use() {
  awk -v p="$1" '$0 == p || index($0, p "/") == 1 {f=1; exit} END{exit !f}' <<<"$open_paths"
}

# Prints why a git repo under PATH must stay; prints nothing when all is pushed.
git_guard() {
  local dotgit repo out
  while IFS= read -r -d '' dotgit; do
    repo=$(dirname "$dotgit")
    if ! out=$(git -c core.fsmonitor=false -C "$repo" status --porcelain 2>/dev/null); then
      echo "unreadable repo $repo"
      return
    fi
    [ -z "$out" ] || { echo "uncommitted work in $repo"; return; }
    out=$(git -C "$repo" log --oneline -1 --branches HEAD --not --remotes 2>/dev/null)
    [ -z "$out" ] || { echo "unpushed commits in $repo"; return; }
    out=$(git -C "$repo" stash list 2>/dev/null)
    [ -z "$out" ] || { echo "stash in $repo"; return; }
  done < <(find "$1" -maxdepth 8 \( -name node_modules -prune \) -o -name .git -print0 2>/dev/null)
}

remove_tree() {
  if [ ! -L "$1" ] && [ -d "$1" ]; then
    chmod -R u+w -- "$1" 2>/dev/null # Go's module cache and nix-shell copies are read-only
  fi
  rm -rf -- "$1" 2>/dev/null
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

# Applies the CLEAN rule to one temporary entry. Returns 0 when it may go.
tmp_candidate() {
  local reason
  [ "$(stat -c %U -- "$1" 2>/dev/null)" = "$ME" ] || return 1
  quiet_for "$1" "$TMP_DAYS" || return 1
  if in_use "$1"; then
    kept tmp "a live process holds it" "$1"
    return 1
  fi
  reason=$(git_guard "$1")
  if [ -n "$reason" ]; then
    kept tmp "$reason" "$1"
    return 1
  fi
}

clean_area() {
  local area=$1 label=$2 total=0 kb p ok=0
  shift 2
  [ $# -gt 0 ] || return 0
  for p in "$@"; do total=$((total + $(size_kb "$p"))); done
  if [ "$mode" = apply ]; then
    for p in "$@"; do
      kb=$(size_kb "$p")
      if remove_tree "$p"; then
        ok=$((ok + 1)); n_removed=$((n_removed + 1))
      else
        total=$((total - kb))
        failed "$area" "could not remove $p"
      fi
    done
    emit REMOVED "$area" "$(human "$total")" "$ok of $# $label"
  else
    n_clean=$((n_clean + 1))
    emit CLEAN "$area" "$(human "$total")" "$# $label"
    if [ "$list" = 1 ]; then
      for p in "$@"; do emit ITEM "$area" "$(human "$(size_kb "$p")")" "$p"; done
    fi
  fi
}

scan_tmp() {
  local e name unknown=() items=()
  # Agent scratch dirs: session directories only, one by one.
  while IFS= read -r -d '' e; do
    tmp_candidate "$e" && items+=("$e")
  done < <(find "$TMP_ROOT/claude-$(id -u)" -mindepth 2 -maxdepth 2 -type d -regextype posix-extended \
    -regex '.*/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' -print0 2>/dev/null)
  # Known throwaway names at the top level. Anything else is reported, not removed:
  # tmux and Claude sockets and the guarded-test lock live here too.
  while IFS= read -r -d '' e; do
    name=$(basename "$e")
    case "$name" in
      nix-shell.* | nix-develop-* | tmp.* | ledger-* | colmap* | bunx-* | playwright* | \
        "${ME}"_sbomnix_* | nx-native-file-cache-* | node-compile-cache | torchinductor_*)
        tmp_candidate "$e" && items+=("$e")
        ;;
      claude-* | cc-* | tmux-* | systemd-private-* | kakapo-* | .*) ;;
      *)
        if [ "$(stat -c %U -- "$e" 2>/dev/null)" = "$ME" ] && quiet_for "$e" "$TMP_DAYS"; then
          unknown+=("$e")
        fi
        ;;
    esac
  done < <(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  clean_area tmp "temporary entries, quiet for ${TMP_DAYS} days" "${items[@]+"${items[@]}"}"
  for e in "${unknown[@]+"${unknown[@]}"}"; do
    ask tmp "$(human "$(size_kb "$e")")" "$e"
  done
  if [ "$mode" = apply ]; then
    # Project directories the removed sessions leave empty.
    find "$TMP_ROOT/claude-$(id -u)" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
  fi
}

scan_caches() {
  local c p kb cold=() known=" nix " e
  for c in "${CACHES[@]}"; do
    p=$HOME_DIR/$c
    [ -d "$p" ] || continue
    known+="$(basename "$p") "
    if cold_for "$p" "$CACHE_DAYS"; then
      cold+=("$p")
    else
      kb=$(size_kb "$p")
      [ "$kb" -ge "$ASK_MIN_KB" ] && ask cache "$(human "$kb")" "$p"
    fi
  done
  clean_area caches "caches not used for ${CACHE_DAYS} days" "${cold[@]+"${cold[@]}"}"
  # Large caches outside the list (model weights and so on): only Saleh decides.
  while IFS= read -r -d '' e; do
    case "$known" in *" $(basename "$e") "*) continue ;; esac
    kb=$(size_kb "$e")
    [ "$kb" -ge "$ASK_MIN_KB" ] && ask cache "$(human "$kb")" "$e"
  done < <(find "$HOME_DIR/.cache" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

scan_docker() {
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || {
    info docker "docker is not reachable; skipped"
    return
  }
  local used id repo r safe unit units_ok=1 name state size
  # A container's image id, not its name: pinned images show as untagged, so
  # `docker image prune` reads them as dangling and a stopped unit would lose
  # its image. Never prune here.
  # shellcheck disable=SC2046
  used=$(docker inspect --format '{{.Image}}' $(docker ps -aq) 2>/dev/null | sort -u)
  for unit in $DECLARED_UNITS; do
    systemctl is-active -q "$unit" || units_ok=0
  done
  while read -r id repo size; do
    [ -n "$id" ] || continue
    grep -qxF "$id" <<<"$used" && continue
    safe=0
    for r in $DECLARED_IMAGE_REPOS; do [ "$repo" = "$r" ] && safe=1; done
    if [ "$safe" = 1 ] && [ "$units_ok" = 1 ]; then
      if [ "$mode" = apply ]; then
        if docker image rm "$id" >/dev/null 2>&1; then
          n_removed=$((n_removed + 1))
          emit REMOVED docker "$size" "$repo ${id:7:12}"
        else
          failed docker "could not remove $repo ${id:7:12}"
        fi
      else
        n_clean=$((n_clean + 1))
        emit CLEAN docker "$size" "$repo ${id:7:12}: an old pin no container uses; the registry can restore it"
      fi
    else
      ask docker-image "$size" "$repo ${id:7:12}"
    fi
  done < <(docker image ls -a --no-trunc --format '{{.ID}} {{.Repository}} {{.Size}}' 2>/dev/null | sort -u)
  while read -r name state; do
    [ -n "$name" ] || continue
    [[ "$name" =~ $DECLARED_CONTAINER_RE ]] || chore docker-container "$name ($state) is not in the flake: a project left it, or it is drift"
  done < <(docker ps -a --format '{{.Names}} {{.State}}')
  while read -r name; do
    [ -n "$name" ] && ask docker-volume "?" "$name"
  done < <(docker volume ls -qf dangling=true 2>/dev/null)
  size=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null | awk '/^Build Cache/{print $3}')
  case "$size" in "" | 0B) ;; *) ask docker-build-cache "$size" "docker builder prune" ;; esac
}

scan_etc_nixos() {
  [ "$offline" = 0 ] || return 0
  [ -d /etc/nixos/.git ] || return 0
  local head remote state
  head=$(sudo -n git -C /etc/nixos rev-parse HEAD 2>/dev/null) || {
    info etc_nixos "sudo cannot read /etc/nixos; skipped"
    return
  }
  remote=$(git ls-remote "https://github.com/$REPO" refs/heads/master 2>/dev/null | cut -f1)
  [ -n "$remote" ] && [ "$head" != "$remote" ] || return 0
  state=$(sudo -n git -C /etc/nixos status --porcelain 2>/dev/null)
  if [ -n "$state" ]; then
    chore etc_nixos "/etc/nixos is behind master and has local changes: find whose they are"
  elif [ "$mode" = apply ]; then
    if sudo -n git -C /etc/nixos fetch -q origin 2>/dev/null &&
      sudo -n git -C /etc/nixos merge -q --ff-only origin/master >/dev/null 2>&1; then
      n_removed=$((n_removed + 1))
      emit REMOVED etc_nixos 0K "/etc/nixos fast-forwarded to ${remote:0:7}"
    else
      failed etc_nixos "could not fast-forward /etc/nixos"
    fi
  else
    n_clean=$((n_clean + 1))
    emit CLEAN etc_nixos 0K "/etc/nixos is behind master: --apply fast-forwards this reference checkout"
  fi
}

# GC removes a path that only a running agent's `nix build --no-link` knows of,
# so it waits until nothing builds, tests or deploys.
host_idle() {
  local busy
  "$SCRIPT_DIR/../../kakapo-change/scripts/host-busy.sh" >/dev/null 2>&1 || return 1
  busy=$(ps -eo args= | awk '{for (i = 1; i <= 3 && i <= NF; i++) if ($i ~ /(^|\/)(nixos-rebuild|nix-build|ci-local\.sh|deploy\.sh|guarded-test\.sh)$/ || ($i ~ /(^|\/)nix$/ && $(i+1) ~ /^(build|flake|develop|shell)$/)) { print; next }}')
  [ -z "$busy" ]
}
scan_nix_store() {
  local out
  if [ "$mode" != apply ]; then
    info nix_store "--apply runs nix store gc when the host is idle. It deletes no generation."
    return
  fi
  if ! host_idle; then
    chore nix_store "skipped nix store gc: another agent builds, tests or deploys now. Run --apply --only nix_store later"
    return
  fi
  if out=$(nix store gc 2>&1); then
    emit REMOVED nix_store "$(tail -1 <<<"$out" | grep -oE '[0-9.]+ [KMGT]iB' | tr -d ' ' | head -1)" "nix store gc"
  else
    failed nix_store "nix store gc failed"
  fi
}

describe_repo() {
  local reason
  [ -e "$1/.git" ] || return 0
  reason=$(git_guard "$1")
  printf ' [%s]' "${reason:-git: all pushed}"
}
scan_strays() {
  local e name
  while IFS= read -r -d '' e; do
    name=$(basename "$e")
    case "$HOME_KNOWN" in *" $name "*) continue ;; esac
    if quiet_for "$e" 3; then
      ask stray "$(human "$(size_kb "$e")")" "$e$(describe_repo "$e") changed $(date_of "$(stat -c %Y -- "$e")")"
    else
      info stray-active "$e changed in the last 3 days; leave it for now"
    fi
  done < <(find "$HOME_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  [ -d "$HOME_DIR/.claude/remote" ] && quiet_for "$HOME_DIR/.claude/remote" "$PROJECT_IDLE_DAYS" &&
    ask stray "$(human "$(size_kb "$HOME_DIR/.claude/remote")")" "$HOME_DIR/.claude/remote (the desktop app uploads it again)"
}

scan_projects() {
  local p name wt line kb
  for p in "$HOME_DIR"/src/*/; do
    p=${p%/}
    [ -d "$p/.git" ] || continue
    name=$(basename "$p")
    # Build output is the only part of a project that housekeeping may suggest.
    if [ -d "$p/node_modules" ] &&
      [ -z "$(find "$p" \( -name node_modules -o -name .direnv -o -name .git \) -prune -o -mmin -$((PROJECT_IDLE_DAYS * 1440)) -print -quit 2>/dev/null)" ]; then
      kb=$(size_kb "$p/node_modules")
      ask project-build "$(human "$kb")" "$p/node_modules"
    fi
    for line in "$p"/result "$p"/result-*; do
      [ -L "$line" ] && ask project-gcroot "$(human "$(size_kb "$(readlink -f "$line")")")" "$line"
    done
    while IFS= read -r wt; do
      [ "$wt" = "$p" ] && continue
      if git -C "$p" worktree list --porcelain | awk -v w="worktree $wt" '$0==w{f=1;next} /^worktree /{f=0} f&&/^locked/{l=1} END{exit !l}'; then
        info project-worktree "$wt is locked; leave it"
      else
        chore project-worktree "$name: review worktree $wt$(describe_repo "$wt"). Use git worktree remove when it is finished"
      fi
    done < <(git -C "$p" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  done
}

scan_var_lib() {
  local e
  while IFS= read -r -d '' e; do
    ask var-lib "$(human "$(sudo -n du -sk -- "$e" 2>/dev/null | awk '{print $1+0}')")" "$e (a migration copy: real data; confirm the service is healthy first)"
  done < <(sudo -n find /var/lib -mindepth 1 -maxdepth 1 -name '*.pre-*' -print0 2>/dev/null)
  local j
  j=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)
  [ -n "$j" ] && info journal "the journal uses $j; journald caps it, so vacuum is not needed"
  info state "$(sudo -n du -xsh /var/lib/docker /var/lib/nook /var/lib/private /var/cache/immich 2>/dev/null | awk '{printf "%s %s; ", $2, $1}') (service state: never housekeeping)"
}

scan_drift() {
  local out unit f
  out=$(nix-env -q 2>/dev/null)
  [ -z "$out" ] || chore drift "nix-env packages outside the flake: $(tr '\n' ' ' <<<"$out")"
  out=$(nix profile list 2>/dev/null | sed -n 's/^Name:[[:space:]]*//p')
  [ -z "$out" ] || chore drift "nix profile packages outside the flake: $(tr '\n' ' ' <<<"$out")"
  for f in .local/bin go/bin .bun/bin .cargo/bin .npm-global/bin; do
    [ -n "$(find "$HOME_DIR/$f" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ] &&
      chore drift "tools installed by hand in ~/$f: tools come from the flake or a project's flake"
  done
  while read -r unit; do
    [ -n "$unit" ] && chore drift "user unit enabled by hand: $unit"
  done < <(find "$HOME_DIR/.config/systemd/user" -mindepth 2 -type l -printf '%f\n' 2>/dev/null | sort -u)
  [ "$(loginctl show-user "$ME" -p Linger --value 2>/dev/null)" = yes ] &&
    chore drift "lingering is on for $ME, so user units outlive logins"
  [ -n "$(sudo -n find /var/spool/cron -type f 2>/dev/null | head -1)" ] && chore drift "a crontab exists: timers belong in the flake"
  out=$(sudo -n tailscale serve status 2>/dev/null)
  case "$out" in "" | *"No serve config"*) ;; *) chore drift "tailscale serve has config: nothing uses it, and boot clears it" ;; esac
  # Dev servers and jobs a session left: section 8 of projects.md says to stop them.
  while read -r line; do
    [ -n "$line" ] && chore listener "a user process listens: $line. Stop it if no session needs it"
  done < <(ss -ltnpH 2>/dev/null | awk -v OFS=' ' '{print $4, $6}' | grep 'users:' | cut -c1-120)
  while read -r line; do
    [ -n "$line" ] && chore old-process "runs for over 7 days: $line. Stop it if no session needs it"
  done < <(ps -u "$ME" -o etimes=,pid=,comm= | awk '$1 > 604800 && $3 !~ /^(systemd|\(sd-pam\)|dbus-broker|dbus-broker-lau|sshd|sshd-session|bash|tmux.*|\.claude-wrapped|claude|herdr|tuios)$/ {print $2, $3}')
  if [ "$(readlink -f /run/current-system)" != "$(readlink -f /nix/var/nix/profiles/system)" ]; then
    info test-activation "a test activation is live; 04:00 or a reboot replaces it. kakapo-health says more"
  fi
}

scan_git_hygiene() {
  [ "$offline" = 0 ] || return 0
  local cutoff line
  cutoff=$(date -d '7 days ago' +%FT%TZ)
  while read -r line; do
    [ -n "$line" ] && chore pr "open for over 7 days: #$line"
  done < <(gh pr list -R "$REPO" --state open --json number,isCrossRepository,createdAt --jq ".[] | select(.createdAt < \"$cutoff\") | \"\(.number)\" + (if .isCrossRepository then \" [external]\" else \"\" end)" 2>/dev/null)
  while read -r line; do
    [ -n "$line" ] && chore branch "remote branch with no open PR: $line"
  done < <(comm -23 \
    <(gh api "repos/$REPO/branches" --paginate --jq '.[].name' 2>/dev/null | grep -vxE 'master|hasala-release|flake-lock-bump' | sort) \
    <(gh pr list -R "$REPO" --state open --limit 100 --json headRefName --jq '.[].headRefName' 2>/dev/null | sort))
  # Only workflows that still exist: a removed one's old failure needs no action.
  local workflows name
  workflows=$(gh workflow list -R "$REPO" --json name --jq '.[].name' 2>/dev/null)
  while read -r name line; do
    [ -n "$name" ] && grep -qxF "$name" <<<"$workflows" && chore workflow "failed in the last 20 runs: $name $line"
  done < <(gh run list -R "$REPO" --limit 20 --json workflowName,conclusion,createdAt --jq '.[] | select(.conclusion == "failure") | .workflowName + " " + .createdAt' 2>/dev/null)
}

scan_generations() {
  local count old
  count=$(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' 2>/dev/null | wc -l)
  old=$(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' -mtime +38 2>/dev/null | wc -l)
  if [ "$count" -gt 4 ] && [ "$old" -gt 0 ]; then
    chore generations "$old generations are older than the policy allows (30 d + a weekly run): check prune-system-generations.service"
  else
    info generations "$count generations; the flake prunes them, so housekeeping does not"
  fi
}

# --remove: one named path at a time, with reasons printed for every refusal.
remove_one() {
  local p kb reason
  p=$(realpath -ms -- "$1")
  local sudo_rm=0
  case "$p" in
    "$HOME_DIR/.claude/remote") ;;
    "$HOME_DIR" | "$HOME_DIR/src" | "$HOME_DIR/.ssh"* | "$HOME_DIR/.gnupg"* | "$HOME_DIR/.claude" | "$HOME_DIR/.claude/"* | \
      "$HOME_DIR/.claude.json" | "$HOME_DIR/.config" | "$HOME_DIR/.config/"* | "$HOME_DIR/.local" | "$HOME_DIR/.local/"* | \
      "$HOME_DIR/.gitconfig" | "$HOME_DIR/.nix-profile" | "$HOME_DIR/.nix-defexpr" | "$HOME_DIR/.cache" | "$HOME_DIR/.cache/nix" | \
      "$HOME_DIR/.cache/nix/"* | "$TMP_ROOT/tmux-"* | "$TMP_ROOT/cc-"* | "$TMP_ROOT/kakapo-"* | "$TMP_ROOT/systemd-private-"*)
      failed remove "protected path: $p"
      return
      ;;
    "$HOME_DIR/"* | "$TMP_ROOT/"*) ;;
    /var/lib/*.pre-*) sudo_rm=1 ;;
    *)
      failed remove "outside the allowed roots: $p"
      return
      ;;
  esac
  if [ "$sudo_rm" = 1 ]; then
    if ! sudo -n test -e "$p"; then
      failed remove "does not exist: $p"
      return
    fi
    kb=$(sudo -n du -sk -- "$p" 2>/dev/null | awk '{print $1+0}')
    if sudo -n rm -rf -- "$p"; then
      n_removed=$((n_removed + 1))
      emit REMOVED remove "$(human "$kb")" "$p"
    else
      failed remove "could not remove $p"
    fi
    return
  fi
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    failed remove "does not exist: $p"
    return
  fi
  if [ -f "$p/.git" ]; then
    failed remove "a git worktree: use git worktree remove, so the repo forgets it: $p"
    return
  fi
  if in_use "$p"; then
    failed remove "a live process holds it: $p"
    return
  fi
  if [ "$discard_git" = 0 ]; then
    reason=$(git_guard "$p")
    if [ -n "$reason" ]; then
      failed remove "$reason. Saleh must name this again; then add --discard-git: $p"
      return
    fi
  fi
  kb=$(size_kb "$p")
  if remove_tree "$p"; then
    n_removed=$((n_removed + 1))
    emit REMOVED remove "$(human "$kb")" "$p"
  else
    failed remove "could not remove $p"
  fi
}

if [ "$mode" = remove ]; then
  collect_open_paths shallow
  for p in "${remove_paths[@]}"; do remove_one "$p"; done
else
  if [ "$mode" = apply ]; then
    exec 9>"$HOME_DIR/.cache/kakapo-housekeeping.lock" 2>/dev/null || exec 9>"$TMP_ROOT/kakapo-housekeeping.lock"
    flock -n 9 || {
      echo "another housekeeping run holds the lock" >&2
      exit 1
    }
  fi
  collect_open_paths deep
  for area in $AREAS; do
    want "$area" && "scan_$area"
  done
fi
emit SUMMARY "$mode" "clean=$n_clean ask=$n_ask kept=$n_kept chore=$n_chore removed=$n_removed failed=$n_failed"
[ "$n_failed" -eq 0 ]
