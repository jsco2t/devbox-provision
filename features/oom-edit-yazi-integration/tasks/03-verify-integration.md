<!-- markdownlint-disable MD013 -->

# Phase 3: Verify the Integration

**Effort:** 1.0d (3 tasks)
**Dependencies:** T1.1, T1.2, T2.1
**Plan Reference:** [plan.md §4](../plan.md#4-test-gap-assessment)

---

## Summary

Extend the repository-native three-pass CI flow with explicit oom-edit/Yazi contract checks, then run the complete Debian flow and targeted check-mode/macOS/interactive smoke tests.

---

## Tasks

### T3.1: Extend Debian CI assertions

**Estimate:** 0.50d
**Dependencies:** T1.1, T1.2, T2.1

**Description:**
Modify `.github/workflows/ci.yml` to raise the timeout to 120 minutes and add assertions around the existing three passes:

- after setup, assert `/home/dev/.local/bin/oom-edit-src/.git` exists, the release artifact is executable, the managed path is a symlink with the exact requested target, and `oom-edit --version` succeeds with `/home/dev/.local/bin` on `PATH`;
- validate the applied `.config/yazi/yazi.toml` as TOML and assert the `oom-edit` opener and `*.md` rule are present;
- after upgrade, assert the checkout `HEAD` equals `refs/remotes/origin/main`; and
- retain the final recap assertion for `changed=0`.

This test task covers T1.1, T1.2, and T2.1. The dotfiles change must be on `main` first because the CI job fetches that external branch during setup.

**Acceptance Criteria:**

- [x] CI fails on a missing checkout, binary, link, wrong link target, non-runnable command, malformed/missing Yazi rule, or stale post-upgrade checkout.
- [x] The upgrade pass completes the unguarded `make build-release` task.
- [x] The final default pass still requires whole-play `changed=0`.
- [x] The timeout reflects the added clone/build work.

**Files:**

- `.github/workflows/ci.yml`

**Completion history:** The initial direct-opener assertions were completed on
2026-09-19 and were revised by T3.3 for the router follow-up.

### T3.2: Run full and platform-specific verification

**Estimate:** 0.25d
**Dependencies:** T3.1

**Description:**
Run the repository's complete Debian CI sequence: setup, `--upgrade`, then default with `changed=0`. Separately exercise the new role in check mode against a fresh home to confirm its predicted checkout does not lead to missing-path failures or filesystem changes. On macOS, run the role through a default converge and verify the Xcode Make/rustup build, symlink, and `oom-edit --version`. Finally, launch Yazi against a Markdown fixture, open it, confirm oom-edit receives that single file, exit the editor, and confirm Yazi resumes.

**Acceptance Criteria:**

- [x] The full Debian three-pass suite passes.
- [x] Fresh role check mode completes without filesystem mutation or missing-path failure.
- [x] The macOS role converge builds and links oom-edit as the invoking user.
- [x] Interactive Yazi opening launches oom-edit for the intended Markdown path and returns to Yazi after exit.
- [x] No API/proto compatibility review is required because none are changed.

**Files:**

- No additional files expected; failures feed fixes back into the files owned by T1.1-T3.1.

## Verification Evidence

- A disposable Debian Trixie container passed setup, upgrade, and a final whole-play `changed=0` converge.
- A fresh-home role check predicted the clone without creating `~/.local` or evaluating absent build/link paths.
- An isolated macOS home passed initial build/link, `oom-edit 0.5.0`, and a second `changed=0` converge.
- A pre-existing regular file at the link path was preserved and caused the intended visible failure.
- Real Yazi launched oom-edit for the Markdown fixture and resumed after the editor exited.

### T3.3: Verify both Markdown router branches

**Estimate:** 0.25d
**Dependencies:** T2.2, T3.1

**Description:**
Update the CI contract assertion to require executable `md_router.sh`, the
blocking `md-router` opener, and the `*.md` mapping. Copy the router into an
isolated directory with test-double executables, verify adjacent oom-edit wins,
remove it, then verify the same protected Markdown path is dispatched to `hx`.

**Acceptance Criteria:**

- [x] Shell syntax validation passes for `md_router.sh`.
- [x] The oom-edit branch invokes the adjacent executable with `--` and the path.
- [x] The fallback branch invokes `hx` with `--` and the same path.
- [x] TOML parsing confirms Yazi's blocking `*.md` rule resolves to `md-router`.
- [x] CI contains equivalent regression assertions for both branches.

**Verification evidence:** Isolated test doubles confirmed exact `--` argument
forwarding for both branches, and a terminal-backed Yazi session opened a
Markdown fixture through the router's Helix fallback with the expected path.

**Files:**

- `.github/workflows/ci.yml`
- `jsco2t/dotfiles:.local/bin/md_router.sh`
- `jsco2t/dotfiles:.config/yazi/yazi.toml`
