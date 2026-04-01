# B0XX: Bug Title

## Summary

Brief description of the bug behavior in one sentence.

## Severity Assessment

<!--
  Severity = Impact x Frequency
  - Impact: How much damage does this cause? (data loss, UX degradation, cosmetic)
  - Frequency: How often does it occur? (always, sometimes, rare edge case)
-->

| Dimension | Value | Notes |
|-----------|-------|-------|
| **Severity** | blocker / major / minor / trivial | |
| **Impact** | data loss / functionality broken / UX degraded / cosmetic | |
| **Frequency** | always / common / rare / edge case | |
| **Affected users** | all / specific role / specific config | |

## Steps to Reproduce

<!--
  Numbered steps that reliably reproduce the bug.
  Include exact inputs, configuration, and state.
-->

1. [Precondition/setup state]
2. [Action taken]
3. [Action taken]
4. [Observe bug]

## Expected Behavior

What should happen at step N.

## Actual Behavior

What actually happens. Include error messages, screenshots, or logs if available.

## Environment

- **OS**: [e.g., Linux 6.x, macOS 15, Windows 11]
- **Version**: [app version or commit hash]
- **Runtime**: [e.g., Go 1.23, Node 22, PHP 8.4]
- **Browser** (if applicable): [e.g., Chrome 130]
- **Config** (if relevant): [specific settings that trigger the bug]

## Root Cause Analysis

<!--
  Populated during investigation. Leave empty if unknown.
  This section helps prevent similar bugs in the future.
-->

### Investigation

- [ ] Bug reproduced locally
- [ ] Minimal reproduction case identified
- [ ] Root cause identified
- [ ] Regression check: was this working before?

### Findings

- **Root cause**: [What code/logic/config causes the bug, or "under investigation"]
- **Introduced in**: [commit/PR/version or "unknown"]
- **Regression**: yes / no / unknown

### Fix Strategy

- **Approach**: [How to fix - e.g., "validate input before processing", "handle nil case"]
- **Risk**: [What could break - e.g., "low - isolated change", "medium - touches shared logic"]
- **Alternative considered**: [Other approach and why rejected, if applicable]

---

## Acceptance Criteria

- [ ] Bug no longer reproduces with steps above
- [ ] No regression introduced in related functionality
- [ ] Test added to prevent recurrence
- [ ] Edge cases from same code path verified

---

## Metadata

- **Status**: backlog | in-progress | done
- **Version**: v0.X.0
- **Priority**: critical | high | medium | low

## Related

- **Caused by**: [commit/PR or "unknown"]
- **Blocks**: [F0XX or "none"]
- **Related issues**: [#123 or "none"]

## Notes

_Workarounds, investigation logs, related discussions._
