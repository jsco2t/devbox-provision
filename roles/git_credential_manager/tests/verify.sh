#!/usr/bin/env bash
#
# verify.sh - acceptance test for the git_credential_manager role.
#
# Converges ONLY this role (tests/test.yml) on this host twice in default mode
# and checks the role's contract:
#   - static: local.yml passes --syntax-check and lists git_credential_manager
#     immediately before dotfiles (header included); download, extract, symlink
#     and API tasks never become root; downloads carry a checksum; API/token
#     tasks set no_log; CI passes GITHUB_TOKEN to the dev user by name only.
#   - run 1 installs the pinned version into ~/.local/share/gcm-core/<ver>/,
#     links ~/.local/bin/git-credential-manager, prunes other version dirs, and
#     leaves only user-owned files.
#   - run 2 reports changed=0 and makes no HTTP(S) request: every proxy
#     variable points at a local recording proxy that must stay silent.
#   - the installed binary prints the pinned version under `env -i`, and a
#     headless `get` fails fast with GCM's interactivity error.
#   - ~/.gitconfig and the XDG git config are byte-for-byte unchanged.
#
# It modifies this host: it first removes the role's footprint (the
# ~/.local/bin/git-credential-manager symlink and ~/.local/share/gcm-core) so
# run 1 always exercises the install path. A failed run can leave GCM missing
# until the next converge. On Linux the role's ICU task needs root, passwordless
# sudo, or a terminal to prompt for the sudo password.
#
#   bash roles/git_credential_manager/tests/verify.sh
#
# Env: GCM_EXPECTED_VERSION  version the role pins (default 2.9.1)
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(cd "$ROLE_DIR/../.." && pwd)"
EXPECTED_VERSION="${GCM_EXPECTED_VERSION:-2.9.1}"

export ANSIBLE_CONFIG="$REPO_ROOT/ansible.cfg"
export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_NOCOLOR=1

FAILURES=0
WORK=""
RECORDER_PID=""
BECOME_ARGS=()
PY=""

pass() { printf 'ok   - %s\n' "$*"; }
fail() {
    printf 'FAIL - %s\n' "$*"
    FAILURES=$((FAILURES + 1))
}
die() {
    printf 'ERROR - %s\n' "$*"
    exit 2
}
section() { printf '\n== %s\n' "$*"; }

cleanup() {
    if [[ -n "$RECORDER_PID" ]]; then
        kill "$RECORDER_PID" 2>/dev/null || true
    fi
    # Remove the seeded stale version dir if the role failed to prune it, and
    # its parent if nothing else landed there.
    if [[ -n "${STALE_DIR:-}" ]]; then
        rm -rf "$STALE_DIR"
        rmdir "$GCM_HOME" 2>/dev/null || true
    fi
    if [[ -n "$WORK" ]]; then
        if ((FAILURES > 0)); then
            printf 'logs kept in %s\n' "$WORK"
        else
            rm -rf "$WORK"
        fi
    fi
}
trap cleanup EXIT

# Ansible refuses non-blocking stdio, so every ansible call reads /dev/null and
# writes to a file. Print a log's tail when a run fails.
show_tail() {
    printf -- '--- last lines of %s\n' "$1"
    tail -n 40 "$1" || true
    printf -- '---\n'
}

# Sum of changed=N over the PLAY RECAP lines (they are the ones that contain
# 'unreachable='), so --diff content cannot false-match.
recap_changed() {
    { grep 'unreachable=' "$1" || true; } |
        sed -E 's/.*changed=([0-9]+).*/\1/' |
        awk '{ s += $1 } END { print s + 0 }'
}

# The interpreter Ansible runs on has PyYAML; PATH's python3 may not.
find_ansible_python() {
    local version_out
    version_out="$(ansible --version </dev/null 2>&1)" ||
        die "ansible --version failed: $version_out"
    PY="$(printf '%s\n' "$version_out" |
        sed -n 's/.*python version = .*(\([^()]*\))$/\1/p' | head -n 1)"
    [[ -n "$PY" && -x "$PY" ]] || PY="$(command -v python3 || true)"
    [[ -n "$PY" ]] || die "no python3 found"
    "$PY" -c 'import yaml' 2>/dev/null || die "$PY lacks PyYAML (needed to parse the YAML under test)"
}

