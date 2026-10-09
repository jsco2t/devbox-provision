# devbox-provision

Idempotent, environment-aware machine setup for ephemeral dev VMs and real
dev machines. Peer repo to [`dotfiles`](https://github.com/jsco2t/dotfiles) —
this repo installs **tools**; the dotfiles repo manages **config** via its
existing bare-repo (`dot`) workflow, which this repo invokes at the end.

Re-running is **fast and idempotent**: by default it installs only what's
missing and skips everything already present. To bump already-installed tools to
their latest versions, run the **upgrade** path (`update-env.sh --upgrade`).

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
   ./update-env.sh
   ```

`bootstrap.sh` ensures git is present, asks where to clone the repo (default:
`<current dir>/devbox-provision`), clones it, then hands off to the repo's
`update-env.sh`. That installs Ansible and converges everything: native
packages, Homebrew tools, Go/Rust toolchains, the source-built `oom-edit`
Markdown editor, the Helix language tooling, Git Credential Manager, and finally
your dotfiles. It also drops a `~/update-env.sh` wrapper so you can re-converge
any time with a single command.

See [Usage](#usage) for re-runs, upgrades, dry runs, and details.

## Supported environments

- **OS:** Linux and macOS (no Windows)
- **Linux families:** Debian-based and Enterprise Linux (RedHat family)
- **Arch:** arm64 and x86_64 (Homebrew, the native package managers, rustup, and
  the language installers resolve arch themselves; the `git_credential_manager`
  role maps it to GCM's `x64`/`arm64` release assets)
- **CI coverage:** CI runs on Debian only. Enterprise Linux 9/10 and macOS are
  supported by design but not tested in CI.

## Design

`bootstrap.sh` clones this repo locally; `update-env.sh` then installs Ansible
and runs `local.yml` against `localhost` (`connection: local`) — the same path
CI exercises. Roles run in order:

1. **common** — print environment summary, ensure git / Xcode CLT
2. **native_packages** — low-level utils from `apt`/`dnf` (enables EPEL on EL)
3. **homebrew** — install Homebrew (Linux + Mac), then fast-moving tools +
   the `node`/`uv` toolchains
4. **golang** — install Go via Homebrew
5. **rust** — install Rust via `rustup` + the `rust-analyzer` component
6. **oom_edit** — clone `oom-edit`, build its release target, and link it from
   `~/.local/bin`
7. **lang_tools** — Helix editor LSPs/formatters/linters via their native
   installers (`go install`, `cargo install`, `npm i -g`, `uv tool install`)
8. **git_credential_manager** — install Git Credential Manager (GCM) from its
   GitHub release tarball into `~/.local/share/gcm-core`, linked from
   `~/.local/bin`; it never configures GCM
9. **dotfiles** — reproduce the bare-repo `dot` workflow idempotently

Environment dispatch uses Ansible facts, not hand-rolled detection:

| Fact | Drives |
|------|--------|
| `ansible_facts['system']` (`Linux`/`Darwin`) | brew prefix, native-vs-brew split, GCM `linux`/`osx` asset |
| `ansible_facts['os_family']` (`Debian`/`RedHat`) | `apt` vs `dnf`, EPEL, ICU package for GCM |
| `ansible_facts['architecture']` | Homebrew prefix (`/opt/homebrew` vs `/usr/local`), GCM `x64`/`arm64` asset |

### Where each tool comes from

- **Native (`apt`/`dnf`):** low-level utils that rarely change — `jq`, `fzf`,
  `ripgrep`, `fd`, `vim`, `tmux`, git, build tooling. Installed `state: present`
  by default (`state: latest` under `--upgrade`). See
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
- **Source build (`make build-release`):** `oom-edit` is cloned to
  `~/.local/bin/oom-edit-src`; its release binary remains in that checkout and
  `~/.local/bin/oom-edit` links to it. The role runs after rustup so the
  repository-pinned Rust toolchain can be resolved.
- **GitHub release tarball:** Git Credential Manager, on Linux and macOS alike.
  The Homebrew cask is avoided because its `.pkg` needs sudo and its postinstall
  runs `git-credential-manager configure`, which rewrites `~/.gitconfig`. A
  default run installs the release pinned in
  `roles/git_credential_manager/defaults/main.yml` (`gcm_version` plus a sha256
  per asset), so it makes no GitHub API call; `--upgrade` resolves the latest
  release and its sha256 from the GitHub API. The download is verified against
  that sha256, extracted to `~/.local/share/gcm-core/<version>/`, and linked as
  `~/.local/bin/git-credential-manager`. On Linux the role also installs the ICU
  runtime GCM needs (`libicu` on EL, `libicuNN` on Debian).

The `lang_tools` lists live in `roles/lang_tools/vars/main.yml`. They mirror
what `jsco2t/dotfiles`'s `.config/helix/deps.sh` installs, expressed as
idempotent Ansible. Which hosts use GCM, its credential store, and the
precedence that keeps `gh` serving github.com are configuration owned by
`jsco2t/dotfiles` (`.config/git/config`); this repository only installs GCM.
Yazi's Markdown opener likewise remains configuration owned by the
peer `jsco2t/dotfiles` repository; this repository only installs the tool. That
configuration routes Markdown through `~/.local/bin/md_router.sh`, which uses
the adjacent `oom-edit` when available and falls back to `hx` otherwise.

## Usage

### Fresh machine (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/jsco2t/devbox-provision/main/bootstrap.sh | bash
```

Ensures git, clones the repo to a location you choose (default
`<cwd>/devbox-provision`), then runs `update-env.sh`, which installs Ansible +
the `community.general` collection and converges the machine. Set
`PROVISION_DEST=/path/to/dir` to skip the interactive clone-location prompt.

### Re-run / update an existing machine

After the first run there is a `~/update-env.sh` wrapper (it `cd`s into the
clone and re-runs its `update-env.sh`):

```bash
~/update-env.sh             # fast converge: install only what's missing
~/update-env.sh --upgrade   # bump every tool to its latest version
~/update-env.sh --check     # dry run (--check --diff)
```

Equivalently, from the clone itself: `./update-env.sh [--upgrade|--check]`.

**Default vs. upgrade.** A default run is fast and idempotent — it installs
missing tools and skips everything already present (`go`/`cargo`/`npm`/`uv`
install tasks and the `oom-edit` source build are guarded on the resulting
binary, and `rustup update` runs only before building a missing cargo tool;
Homebrew and apt/dnf use `state: present` and skip `brew update`; GCM
is installed only when `~/.local/bin/git-credential-manager` does not resolve to
a binary). `--upgrade` is the slow path: it runs `brew update`, `state: latest`,
re-fetches the language tools at `@latest`, runs `rustup update`, pulls the
configured `oom-edit` branch, invokes `make build-release` again, and
re-downloads the latest GCM release. Set `GITHUB_TOKEN` to authenticate the GCM
upgrade's GitHub API call; without it the unauthenticated rate limit applies.

Bumping the pinned GCM release changes only fresh installs: hosts that already
have GCM move to a new version on `--upgrade`. To bump the pin, update
`gcm_version` and `gcm_sha256` from the `tag_name` and per-asset `digest` at
`https://api.github.com/repos/git-ecosystem/git-credential-manager/releases/latest`,
and update the `GCM_EXPECTED_VERSION` default in
`roles/git_credential_manager/tests/verify.sh` to match.

### Dry run

```bash
~/update-env.sh --check
# or directly:
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
*workflow_dispatch*). It spins up a Debian (`debian:trixie`) container, creates
an unprivileged user, and runs `update-env.sh` three times:

1. **setup** — a default converge installs everything that's missing,
2. **`--upgrade`** — exercises the bump-to-latest path,
3. **default again** — asserts the steady-state converge reports `changed=0`
   (the idempotency guarantee).

CI covers Debian only. The Enterprise Linux 9/10 and macOS paths are reasoned
about but not tested in CI. `roles/git_credential_manager/tests/verify.sh` is a
role-level acceptance test you can run by hand. It deletes and reinstalls GCM
on the host it runs on.

## Notes

- The dotfiles role does **not** run the original destructive `rm -fr`
  preamble. It skips the bare clone if `~/.dotfiles` already exists and uses
  `reset --hard origin/main` to apply tracked files, leaving untracked files
  in `$HOME` alone.
- On Linux, ensure your dotfiles put the toolchains on `PATH`:
  `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`, plus `~/.cargo/bin`,
  `~/go/bin`, and `~/.local/bin` (cargo / go / uv install targets).
