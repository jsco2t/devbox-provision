# devbox-provision

Idempotent, environment-aware machine setup for ephemeral dev VMs and real
dev machines. Peer repo to [`dotfiles`](https://github.com/jsco2t/dotfiles) —
this repo installs **tools**; the dotfiles repo manages **config** via its
existing bare-repo (`dot`) workflow, which this repo invokes at the end.

Re-running is an **upgrade**: missing tools get installed, already-installed
tools get bumped to their current version.

## Getting started

On a fresh machine:

1. **Set your git identity** for the dotfiles bare repo via environment
   variables — no need to edit or fork this repo:

   ```bash
   export DOTFILES_USER_NAME="Your Name"
   export DOTFILES_USER_EMAIL="you@example.com"
   ```

   (Optional: `export DOTFILES_REPO_URL=...` to use your own dotfiles fork.)
   These are read at run time; if unset, the fallbacks in `group_vars/all.yml`
   are used.

2. **Run the bootstrap** in the same shell (exported vars carry through):

   ```bash
   # remote one-liner:
   curl -fsSL https://raw.githubusercontent.com/jsco2t/devbox-provision/main/bootstrap.sh | bash

   # or from a local clone:
   git clone https://github.com/jsco2t/devbox-provision.git && cd devbox-provision
   ./bootstrap.sh --local
   ```

That installs Ansible, then converges everything: native packages, Homebrew
tools, Go/Rust toolchains, the Helix language tooling, and finally your
dotfiles. Re-run the same command any time to upgrade.

See [Usage](#usage) for re-runs, dry runs, and details.

## Supported environments

- **OS:** Linux and macOS (no Windows)
- **Linux families:** Debian-based and Enterprise Linux (RedHat family)
- **Arch:** arm64 and x86_64 (Homebrew, the native package managers, rustup, and
  the language installers all resolve arch themselves)

## Design

`ansible-pull` clones this repo and runs `local.yml` against `localhost`.
Roles run in order:

1. **common** — print environment summary, ensure git / Xcode CLT
2. **native_packages** — low-level utils from `apt`/`dnf` (enables EPEL on EL)
3. **homebrew** — install Homebrew (Linux + Mac), then fast-moving tools +
   the `node`/`uv` toolchains
4. **golang** — install Go via Homebrew
5. **rust** — install Rust via `rustup` + the `rust-analyzer` component
6. **lang_tools** — Helix editor LSPs/formatters/linters via their native
   installers (`go install`, `cargo install`, `npm i -g`, `uv tool install`)
7. **dotfiles** — reproduce the bare-repo `dot` workflow idempotently

Environment dispatch uses Ansible facts, not hand-rolled detection:

| Fact | Drives |
|------|--------|
| `ansible_system` (`Linux`/`Darwin`) | brew prefix, native-vs-brew split |
| `ansible_os_family` (`Debian`/`RedHat`) | `apt` vs `dnf`, EPEL |
| `ansible_architecture` | Homebrew prefix (`/opt/homebrew` vs `/usr/local`) |

### Where each tool comes from

- **Native (`apt`/`dnf`), `state: latest`:** low-level utils that rarely change
  — `jq`, `fzf`, `ripgrep`, `fd`, `vim`, `tmux`, git, build tooling. See
  `roles/native_packages/vars/main.yml`.
- **Homebrew (Linux + Mac):** fast-moving tools (`bat`, `yq`, `neovim`, `helix`,
  `starship`, `eza`, `zoxide`, `git-delta`, `lazygit`, `gh`), the brew-only LSP
  tools (`marksman`, `shellcheck`), and the `node`/`uv` toolchains. See
  `roles/homebrew/vars/main.yml`.
- **Go (`go install`):** Go LSP/formatter/linter set — `gopls`, `dlv`,
  `goimports`, `gofumpt`, `golangci-lint`, `staticcheck`, `yamlfmt`, `shfmt`,
  `efm-langserver`, `helm-ls`, plus `terraform-ls` (built from source rather
  than HashiCorp's brew tap, to avoid that tap's trust gate).
- **Cargo (`cargo install`):** `taplo-cli`, `harper-ls`, `dprint`,
  `markdown-oxide` (git source).
- **npm (`npm i -g`):** language servers for Ansible, JSON/HTML/CSS, Dockerfile,
  Docker Compose, YAML, Bash, plus `markdownlint-cli` and `prettier`.
- **uv (`uv tool install`):** `python-lsp-server`, `black`.

The `lang_tools` lists live in `roles/lang_tools/vars/main.yml`. They mirror
what `jsco2t/dotfiles`'s `.config/helix/deps.sh` installs, expressed as
idempotent Ansible.

## Usage

### Fresh machine (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/jsco2t/devbox-provision/main/bootstrap.sh | bash
```

`bootstrap.sh` installs Ansible via the host's package manager (or pip), ensures
the `community.general` collection is present, then runs `ansible-pull`.

### Re-run / update an existing machine

```bash
ansible-pull -U https://github.com/jsco2t/devbox-provision.git -i 'localhost,' local.yml
```

or, from a local clone (runs against the working tree, no remote pull):

```bash
./bootstrap.sh --local
# or directly:
ansible-playbook -i 'localhost,' -c local local.yml
```

### Dry run

```bash
ansible-playbook -i 'localhost,' -c local local.yml --check --diff
```

## Configuration

Your git identity is written to the dotfiles bare repo via `config --local`
(exactly as the original `.dotsetup.sh` did; it does not touch global git
config). Two ways to set it:

**Environment variables (no repo edit needed):**

```bash
export DOTFILES_USER_NAME="Your Name"
export DOTFILES_USER_EMAIL="you@example.com"
export DOTFILES_REPO_URL="https://github.com/you/dotfiles.git"  # optional
```

These are read at run time by `group_vars/all.yml`. If a variable is unset or
empty, the fallback baked into `group_vars/all.yml` is used.

**Or edit the fallbacks** in `group_vars/all.yml` if you own/fork this repo:

```yaml
dotfiles_user_name: "{{ lookup('env', 'DOTFILES_USER_NAME') | default('Jason', true) }}"
dotfiles_user_email: "{{ lookup('env', 'DOTFILES_USER_EMAIL') | default('you@example.com', true) }}"
```

## CI

`.github/workflows/ci.yml` runs on every push to `main` (and on demand via
*workflow_dispatch*). It spins up a Debian container, creates an unprivileged
user, and runs `bootstrap.sh --local` twice — proving a fresh machine converges
and that a second run is idempotent / upgrades cleanly.

## Notes

- The dotfiles role does **not** run the original destructive `rm -fr`
  preamble. It skips the bare clone if `~/.dotfiles` already exists and uses
  `reset --hard origin/main` to apply tracked files, leaving untracked files
  in `$HOME` alone.
- On Linux, ensure your dotfiles put the toolchains on `PATH`:
  `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`, plus `~/.cargo/bin`,
  `~/go/bin`, and `~/.local/bin` (cargo / go / uv install targets).
