#!/usr/bin/env bash
#
# bootstrap.sh - fresh-machine entry point.
#
# Ensures git is present, clones devbox-provision to a location you choose
# (default: <current dir>/devbox-provision), then hands off to the repo's
# update-env.sh, which installs Ansible and converges the machine. This is the
# same path CI exercises, so "works on a fresh box" and "passes CI" stay in sync.
#
# Remote:  curl -fsSL https://raw.githubusercontent.com/jsco2t/devbox-provision/main/bootstrap.sh | bash
# Local:   ./bootstrap.sh
#
# Env overrides:
#   PROVISION_REPO_URL     repo to clone (default: the canonical GitHub repo)
#   PROVISION_REPO_BRANCH  branch/tag to clone (default: main)
#   PROVISION_DEST         clone destination (skips the interactive prompt)
# Any extra args are forwarded to update-env.sh (e.g. --upgrade, --check).
set -euo pipefail

REPO_URL="${PROVISION_REPO_URL:-https://github.com/jsco2t/devbox-provision.git}"
REPO_BRANCH="${PROVISION_REPO_BRANCH:-main}"
REPO_NAME="devbox-provision"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[bootstrap:error]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# git is needed to clone the repo. Install it up front (the playbook also
# ensures git later, but we need it before that to get the repo at all).
ensure_git() {
  if have git; then
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      # git ships with the Xcode command line tools; we can't silently install
      # those (GUI installer), so point the user at it.
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

# Ask where to clone. Under `curl | bash` the script itself is on stdin, so a
# plain `read` would consume the script -- prompt and read via the controlling
# terminal (/dev/tty) instead. Falls back to the default when there is no TTY.
prompt_dest() {
  local default="$1" reply=""
  if [[ -r /dev/tty ]]; then
    printf '[bootstrap] clone devbox-provision into [%s]: ' "$default" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
  fi
  printf '%s' "${reply:-$default}"
}

main() {
  ensure_git

  local dest
  if [[ -n "${PROVISION_DEST:-}" ]]; then
    dest="$PROVISION_DEST"
  else
    dest="$(prompt_dest "${PWD}/${REPO_NAME}")"
  fi
  # Expand a leading ~ to $HOME so a typed "~/foo" lands in the home directory.
  dest="${dest/#\~/$HOME}"
  mkdir -p "$(dirname "$dest")"

  if [[ -d "$dest/.git" ]]; then
    log "repo already present at $dest; fetching latest ($REPO_BRANCH)"
    git -C "$dest" fetch --quiet origin "$REPO_BRANCH"
    git -C "$dest" checkout --quiet "$REPO_BRANCH"
    git -C "$dest" pull --ff-only --quiet origin "$REPO_BRANCH" || true
  elif [[ -e "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    err "destination '$dest' exists and is not a git checkout; refusing to clobber it."
    err "Choose another path (PROVISION_DEST=...) or remove it first."
    exit 1
  else
    log "cloning $REPO_URL ($REPO_BRANCH) -> $dest"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$dest"
  fi

  # Invoke via `bash` so an un-executable checkout still runs. update-env.sh
  # installs Ansible, converges the machine, and drops the ~/update-env.sh
  # convenience wrapper for future runs.
  log "handing off to update-env.sh"
  exec bash "$dest/update-env.sh" "$@"
}

main "$@"
