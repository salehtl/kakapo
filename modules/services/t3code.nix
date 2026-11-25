# T3 Code (github.com/pingdotgg/t3code, 2026-11-19): a web UI for coding
# agents (Codex, Claude Code). Package from nixpkgs-unstable (not in 26.05);
# only its headless server (`t3 serve`) runs here, not the Electron app.
#
# User:    its own system user `t3code`, by Saleh's choice (2026-11-19): no
#          sudo, no access to /home, and NoNewPrivileges. Agents run shell
#          commands as this user, so it must never join `wheel`, `docker` or
#          any group that reaches root or the house DNS.
# State:   /var/lib/t3code (0700, t3code): t3's data in `t3/`, the agents'
#          own logins in the home directory (`.codex`, `.claude`), and the
#          workspace in `work/`. Claude Code uses CLIProxyAPI on loopback
#          with its API key, so it needs no login here (2026-11-19). Codex
#          logs in out of band (commands below). Projects are cloned
#          to /var/lib/t3code/<name>, so the project rules
#          (modules/claude-projects.md) are linked as
#          /var/lib/t3code/CLAUDE.md: Claude Code loads every CLAUDE.md from
#          the working directory up, and ~/src/CLAUDE.md (modules/claude.nix)
#          exists only for normal users.
# Limits:  every agent of every session is in this one cgroup, and the host
#          has no swap. With MemoryMax=8G and the default OOMPolicy=stop, two
#          parallel Nix evaluations stopped the whole unit twice on
#          2026-11-22, which ended every agent session at once. Now 14G
#          (throttle and reclaim) / 16G (hard) of the host's 31 GiB, and
#          OOMPolicy=continue: the kernel kills one process and the unit
#          stays up. CPUWeight/IOWeight are half the default, so under
#          contention each house service gets twice this unit's share
#          (IOWeight does nothing until a disk uses BFQ or io.cost). Builds
#          that agents start run in nix-daemon.service, outside these limits.
#          The unit restarts when an activation changes it (restartIfChanged
#          is the default), which ends every running agent session.
# GitHub:  a fine-grained token of Saleh's (secrets/t3code.yaml), scoped to
#          chosen repos with no `statuses` or `workflows` permission, so a
#          t3 agent can push branches and open PRs but cannot make a PR green
#          and merge it (write access to kakapo with statuses is root here).
#          It reaches the unit only through LoadCredential= as GH_TOKEN.
#          A fine-grained token has one owner, so the Hasala org
#          (github.com/Hasala, since 2026-11-22) has its own token
#          (secrets/t3code-hasala.yaml, GH_TOKEN_HASALA) with the same
#          limits. `gh` (ghByOwner) and git (gitCredential) pick the token
#          by the repository's owner. Never a copy of Saleh's own `gh` login
#          or SSH key.
# Ingress: tailnet only, https://t3.salehtl.com via the LAN proxy's
#          `tailnetOnly` list (tailscale-nginx-auth), plus t3's own pairing:
#          a browser must present a one-time pairing token first
#          (`t3code-pair` on kakapo). Never `--lan`, `--tailscale-serve` or
#          `t3 up`: they bind off loopback or use tailscale serve.
#
# Own user, not saleh: saleh has passwordless sudo, and agents run shell
#          commands from a web page.
# Pairing: `t3code-pair` mints a 5-minute token and prints the URL to open.
#          Never `t3 pair --tailscale`.
# Codex:   sudo -u t3code -H codex login --device-auth
# Gemini:  sign in by hand in t3's provider settings. Never its "Install"
#          button: the flake owns the Antigravity runtime.
# GitHub:  the token has Contents and Pull requests write only, and expires.
#          Rotate it with `sops secrets/t3code.yaml`. CI and guarded-test for a
#          t3 agent's PR run from Saleh's own session.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  port = 3773;
  stateDir = "/var/lib/t3code";
  baseDir = "${stateDir}/t3";
  workDir = "${stateDir}/work";
  # GitHub tokens by repository owner. GH_TOKEN is Saleh's personal token;
  # a repository of the Hasala org uses GH_TOKEN_HASALA. Both are set in the
  # unit's script from LoadCredential=.
  ghByOwner = pkgs.writeShellScriptBin "gh" ''
    # The owner comes only from places that name a repository, never from
    # free text (a --title or --body can hold "Owner/repo" or a URL):
    #   1. -R/--repo (OWNER/REPO, HOST/OWNER/REPO or a URL);
    #   2. `gh api`: the first REST path argument, repos/OWNER/... or orgs/OWNER;
    #   3. `gh GROUP COMMAND TARGET`: TARGET, the third argument, when it is
    #      OWNER/REPO or a github.com URL;
    #   4. GH_REPO, then the `origin` remote of the current directory.
    own() {
      local r=$1
      r=''${r#*://}; r=''${r#git@}; r=''${r#github.com}; r=''${r#[:/]}
      printf '%s' "''${r%%/*}"
    }
    owner= prev=
    for a in "$@"; do
      case "$prev" in -R | --repo) owner=$(own "$a") ;; esac
      case "$a" in
        --repo=*) owner=$(own "''${a#--repo=}") ;;
        -R?*) owner=$(own "''${a#-R}") ;;
      esac
      prev=$a
    done
    if [ -z "$owner" ] && [ "''${1:-}" = api ]; then
      for a in "''${@:2}"; do
        case "$a" in
          repos/* | /repos/* | orgs/* | /orgs/*) r=''${a#/}; r=''${r#*/}; owner=''${r%%/*}; break ;;
        esac
      done
      # {owner} is filled in by gh from the current repository.
      [ "$owner" != "{owner}" ] || owner=
    elif [ -z "$owner" ]; then
      case "''${3:-}" in
        -* | "") ;;
        *github.com[/:]*) owner=$(own "''${3#*github.com}") ;;
        */*) owner=''${3%%/*} ;;
      esac
    fi
    [ -n "$owner" ] || [ -z "''${GH_REPO:-}" ] || owner=$(own "$GH_REPO")
    if [ -z "$owner" ]; then
      url=$(${lib.getExe pkgs.git} remote get-url origin 2>/dev/null || true)
      case "$url" in *github.com[/:]*) owner=$(own "''${url#*github.com}") ;; esac
    fi
    case "''${owner,,}" in
      hasala) [ -z "''${GH_TOKEN_HASALA:-}" ] || export GH_TOKEN="$GH_TOKEN_HASALA" ;;
    esac
    exec ${lib.getExe pkgs.gh} "$@"
  '';
  # git's credential helper for https://github.com, with the same rule.
  gitCredential = pkgs.writeShellScript "t3code-git-credential" ''
    [ "''${1:-}" = get ] || exit 0
    host= path=
    while IFS== read -r k v; do
      [ -n "$k" ] || break
      case "$k" in host) host=$v ;; path) path=$v ;; esac
    done
    [ "$host" = github.com ] || exit 0
    token=''${GH_TOKEN:-}
    owner=''${path%%/*}
    case "''${owner,,}" in hasala) token=''${GH_TOKEN_HASALA:-$token} ;; esac
    [ -n "$token" ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$token"
  '';
  package = pkgs.unstable.t3code.override {
    enableClaude = true;
    gh = ghByOwner;
  };
  t3 = lib.getExe' package "t3";

  # Google's Antigravity ACP runtime, which t3's `antigravity` provider runs
  # for Gemini with Saleh's Google subscription (2026-11-22). t3 would
  # download it into its state on its own ("Install" in the provider
  # settings); this is the same release, pinned to the version and hash
  # t3 0.1.8 carries (`antigravityRelease.ts`), so the flake owns it. t3
  # finds `agy_acp_server.par` on PATH and takes `localharness_external`
  # from the directory it resolves to, so both stay side by side.
  # Not patched: the harness is static and the server needs only glibc,
  # which nix-ld provides (modules/claude.nix). patchelf would also move
  # the archive the .par carries at its end. About 1 GB in the store.
  # Bump it with t3: take the linux-x64 url and sha256 from its release.
  antigravityAcp = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "agy-acp-server";
    version = "1.4.5";
    src = pkgs.fetchurl {
      url = "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-${version}-linux-x86_64.zip";
      hash = "sha256-kjkjoNfcgHP2bMb3hkejEH46fuK34aJN+LOSe1GIATs=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      install -Dm755 agy_acp_server.par localharness_external -t $out/libexec/agy-acp-server
      mkdir -p $out/bin
      ln -s $out/libexec/agy-acp-server/agy_acp_server.par $out/bin/agy_acp_server.par
    '';
    meta = {
      description = "Antigravity ACP server for T3 Code's antigravity provider";
      license = lib.licenses.unfree;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      platforms = [ "x86_64-linux" ];
    };
  };

  # Mint a one-time pairing token for a browser, as the service user.
  pair = pkgs.writeShellScriptBin "t3code-pair" ''
    exec /run/wrappers/bin/sudo -u t3code HOME=${stateDir} ${t3} pair --base-dir ${baseDir} "$@"
  '';
in
{
  users.users.t3code = {
    isSystemUser = true;
    group = "t3code";
    home = stateDir;
    shell = pkgs.bashInteractive;
  };
  users.groups.t3code = { };

  systemd.tmpfiles.settings.t3code = {
    ${baseDir}.d = {
      user = "t3code";
      group = "t3code";
      mode = "0700";
    };
    ${workDir}.d = {
      user = "t3code";
      group = "t3code";
      mode = "0700";
    };
    # The project rules, for every session under the state directory. Same
    # line as ~/src/CLAUDE.md in modules/claude.nix.
    "${stateDir}/CLAUDE.md"."L+".argument = "/etc/claude-code/projects.md";
  };

  systemd.services.t3code = {
    description = "T3 Code server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # What the agents run: a basic shell kit (jq, bc, unzip and file since
    # 2026-11-22, because agents and project scripts kept failing without
    # them). Projects bring the rest from their own flakes.
    path = [
      package
      antigravityAcp
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.ripgrep
      pkgs.jq
      pkgs.bc
      pkgs.unzip
      pkgs.file
      pkgs.git
      ghByOwner
      pkgs.openssh
      pkgs.nix
    ];
    environment = {
      HOME = stateDir;
      DISABLE_AUTOUPDATER = "1";
      # Claude Code talks to CLIProxyAPI (modules/services/cliproxyapi.nix),
      # which holds Saleh's Claude login, so `t3code` needs no login of its
      # own. The key comes from the credential below, set in the script.
      ANTHROPIC_BASE_URL = "http://127.0.0.1:${toString config.services.cliproxyapi.settings.server.port}";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      # HTTPS git to github.com authenticates with the owner's token (set
      # below), in the environment rather than a ~/.gitconfig, so the flake
      # owns it. useHttpPath gives the helper the repository path.
      GIT_CONFIG_COUNT = "3";
      GIT_CONFIG_KEY_0 = "credential.https://github.com.helper";
      GIT_CONFIG_VALUE_0 = "";
      GIT_CONFIG_KEY_1 = "credential.https://github.com.helper";
      GIT_CONFIG_VALUE_1 = "${gitCredential}";
      GIT_CONFIG_KEY_2 = "credential.https://github.com.useHttpPath";
      GIT_CONFIG_VALUE_2 = "true";
    };
    script = ''
      ANTHROPIC_AUTH_TOKEN=$(<"$CREDENTIALS_DIRECTORY/cliproxy-api-key")
      export ANTHROPIC_AUTH_TOKEN
      GH_TOKEN=$(<"$CREDENTIALS_DIRECTORY/github-token")
      export GH_TOKEN
      GH_TOKEN_HASALA=$(<"$CREDENTIALS_DIRECTORY/github-token-hasala")
      export GH_TOKEN_HASALA
      exec ${t3} serve --mode web --host 127.0.0.1 --port ${toString port} --base-dir ${baseDir} --no-browser ${workDir}
    '';
    serviceConfig = {
      User = "t3code";
      Group = "t3code";
      StateDirectory = "t3code";
      StateDirectoryMode = "0700";
      WorkingDirectory = workDir;
      LoadCredential = [
        "cliproxy-api-key:${config.sops.secrets."cliproxyapi/api_key".path}"
        "github-token:${config.sops.secrets."t3code/github_token".path}"
        "github-token-hasala:${config.sops.secrets."t3code/github_token_hasala".path}"
      ];
      Restart = "on-failure";
      RestartSec = 5;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      UMask = "0077";

      # See "Limits" at the top of this file.
      MemoryHigh = "14G";
      MemoryMax = "16G";
      OOMPolicy = "continue";
      CPUWeight = 50;
      IOWeight = 50;
    };
  };

  # Agent shells put /run/current-system/sw/bin before the unit's PATH, so
  # the wrapper must also be the system's `gh`. It changes nothing for other
  # users: without GH_TOKEN_HASALA it only runs gh.
  environment.systemPackages = [
    pair
    (lib.hiPrio ghByOwner)
  ];
}
