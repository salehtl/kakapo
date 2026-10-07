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

## 3. Dev servers and services

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

## 4. Privileges

- No `sudo` for project work. The user has passwordless sudo, so a mistake
  here is a mistake as root on the house's DNS server.
- Do not touch `/etc`, system services (`systemctl` on anything but your own
  `--user` units), `nixos-rebuild`, `/etc/nixos` or the kakapo flake from a
  project session. Host changes are separate work that follows
  `/etc/nixos/CLAUDE.md`.
- Never read `/run/secrets` or other services' state (`/var/lib/*`). A
  project's own secrets go in a gitignored `.env`, never in the repo.

## 5. Share the machine

8 cores / 16 threads and 32 GB are shared with the house's services, and
nothing enforces limits yet.

- Keep builds and test runs to about half the machine (`-j8`, a few workers),
  and run long or heavy jobs at low priority: `nice -n 10 <command>`.
- Stay under ~16 GB of memory. If something may need more, ask first.
- Long-running processes go in herdr or tmux, and are stopped when done.
- The disk is large but not infinite; leave datasets and model weights out
  of `~/src` unless the project needs them, and say where you put them.

## 6. From project to production

A project that should run permanently becomes a NixOS module in the kakapo
flake (`modules/services/<name>.nix`): branch, `scripts/guarded-test.sh`,
merge to master, as `/etc/nixos/CLAUDE.md` describes. That is a deploy and
needs the user's go-ahead. Until then it only runs while someone runs it.

## 7. Cleaning up

- Removing a project: `docker compose down -v` (if it used containers), then
  `rm -rf ~/src/<name>`, then `nix store gc` to free its tools. Deleting the
  project deletes its `.direnv/`, which is what kept its tools alive; the
  weekly GC catches anything left over.
- Before you finish a session: nothing of yours still listening (`ss -ltnp`),
  no stray background processes, containers stopped, work committed and
  pushed, nothing changed outside the project.
