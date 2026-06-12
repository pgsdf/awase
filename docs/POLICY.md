# PGSD policy: account model, attributes, and regulatory posture

This document describes what PGSD does and does not do regarding
user accounts, per-user attributes (including age-related
attributes), and compliance with regulatory frameworks that impose
operating-system-level requirements on age verification or age
signaling.

The document is descriptive. It records the technical state of
the system and the responsibility boundary between PGSDF (the
distribution maintainer) and operators (the parties who deploy
PGSD on actual hardware). It does not take positions on the
merits of any law or regulatory framework.

This document covers the substrate (UTF) and the distribution
(PGSD) together where relevant, and notes the layer split where
it matters. See README.md for the substrate-versus-distribution
framing.

## PGSD account model

PGSD relies on FreeBSD's standard user account infrastructure.
There is no parallel PGSD-only account database; PGSD adds
metadata alongside the existing FreeBSD account model, not in
place of it.

### Account storage

User accounts are stored in `/etc/master.passwd` and `/etc/passwd`
per FreeBSD convention. Account creation, password changes,
shell assignments, and account deletion use the standard FreeBSD
tools (`adduser(8)`, `pw(8)`, `passwd(1)`, `rmuser(8)`).

PGSD does not duplicate, mirror, or replace this storage. PGSD
does not maintain a separate user database that would need to
be kept in sync with `/etc/master.passwd`.

### Authentication

`pgsd-sessiond`, PGSD's graphical login daemon, authenticates
users via PAM (Pluggable Authentication Modules). The default
PAM stack at `/etc/pam.d/pgsd-sessiond` uses `pam_unix` against
`/etc/master.passwd`, identical to the configuration used by
`login(1)` and `sshd`.

Operators may swap the PAM stack to use `pam_ldap`, `pam_krb5`,
or any other supported PAM module without modifications to
`pgsd-sessiond` itself. Authentication backend selection is the
operator's choice.

### User enumeration

`pgsd-sessiond` enumerates eligible users for the login screen
by scanning `/etc/master.passwd` and including each entry that
satisfies:

  - `pw_uid > 1000`, and
  - `pw_shell` is present in `/etc/shells`.

UIDs 0 through 1000 are excluded. This includes root and FreeBSD
system accounts.

The full design of `pgsd-sessiond` is at
`pgsd-sessiond/docs/adr/0001-design.md`.

## Per-user attributes

PGSD stores PGSD-specific per-user metadata in
`/etc/utf/users/<username>.conf`, one file per enrolled user.
The format is plain-text key-value pairs.

The fields defined in the initial design are:

  - `display_name`: UI override of the GECOS field for the login
    screen.
  - `default_session`: the name of the `.session` file under
    `/usr/local/share/pgsd/sessions/` to launch by default.
  - `avatar_path`: path to an image file (reserved field; not
    rendered in the initial login UI).
  - `age_bracket`: one of `under-13`, `13-15`, `16-17`, `adult`,
    `unspecified`. Default `unspecified`.
  - `capabilities`: comma-separated list of capability flag
    strings (initial set: `can-shutdown`, `can-add-users`).

Files are operator-managed. PGSD does not provide a tool that
prompts users to fill in these fields; the operator creates and
edits the files.

### Behavior of the `age_bracket` field

The `age_bracket` field is operator-set. It is not collected
from the user during account creation, not collected at login,
and not exposed to applications via any system API.

PGSD does not validate the value against the user's actual age.
PGSD does not require the field to be set. PGSD does not block
or restrict any system functionality based on the field's value.
The login UI does not display the field.

The field exists to give operators a place to record an
age-bracket attribute alongside other per-user metadata if the
operator's deployment context requires such a record. PGSD
itself does not act on the field.

### Behavior of the `capabilities` field

The `capabilities` field is operator-set. PGSD components may
read the list to gate optional UI affordances (the initial v1
example: a `can-shutdown` user is offered shutdown and restart
buttons in a hypothetical future logout panel; in the initial
v1 login UI all users see the shutdown buttons unconditionally).

Capability strings are advisory. Where a capability has a
corresponding FreeBSD group (`wheel`, `operator`), enforcement
of the underlying privilege is via the standard FreeBSD group
mechanism, not via the capability flag string. The flag string
is a hint to PGSD-aware UI, not a security boundary.

## What PGSD does not implement