# Mirrors update-env.sh's detect_become_args: probe the sudo policy, not a
# cached credential, and prompt only when a terminal exists.
detect_become_args() {
    [[ "$(uname -s)" == Linux ]] || return 0
    [[ "$(id -u)" -ne 0 ]] || return 0
    sudo -k 2>/dev/null || true
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if [[ -r /dev/tty ]]; then
        BECOME_ARGS=(--ask-become-pass)
    else
        die "sudo needs a password and no terminal is attached; run from a terminal"
    fi
}

converge() {
    ansible-playbook \
        --inventory "localhost," \
        --connection local \
        --extra-vars "upgrade=false" \
        "${BECOME_ARGS[@]+"${BECOME_ARGS[@]}"}" \
        "$TESTS_DIR/test.yml" </dev/null >"$1" 2>&1
}

# Route every HTTP(S) client (urllib in Ansible modules and lookups, curl,
# git) through the recording proxy at $1.
use_proxy() {
    unset no_proxy NO_PROXY
    export http_proxy="$1" https_proxy="$1" all_proxy="$1"
    export HTTP_PROXY="$1" HTTPS_PROXY="$1" ALL_PROXY="$1"
}

# Records the request line of every connection to $WORK/requests.log and
# answers 403, so a request fails fast but is never missed, even when a task
# ignores its own failure.
start_recorder() {
    local port_file="$WORK/proxy.port" port="" _
    "$PY" - "$port_file" "$WORK/requests.log" >/dev/null 2>&1 <<'PY' &
import os
import socket
import sys

port_file, log_file = sys.argv[1], sys.argv[2]
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(16)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.getsockname()[1]))
os.replace(port_file + ".tmp", port_file)
while True:
    conn, _ = server.accept()
    conn.settimeout(5)
    try:
        data = conn.recv(4096)
    except OSError:
        data = b""
    line = data.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    with open(log_file, "a") as f:
        f.write((line or "<connection without a request line>") + "\n")
    try:
        conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
    except OSError:
        pass
    conn.close()
PY
    RECORDER_PID=$!
    for _ in $(seq 50); do
        [[ -s "$port_file" ]] && break
        sleep 0.1
    done
    [[ -s "$port_file" ]] || die "recording proxy did not start"
    port="$(cat "$port_file")"
    PROXY_URL="http://127.0.0.1:$port"
    : >"$WORK/requests.log"
}

