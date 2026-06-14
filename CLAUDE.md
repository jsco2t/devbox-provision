# AI Coding Agents Guidance

This file provides guidance to AI Agents (Claude, Codex, Pi.dev, OpenCode...etc) when working with code in this repository.

## What this is

An Ansible project that provisions a development machine (ephemeral VM or real
box) idempotently. It installs **tools only**; user **config** is owned by the
peer `jsco2t/dotfiles` bare-repo workflow, which the final role reproduces.
Re-running any entry point is an **upgrade**, not just a no-op converge —
several tasks are intentionally always-changed (see Idempotency below).

There is no application code here: the "code" is Ansible YAML plus
`bootstrap.sh`. Linux (Debian + RedHat families) and macOS, arm64 + x86_64.

## Commands

```bash
# Converge against the local checkout (primary dev loop — no GitHub pull):
./bootstrap.sh --local
# equivalently, skipping the ansible-install step:
ansible-playbook -i 'localhost,' -c local local.yml

# Dry run / see what would change:
ansible-playbook -i 'localhost,' -c local local.yml --check --diff

# Run a single role (tags are not defined; use --start-at-task or limit roles):
ansible-playbook -i 'localhost,' -c local local.yml --start-at-task="Install/upgrade Go tools"

# Fresh-machine remote path (installs Ansible first, then ansible-pull):
curl -fsSL https://raw.githubusercontent.com/jsco2t/devbox-provision/main/bootstrap.sh | bash

# Re-run on an existing machine via pull:
ansible-pull -U https://github.com/jsco2t/devbox-provision.git -i 'localhost,' local.yml
```

There is no unit-test framework. **CI (`.github/workflows/ci.yml`) is the test**:
it runs `bootstrap.sh --local` twice in a `debian:trixie` container (as an
unprivileged `dev` user with passwordless sudo) to prove both fresh-converge and
upgrade-on-rerun succeed. Validate non-trivial changes by reasoning about that
flow or replicating it in a Debian container.

**CI gap to be aware of:** CI only exercises the `--local` path, and it
pre-installs `git` in its base-deps step. It therefore does **not** cover the
remote `curl | bash` → `ansible-pull` path, where `bootstrap.sh` must install
`git` itself (via `ensure_git`) _before_ `ansible-pull` can clone the repo, and
where `BASH_SOURCE[0]` is unset (script comes from stdin under `set -u`). Changes
to those code paths can't be caught by CI — test them by piping the raw script
to `bash` on a fresh box.

## Architecture

`bootstrap.sh` → (installs Ansible) → `ansible-pull`/`ansible-playbook` runs
`local.yml` against `localhost` with `connection: local`. `local.yml` runs seven
roles **in a fixed order that encodes a dependency chain**:

1. **common** — env summary; ensure git (apt/dnf) / Xcode CLT (macOS)
2. **native_packages** — low-level utils from apt/dnf (no-op on macOS)
3. **homebrew** — install brew (Linux + macOS), then fast-moving tools **and the
   `node`/`uv` toolchains**
4. **golang** — Go via Homebrew
5. **rust** — Rust via rustup + the `rust-analyzer` component
6. **lang_tools** — Helix LSPs/formatters/linters via `go`/`cargo`/`npm`/`uv`
7. **dotfiles** — reproduce the bare-repo `dot` workflow

The order matters: `lang_tools` needs go/node/uv (from `homebrew`) and
cargo/rustup (from `rust`) to exist first. Do not reorder roles without
accounting for this.

### Two things every contributor must internalize

**1. The privilege split.** `local.yml` sets `become: false` at the play level
on purpose. Native package roles opt into `become: true` **per task**; Homebrew,
language installers, and dotfiles must run as the **invoking user** (Homebrew
refuses to run as root; go/cargo/npm/uv install into `$HOME`). When adding tasks,
add `become: true` only to things that genuinely need root, never a blanket
escalation.

