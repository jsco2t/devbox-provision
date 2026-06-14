#!/usr/bin/env bash
#
# bootstrap.sh - one-shot entry point for a fresh machine.
#
# Installs Ansible using whatever is available on the host, then hands off to
# ansible-pull, which clones this repo and runs local.yml against localhost.
#
# Usage (remote):
#   curl -fsSL https://raw.githubusercontent.com/jsco2t/devbox-provision/main/bootstrap.sh | bash
#
# Usage (local clone):
#   ./bootstrap.sh
#
set -euo pipefail

REPO_URL="${PROVISION_REPO_URL:-https://github.com/jsco2t/devbox-provision.git}"
REPO_BRANCH="${PROVISION_REPO_BRANCH:-main}"
PLAYBOOK="local.yml"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[bootstrap:error]\033[0m %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve the script's own directory. When invoked via `curl ... | bash` the
# script comes from stdin and BASH_SOURCE[0] is unset, which trips `set -u`;
# fall back to $0. SCRIPT_DIR is only actually used in --local mode (where the
# script is a real file), so the fallback value is harmless for the pull path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$PWD")"

# Run against the local checkout instead of pulling from GitHub. Set via the
# --local flag or PROVISION_LOCAL=1 (used by CI and when iterating locally).
LOCAL_MODE="${PROVISION_LOCAL:-}"

install_ansible() {
  if have ansible-pull; then
    log "ansible already present: $(ansible --version | head -n1)"
    return 0
  fi

  local uname_s
  uname_s="$(uname -s)"

  case "$uname_s" in
    Darwin)
      if have brew; then
        log "installing ansible via Homebrew"
        brew install ansible
      else
        err "Homebrew not found. Install it first: https://brew.sh"
        err "Or: python3 -m pip install --user ansible"
        exit 1
      fi
      ;;
    Linux)
      if have apt-get; then
        log "installing ansible via apt"
        sudo apt-get update -y
        sudo apt-get install -y ansible
      elif have dnf; then
        log "installing ansible via dnf (enabling EPEL on EL)"
        sudo dnf install -y epel-release || true
        sudo dnf install -y ansible
      elif have pipx; then
        log "installing ansible via pipx"
        pipx install --include-deps ansible
      elif have python3; then
        log "installing ansible via pip (user)"
        python3 -m pip install --user ansible
        export PATH="$HOME/.local/bin:$PATH"
      else
        err "No supported installer (apt/dnf/pipx/python3) found."
        exit 1
      fi
      ;;
    *)
      err "Unsupported OS: $uname_s (Linux and macOS only)"
      exit 1
      ;;
  esac
}

# ansible-pull clones this repo with git BEFORE any role runs, so git must be
# present up front -- the `common` role's git install is too late for the pull
# path. (The --local path doesn't need this: the user already has a git clone.)
ensure_git() {
  if have git; then
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      # git ships with the Xcode command line tools; we can't silently install
      # those (GUI installer). Point the user at it -- the common role checks
      # for CLT too, but we need git earlier than that for the pull.
      err "git not found. Run 'xcode-select --install', then re-run."
      exit 1
      ;;
    Linux)
      if have apt-get; then
        log "installing git via apt"
        sudo apt-get update -y
        sudo apt-get install -y git
      elif have dnf; then
        log "installing git via dnf"
        sudo dnf install -y git
      else
        err "git not found and no supported installer (apt/dnf). Install git and re-run."
        exit 1
      fi
      ;;
    *)
      err "git not found. Install git and re-run."
      exit 1
      ;;
  esac
}

# The homebrew/homebrew_tap modules live in the community.general collection.
# Every bootstrap path installs the full `ansible` package, which bundles it,
# so only fetch it if it is genuinely missing. Avoid --upgrade: the latest
# collection can require a newer ansible-core than the distro package ships.
ensure_collections() {
  if ansible-galaxy collection list community.general >/dev/null 2>&1; then
    log "community.general collection already available"
    return 0
  fi
  log "installing community.general collection"
  ansible-galaxy collection install community.general
}

run_pull() {
  log "running ansible-pull from $REPO_URL ($REPO_BRANCH)"
  # -U: repo, -C: branch, -i: inventory (localhost), running local.yml.
  # ansible-pull clones into ~/.ansible/pull/<hostname> by default and
  # only runs if the repo changed unless --full is passed.
  ansible-pull \
    --url "$REPO_URL" \
    --checkout "$REPO_BRANCH" \
    --inventory "localhost," \
    --diff \
    "$PLAYBOOK" \
    "$@"
}

run_local() {
  log "running ansible-playbook against local checkout: $SCRIPT_DIR"
  ansible-playbook \
    --inventory "localhost," \
    --connection local \
    --diff \
    "$SCRIPT_DIR/$PLAYBOOK" \
    "$@"
}

main() {
  # Allow `--local` as the first argument (in addition to PROVISION_LOCAL=1).
  if [[ "${1:-}" == "--local" ]]; then
    LOCAL_MODE=1
    shift
  fi

  install_ansible
  hash -r
  ensure_collections
  if [[ -n "$LOCAL_MODE" ]]; then
    run_local "$@"
  else
    ensure_git
    run_pull "$@"
  fi
  log "done."
}

main "$@"
