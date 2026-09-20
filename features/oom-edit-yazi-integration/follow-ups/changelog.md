<!-- markdownlint-disable MD013 -->

# Change Log

**Feature:** Install oom-edit from source and use it for Markdown in Yazi
**Jira:** N/A

---

## 2026-09-20T11:06:42-06:00 — Follow-Up Update

### Change Context

The dotfiles checkout and Yazi configuration must remain usable on a machine
where oom-edit has not yet been cloned and built.

### Sources

- User-provided text

### Change Summary

| # | Type | Description | Affects |
| - | ---- | ----------- | ------- |
| 1 | Changed | Route Markdown through a dotfiles-owned script instead of invoking oom-edit directly | Plan, dotfiles, CI |
| 2 | New | Fall back to `hx` when no executable adjacent oom-edit exists | Script, tests, risks |

### Documents Updated

| Phase | Document | Change Type | Summary |
| ----- | -------- | ----------- | ------- |
| Plan | `plan.md` | Updated | Replaced the direct opener with router behavior and added fallback risks/tests |
| Design | `plan.md` §2-3 | Updated | Defined POSIX router resolution, argument safety, and ownership |
| Tests | `plan.md` §4 | Updated | Added deterministic coverage of both dispatch branches |
| Tasks | `tasks/02-configure-yazi.md`, `tasks/03-verify-integration.md` | Updated | Added T2.2 and T3.3 while preserving completed task history |
| Verification | `.github/workflows/ci.yml` | Updated | Added script/config assertions and test-double dispatch checks |

### Impact Summary

- **Requirements changes:** 1 changed, 1 new, 0 removed
- **Design decisions revisited:** 1
- **Tasks added/modified/removed:** 2 / 0 / 0
- **Verification tests added/modified/removed:** 1 / 1 / 0
- **Open items:** 0 resolved, 0 new, 0 continuing