# Prints one line per check; the exit status is the number of failures.
static_checks() {
    "$PY" - "$REPO_ROOT" <<'PY'
import os
import re
import sys

import yaml

repo = sys.argv[1]
role = os.path.join(repo, "roles", "git_credential_manager")
tasks_dir = os.path.join(role, "tasks")
failures = 0


def check(ok, msg):
    global failures
    print(("ok   - " if ok else "FAIL - ") + msg)
    failures += 0 if ok else 1


def load(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def truthy(value):
    return value is True or str(value).strip().lower() in ("true", "yes", "on", "1")


# --- local.yml: role order, header, no escalation of the role ---------------
with open(os.path.join(repo, "local.yml"), encoding="utf-8") as f:
    local_text = f.read()
play = yaml.safe_load(local_text)[0]
entries = play.get("roles") or []
roles = [e["role"] if isinstance(e, dict) else e for e in entries]
check(
    "git_credential_manager" in roles
    and "dotfiles" in roles
    and roles.index("git_credential_manager") + 1 == roles.index("dotfiles"),
    "local.yml runs git_credential_manager immediately before dotfiles",
)
header = []
for line in local_text.splitlines():
    if line.startswith("---") or not line.strip():
        continue
    if not line.startswith("#"):
        break
    match = re.match(r"#\s+\d+\.\s+([A-Za-z0-9_]+)(?:\s|$)", line)
    if match:
        header.append(match.group(1))
check(header == roles, "local.yml header lists the roles in play order")
entry = next(
    (e for e in entries if isinstance(e, dict) and e.get("role") == "git_credential_manager"),
    {},
)
check(not truthy(entry.get("become", False)), "local.yml does not escalate the whole role")

# --- role tasks: no become on user-space work, checksum, no_log -------------
main = os.path.join(tasks_dir, "main.yml")
check(os.path.isfile(main), "role has tasks/main.yml")
found = {"get_url": 0, "unarchive": 0, "link": 0}
issues = []
visited = set()


# Task keywords; any other key on a task is its module.
KEYWORDS = {
    "action", "any_errors_fatal", "args", "async", "become", "become_exe",
    "become_flags", "become_method", "become_user", "changed_when", "check_mode",
    "collections", "connection", "debugger", "delay", "delegate_facts",
    "delegate_to", "diff", "environment", "failed_when", "ignore_errors",
    "ignore_unreachable", "local_action", "loop", "loop_control",
    "module_defaults", "name", "no_log", "notify", "poll", "register",
    "retries", "run_once", "tags", "throttle", "timeout", "until", "vars",
    "when",
}


def short(key):
    for prefix in ("ansible.builtin.", "ansible.legacy."):
        if key.startswith(prefix):
            return key[len(prefix):]
    return key


def module_args(args):
    if isinstance(args, dict):
        return args
    if isinstance(args, str):
        return dict(p.split("=", 1) for p in args.split() if "=" in p)
    return {}


def walk(path, tasks, become, no_log):
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        t_become = truthy(task["become"]) if "become" in task else become
        t_no_log = truthy(task["no_log"]) if "no_log" in task else no_log
        if "block" in task:
            for key in ("block", "rescue", "always"):
                walk(path, task.get(key), t_become, t_no_log)
            continue
        label = "%s: %r" % (os.path.relpath(path, repo), task.get("name", "<unnamed>"))
        mentions_token = re.search(r"GITHUB_TOKEN|Authorization", yaml.safe_dump(task))
        for key, args in task.items():
            if key in KEYWORDS or key.startswith("with_"):
                continue
            mod = short(key)
            margs = module_args(args)
            if mod in ("include_tasks", "import_tasks"):
                name = args if isinstance(args, str) else margs.get("file")
                inc = os.path.join(tasks_dir, name) if name else ""
                if os.path.isfile(inc) and inc not in visited:
                    visited.add(inc)
                    walk(inc, load(inc), t_become, t_no_log)
                continue
            is_link = mod == "file" and margs.get("state") == "link"
            if mod == "get_url":
                found["get_url"] += 1
                if not str(margs.get("checksum") or "").strip():
                    issues.append("%s: get_url has no checksum" % label)
            if mod == "unarchive":
                found["unarchive"] += 1
            if is_link:
                found["link"] += 1
            if (mod in ("get_url", "unarchive", "uri") or is_link) and t_become:
                issues.append("%s: %s runs with become" % (label, mod))
            if (mod == "uri" or mentions_token) and not t_no_log:
                issues.append("%s: %s handles the API/token without no_log" % (label, mod))


if os.path.isfile(main):
    visited.add(main)
    walk(main, load(main), False, False)
# Files reached only through a templated include (e.g. per-platform task
# files) are walked on their own; the runtime ownership check still covers
# any become inherited from the include.
if os.path.isdir(tasks_dir):
    for name in sorted(os.listdir(tasks_dir)):
        path = os.path.join(tasks_dir, name)
        if name.endswith((".yml", ".yaml")) and path not in visited:
            visited.add(path)
            walk(path, load(path), False, False)
check(found["get_url"] > 0, "role downloads the release tarball with get_url")
check(found["unarchive"] > 0, "role extracts the tarball with unarchive")
check(found["link"] > 0, "role links the binary with file state=link")
for issue in issues:
    check(False, issue)
if os.path.isfile(main) and not issues:
    check(True, "download/extract/symlink/API tasks run without become, with a checksum, and API/token tasks set no_log")

# --- ci.yml: GITHUB_TOKEN reaches the dev user, never expanded --------------
workflow = load(os.path.join(repo, ".github", "workflows", "ci.yml"))
token_expr = re.compile(r"^\$\{\{\s*(secrets\.GITHUB_TOKEN|github\.token)\s*\}\}$")
by_name = re.compile(r"\bsudo\b[^\n|;&]*--preserve-env=[\w,]*\bGITHUB_TOKEN\b")
expanded = re.compile(r"\$\{?GITHUB_TOKEN\b|secrets\.GITHUB_TOKEN|github\.token")
steps = 0
for job in (workflow.get("jobs") or {}).values():
    for step in job.get("steps") or []:
        run = str(step.get("run") or "")
        if "update-env.sh" not in run:
            continue
        steps += 1
        name = step.get("name", "<unnamed step>")
        env = {}
        for scope in (workflow, job, step):
            env.update(scope.get("env") or {})
        check(
            bool(token_expr.match(str(env.get("GITHUB_TOKEN", "")).strip())),
            "ci.yml %r sets env GITHUB_TOKEN from the workflow token" % name,
        )
        joined = run.replace("\\\n", " ")
        check(
            bool(by_name.search(joined)),
            "ci.yml %r passes GITHUB_TOKEN to the dev user via sudo --preserve-env=GITHUB_TOKEN" % name,
        )
        check(
            not expanded.search(run),
            "ci.yml %r never expands the token in the (xtraced) script" % name,
        )
check(steps > 0, "ci.yml has update-env.sh steps")

sys.exit(min(failures, 100))
PY
}

check_layout() {
    local ver_dir="$GCM_HOME/$EXPECTED_VERSION" target expected others foreign f
    local -a files=(git-credential-manager)
    if [[ "$(uname -s)" == Linux ]]; then
        files+=(libSkiaSharp.so libHarfBuzzSharp.so)
    fi

    if [[ ! -e "$STALE_DIR" ]]; then
        pass "run 1 pruned the stale version dir"
    else
        fail "run 1 left the stale version dir $STALE_DIR"
    fi

    for f in "${files[@]}"; do
        if [[ -f "$ver_dir/$f" ]]; then
            pass "$ver_dir/$f exists"
        else
            fail "$ver_dir/$f is missing"
        fi
    done

    if [[ -L "$GCM_LINK" ]]; then
        target="$("$PY" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$GCM_LINK")"
        expected="$("$PY" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$ver_dir/git-credential-manager")"
        if [[ "$target" == "$expected" && -x "$target" ]]; then
            pass "$GCM_LINK links the extracted binary"
        else
            fail "$GCM_LINK resolves to $target, expected executable $expected"
        fi
    else
        fail "$GCM_LINK is not a symlink"
    fi

    others="$(find "$GCM_HOME" -mindepth 1 -maxdepth 1 -type d ! -name "$EXPECTED_VERSION" 2>/dev/null || true)"
    if [[ -z "$others" ]]; then
        pass "$GCM_HOME holds only the $EXPECTED_VERSION version dir"
    else
        fail "$GCM_HOME holds other version dirs: $others"
    fi

    foreign="$(find "$GCM_HOME" "$GCM_LINK" ! -user "$(id -u)" 2>/dev/null || true)"
    if [[ -z "$foreign" ]]; then
        pass "install files and symlink belong to $(id -un) (no become)"
    else
        fail "install paths not owned by $(id -un): $foreign"
    fi
}