PGSD does not implement the following:

  - **Age verification.** PGSD does not collect a date of birth
    at account creation, at first login, or at any other point.
    PGSD does not validate user-supplied or operator-supplied
    age information against any external source (no document
    upload, no biometric check, no third-party identity
    service).
  - **An age-signal API for applications.** PGSD does not
    provide an operating-system-level API by which applications
    may query a signal regarding the user's age or age bracket.
    No such API exists in UTF substrate or in PGSD distribution
    layer.
  - **Parental-consent workflows.** PGSD does not implement any
    workflow that requires a parent or legal guardian to verify
    information about another user, to authorize the creation
    of an account, or to gate access to system functionality
    on a relationship between two accounts.
  - **App-store-level controls.** PGSD does not include an
    app store. Software is installed via FreeBSD's package
    system (`pkg(8)`) and via standard build-from-source
    procedures. Neither path includes age-based access
    controls. PGSD does not modify FreeBSD's package system to
    add such controls.
  - **Compliance attestation.** PGSDF does not certify or
    attest that PGSD complies with any specific regulatory
    framework regarding age verification, age signaling,
    parental consent, or related requirements.

## Regulatory frameworks

The following regulatory frameworks impose operating-system or
app-store-level requirements regarding age verification or age
signaling. The list is not exhaustive; it is included to
indicate the type of requirement that PGSD does not implement.

  - **California AB 1043 (Digital Age Assurance Act).** Signed
    October 13, 2025. Operative January 1, 2027. Requires
    operating-system providers to collect age information from
    users at account setup and to provide an age-bracket signal
    to applications via a real-time API. Brackets are defined
    as under 13, 13 to under 16, 16 to under 18, and 18 or
    older. Self-attested; no document upload or biometric
    verification required.
  - **Utah HB 498 (App Store Accountability Act Amendments).**
    Signed March 18, 2026. Most provisions effective May 6,
    2027 (delayed from the original May 6, 2026 effective date).
    Requires app-store providers and developers to verify a
    user's age category and obtain parental consent for minors,
    with enforcement via private right of action.
  - **Texas SB 2420 (App Store Accountability Act).**
    Originally to take effect January 1, 2026; preliminarily
    enjoined on First Amendment grounds before that date.
  - **Colorado SB 26-051.** Pending. Imposes operating-system
    age-verification requirements similar in shape to AB 1043.
  - **Federal HR 8250 (Parents Decide Act).** Introduced in
    the U.S. House of Representatives April 13, 2026.
    Currently in the House Committee on Energy and Commerce.
    Would require operating-system providers to collect a
    date of birth from each user and obtain parental
    verification for users under 18.
  - **Other states.** Similar legislation is pending in
    Illinois, Louisiana, New York, and other states. The
    landscape is changing on a quarterly cadence as bills are
    introduced, amended, enjoined, or come into effect.

PGSD does not implement compliance machinery for any of the
above frameworks. The mechanisms PGSD does provide (the
per-user attribute file, including the `age_bracket` field)
are not designed to satisfy the requirements of any specific
framework. They exist to give operators a building block they
may use, at their discretion, in operator-driven policy.

## Operator responsibilities

If an operator deploys PGSD in a context with regulatory
requirements regarding age verification, age signaling, or
parental consent, the operator is responsible for determining
whether the deployment satisfies those requirements. PGSDF does
not represent that PGSD satisfies any such requirements.

The per-user attribute mechanism (`/etc/utf/users/<name>.conf`)
may serve as a building block for operator-driven policy. An
operator can:

  - Set `age_bracket` for each enrolled user from out-of-band
    knowledge.
  - Configure session types per user via `default_session` so
    that users with different `age_bracket` values land in
    different session environments.
  - Configure capability flags per user via `capabilities` to
    gate UI affordances.
  - Map capability flags to FreeBSD groups and configure PAM
    session hooks to add the user to those groups at session
    open.
  - Layer operator-managed application-level policy on top of
    these primitives.

Doing so is the operator's choice and the operator's
responsibility. PGSD provides the primitives; PGSD does not
configure them, does not enforce a particular policy on top of
them, and does not represent any specific configuration as
satisfying any specific regulatory requirement.

If the regulatory landscape requires a system that does not
permit operator-discretion over age handling (for example, a
framework that requires the operating system to mandatorily
collect a date of birth at account setup), PGSD does not
satisfy that requirement and is not configurable to satisfy
that requirement without modifications outside PGSD's design
scope. Operators in such contexts should evaluate whether
PGSD is an appropriate choice for their deployment.

## Document scope and updates

This document describes the state of PGSD's account model, the
per-user attribute mechanism, and the relationship between
PGSD's design and the regulatory landscape as of the document's
last revision date.

Regulatory frameworks change on a quarterly or faster cadence.
The list of frameworks above is a snapshot, not an authoritative
or current legal reference. Operators are responsible for their
own legal analysis of whether PGSD is appropriate for their
deployment context.

PGSD's design changes more slowly. Substantive changes to the
account model, the per-user attribute mechanism, or PGSDF's
posture on regulatory compliance are recorded as ADRs under
`pgsd-sessiond/docs/adr/` and similar component directories,
with this document updated to reflect the resulting state.

The initial revision of this document is dated 2026-05-10 and
reflects the design captured in
`pgsd-sessiond/docs/adr/0001-design.md`.
