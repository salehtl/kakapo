# Working on projects on kakapo

This file is loaded for every agent session under `~/src`. It is managed by
the kakapo flake (`modules/claude-projects.md` in github:salehtl/kakapo), so
edits here do not stick: change it there.

kakapo is a home server first. It answers DNS for every device in the house
(AdGuard), and runs ledger (real financial data), Immich (the photo library),
Grafana and a few more apps. Project work happens alongside them and must
never put them at risk. When a rule below gets in your way, stop and ask the
user; do not work around it.

## 1. Where projects live

- Every project is its own git repository at `~/src/<name>`. Clone or create
  projects there, nowhere else.
- Push to a remote early and often. Treat the machine as disposable: work that
  exists only on kakapo is at risk.

## 2. Tools come from the project, never the system

Each project declares its whole toolchain in its own `flake.nix` devShell and
pins it with a committed `flake.lock`. Nothing a project needs is installed on
the host.

- No global installs: no `nix profile install`, `nix-env -i`, `npm -g`,
  `pip install --user`, `cargo install`, `go install` to `~/go/bin`, or
  `curl … | sh` installers.
- Do not rely on tools that happen to be on the host (node, python, gcc). The
  system Node.js is temporary and will go away. If the project needs it, the
  flake declares it.
- Never add a project's tool to the kakapo flake.
- A project without a flake gets one before anything else is installed:

```nix
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05"; # or nixos-unstable
  outputs =
    { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          pkgs.nodejs_22
          pkgs.pnpm
        ];
      };
    };
}
```

- Next to the flake, commit an `.envrc` containing one line, `use flake`, and
  run `direnv allow` once. direnv (with nix-direnv) then loads the devShell
  whenever a shell enters the project, and keeps its tools from being
  garbage-collected while the project exists.
- Agents' shells are not interactive, so direnv does not load by itself.
  Run every command through it: `direnv exec . <command>` (cached, fast), or
  `nix develop -c <command>` where there is no `.envrc`. Tools are fetched on
  first use and then stay cached.
- Unfree packages and CUDA are enabled in the project's own flake, never on
  the host: `pkgs = import nixpkgs { system = "x86_64-linux"; config =
  { allowUnfree = true; cudaSupport = true; }; };`. The host carries only the
  NVIDIA driver (RTX 2060, 6 GB).
- Language package managers (npm, pnpm, pip/uv, cargo) are fine inside the
  devShell. Their output stays in the project (`node_modules/`, `.venv/`,
  `target/`) and is gitignored, along with `result` and `.direnv/`.

## 3. Setting up an existing repository

1. Clone it to `~/src/<name>` and read its README, CONTRIBUTING and any
   `CLAUDE.md`/`AGENTS.md`. Those govern the code; this file governs the
   machine.
2. Use the repo's own environment if it has one (a `flake.nix` with an
   x86_64-linux devShell, or devenv). Otherwise write a flake from what the
   repo pins: `.nvmrc`/`.node-version`, `package.json` (`engines`,
   `packageManager`), `.python-version`/`pyproject.toml`, `uv.lock`,
   `rust-toolchain.toml`, `go.mod`, `.tool-versions`, `.ruby-version`,
   `.devcontainer/`, a Dockerfile's `FROM`. Match major versions, use
   `nixos-unstable` when 26.05 lacks one, and note any version you guessed.
3. Where the flake goes depends on whose repo it is:
   - The user's own repos (ask if unsure): `flake.nix`, `flake.lock` and
     `.envrc` go in the repo and are committed like any change.
   - Anyone else's: never add them to the repo. Put the flake in a sibling
     directory, `~/src/<name>.nix/`, point the repo's `.envrc` at it
     (`use flake ../<name>.nix`), and list `.envrc` and `.direnv/` in
     `.git/info/exclude`. The repo's `git status` stays clean, so nothing can
     leak into a commit or PR. A flake inside a git repo is invisible to Nix
     until git tracks it ("is not tracked by Git"); never work around that
     with `git add`, a `path:` flake or a global install.
4. `direnv allow`, then install dependencies with the project's own tool:
   `direnv exec . <command>`.
5. Copy `.env.example` (or similar) to `.env` with local values. Ask the user
   for real credentials; never commit them.