check_version() {
    local out
    if out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin "$GCM_LINK" --version 2>&1)" &&
        [[ "${out%%+*}" == "$EXPECTED_VERSION" ]]; then
        pass "env -i ... git-credential-manager --version prints $EXPECTED_VERSION"
    else
        fail "env -i ... git-credential-manager --version printed: $out"
    fi
}

# A throwaway HOME keeps GCM's provider autodetection away from the real
# global git config.
check_headless_get() {
    local home="$WORK/headless-home"
    mkdir -p "$home"
    "$PY" - "$GCM_LINK" "$home" <<'PY'
import re
import subprocess
import sys
import time

gcm, home = sys.argv[1], sys.argv[2]
cmd = [
    "env", "-i", "HOME=" + home, "PATH=/usr/bin:/bin",
    "GCM_INTERACTIVE=0", "GCM_CREDENTIAL_STORE=cache", gcm, "get",
]
start = time.monotonic()
try:
    proc = subprocess.run(
        cmd,
        input="protocol=https\nhost=example.invalid\n\n",
        capture_output=True,
        text=True,
        timeout=30,
    )
except subprocess.TimeoutExpired:
    print("FAIL - headless get hung (no exit within 30s)")
    sys.exit(1)
elapsed = time.monotonic() - start
problems = []
if proc.returncode == 0:
    problems.append("exited 0")
if not re.search(r"interactivity has been disabled", proc.stderr, re.I):
    problems.append("no interactivity error on stderr")
if re.search(r"skia|harfbuzz|avalonia|DllNotFound|unable to load shared library", proc.stderr, re.I):
    problems.append("GUI/Skia load error on stderr")
if "password=" in proc.stdout:
    problems.append("returned a credential")
if problems:
    print("FAIL - headless get: %s; stderr was:\n%s" % (", ".join(problems), proc.stderr))
    sys.exit(1)
print("ok   - headless get fails fast (%.1fs, rc %d) with GCM's interactivity error" % (elapsed, proc.returncode))
PY
}

