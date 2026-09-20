<!-- markdownlint-disable MD013 -->

# Phase 1: Provision oom-edit

**Effort:** 1.0d (2 tasks)
**Dependencies:** None
**Plan Reference:** [plan.md §3.1](../plan.md#31-proposed-change)

---

## Summary

Add a user-owned Ansible role that clones, release-builds, and links oom-edit while preserving default idempotency, upgrade behavior, privilege boundaries, and check mode.

---

## Tasks

### T1.1: Implement the oom_edit role

**Estimate:** 0.75d
**Dependencies:** None

**Description:**
Create `roles/oom_edit/defaults/main.yml` and `roles/oom_edit/tasks/main.yml`. Default the checkout to `~/.local/bin/oom-edit-src`, the release artifact to `target/release/oom-edit`, and the managed link to `~/.local/bin/oom-edit`. Ensure the containing directory exists, use `ansible.builtin.git` with `update: "{{ upgrade | bool }}"`, run `make build-release` with Cargo on `PATH`, omit `creates` only in upgrade mode, and create an absolute non-forced symlink. Add pre-state checks/conditions so a fresh `--check` does not attempt to build inside a checkout that check mode only predicted.

Keep every task unprivileged. Do not reuse `lang_tools_path`, because the role should depend only on the explicitly preceding Rust role rather than on a fact created by a later, unrelated role.

**Acceptance Criteria:**

- [x] A fresh default converge clones `main` from `https://github.com/jsco2t/oom-edit.git` into the requested directory.
- [x] It invokes the repository-owned `make build-release` target and produces the expected executable.
- [x] It creates an exact absolute symlink at `~/.local/bin/oom-edit` without overwriting an unrelated existing file.
- [x] A default re-run neither updates the checkout nor reruns the build when the release binary exists.
- [x] Upgrade mode updates the checkout and invokes the Make target without a `creates` guard.
- [x] A fresh check-mode run does not fail because the checkout or binary is absent.
- [x] No task uses `become`.

**Files:**

- `roles/oom_edit/defaults/main.yml`
- `roles/oom_edit/tasks/main.yml`

### T1.2: Wire and document the role

**Estimate:** 0.25d
**Dependencies:** T1.1

**Description:**
Insert `oom_edit` after `rust` in `local.yml`, renumber the documented dependency chain, and update `README.md` plus `CLAUDE.md` to describe the source-built application, exact install/link paths, default versus upgrade behavior, and the reason the role must run after rustup and before the final dotfiles handoff.

**Acceptance Criteria:**

- [x] Role order guarantees Git, Make, and rustup exist before the build.
- [x] `dotfiles` remains the final role and no blanket privilege escalation is introduced.
- [x] User and agent documentation accurately describe all eight roles and oom-edit's two converge modes.
- [x] Documentation states that Yazi configuration remains owned by `jsco2t/dotfiles`.

**Files:**

- `local.yml`
- `README.md`
- `CLAUDE.md`