6. If the repo has a compose file, publish its ports on loopback with an
   untracked `compose.override.yaml` (excluded like `.envrc`). It needs
   `!override`: without it Compose adds these ports to the original ones and
   the `0.0.0.0` binding stays.

   ```yaml
   services:
     db:
       ports: !override ["127.0.0.1:55432:5432"]
   ```

   Dev servers that listen on all interfaces by default (Next.js, Django on
   `0.0.0.0`, …) get their host option set to `127.0.0.1`.
7. Done means proven: the project's install and tests (or build) pass through
   `direnv exec .`, and `ss -ltnp` shows nothing of yours on `0.0.0.0`.
   Report what you set up, what is committed and what stays local, and any
   version you had to guess.

## 4. Dev servers and services

- Bind to `127.0.0.1`. Never `0.0.0.0` or `::`: Tailscale accepts all traffic
  from the tailnet ahead of the firewall, so anything listening on all
  interfaces is reachable by every tailnet device, including other people's.
- Do not open firewall ports, use `tailscale serve`/`funnel`, or edit nginx.
  To reach a dev server from another device, use an SSH tunnel
  (`ssh -L 5173:127.0.0.1:5173 kakapo`). If a phone needs it, ask the user to
  give it a tailnet-only name in the kakapo flake.
- Ports already taken, never reuse: 22, 53, 443, 2283, 3000, 3001, 3003, 3773,
  5432, 8090, 9090, 9100, 9633, 9835. Check `ss -ltn` before picking one.
- A database or queue for a project runs from the project: `docker compose`,
  or devenv/process-compose. Never use the host's Postgres (5432) or Redis:
  they belong to Immich.
- Docker publishes ports past the host firewall. Always bind them to loopback
  (`127.0.0.1:5432:5432`, never `5432:5432`), prefix names with the project,
  and tear down with `docker compose down -v` when done.

## 5. Privileges

- No `sudo` for project work. The user has passwordless sudo, so a mistake
  here is a mistake as root on the house's DNS server.
- Do not touch `/etc`, system services (`systemctl` on anything but your own
  `--user` units), `nixos-rebuild`, `/etc/nixos` or the kakapo flake from a
  project session. Host changes are separate work that follows
  `/etc/nixos/CLAUDE.md`.
- Never read `/run/secrets` or other services' state (`/var/lib/*`). A
  project's own secrets go in a gitignored `.env`, never in the repo.

## 6. Share the machine

8 cores / 16 threads and 32 GB are shared with the house's services, and
nothing enforces limits yet.

- Keep builds and test runs to about half the machine (`-j8`, a few workers),
  and run long or heavy jobs at low priority: `nice -n 10 <command>`.
- Stay under ~16 GB of memory. If something may need more, ask first.
- Long-running processes go in herdr or tmux, and are stopped when done.
- The disk is large but not infinite; leave datasets and model weights out
  of `~/src` unless the project needs them, and say where you put them.

## 7. From project to production

A project that should run permanently becomes a NixOS module in the kakapo
flake (`modules/services/<name>.nix`): branch, `scripts/guarded-test.sh`,
merge to master, as `/etc/nixos/CLAUDE.md` describes. That is a deploy and
needs the user's go-ahead. Until then it only runs while someone runs it.

## 8. Cleaning up

At the end of every session (the project stays):

- Stop what you started: dev servers, watchers and background jobs
  (`ss -ltnp` shows nothing of yours), and containers (`docker compose stop`
  keeps their data).
- Commit and push work worth keeping. Nothing changed outside
  `~/src/<name>` (and `~/src/<name>.nix`).

When a project is finished for good (only when the user says so; if your
tools will not delete a directory, give the user the commands instead):

1. Check everything worth keeping is pushed: `git status`, `git log @{u}..`.
2. `docker compose down -v --rmi local`: its containers, volumes and the
   images built for it.
3. Delete `~/src/<name>`, and `~/src/<name>.nix` if there is one.
4. `nix store gc`. Deleting the project deleted its `.direnv/`, which is what
   kept its tools alive; the weekly GC would get them anyway.

Shared caches (npm, pnpm, uv, cargo, Docker's build cache) serve every
project. Leave them alone unless the user asks.
