#!/usr/bin/env bash
#
# update-env.sh - converge this machine against the local checkout.
#
# Installs Ansible (if missing) + the community.general collection, works out
# how to satisfy sudo, refreshes the ~/update-env.sh convenience wrapper, then
# runs the playbook against localhost. Safe to run repeatedly -- this is the
# steady-state "update my dev environment" command, and the entry point CI uses.
#
#   ./update-env.sh            # fast converge: install only what is missing
#   ./update-env.sh --upgrade  # bump every tool to its latest version (slow)
#   ./update-env.sh --check    # dry run (adds --check --diff)
# Any other args pass straight through to ansible-playbook.
#
# Env overrides:
#   PROVISION_ASK_BECOME_PASS=1|0  force / disable the sudo password prompt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLAYBOOK="$SCRIPT_DIR/local.yml"

log() { printf '\033[1;34m[update-env]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[update-env:error]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

install_ansible() {
    if have ansible-playbook; then
        log "ansible already present: $(ansible --version | head -n1)"
        return 0
    fi

    case "$(uname -s)" in
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
            err "Unsupported OS: $(uname -s) (Linux and macOS only)"
            exit 1
            ;;
    esac
}

# community.general provides the homebrew module. The full `ansible` package
# bundles it, so only fetch it if it is genuinely missing. Avoid --upgrade: the
# latest collection can require a newer ansible-core than the distro ships.
ensure_collections() {
    if ansible-galaxy collection list community.general >/dev/null 2>&1; then
        log "community.general collection already available"
        return 0
    fi
    log "installing community.general collection"
    ansible-galaxy collection install community.general
}

# The playbook escalates to root per-task via sudo (apt/dnf installs). Work out
# how to satisfy that and stash the right flags in BECOME_ARGS:
#   - already root, or no sudo binary  -> nothing to add
#   - passwordless sudo (NOPASSWD)     -> nothing to add
#   - sudo needs a password            -> --ask-become-pass (Ansible prompts on
#                                         /dev/tty, which works under curl|bash)
#   - password needed but no TTY       -> fail with guidance (can't prompt)
#
# PROVISION_ASK_BECOME_PASS overrides the probe: 1 forces the prompt, 0 disables
# it (e.g. for a non-interactive run you know is passwordless).
#
# NOTE: we `sudo -k` before probing on purpose. An earlier `sudo` in this script
# (e.g. the apt ansible install) may have cached a credential, which would make
# `sudo -n true` succeed even on a password-required host and hide the real
# config. Clearing the timestamp first tests the policy, not the cache.
BECOME_ARGS=()
detect_become_args() {
    case "${PROVISION_ASK_BECOME_PASS:-}" in
        1)
            BECOME_ARGS=(--ask-become-pass)
            log "sudo password prompt forced via PROVISION_ASK_BECOME_PASS=1"
            return 0
            ;;
        0)
            log "sudo password prompt disabled via PROVISION_ASK_BECOME_PASS=0"
            return 0
            ;;
    esac

    if [[ "$(id -u)" -eq 0 ]] || ! have sudo; then
        return 0
    fi

    sudo -k 2>/dev/null || true
    if sudo -n true 2>/dev/null; then
        log "passwordless sudo detected"
        return 0
    fi

    if [[ -r /dev/tty ]]; then
        log "sudo requires a password; Ansible will prompt for it"
        BECOME_ARGS=(--ask-become-pass)
    else
        err "sudo requires a password but no terminal is attached to prompt on."
        err "Re-run from an interactive shell, or configure passwordless sudo,"
        err "or set PROVISION_ASK_BECOME_PASS=0 if escalation is already handled."
        exit 1
    fi
}

# Drop a ~/update-env.sh wrapper that cd's into this checkout and re-runs this
# script, so the user has one stable command regardless of where the repo lives.
# Skipped if the repo itself sits at $HOME (the wrapper would be this file).
write_home_wrapper() {
    local wrapper="$HOME/update-env.sh"
    if [[ "$wrapper" -ef "${BASH_SOURCE[0]}" ]] 2>/dev/null; then
        return 0
    fi
    cat >"$wrapper" <<EOF
#!/usr/bin/env bash
# Auto-generated by devbox-provision (bootstrap.sh / update-env.sh).
# Re-converges your dev environment. Pass --upgrade to bump tools, --check for a
# dry run. Edit nothing here; it is regenerated on every converge.
set -euo pipefail
cd "$SCRIPT_DIR" && exec ./update-env.sh "\$@"
EOF
    chmod +x "$wrapper"
    log "refreshed convenience wrapper: $wrapper"
}

main() {
    local extra=()
    local upgrade="false"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --upgrade) upgrade="true" ;;
            --check) extra+=(--check --diff) ;;
            *) extra+=("$arg") ;;
        esac
    done

    # On --upgrade, refresh the provisioning sources too. Guarded so it is safe:
    #   - only when on a branch -> a detached HEAD (e.g. CI's actions/checkout,
    #     which checks out a SHA) skips this, so CI keeps testing its exact
    #     commit instead of pulling origin out from under itself;
    #   - `-C "$SCRIPT_DIR"` so it targets the repo regardless of CWD;
    #   - `--ff-only` + tolerate failure so a divergent/offline checkout still
    #     converges against what is on disk.
    if [[ "$upgrade" == "true" ]]; then
        if git -C "$SCRIPT_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
            log "pulling latest provisioning sources"
            git -C "$SCRIPT_DIR" pull --ff-only || err "git pull failed; continuing with local checkout"
        else
            log "detached HEAD (e.g. CI); skipping git pull"
        fi
    fi

    install_ansible
    hash -r
    ensure_collections
    detect_become_args
    write_home_wrapper

    log "converging (upgrade=$upgrade)"
    ansible-playbook \
        --inventory "localhost," \
        --connection local \
        --diff \
        --extra-vars "upgrade=$upgrade" \
        "${BECOME_ARGS[@]+"${BECOME_ARGS[@]}"}" \
        "${extra[@]+"${extra[@]}"}" \
        "$PLAYBOOK"
    log "done."
}

main "$@"
