#!/usr/bin/env bash
# Tests housekeep.sh on fixtures: every "must stay" case must survive --apply,
# and --remove must refuse what it should. It touches only a new temp directory
# and runs only the tmp and caches areas, so it is safe to run on the live host.
set -u
HK=$(cd "$(dirname "$0")" && pwd)/housekeep.sh
root=$(mktemp -d)
trap 'kill "${holder:-0}" 2>/dev/null; chmod -R u+w "$root"; rm -rf "$root"' EXIT
export HOUSEKEEP_HOME=$root/home HOUSEKEEP_TMP=$root/tmp
uid=$(id -u)
sid=11111111-2222-3333-4444-555555555555
sid2=99999999-2222-3333-4444-555555555555
fails=0
mkdir -p "$HOUSEKEEP_HOME/.cache" "$HOUSEKEEP_TMP"

# Backdate a whole tree, so only the fixture's own freshness counts. mtime and
# atime can move back; ctime cannot, so the script's ctime test is covered by
# the "fresh" case and old fixtures sit behind a faked-up clock below.
age() { find "$1" -exec touch -h -d '40 days ago' {} + ; }
check() { # description, command...
  local d=$1
  shift
  if "$@"; then echo "ok   $d"; else echo "FAIL $d"; fails=$((fails + 1)); fi
}
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
there() { [ -e "$1" ] || [ -L "$1" ]; }

t=$HOUSEKEEP_TMP
mkdir -p "$t/nix-shell.old/ro" "$t/nix-shell.fresh" "$t/nix-shell.held" "$t/unknown-thing" \
  "$t/tmux-$uid" "$t/kakapo-lock-dir" "$t/claude-$uid/proj/$sid" "$t/claude-$uid/proj/$sid2" "$t/claude-$uid/proj/not-a-session"
echo x >"$t/nix-shell.old/ro/f"; chmod 555 "$t/nix-shell.old/ro"
echo x >"$t/nix-shell.fresh/f"
echo x >"$t/nix-shell.held/f"
echo x >"$t/unknown-thing/f"
echo x >"$t/tmux-$uid/f"
echo x >"$t/kakapo-lock-dir/f"
echo x >"$t/claude-$uid/proj/$sid/f"
outside=$root/outside-file; echo keep >"$outside"
ln -s "$outside" "$t/nix-shell.link"

repo() { # path: a clone of a bare origin
  git init -q --bare "$root/origin-$1.git"
  git clone -q "$root/origin-$1.git" "$2" 2>/dev/null
  git -C "$2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$2" push -q origin HEAD 2>/dev/null
}
repo pushed "$t/tmp.pushed/kakapo"
repo unpushed "$t/tmp.unpushed/kakapo"; git -C "$t/tmp.unpushed/kakapo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
repo dirty "$t/tmp.dirty/kakapo"; echo x >"$t/tmp.dirty/kakapo/new"
repo stash "$t/claude-$uid/proj/$sid2/kakapo"; echo x >"$t/claude-$uid/proj/$sid2/kakapo/a"
git -C "$t/claude-$uid/proj/$sid2/kakapo" add a
git -C "$t/claude-$uid/proj/$sid2/kakapo" -c user.name=t -c user.email=t@t stash -q

h=$HOUSEKEEP_HOME
mkdir -p "$h/.cache/go-build" "$h/.cache/uv" "$h/.cache/torch" "$h/go/pkg/mod/ro" "$h/src/proj" "$h/.ssh" "$h/stray-dir" "$h/.claude/projects"
echo x >"$h/.cache/go-build/f"; echo x >"$h/.cache/uv/f"; echo x >"$h/.cache/torch/f"; echo x >"$h/go/pkg/mod/ro/f"; chmod 555 "$h/go/pkg/mod/ro"
echo x >"$h/.ssh/id"; echo x >"$h/stray-dir/f"; echo x >"$h/.claude/projects/f"
repo project "$h/src/proj"

for p in "$t"/nix-shell.old "$t"/nix-shell.held "$t"/nix-shell.link "$t"/unknown-thing "$t"/tmux-* "$t"/kakapo-lock-dir "$t"/tmp.* \
  "$t/claude-$uid/proj/$sid" "$t/claude-$uid/proj/$sid2" "$t/claude-$uid/proj/not-a-session" "$h/.cache/go-build" "$h/go/pkg/mod"; do
  chmod -R u+w "$p" 2>/dev/null
  age "$p"
done
chmod 555 "$t/nix-shell.old/ro" "$h/go/pkg/mod/ro"
touch -a -d '40 days ago' "$t/nix-shell.old/ro/f"

