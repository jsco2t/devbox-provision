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
# Steady-state dev loop: converge against the local checkout (fast; installs
# only what's missing). This is the primary command.
./update-env.sh

# Bump every tool to its latest version (slow path).
./update-env.sh --upgrade

# Dry run.
./update-env.sh --check        # == ansible-playbook ... --check --diff

# Run the playbook directly (what update-env.sh ends up invoking):
ansible-playbook -i 'localhost,' -c local local.yml -e upgrade=false

# Run a single task onward (no tags defined; use --start-at-task):
ansible-playbook -i 'localhost,' -c local local.yml -e upgrade=false \
  --start-at-task="Install Go tools (skip if already built; --upgrade re-fetches @latest)"

# Fresh-machine remote path: ensures git, clones the repo (prompts for location,
# default <cwd>/devbox-provision), then runs update-env.sh.
curl -fsSL https://raw.githubusercontent.com/jsco2t/devbox-provision/main/bootstrap.sh | bash
```

There is no unit-test framework. **CI (`.github/workflows/ci.yml`) is the test**:
in a `debian:trixie` container (unprivileged `dev` user, passwordless sudo) it
runs `update-env.sh` three times — **setup** (default converge), **`--upgrade`**
(bump path), then **default again asserting `changed=0`** (idempotency). Validate
non-trivial changes by reasoning about that flow or replicating it in a Debian
container.

**CI gap to be aware of:** CI runs `update-env.sh` directly against the checkout,
so it does **not** cover `bootstrap.sh` itself — the git-install, the
clone-location prompt, and the `curl | bash` stdin/`BASH_SOURCE` handling are
exercised only on a real fresh box. Test those by piping the raw script to `bash`.
Note the deployment coupling: the remote one-liner fetches `bootstrap.sh` from
`main`, which then execs `update-env.sh` **from the clone** — so changes to the
converge flow must be committed/pushed to `main` before a remote test reflects
them.

## Architecture

`bootstrap.sh` (git + clone) → `update-env.sh` (installs Ansible + collection,
detects sudo, writes the `~/update-env.sh` wrapper) → `ansible-playbook` runs
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

Because those tasks escalate via sudo, `update-env.sh` must satisfy sudo before
invoking Ansible. `detect_become_args()` probes this and passes
`--ask-become-pass` to ansible-playbook when sudo needs a password
(both passwordless-NOPASSWD and password-prompt hosts are supported; the latter
needs a TTY, which `curl | bash` has over SSH). The probe runs `sudo -k` first
so it reads the sudo *policy*, not a cached credential left by an earlier sudo in
the script. Override with `PROVISION_ASK_BECOME_PASS=1|0`. On a password-prompt
host the pull path prompts twice — once for `ensure_git`'s apt/dnf install, once
for Ansible — because the two use independent sudo sessions.

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
  homebrew-core; no third-party taps (avoids tap-trust gates). On **Linux** the
  role pre-creates the `/home/linuxbrew/.linuxbrew` prefix as root and chowns it
  to the invoking user *before* running the installer — the installer's own sudo
  can't authenticate under Ansible (no TTY, no become password passed to the
  shell), but a pre-owned, writable prefix makes it skip sudo entirely (see the
  `! [[ -w "${HOMEBREW_PREFIX}" ]] && ... && ! have_sudo_access` gate in
  install.sh). The install task is guarded (`brew_check.rc != 0` **and** prefix
  binary absent), so it doesn't re-run once brew exists.
- **lang_tools** — the Helix tooling, by ecosystem, in `roles/lang_tools/vars/main.yml`:
  `lang_tools_go` (`go install ...@latest`), `lang_tools_cargo` /
  `lang_tools_cargo_git` (`cargo install --locked`), `lang_tools_npm`
  (`npm i -g`), `lang_tools_python` (`uv tool install`). These lists mirror
  `jsco2t/dotfiles`'s `.config/helix/deps.sh` — keep them in sync. Notable:
  `terraform-ls` is built from source (`go install`) rather than HashiCorp's brew
  tap, specifically to avoid that tap's trust gate. Each install task is guarded
  on the resulting binary so a default converge skips already-installed tools
  (see Idempotency contract). **When you add a tool here, you must also give its
  guard target**: go derives the binary as `item | basename` (no extra data
  needed); cargo/npm/uv need a `bin:` field (or, for npm, the package dir under
  `npm root -g`) — a wrong/missing guard only costs a needless rebuild, never
  breakage.

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

There are **two converge modes**, switched by the `upgrade` var (default
`false`; `group_vars/all.yml`, also reads `PROVISION_UPGRADE`; `update-env.sh
--upgrade` sets `-e upgrade=true`):

- **Default (`upgrade=false`) — fast & idempotent.** Install only what's
  missing; skip everything present. A steady-state converge must report
  **`changed=0`** (CI's third run asserts this). Mechanism: `state: present` +
  `update_homebrew: false` (no `brew update`); apt/dnf `state: present`; the
  language-tool tasks use `creates:` guards on the resulting binary so
  already-built tools are skipped; `rustup update` is skipped. The one task that
  needs care to stay at `changed=0` is the dotfiles `reset --hard` — it keys
  `changed_when` on HEAD-vs-fetched-tip, not on the always-present "HEAD is now
  at" output.
- **Upgrade (`upgrade=true`) — slow.** `brew update` + `state: latest`,
  go/cargo/npm re-fetch `@latest` (cargo adds `--force`, `creates` omitted),
  `rustup update`. Intentionally re-does work; **not** a zero-change run.

When adding a tool, wire it into **both** modes: a `state:`/`update_homebrew:`
that flips on `upgrade`, or a `creates:` guard of the form
`{{ omit if (upgrade | bool) else <binary path> }}`. Do **not** reintroduce
unconditional `changed_when: true` / `--force` on the default path — it breaks
the idempotency assertion.

## Configuration

Git identity for the dotfiles repo is read at runtime from env vars (no repo edit
needed), with fallbacks in `group_vars/all.yml`:
`DOTFILES_USER_NAME`, `DOTFILES_USER_EMAIL`, `DOTFILES_REPO_URL`. Empty values
are safe — the dotfiles role skips the `config --local` steps when they're empty.
Script env vars: `bootstrap.sh` honors `PROVISION_REPO_URL`,
`PROVISION_REPO_BRANCH`, and `PROVISION_DEST` (clone location, skips the prompt);
`update-env.sh` honors `PROVISION_ASK_BECOME_PASS=1|0` (sudo prompt) and
`PROVISION_UPGRADE` (upgrade mode). `bootstrap.sh` forwards extra args
(`--upgrade`, `--check`) through to `update-env.sh`.
