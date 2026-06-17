# docs/ index

This index declares each document's class, so staleness has an
owner and a rule.

**LIVING** documents claim current truth. When reality changes
(an ADR closes, a daemon retires, a path moves), the change is
not complete until the affected living documents are updated;
F.6's Decision 5 reconciliation pass is the worked example.

**RECORD** documents are frozen evidence: dated sign-offs,
session memos, resolved investigations. They are never edited
to track later reality; history stays true. Their statements
are accurate as of their stated date.

| Document | Class | Subject |
|---|---|---|
| AWASE_ARCHITECTURAL_DISCIPLINE.md | LIVING | The guarantee-path doctrine: what Awase writes vs accepts. |
| AWASE_PROJECT_SCOPE.md | LIVING | Substrate vs distribution scope. |
| AWASE_DAEMON_DEPENDENCY_ABSENCE.md | LIVING | Startup postures under missing dependencies. |
| FAILURE_MODES.md | LIVING | Operator-facing runtime failure catalog. |
| AWASE_STORAGE_DEPENDENCY.md | LIVING | Filesystem and persistence expectations. |
| AWASE_USB_HID_BOUNDARY.md | LIVING | Where Awase's input ownership begins. |
| AWASE_ZIG_STDLIB_BOUNDARY.md | LIVING | Which stdlib facilities the guarantee path may use. |
| FREEBSD_SUBSYSTEMS.md | LIVING | Disposition table for FreeBSD subsystems. |
| FREEBSD_IMPROVEMENTS.md | LIVING | Improvements Awase would want upstream. |
| FREEBSD_ISSUES.md | LIVING | Known platform issues affecting Awase. |
| POLICY.md | LIVING | PGSD account model and regulatory posture. |
| PROTOCOL_NAMESPACE_CONVENTION.md | LIVING | Protocol naming rules. |
| does-awase-have-a-framebuffer.md | LIVING | The framebuffer question, answered. |
| Thoughts.md | RECORD | chronofs architecture design (the design held; ADRs govern changes). |
| PROTOCOL_MISMATCH_FINDINGS.md | RECORD | Integration audit, resolved. |
| AD12_VERIFICATION.md | RECORD | AD-12 sign-off, 2026-05-05. |
| AD13_VERIFICATION.md | RECORD | AD-13 sign-off. |
| AD36_VERIFICATION.md | RECORD | AD-36 sign-off. |
| DF4_VERIFICATION.md | RECORD | DF-4 sign-off. |
| sessions/*.md | RECORD | Per-session working memos. |

Subsystem documentation under `<subsystem>/docs/` follows the
same split implicitly: ADRs and dated verification protocols are
RECORDS; proposals are RECORDS once their stage closes (the ADR
chain supersedes them as the source of truth); READMEs and
operational guides (such as `semasound/docs/SUPERVISION.md` and
`INSTALL.md` at the root) are LIVING.

The sprint-backlog experiment (`SPRINT.md`) ended with its only
sprint (closed 2026-04-19) and the file was removed 2026-06-05;
the project's cadence is ADR-governed milestone work recorded in
`BACKLOG.md`, with closed work in `BACKLOG-history.md`.
