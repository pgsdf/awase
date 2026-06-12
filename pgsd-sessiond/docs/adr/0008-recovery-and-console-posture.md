# 0008 Recovery and console posture

## Status

Proposed (2026-06-08). This ADR is AD-11.1. It records the posture
the AD-11 BACKLOG entry already argued, and it settles the two
mechanism questions that entry left open: where the recovery marker
lives and how it behaves, and where Alt detection happens. Operator
ratification moves it to Accepted; the sub-stages AD-11.2 through
AD-11.5 implement and bench what is decided here.

## Context

AD-39 compiled vt(4) (and vt_efifb with it) out of the PGSD kernel,
so there is no FreeBSD console-on-framebuffer driver competing with
UTF for the display, and there is no ttyvN shell to fall back to.
SM-1 made pgsd-sessiond the graphical login surface, and AD-12 gave
us s6 and rc.d service lifecycle. What remains is to make
pgsd-sessiond the universal login surface for recovery as well as
normal use, so that every path that once ended at a vt(4) shell now
ends at the pgsd-sessiond prompt rendered through drawfs on the
inputfs and drawfs substrate a normal session uses.

Recovery here is a normal UTF session started under a different
profile, not a separate console layer. It is reached three ways, all
resolving to one boolean consumed by later rc.d stages and by
pgsd-sessiond:

  1. Normal bootstrap. rc.d ordering completes, pgsd-sessiond
     presents the login prompt, the user logs into a normal session.
  2. Operator-selected recovery. The operator signals recovery at
     boot; bootstrap selects the recovery profile (minimal services,
     recovery tools on PATH, defaults biased to root login).
  3. Auto-recovery. The previous boot did not complete cleanly, or a
     detectable rc.d failure or an explicit operator request asked
     for it; bootstrap selects the recovery profile on its own.

Recovery is a routine mode operators choose (change a boot
environment, roll back a ZFS BE, repair a config that breaks the
normal session), not only a state the system falls into.

## Decision

### D1: Recovery is a session profile

There is no console substrate, no consfs, no kernel-side text
rendering. Recovery is an rc.d profile variant plus a pgsd-sessiond
configuration that adjusts defaults. This keeps AD-11 inside the
session layer UTF already owns and holds the scope at Medium.

### D2: One recovery boolean, three triggers

Early bootstrap resolves a single boolean, "enter recovery", from
the OR of three sources: an operator signal at boot (D4), the
persisted marker (D3), and a detectable bootstrap failure. Later
rc.d stages and pgsd-sessiond read only the boolean; they do not
each re-derive the triggers.

### D3: The persisted marker, and why the panic path does not write it

The marker question is really two independent signals; conflating
them is what made the original "the panic handler sets a marker"
idea look simple when it is not. Writing any persistent store from
panic context is unsafe: the filesystem may be the fault, I/O in
panic context is not dependable, and EFI variable writes from a
faulted kernel are a way to brick firmware (the more so on the
idiosyncratic Apple firmware these machines run). So the panic path
does not write a marker. Instead:

  - Auto-detection of an unclean previous boot is done by inversion.
    A boot-progress state lives in a small marker file on /boot
    (available very early, survives a failed main-pool import, and
    avoids NVRAM writes). Very early bootstrap reads it: if it still
    reads "in-progress" from the previous cycle, that boot never
    reached completion (panic, hang, or power loss), so "enter
    recovery" is set. Early bootstrap then arms it to "in-progress";
    a late rc.d "boot complete" stage advances it to "clean"; a
    clean shutdown or reboot also leaves it "clean". A panic writes
    nothing and simply leaves "in-progress" behind, which is the
    signal. This is self-resetting per boot, so it cannot trap the
    system in recovery.

  - Explicit recovery requests use a separate field in the same
    marker file, written from normal userland where writing is safe:
    a reboot-into-recovery command sets it, and a detectable rc.d
    failure (ZFS import fails, a critical service refuses to start)
    sets it with a reason string. This field is cleared when a
    recovery session starts, so the next normal boot is normal
    again. If the system crashes again before recovery finishes, the
    boot-progress signal above independently re-triggers, so an
    unclean exit from recovery still lands back in recovery.

