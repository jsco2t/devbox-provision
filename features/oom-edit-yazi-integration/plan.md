<!-- markdownlint-disable MD013 -->

# Implementation Plan: oom-edit Yazi Integration

**Feature:** Install oom-edit from source and use it for Markdown in Yazi
**Author:** Jason
**Created:** 2026-09-19T20:01:30-06:00
**Updated:** 2026-09-20T11:06:42-06:00
**Status:** Complete

---

## 1. Problem Statement

### 1.1 Observed Behavior

`devbox-provision` installs Yazi as a Homebrew formula (`roles/homebrew/vars/main.yml:18-28`) and installs Rust before user-level language tooling (`local.yml:43-50`), but it does not install `oom-edit`. The authoritative Yazi configuration is tracked in the peer `jsco2t/dotfiles` repository at `.config/yazi/yazi.toml:1-17`; it currently has manager, preview, and Git fetcher settings but no Markdown-specific opener. Both `.zshrc:30-35` and `.bashrc:37-42` in that repository already add `~/.local/bin` to interactive-shell `PATH`.

The `oom-edit` source repository's `Makefile:33-35` defines `make build-release` as an offline, locked Cargo release build. Its workspace pins Rust 1.97.1 in `rust-toolchain.toml:1-3`, and `crates/oom-edit/Cargo.toml:9-11` confirms the resulting binary name is `oom-edit`. The CLI accepts exactly one positional path (`crates/oom-edit/src/args.rs:43-57,89-97`).

### 1.2 Expected Behavior

A fresh default converge must:

1. clone `https://github.com/jsco2t/oom-edit.git` branch `main` into `~/.local/bin/oom-edit-src`;
2. run `make build-release` as the invoking user with Cargo available on `PATH`;
3. create `~/.local/bin/oom-edit` as a symlink to `~/.local/bin/oom-edit-src/target/release/oom-edit`; and
4. apply dotfiles whose Yazi rules open `*.md` through a blocking
   `~/.local/bin/md_router.sh` command. The router uses the adjacent `oom-edit`
   executable when available and falls back to `hx` when it is not.

A subsequent default converge must report `changed=0`. An upgrade converge must update the source checkout from `origin/main` and invoke `make build-release` again, after which a following default converge must again report `changed=0`.

### 1.3 Reproduction

- Fresh host: run `./update-env.sh`, then inspect `~/.local/bin/oom-edit-src`, the release binary, the symlink, and the installed Yazi configuration.
- Upgrade: run `./update-env.sh --upgrade` and confirm the checkout is synchronized with `origin/main` and the release build task runs.
- Steady state: immediately run `./update-env.sh` again and confirm the play recap contains `changed=0`.
- User path: start a new Bash or Zsh session, run `command -v oom-edit`, then open a Markdown file from Yazi.

## 2. Implementation Analysis

### 2.1 Code Path

1. `update-env.sh:153-196` translates `--upgrade` into the `upgrade` extra variable and invokes `local.yml`.
2. `group_vars/all.yml:1-11` provides the default/upgrade mode contract.
3. `local.yml:43-50` orders roles. `common` guarantees Git (`roles/common/tasks/main.yml:14-30`), `native_packages` guarantees GNU Make on Linux (`roles/native_packages/vars/main.yml:8-34`), and `common` requires Xcode CLT on macOS (`roles/common/tasks/main.yml:32-48`).
4. `rust` installs rustup and Cargo as the invoking user (`roles/rust/tasks/main.yml:1-39`). The new source-build role must therefore run after `rust` and without privilege escalation.
5. `dotfiles` runs last and resets tracked home-directory files to the fetched peer-repository tip (`roles/dotfiles/tasks/main.yml:62-102`). Therefore, modifying `~/.config/yazi/yazi.toml` from an earlier provisioning role would be overwritten, while modifying it afterward would dirty the managed dotfiles worktree.
6. Yazi resolves a matching `[open]` rule to a named `[opener]`. The opener
   calls `~/.local/bin/md_router.sh %s1`; `%s1` supplies only the first selected
   path. The router inserts `--` before forwarding arguments, protecting names
   beginning with `-` for both oom-edit and Helix.

### 2.2 Current Logic and Change Point

Add a dedicated `oom_edit` role rather than treating the application as a generic Cargo tool. Its required source checkout, Make target, source-tree binary, and separate symlink do not fit `roles/lang_tools/tasks/cargo.yml`, which uses `cargo install` and places binaries directly in `~/.cargo/bin`.

Representative role logic:

```yaml
- name: Check out oom-edit source
  ansible.builtin.git:
    repo: "{{ oom_edit_repo_url }}"
    dest: "{{ oom_edit_source_dir }}"
    version: "{{ oom_edit_version }}"
    update: "{{ upgrade | bool }}"

- name: Build oom-edit release binary
  ansible.builtin.command:
    cmd: make build-release
    chdir: "{{ oom_edit_source_dir }}"
    creates: "{{ omit if (upgrade | bool) else oom_edit_release_binary }}"
  environment:
    PATH: "{{ ansible_facts['user_dir'] }}/.cargo/bin:{{ ansible_facts['env']['PATH'] }}"
```

