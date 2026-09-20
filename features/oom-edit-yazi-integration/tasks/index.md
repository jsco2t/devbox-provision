<!-- markdownlint-disable MD013 -->

# Tasks Index

**Parent:** [../index.md](../index.md)
**Last Updated:** 2026-09-20T11:06:42-06:00

---

## Documents

| Document | Description | Created |
| -------- | ----------- | ------- |
| [`01-provision-oom-edit.md`](01-provision-oom-edit.md) | Add and wire the source-build role | 2026-09-19 |
| [`02-configure-yazi.md`](02-configure-yazi.md) | Add the authoritative Markdown opener in dotfiles | 2026-09-19 |
| [`03-verify-integration.md`](03-verify-integration.md) | Extend CI and execute full verification | 2026-09-19 |

## Task Tracking

| Task ID | Task Name | Estimate | Dependencies | Completed |
| ------- | --------- | -------- | ------------ | --------- |
| T1.1 | Implement the oom_edit role | 0.75d | None | Yes |
| T1.2 | Wire and document the role | 0.25d | T1.1 | Yes |
| T2.1 | Configure Yazi in dotfiles | 0.25d | None | Yes |
| T2.2 | Add Markdown router with Helix fallback | 0.25d | T2.1 | Yes |
| T3.1 | Extend Debian CI assertions | 0.50d | T1.1, T1.2, T2.1 | Yes |
| T3.2 | Run full and platform-specific verification | 0.25d | T3.1 | Yes |
| T3.3 | Verify both Markdown router branches | 0.25d | T2.2, T3.1 | Yes |

Initial critical path completed: T1.1 → T1.2 → T3.1 → T3.2. Follow-up path completed: T2.1 → T2.2 → T3.3.