The marker file is /boot/utf-recovery (one small text file, two
fields: boot-progress state and an optional recovery-request reason).
The loader does not need to read it under D4, so no loader filesystem
dependency is added.

### D4: Alt detection lives in early rc.d, over inputfs

The operator signal is detected in an early rc.d stage, just after
inputfs attaches and the keyboard is enumerated, by polling inputfs
for a designated held key (Alt) over a brief, prompted window. This
keeps the input path on UTF's own substrate, the same posture
inputfs takes toward kbdmux for early keyboard, and it avoids
loader-level modifier detection, which is unreliable over the EFI
Simple Text Input protocol (it delivers keystrokes, not clean
modifier state).

The gap this leaves, a failure earlier than inputfs attach where the
operator cannot be seen holding Alt, is covered by D3: such a boot
never reaches "clean", so the next boot auto-recovers. For an
operator who wants recovery before inputfs is up on the current
boot, the reliable pre-inputfs path is a loader menu entry that sets
a kenv variable (a menu selection, not modifier detection), folded
into the same boolean; this is recommended as a cheap complement,
not as the primary mechanism. The combination (loader menu for the
pre-inputfs window, inputfs Alt for convenience in-OS, marker for
automatic cases) leaves no uncovered trigger.

### D5: What UTF does not own

UTF replaces the user-facing console, not the kernel's own
diagnostic channel. Specifically out of scope, as platform
transport:

  - kernel-side text rendering for panic or early-printf messages.
    Before drawfs.ko loads there is no on-screen destination on a
    PGSD kernel; those messages reach the dmesg ring and any serial
    console, which is the same posture FreeBSD GENERIC takes when
    vt(4) cannot initialise.
  - a getty or TTY-like abstraction. pgsd-sessiond is the login
    surface; TTY semantics belong to the shell under the session.
  - single-user mode in the init sense; the recovery profile
    supersedes it.

When drawfs, inputfs, or the display are broken badly enough that
pgsd-sessiond cannot render a prompt, AD-11 cannot help and the
operator's path is external media. This is acknowledged, not worked
around.

### D6: Recovery profile (sketch; detailed design deferred to AD-11.3)

The recovery profile starts a minimal service set, puts recovery
tools on PATH, and biases login defaults toward root. It is selected
by the recovery boolean at the rc.d profile-selection point and
communicated to pgsd-sessiond through its existing configuration
surface. The concrete service list, PATH, and login defaults are
AD-11.3.

## Implementation

  - AD-11.2: the early-bootstrap trigger. inputfs Alt poll plus
    marker read (and the optional loader-menu kenv), resolved to the
    single boolean. Bench: hold Alt at boot, observe recovery select.
  - AD-11.3: the recovery session profile (D6 made concrete).
  - AD-11.4: the marker writers and clearer. The late rc.d
    boot-complete stage that advances boot-progress to clean; the
    rc.d failure hook that sets the recovery-request reason; the
    reboot-into-recovery command; the clear-on-recovery-start step.
    No panic-handler writer (D3).
  - AD-11.5: bench across all paths. Alt at boot; a deliberately
    broken config to exercise the rc.d failure path; an injected
    panic (AD-9 harness) to confirm the next boot auto-recovers via
    the left-behind in-progress state; an operator
    reboot-into-recovery.

## Risks and mitigations

  - Marker traps the system in recovery. Mitigated by D3's split:
    boot-progress is self-resetting per boot, and the explicit
    request clears on recovery-session start. Neither sticks.
  - Alt detection placement leaves a window. Accepted and covered:
    failures before inputfs attach are caught by boot-progress on
    the next boot, and the loader-menu complement covers a
    deliberate pre-inputfs operator choice.
  - The recovery session itself is broken. If drawfs or inputfs
    cannot render a prompt, external media is the answer (D5). Not
    worked around.
  - /boot availability. The marker is on /boot specifically so it
    survives a failed main-pool import; if /boot itself is
    unreadable the machine is already in external-media territory.

## Notes

This ADR refines one assumption in the AD-11 BACKLOG entry: the entry
described the marker as something the panic handler sets before
reboot. D3 replaces that with the boot-progress inversion because a
panic-context persistent write is unsafe; the observable outcome the
entry wanted (a panic leads to auto-recovery on the next boot) is
preserved, by safer means.