**2. PATH is hand-composed, not inherited.** A freshly installed brew/rustup/etc.
is **not on the Ansible session's PATH**. So:

- `homebrew` computes `brew_prefix` from facts (`/opt/homebrew` on Apple
  Silicon, `/usr/local` on Intel mac, `/home/linuxbrew/.linuxbrew` on Linux) and
  passes `path:` explicitly to the `community.general.homebrew` module.
- `lang_tools` builds `lang_tools_path` (`~/.cargo/bin:~/go/bin:~/.local/bin:<brew>/bin:$PATH`)
  and passes it via `environment:` to every install task. New language tooling
  must run under this PATH or it won't find its toolchain.

### Environment dispatch via facts

Detection uses Ansible facts, never hand-rolled OS sniffing:
`ansible_system` (Linux/Darwin), `ansible_os_family` (Debian/RedHat),
`ansible_architecture`. `local.yml`'s `pre_tasks` assert a supported OS/family
and fail fast otherwise. Follow this pattern for any platform branching.

### Where each tool comes from (and why)

The split is deliberate — match it when adding tools:

- **native (apt/dnf), `state: latest`** — stable low-level utils (`jq`, `fzf`,
  `ripgrep`, `vim`, `tmux`, build tooling). Lists in `roles/native_packages/vars/main.yml`.
  Note the `fdfind`→`fd` symlink shim on Debian/EL.
- **Homebrew (Linux + macOS)** — fast-moving tools + the brew-only LSPs +
  node/uv toolchains. Lists in `roles/homebrew/vars/main.yml`. Only
  homebrew-core; no third-party taps (avoids tap-trust gates).
- **lang_tools** — the Helix tooling, by ecosystem, in `roles/lang_tools/vars/main.yml`:
  `lang_tools_go` (`go install ...@latest`), `lang_tools_cargo` /
  `lang_tools_cargo_git` (`cargo install --locked --force`), `lang_tools_npm`
  (`npm i -g`), `lang_tools_python` (`uv tool install`). These lists mirror
  `jsco2t/dotfiles`'s `.config/helix/deps.sh` — keep them in sync. Notable:
  `terraform-ls` is built from source (`go install`) rather than HashiCorp's brew
  tap, specifically to avoid that tap's trust gate.

### dotfiles role — the subtle one

Reproduces `jsco2t/dotfiles`'s `.dotsetup.sh` bare-repo (`dot`) workflow
idempotently, but **omits the original destructive `rm -fr` preamble**. Key
behaviors to preserve:

- Skips the bare clone if `~/.dotfiles/HEAD` already exists.
- Writes `user.name`/`user.email` with `git config --local` to the **bare repo
  only** (never global git config), and only when those vars are non-empty.
- Applies tracked files with `reset --hard FETCH_HEAD` — **not** `origin/main`:
  `git clone --bare` creates no remote-tracking refs, so `origin/main` doesn't
  exist. Untracked files in `$HOME` are left alone.

## Idempotency contract

Re-run = upgrade. This is by design and means CI's second converge is **not** a
zero-change assertion. Expect always-changed tasks: `go install ...@latest`,
`cargo install --force`, `npm i -g`, and brew/apt/dnf `state: latest`. When you
add a tool via a native package manager, use `state: latest`; when you add it via
a language installer, follow the existing "fetch latest each run" pattern rather
than trying to make it report unchanged.

## Configuration

Git identity for the dotfiles repo is read at runtime from env vars (no repo edit
needed), with fallbacks in `group_vars/all.yml`:
`DOTFILES_USER_NAME`, `DOTFILES_USER_EMAIL`, `DOTFILES_REPO_URL`. Empty values
are safe — the dotfiles role skips the `config --local` steps when they're empty.
`bootstrap.sh` honors `PROVISION_LOCAL=1` / `--local`, `PROVISION_REPO_URL`,
`PROVISION_REPO_BRANCH`.