The role must also create `~/.local/bin` before cloning and manage the absolute symlink with `ansible.builtin.file`. Do not use `force: true`; an unrelated existing file at `~/.local/bin/oom-edit` should cause a visible failure rather than be overwritten. Guard build/link behavior on a fresh `--check` run so check mode does not fail merely because the predicted clone directory is not yet present.

The coordinated dotfiles change includes this POSIX shell router:

```sh
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

if [ -x "$script_dir/oom-edit" ]; then
  exec "$script_dir/oom-edit" -- "$@"
fi

exec hx -- "$@"
```

Yazi invokes it with:

```toml
[[opener.md-router]]
run = "~/.local/bin/md_router.sh %s1"
block = true
for = "unix"
desc = "Edit Markdown with oom-edit or Helix"

[[open.prepend_rules]]
url = "*.md"
use = "md-router"
```

`prepend_rules` preserves Yazi's shipped defaults while ensuring the specific Markdown rule wins.

### 2.3 Blast Radius

- Provisioning gains one unprivileged role between `rust` and `lang_tools`; existing privilege boundaries remain unchanged.
- The initial checkout is large because `oom-edit` vendors its Cargo dependency tree, and initial compilation adds material CI/runtime cost. Upgrade runs invoke the Make target even if Cargo determines that no compilation work is necessary.
- The Yazi change belongs in `jsco2t/dotfiles`, consistent with this repository's tools/config ownership boundary (`README.md:3-6`). It affects Unix hosts receiving those dotfiles; Windows is outside this repository's supported platforms.
- `~/.local/bin` is already added to Bash and Zsh `PATH` by the dotfiles. Existing shells must be restarted or re-sourced after first converge.
- Yazi remains usable for Markdown when the oom-edit checkout/build is absent;
  the router falls back to the already-provisioned `hx` executable.
- No API, protocol, database, or generated-code changes are involved.
- CI reads dotfiles from its live `main` branch, so the dotfiles change must land before the devbox CI assertion that inspects the Yazi rule.

## 3. Implementation Strategy

### 3.1 Proposed Change

1. Create `roles/oom_edit/defaults/main.yml` with overridable repository URL, branch, source directory, release binary, and symlink paths. Default them to the exact locations requested.
2. Create `roles/oom_edit/tasks/main.yml` to:
   - create `~/.local/bin` as the invoking user;
   - inspect pre-existing source/binary state for safe check-mode guards;
   - clone on first converge and set `update` from `upgrade` so ordinary converges do not contact/pull the remote;
   - run `make build-release` with `~/.cargo/bin` prepended to `PATH`, using `creates` only outside upgrade mode;
   - create the absolute symlink after a successful build; and
   - remain entirely `become: false`.
3. Insert `oom_edit` immediately after `rust` in `local.yml`. Keep `lang_tools` after it and `dotfiles` last.
4. Update the role-order and tool-source documentation in `README.md` and `CLAUDE.md` (the tracked target of the `AGENTS.md` symlink).
5. In `jsco2t/dotfiles`, add executable `.local/bin/md_router.sh`, which
   selects an adjacent executable `oom-edit` or falls back to `hx`. Add a
   blocking opener for that router and a `*.md` prepend rule to
   `.config/yazi/yazi.toml`.
6. Extend `.github/workflows/ci.yml` with post-setup install assertions, post-upgrade source assertions, and a TOML/config assertion while retaining the final `changed=0` gate. Increase the timeout from 90 to 120 minutes to accommodate the vendored clone and two release-target invocations.

### 3.2 Alternative Approaches

- **Use `cargo install --git`: rejected.** It violates the requested checkout and symlink layout and bypasses the repository's Make build system.
- **Add tasks to `lang_tools`: rejected.** That role models editor language servers installed through ecosystem package managers. `oom-edit` is an end-user application with a persistent source checkout and different upgrade semantics.
- **Patch Yazi configuration from Ansible: rejected.** The final dotfiles reset would overwrite a pre-reset edit; a post-reset edit would leave the bare-repo worktree dirty and split configuration ownership across repositories.
- **Replace all Yazi rules with `[open].rules`: rejected.** A focused `prepend_rules` entry preserves upstream default handlers for every non-Markdown type.
- **Call oom-edit directly from Yazi: superseded.** A dotfiles checkout may be
  usable before oom-edit is built. Routing through `md_router.sh` preserves the
  preferred editor while providing a Helix fallback.
- **Use `%s` in the opener: rejected.** Yazi may pass multiple selected paths,
  but oom-edit rejects more than one positional path. `%s1` matches its current
  CLI contract.

### 3.3 Files Changed

