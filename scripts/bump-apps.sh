#!/usr/bin/env bash
# Moves the apps kakapo pins outside flake.lock to their newest release.
# Run from the repo root by the daily `apps` run of
# .github/workflows/update-flake-lock.yml, or by hand:
#
#   scripts/bump-apps.sh [app...]     (default: every app below)
#
# Apps:
#   claude-code  pkgs/claude-code/manifest.json, Anthropic's own release
#                manifest for one version (the file nixpkgs' claude-code
#                package reads; flake.nix passes ours in). It follows the
#                `latest` channel, the one nixpkgs follows too. The manifest
#                carries each platform's SHA-256, so there is no hash to
#                prefetch: the build checks the download against it.
#
# Never moves an app back: a version set by hand ahead of the channel stays
# until the channel passes it. An app that cannot be bumped is left as it was,
# with a warning, and the rest go ahead. Exit status is 0 unless an argument
# names an unknown app.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

apps=("$@")
[ ${#apps[@]} -gt 0 ] || apps=(claude-code)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
note() {
  echo "$*"
  echo "- $*" >>"$summary"
}

# True when $1 is a newer version than $2.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

bump_claude_code() {
  local base=https://downloads.claude.ai/claude-code-releases
  local file=pkgs/claude-code/manifest.json cur new tmp
  cur=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$file") ||
    { note "claude-code: cannot read the version in $file"; return 1; }
  new=$(curl -fsSL --max-time 30 "$base/latest" | tr -d '[:space:]')
  [[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { note "claude-code: the latest channel gave no version"; return 1; }
  if ! newer "$new" "$cur"; then
    echo "claude-code: $cur is current (channel: $new)"
    return 0
  fi
  tmp=$(mktemp)
  curl -fsSL --max-time 60 "$base/$new/manifest.zst.json" -o "$tmp" ||
    { note "claude-code $new: no manifest.zst.json"; rm -f "$tmp"; return 1; }
  # The manifest must be for that version and carry a checksum for every
  # platform this flake builds; anything else keeps the old one.
  python3 -I - "$tmp" "$new" <<'EOF' || { note "claude-code $new: unexpected manifest; kept $cur"; rm -f "$tmp"; return 1; }
import json, re, sys
m = json.load(open(sys.argv[1]))
assert m["version"] == sys.argv[2], "version"
for platform in ("linux-x64",):
    entry = m["platforms"][platform]
    assert re.fullmatch(r"[0-9a-f]{64}", entry["checksum"]), platform
    assert entry["binary"], platform
EOF
  python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=2); open(sys.argv[2], "a").write("\n")' "$tmp" "$file"
  rm -f "$tmp"
  note "claude-code: $cur -> $new"
}

rc=0
for app in "${apps[@]}"; do
  case $app in
    claude-code) bump_claude_code || true ;;
    *)
      echo "unknown app: $app" >&2
      rc=2
      ;;
  esac
done
exit "$rc"