snapshot_git_config() {
    local f
    for f in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"; do
        if [[ -e "$f" ]]; then
            printf '%s %s\n' "$f" "$(cksum <"$f")"
        else
            printf '%s absent\n' "$f"
        fi
    done
}

main() {
    local static_status=0 run1_ok=false rc changed gitconfig_before log1 log2

    [[ -n "${HOME:-}" && -d "$HOME" ]] || die "HOME is not a directory"
    command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not found"
    GCM_HOME="$HOME/.local/share/gcm-core"
    GCM_LINK="$HOME/.local/bin/git-credential-manager"
    STALE_DIR=""
    WORK="$(mktemp -d)"
    find_ansible_python

    section "static checks"
    static_checks || static_status=$?
    FAILURES=$((FAILURES + static_status))

    if ansible-playbook -i 'localhost,' -c local "$REPO_ROOT/local.yml" --syntax-check \
        </dev/null >"$WORK/syntax.log" 2>&1; then
        pass "local.yml --syntax-check"
    else
        fail "local.yml --syntax-check"
        show_tail "$WORK/syntax.log"
    fi

    section "run 1: install from a clean footprint"
    detect_become_args
    gitconfig_before="$(snapshot_git_config)"
    if [[ -L "$GCM_LINK" ]]; then
        rm -f "$GCM_LINK"
    elif [[ -e "$GCM_LINK" ]]; then
        die "$GCM_LINK exists and is not a symlink; refusing to remove it"
    fi
    rm -rf "$GCM_HOME"
    STALE_DIR="$GCM_HOME/0.0.0-verify-stale"
    mkdir -p "$STALE_DIR"
    : >"$STALE_DIR/marker"

    log1="$WORK/run1.log"
    rc=0
    converge "$log1" || rc=$?
    changed="$(recap_changed "$log1")"
    if ((rc == 0 && changed > 0)); then
        run1_ok=true
        pass "run 1 succeeded (changed=$changed)"
        check_layout
    else
        fail "run 1 must succeed and install GCM (rc=$rc, changed=$changed)"
        show_tail "$log1"
        printf 'skipped run 2 and the binary checks: run 1 installed nothing\n'
    fi

    if [[ "$run1_ok" == true ]]; then
        section "run 2: converged box, network blocked"
        start_recorder
        (
            use_proxy "$PROXY_URL"
            ansible localhost -i 'localhost,' -c local -m ansible.builtin.uri \
                -a "url=https://api.github.com/ timeout=5" \
                </dev/null >"$WORK/proxy-selftest.log" 2>&1
        ) || true
        if grep -q 'api.github.com' "$WORK/requests.log"; then
            pass "recording proxy sees Ansible module requests (self-test)"
        else
            fail "recording proxy self-test: an Ansible uri request did not reach it, so the no-request check would prove nothing"
            show_tail "$WORK/proxy-selftest.log"
        fi
        : >"$WORK/requests.log"

        log2="$WORK/run2.log"
        rc=0
        (
            use_proxy "$PROXY_URL"
            converge "$log2"
        ) || rc=$?
        changed="$(recap_changed "$log2")"
        if ((rc == 0 && changed == 0)); then
            pass "run 2 succeeded with changed=0"
        else
            fail "run 2 must succeed with changed=0 (rc=$rc, changed=$changed)"
            show_tail "$log2"
        fi
        if [[ ! -s "$WORK/requests.log" ]]; then
            pass "run 2 made no GitHub API or download request"
        else
            fail "run 2 made network requests:"
            sed 's/^/    /' "$WORK/requests.log"
        fi

        section "installed binary"
        check_version
        check_headless_get || FAILURES=$((FAILURES + 1))
    fi

    section "global git config"
    if [[ "$(snapshot_git_config)" == "$gitconfig_before" ]]; then
        pass "$HOME/.gitconfig and the XDG git config are unchanged"
    else
        fail "the role modified $HOME/.gitconfig or the XDG git config"
    fi

    printf '\n'
    if ((FAILURES > 0)); then
        printf 'FAILED: %d check(s)\n' "$FAILURES"
        exit 1
    fi
    printf 'PASSED: all checks\n'
}

main "$@"