| File | Change |
| ---- | ------ |
| `roles/oom_edit/defaults/main.yml` | New defaults for repository, version, checkout, binary, and link paths |
| `roles/oom_edit/tasks/main.yml` | New idempotent clone/build/link workflow with upgrade and check-mode handling |
| `local.yml` | Run `oom_edit` after Rust and before downstream user tooling/dotfiles |
| `README.md` | Document role order, source-built tool, upgrade behavior, and PATH outcome |
| `CLAUDE.md` | Update repository architecture and idempotency guidance for the new role |
| `.github/workflows/ci.yml` | Assert install/link/router/config contracts and retain upgrade plus idempotency coverage |
| `jsco2t/dotfiles:.local/bin/md_router.sh` | Prefer adjacent oom-edit and fall back to Helix |
| `jsco2t/dotfiles:.config/yazi/yazi.toml` | Route `*.md` through the blocking Markdown router |

## 4. Test Gap Assessment

### 4.1 Existing Test Coverage

There is no unit-test framework. `.github/workflows/ci.yml:54-99` performs three Debian converges: initial setup, upgrade, and a final default converge whose recap must report `changed=0`. This will exercise the new role's main state transitions, but today it has no explicit assertion for a source checkout, built executable, symlink target, command discoverability, source synchronization, or Yazi rule.

CI does not cover macOS, password-requiring sudo, `bootstrap.sh`, or a fresh `--check` run.

### 4.2 Adjusted/Improved/Changed Test Coverage

- Add an install-contract step after setup that verifies the checkout is a Git worktree, the expected release binary is executable, the managed path is a symlink to that binary, and `oom-edit --version` works with `~/.local/bin` on `PATH`.
- Validate the applied Yazi TOML and assert that it contains the named router
  opener and `*.md` rule. Exercise the router with test doubles both when an
  adjacent `oom-edit` exists and when it must fall back to `hx`. Because the
  config and script are externally owned, merge the dotfiles commit before
  enabling this assertion here.
- After upgrade, assert the checkout's `HEAD` equals its refreshed `refs/remotes/origin/main`. The play's successful build task proves `make build-release` was invoked; Cargo is allowed to do no compilation when the source is unchanged.
- Keep the final whole-play `changed=0` assertion as the regression test for `update: false`, the default build `creates` guard, and idempotent symlink management.
- Manually smoke-test macOS and interactive Yazi dispatch, which the Debian non-TTY workflow cannot validate.

### 4.3 Test Plan

| # | Test Case | What It Validates | Type |
| - | --------- | ----------------- | ---- |
| 1 | Fresh Debian setup installs oom-edit | Clone, pinned Make release build, executable output, and exact symlink target | Modified |
| 2 | oom-edit is command-discoverable | `~/.local/bin` link executes and reports a version | Modified |
| 3 | Applied Yazi configuration is valid | TOML parses and `*.md` resolves to the blocking Markdown router | Modified |
| 4 | Upgrade synchronizes source and invokes build | `HEAD == refs/remotes/origin/main`; upgrade play completes the unguarded build task | Modified |
| 5 | Third converge reports `changed=0` | Default checkout, build, and symlink paths remain idempotent | Existing/Modified |
| 6 | Fresh check mode does not fail | Predicted clone does not cause missing-`chdir` or missing-link-source failures | New |
| 7 | macOS source build smoke | Xcode Make, rustup toolchain resolution, binary, and symlink work without become | New |
| 8 | Interactive Yazi Markdown open | Entering `*.md` launches oom-edit for one path and returns cleanly to Yazi | New |
| 9 | Markdown router branches | Adjacent oom-edit is preferred; absent oom-edit dispatches the same protected path to `hx` | New |

## 5. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
| ---- | ---------- | ------ | ---------- |
| Large vendored clone and Rust build exceed CI time | M | H | Raise timeout to 120 minutes and preserve default-mode guards so only setup and upgrade invoke work |
| Rust 1.97.1 is not already installed | M | M | Run after rustup installation with `~/.cargo/bin` on `PATH`; allow rustup to resolve the repository-pinned toolchain |
| Yazi receives multiple selected files | M | M | Use `%s1`, matching oom-edit's one-positional-path CLI |
| Existing non-symlink `~/.local/bin/oom-edit` conflicts | L | M | Fail without `force`; require the user to resolve ownership explicitly |
| Local changes in `oom-edit-src` block upgrade | L | M | Do not force-reset or discard user changes; surface the Git failure |
| Cross-repository CI ordering causes transient failure | M | M | Merge dotfiles configuration before devbox assertions that depend on it |
| Fresh `--check` references a checkout not created in check mode | M | M | Stat existing state and guard build/link operations that require materialized paths |
| Interactive shell has stale PATH after first install | M | L | Document that a new/re-sourced shell is required; dotfiles already export `~/.local/bin` |
| Neither oom-edit nor `hx` is executable | L | M | Let the router fail visibly; normal provisioning installs Helix before applying dotfiles |

## 6. Resolved Questions

| # | Resolution | Affects |
| - | ---------- | ------- |
| 1 | Match only `*.md`, as requested and planned; additional extensions remain out of scope. | Dotfiles match scope |
| 2 | Route Markdown through a dotfiles-owned script that prefers adjacent oom-edit and falls back to `hx`. | Yazi availability before oom-edit is built |
