<!-- markdownlint-disable MD013 -->

# oom-edit Yazi Integration — Feature Implementation Documentation

**Feature:** Install oom-edit from source and use it for Markdown in Yazi
**Jira:** N/A
**Repository:** `/Users/jason/Developer/sources/personal/devbox-provision` with a coordinated `jsco2t/dotfiles` change
**Created:** 2026-09-19T20:01:30-06:00
**Status:** Complete

---

## Documentation Structure

| Document | Purpose |
| -------- | ------- |
| [`plan.md`](plan.md) | Implementation plan, strategy, and test gap assessment |
| [`tasks/`](tasks/index.md) | Implementation task breakdown with test-forward approach |
| [`follow-ups/changelog.md`](follow-ups/changelog.md) | Requirement changes applied after initial completion |

---

## Summary

| Metric | Value |
| ------ | ----- |
| Total Tasks | 7 |
| Estimated Effort | 2.5 days |
| Test Gap | Closed: CI now checks installation, upgrade/idempotency, and both Markdown router branches |

---

## Revision History

| Date | Type | Summary | Change Log |
| ---- | ---- | ------- | ---------- |
| 2026-09-19 | Initial | Planned and implemented direct oom-edit integration | — |
| 2026-09-20 | Follow-Up | Added a dotfiles-owned Markdown router with Helix fallback | [`follow-ups/changelog.md`](follow-ups/changelog.md) |