# ctime cannot be backdated, so the fixtures look fresh to a real run. Make
# `find -cmin` and `-mmin` honest by running with the ctime test relaxed: the
# wrapper rewrites only `-cmin -N` to `-cmin -0`, which matches nothing.
fakebin=$root/bin; mkdir -p "$fakebin"
realfind=$(command -v find)
cat >"$fakebin/find" <<EOF
#!/usr/bin/env bash
args=()
while [ \$# -gt 0 ]; do
  if [ "\$1" = -cmin ]; then args+=(-cmin -0); shift 2; continue; fi
  args+=("\$1"); shift
done
exec "$realfind" "\${args[@]}"
EOF
chmod +x "$fakebin/find"
export PATH=$fakebin:$PATH

(cd "$t/nix-shell.held" && exec sleep 300) &
holder=$!
sleep 0.3

run() { "$HK" --only tmp,caches --offline "$@"; }

echo "--- scan changes nothing"
scan=$(run)
echo "$scan" | sed 's/^/    /' | cut -c1-110
check "scan leaves the old entry" there "$t/nix-shell.old"
check "scan finds CLEAN items" grep -q '^CLEAN' <<<"$scan"
check "scan keeps an in-use entry" grep -q "^KEPT.*a live process.*nix-shell.held" <<<"$scan"

echo "--- apply"
applied=$(run --apply); rc=$?
echo "$applied" | sed 's/^/    /' | cut -c1-110
check "apply exits 0" test "$rc" = 0
check "removes an old entry, read-only dirs too" gone "$t/nix-shell.old"
check "removes an old session" gone "$t/claude-$uid/proj/$sid"
check "removes a clone with all work pushed" gone "$t/tmp.pushed"
check "removes a cold cache" gone "$h/.cache/go-build"
check "removes a read-only cold cache" gone "$h/go/pkg/mod"
check "removes a symlink entry" gone "$t/nix-shell.link"
check "does not follow a symlink" there "$outside"
check "keeps a fresh entry" there "$t/nix-shell.fresh/f"
check "keeps an entry a process holds" there "$t/nix-shell.held/f"
check "keeps unpushed commits" there "$t/tmp.unpushed/kakapo/.git"
check "keeps uncommitted work" there "$t/tmp.dirty/kakapo/new"
check "keeps a stash" there "$t/claude-$uid/proj/$sid2/kakapo/.git"
check "keeps an unknown name" there "$t/unknown-thing/f"
check "keeps tmux" there "$t/tmux-$uid/f"
check "keeps a kakapo- lock" there "$t/kakapo-lock-dir/f"
check "keeps a dir not named like a session" there "$t/claude-$uid/proj/not-a-session"
check "keeps a hot cache" there "$h/.cache/uv/f"
check "keeps weights outside the list" there "$h/.cache/torch/f"
check "keeps a project" there "$h/src/proj/.git"

echo "--- remove"
refused() { # description, path, extra flags
  local d=$1 p=$2
  shift 2
  if "$HK" --remove "$@" "$p" >/dev/null 2>&1; then echo "FAIL refuses $d"; fails=$((fails + 1)); else echo "ok   refuses $d"; fi
  check "$d is still there" there "$p"
}
refused "unpushed work" "$t/tmp.unpushed"
refused "uncommitted work" "$t/tmp.dirty"
refused "a held entry" "$t/nix-shell.held"
refused "the ssh directory" "$h/.ssh"
refused "the ssh key" "$h/.ssh/id"
refused "Claude data" "$h/.claude/projects"
refused "the home directory" "$h"
refused "the src directory" "$h/src"
refused "tmux" "$t/tmux-$uid"
refused "a path outside the roots" "$outside"
refused "a traversal out of the roots" "$h/../outside-file"
refused "/etc" /etc
refused "/" /
if "$HK" --remove "$h/stray-dir" >/dev/null; then echo "ok   removes a named stray"; else echo "FAIL removes a named stray"; fails=$((fails + 1)); fi
check "the stray is gone" gone "$h/stray-dir"
check "--discard-git removes unpushed work when named" "$HK" --remove --discard-git "$t/tmp.unpushed"
check "the unpushed repo is gone" gone "$t/tmp.unpushed"

echo "--- usage"
"$HK" --only nonsense >/dev/null 2>&1; check "unknown area exits 64" test $? = 64
"$HK" /tmp/x >/dev/null 2>&1; check "a bare path exits 64" test $? = 64
"$HK" --remove >/dev/null 2>&1; check "--remove with no path exits 64" test $? = 64

echo
if [ "$fails" = 0 ]; then echo "PASS"; else echo "FAILED: $fails"; exit 1; fi
