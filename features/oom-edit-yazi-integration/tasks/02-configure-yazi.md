<!-- markdownlint-disable MD013 -->

# Phase 2: Configure Yazi

**Effort:** 0.50d (2 tasks)
**Dependencies:** None; merge before T3.1
**Plan Reference:** [plan.md §3.1](../plan.md#31-proposed-change)

---

## Summary

Change the peer dotfiles repository, which is the authoritative owner of user
configuration, so Yazi dispatches Markdown files through a resilient router
that prefers oom-edit and falls back to Helix.

---

## Tasks

### T2.1: Add the oom-edit opener and Markdown rule

**Estimate:** 0.25d
**Dependencies:** None

**Description:**
In `jsco2t/dotfiles`, extend `.config/yazi/yazi.toml:1-17` with a Unix-only, blocking opener that runs `oom-edit -- %s1`, then prepend a `url = "*.md"` rule using that opener. Preserve the existing manager, preview, and Git plugin configuration.

Use `%s1`, not `%s`, because `oom-edit` accepts exactly one positional path. Keep this change out of the Ansible role so the final dotfiles reset remains authoritative and clean.

**Acceptance Criteria:**

- [x] Yazi's configuration remains valid TOML.
- [x] `*.md` resolves to the named `oom-edit` opener before Yazi's default text rule.
- [x] The opener blocks so the terminal is returned to Yazi after oom-edit exits.
- [x] A selected path beginning with `-` is protected by the `--` argument separator.
- [x] Existing Yazi rules are retained.

**Files:**

- `jsco2t/dotfiles:.config/yazi/yazi.toml`

**Completion history:** This original direct opener was completed on 2026-09-19
and superseded by T2.2 without removing its audit trail.

### T2.2: Add a Markdown router with Helix fallback

**Estimate:** 0.25d
**Dependencies:** T2.1

**Description:**
Add executable `jsco2t/dotfiles:.local/bin/md_router.sh`. Resolve the script's
physical directory and, when an executable `oom-edit` exists beside it, execute
that binary with the supplied Markdown path. Otherwise execute `hx` from
`PATH`. Insert `--` before forwarded arguments in both branches.

Replace Yazi's direct oom-edit opener with a blocking `md-router` opener that
runs `~/.local/bin/md_router.sh %s1`. Keep the existing `*.md` prepend rule but
point it at the router.

**Acceptance Criteria:**

- [x] The router is executable and compatible with POSIX `/bin/sh`.
- [x] An executable adjacent `oom-edit` is preferred over any command from `PATH`.
- [x] When adjacent oom-edit is absent or not executable, the same arguments are sent to `hx`.
- [x] Both branches insert `--` before the supplied path.
- [x] Yazi's blocking `*.md` rule uses the router and existing unrelated configuration is retained.

**Files:**

- `jsco2t/dotfiles:.local/bin/md_router.sh`
- `jsco2t/dotfiles:.config/yazi/yazi.toml`
