# 0011 Reconcile F-stage map with the vertical-slice path taken in commits 1-6g

## Status

Accepted, 2026-05-28. Decision-owner ratification.

This ADR is bookkeeping. It does not reverse, reopen, or
amend ADR 0006's decision to replace snd(4) in full, ADR
0007's physics/semantics boundary, ADR 0008's F-stage scope
ordering, or any other accepted decision. It records the
gap between the formal F-stage map in ADR 0008 (which
sequences F.1 then F.2 then F.3) and the path audiofs's
commits 1 through 6g actually took (a vertical slice
through controller, codec, stream descriptor, and DAC
producing audible output without F.1's state-file
publication or F.2's event ring). The body below maps what
was done against what each formal sub-stage required,
reframes the closure criteria so future readers can verify
each sub-stage closes by checking concrete artefacts, and
leaves the substantive remaining work (state-file
publication, event ring, continuous streaming, format
negotiation, clock-writer integration) for the per-sub-stage
ADRs that will follow.

ADR-before-code discipline continues to hold. Each remaining
F-stage sub-stage still requires its own ADR before
implementation. This ADR does not pre-empt those ADRs; it
documents the starting state they will build on.

This ADR is the audiofs analogue of the inputfs scope
reconciliation ADRs that landed when inputfs's
implementation deviated from its original sub-stage plan.
Like those, it does not edit prior ADRs (forward-only
discipline); it records the supersession of specific
closure criteria so future readers follow the chain.

## Context

ADR 0008 ("Stage F scope and sequencing") set out an
F.0-F.7 sub-stage map. The relevant sub-stages here are:

  - **F.1**: audiofs kernel skeleton. Per ADR 0008 line
    300-303: "Attaches to one PCM endpoint on a listed
    chipset, publishes `/var/run/sema/audio/state`, no
    audio data flow. Mirrors inputfs's USB-HID-first
    skeleton." The proposal at
    `audiofs/docs/audiofs-proposal.md` Stage F.1 added the
    verifiable criterion: "state file exists with correct
    magic and version, device count matches the number of
    attached USB audio devices."
  - **F.2**: stream lifecycle events ring. Per ADR 0008
    line 304-306: "begin / end / xrun / format-change, per
    ADR 0007's physics-only constraint and its xrun
    tiebreak." Proposal: "events ring publishes stream
    begin, stream end, xrun, and format-change events. No
    audio data yet."
  - **F.3**: the audio data path. Per ADR 0008 line
    307-315: "where per-chipset hardware-driver work
    actually begins and where the scope ADR 0006 commits
    to becomes real. Largest single sub-stage with the
    most unknowns; should be decomposed further in its
    own sub-stage ADR before it starts."

The 2026-05-20 status update (BACKLOG.md AD-3) recorded that
experimental implementation began on `pgsd-bare-metal`. It
took a vertical-slice path through commits 1 through 6g
that ended with audible output through the iMac internal
speaker on 2026-05-21. The implementation traversed parts
of F.1, F.2, and F.3 territory without closing any one of
them in the form ADR 0008 / the proposal required.

ADR 0010 (2026-05-27 evening) retired the audit-as-gate
framing. With the gate retired and substantive work
continuing, the question now surfaces: do F.1 and F.2 and
F.3 close based on what was done, or do they require what
the original specs called for? The honest answer is the
second; this ADR records that and the closure criteria the
remaining work must meet.

## What was actually done in commits 1-6g

Verified by inspection of `audiofs/sys/dev/audiofs/audiofs.c`
(3,580 lines as of 2026-05-27 evening) and the file-header
commit summary:

### Controller attachment (commits 1)
PCI class match on PCIC_MULTIMEDIA / PCIS_MULTIMEDIA_HDA.
BAR0 mapping. GCAP read. Controller reset per HDA 1.0a
section 4.3. Verified attaching to both controllers on
pgsd-bare-metal (Intel Sunrise Point HDA at audiofs0; ATI
Oland HDMI at audiofs1).

### Codec command path (commit 2)
DMA-backed CORB and RIRB rings. Codec command dispatch via
CORB. Response read via polling on RIRB. STATESTS-driven
populated-slot enumeration. Vendor / device / revision /
stepping id read per codec.

### Codec topology walk (commits 3, 4a)
Function-group sub-node query. Audio vs modem FG
classification. Subsystem id read. Widget enumeration with
type and audio-widget-cap log. Pin-complex configuration-
default register log. Connection list expansion (range
encoding flattened to `conns[]` arrays).

### Path discovery (commit 4b)
Reverse-walk from each connected output pin to a DAC,
following `conns[0]` at each widget. Paths discovered and
logged.

### Codec state writes (commits 5, 6a)
Pin widget control register: OUT_ENABLE if OUTPUT_CAP,
HPHN_ENABLE if HEADPHONE_CAP. Output amplifier unmute: gain
to OFFSET (0 dB), mute=0, both stereo channels. Read-back
verification on each write.

### DAC format binding (commit 6b)
PCM size/rate cap query. Stream-format cap query. Format
word write via SET_CONV_FMT (48 kHz / 16-bit / PCM).
Read-back verification.

### Stream descriptor setup (commit 6c)
Output stream slot 0 selected. DMA-backed BDL (2 entries).
DMA-backed audio buffer (8 KB, zero-filled). Stream
descriptor reset and configuration: SDnCBL, SDnLVI, SDnFMT,
SDnBDPL, SDnBDPU, SDnCTL2 STRM. RUN bit deliberately not
set yet.

### DAC binding and RUN (commit 6d)
SET_CONV_STREAM_CHAN binds DAC to stream tag. SDCTL RUN bit
set. SDnLPIB sampled at 10 ms intervals to confirm
position advances. RUN cleared at end. Proves DMA path is
live with the zero buffer.

### Audible test signal (commit 6e)
8 KB buffer replaced with 750 Hz sine wave (64 samples per
period at 48 kHz, 32 full periods). Run extended to 290 ms.
With the CS4206's internal speaker enabled, this is the
first audiofs-generated sound on pgsd-bare-metal.

### Platform-policy diagnostic infrastructure (commit 6f)
GPIO inventory query (HDA spec param 0x11). EAPD_CAP query
per pin. Platform-codec adoption for codecs that advertise
GPIO lines. Two RW sysctls: `dev.audiofs.N.gpio_data` (writes
SET_GPIO_DATA verb) and `dev.audiofs.N.play_test_tone`
(re-runs the audible test). Empirical sweep on pgsd-bare-
metal found `gpio_data` bit 3 enables the iMac internal
speaker amplifier.

### Platform-policy table (commit 6g)
(PCI subvendor, PCI subdevice) -> initial gpio_data map.
Single entry: Apple iMac (0x106b, 0x8200, gpio_data=0x08).
On no match, gpio_data stays 0 (safe). With this commit
the iMac's internal speaker produces sound automatically at
module load.

### Read-only diagnostic sysctls (across commits)
`dev.audiofs.N.{eventlog, num_iss, num_oss, num_bss,
support_64bit, pci_vendor, pci_device}`. The `eventlog`
sysctl returns a string of recent in-kernel lifecycle log
lines; it is NOT the F.2 events ring (which is a different
artefact at `/var/run/sema/audio/events` per the proposal
and ADRs 0005 / 0007).

## What was NOT done

By contrast with the formal sub-stage scope statements:

### F.1's `/var/run/sema/audio/state` publication: not done
No state file. The state-file machinery (magic, version,
device inventory in tmpfs-published form) does not exist in
audiofs.c. The closest thing in the current code is the
per-instance `eventlog` sysctl, which is an in-memory ring
of log lines, not a public state file with documented
schema.

### F.1's USB-audio-class start: not the path taken
The proposal scoped F.1's skeleton as "initially USB audio
class only, mirroring inputfs's USB-HID-first start." The
implementation instead targeted PCI HDA (both Intel
Sunrise Point and ATI Oland HDMI controllers on pgsd-bare-
metal). USB audio class is not addressed by audiofs.c.

### F.2's events ring: not done
No events ring at `/var/run/sema/audio/events`. The four
event categories the proposal named (stream begin / stream
end / xrun / format-change) are not produced. The internal
`eventlog` is a diagnostic surface, not the public,
ADR-0007-physics-only events ring.

### F.3's data-path completeness: partial only
The audible test signal proves the controller-to-DAC path
works mechanically end-to-end. It does NOT cover:

  - **Continuous streaming.** The current path runs for
    290 ms then stops. Production needs buffer refill and
    indefinite running.
  - **User-controlled playback.** No ioctl, no /dev node,
    no application-facing API. The test tone is produced
    by attach-time code paths plus a sysctl write to
    re-run the test.
  - **Format negotiation.** Fixed at 48 kHz / 16-bit /
    stereo. No path for a user to request a different
    format or for the substrate to negotiate one.
  - **Underrun detection.** No xrun detection in the
    interrupt path.
  - **Interrupt-driven position tracking.** The 6d/6e/6g
    code polls SDnLPIB rather than handling stream
    interrupts.

### F.3's HDMI bring-up: not done
The ATI Oland HDMI controller attaches and its codec is
enumerated, but no HDMI presence detection runs and no
HDMI stream has been verified to advance LPIB.

### F.4's CLOCK region writing: not done
audiofs is not yet a clock writer. `/var/run/sema/clock`
is still semaaud's responsibility per ADR 0003's pre-
takeover state. ADR 0003 section 5 anticipated semaaud's
clock-writer code path becoming redundant; that has not
happened.

### F.5 and F.6: not started
semasound (userland) does not exist. semaaud is not
retired. AD-2-modelled cutover is future work.

## The vertical-slice path's evidence value

The path taken was not the path ADR 0008 sequenced, but it
was a legitimate path for a different purpose: proving the
controller-to-DAC mechanical achievability end-to-end as
quickly as possible. The audible-output milestone has real
evidence value:

  - audiofs's CORB/RIRB command path actually works against
    two distinct silicon vendors' HDA controllers (Intel and
    AMD/ATI).
  - The codec topology walk and pin-control writes produce
    a working analog-output path on the iMac without
    snd_hda, hdaa, or any pcm-core involvement.
  - The stream descriptor + BDL setup runs DMA that the
    DAC consumes (LPIB advancing).
  - Platform-specific quirks (the Apple GPIO bit 3 finding)
    can be discovered empirically via in-kernel sysctls and
    codified in a data table without becoming
    vendor-quirk code in the substrate.

This is the substrate evidence-stream that ADR 0006's
governance-independence argument anticipated and that ADR
0010 named as the substituted evidence-gathering mode after
retiring the audit-as-gate. The vertical-slice path delivered
exactly that evidence. What it did not deliver is the
formal F.1, F.2, F.3 closures, because those closures are
defined in terms of public-interface artefacts (the state
file, the events ring, the user-control surface) that the
vertical slice did not produce.

This is consistent with how UTF normally operates: a
vertical slice proves the path is mechanically possible
first; the public-interface plumbing follows. The
reconciliation is honest about that ordering and does not
retrofit it as the originally-planned order.

## Decision

The F.1, F.2, and F.3 closure criteria are reframed as
follows. The reframing does not soften the substantive
requirements; it makes the closure criteria reflect what
is and is not actually present in audiofs.c and what
remains owed.

### F.1 reframed closure criteria

F.1 closes when:

  1. The state-file machinery exists at
     `/var/run/sema/audio/state`. Magic, version, and a
     documented schema per ADR 0007's physics-only
     constraint.
  2. The schema includes the device inventory in a form
     that lets a reader (semasound or its precursor)
     enumerate what audiofs has attached.
  3. MOD_LOAD writes the state file; MOD_UNLOAD removes it
     or marks it invalid; reattachment is clean.
  4. At least one controller is enumerated in the file
     (this criterion is already satisfied by the existing
     attachment to both pgsd-bare-metal controllers; the
     gap is the file, not the attachment).

The proposal's "USB audio class only" framing of F.1 is
retired. F.1 now closes on PCI HDA evidence (which is
already present); USB audio class is folded into F.3 (data
path) where USB-audio-specific stream handling belongs
anyway. This is consistent with the vertical-slice path
actually taken.

### F.2 reframed closure criteria

F.2 closes when:

  1. The events ring exists at
     `/var/run/sema/audio/events`. Schema and concurrency
     model per ADR 0005's events surface and ADR 0007's
     physics-only constraint.
  2. The four event categories from the proposal are
     emitted by audiofs: stream begin, stream end, xrun,
     format-change.
  3. A reader (initially `audiodump` or equivalent
     diagnostic tool, later semasound) can observe events
     with monotonic sequence numbers and physics-level
     payloads (no policy-flavoured semantics).

The existing internal `eventlog` sysctl remains as a
diagnostic surface but is NOT the F.2 events ring. The
distinction is preserved.

### F.3 reframed closure criteria

F.3 is decomposed into named milestones, each of which
gets its own ADR before its implementation:

  - **F.3.a Continuous streaming.** Buffer refill loop;
    indefinite running; stream lifecycle cleanly tied to
    explicit start/stop control. No user-API yet.
  - **F.3.b User-controlled playback.** ioctl or /dev node
    or other application-facing surface (the choice is
    F.3.b's own ADR work; ADR 0005 implies a control-socket
    architecture in semasound, so audiofs's surface here
    needs to fit cleanly under that).
  - **F.3.c Interrupt-driven position tracking.** Replace
    LPIB polling with stream interrupt handler. Position
    updates flow into the events ring (F.2) and the clock
    region (F.4).
  - **F.3.d Underrun detection and reporting.** xrun
    detection in the interrupt path; xrun events emitted
    on the F.2 events ring with physics-level payload.
  - **F.3.e Format negotiation.** Format query at attach
    time per DAC; format negotiation through the
    user-control surface (F.3.b). Native-format-only in
    the kernel per ADR 0007.
  - **F.3.f HDMI bring-up.** Presence detection, HDMI
    audio infoframes, HDMI stream verification.

F.3 closes when all six sub-milestones close. Each
sub-milestone's ADR scopes its specific work; this ADR
names them and gives the closure ordering rule.

### Closure dependency map

  - F.1 has no F-stage dependency. It can be done now.
  - F.2 depends on F.1 (the state file needs to exist
    before events that reference state are meaningful).
  - F.3.a depends on F.2 (continuous streaming should emit
    begin/end events).
  - F.3.b depends on F.3.a (user control needs a
    continuous stream to control).
  - F.3.c depends on F.2 (interrupts need a place to report
    state to).
  - F.3.d depends on F.3.c (xrun detection needs the
    interrupt path).
  - F.3.e depends on F.3.b (format negotiation needs the
    user surface to negotiate through).
  - F.3.f is parallel to F.3.a-e; can be done at any time
    after F.1 closes.
  - F.4 depends on F.3.c (interrupt-driven position
    feeds the clock writer).
  - F.5 depends on F.4 (semasound mixes against an
    audiofs-written clock).
  - F.6 depends on F.5 (semaaud retires once semasound is
    verified end-to-end).

## What changes for the BACKLOG AD-3 status

The AD-3 status string (post-ADR-0010) lists three
outstanding items: F.5 semasound, F.6 semaaud retirement,
maintenance model. After this ADR, the list is more
honest:

  - F.1 (state-file publication)
  - F.2 (events ring)
  - F.3 sub-milestones a-f
  - F.4 (CLOCK region writing)
  - F.5 (semasound)
  - F.6 (semaaud retirement)
  - Maintenance model

The status string update is a separate edit (companion to
this ADR) to keep BACKLOG truthful about what is owed.

## Relationship to ADR 0006

ADR 0006's decision to replace snd(4) stands. Its rationale
is principled, not measurement-contingent, per ADR 0006
lines 50-54. The reconciliation in this ADR does not affect
ADR 0006's standing; it records what implementation
progress has and has not been made toward executing ADR
0006's decision.

## Relationship to ADR 0008

ADR 0008's overall structure stands. The F-stage breakdown,
the gate-retirement (per ADR 0010), the maintenance-model
owed input, the chipset list owed input, all retained.
What this ADR supersedes is one specific aspect of ADR
0008: the F.1, F.2, F.3 closure criteria as written.
Those are reframed in this ADR's Decision section. ADR
0008 itself is not edited (forward-only ADR discipline);
this ADR records the supersession of those specific
criteria.

ADR 0008 line 363 anticipated F.3's internal decomposition
needing its own ADR. This ADR provides that decomposition
(F.3.a through F.3.f), though it is not the F.3 ADR
proper; each sub-milestone still needs its own ADR before
implementation. This ADR names the milestones; it does not
scope their internals.

## Relationship to ADR 0010

ADR 0010 retired the audit-as-gate framing. This ADR
operates under the post-0010 regime: F.3+ progression
proceeds under standard ADR-before-code discipline without
audit clearance. What this ADR adds is structure for that
progression: the F.3 internal decomposition (F.3.a-f) gives
the next several ADRs concrete sub-stages to scope.

## Relationship to ADR 0009

ADR 0009 was the F.0 closure reconciliation: it reconciled
the bookkeeping contradiction between ADR 0001's stated
F.0 closure criterion and ADR 0008's assertion that F.0
was complete. ADR 0011 is structurally similar but at the
F.1/F.2/F.3 boundary: a vertical-slice path was taken that
does not match the formal closure criteria, and the
reframing acknowledges what was done and what is still
owed. Same discipline (do not edit prior ADRs; record the
supersession; reframe closure criteria honestly); different
boundary.

## Consequences

### What this enables

  - **F.1 work has a concrete scope.** The next ADR can
    pick up F.1 and write its closure-criteria-bound work.
    Probably small: define the state-file schema (per ADR
    0007), write the publish/unpublish code, smoke-test.
  - **F.2 has a sequenced position.** F.2 follows F.1, can
    start as soon as F.1 closes.
  - **F.3 is no longer a monolith.** Six named sub-
    milestones with a dependency map mean F.3 work can
    proceed in tractable steps rather than as one large
    undefined chunk.
  - **The BACKLOG entry becomes more honest.** Replacing
    the three-item list with the seven-item list reflects
    what is actually owed without softening the substantive
    requirements.

### What this commits

  - **Per-sub-milestone ADR discipline.** F.1, F.2, F.3.a
    through F.3.f, F.4, F.5, F.6 each need their own ADR
    before implementation. The discipline is not waived for
    smaller sub-milestones; it scales to them.
  - **The state file and events ring as defined artefacts.**
    `/var/run/sema/audio/state` and
    `/var/run/sema/audio/events` are committed names with
    documented schemas (to be specified in the F.1 and F.2
    ADRs). They are not optional.
  - **No retroactive closure claims.** F.1 is not closed
    today. F.2 is not closed today. F.3 is partially
    implemented but no sub-milestone is closed in the form
    this ADR requires. The reconciliation does not retrofit
    the vertical slice into formal closures.

### What this does not address

  - **The specific schema of the state file or the events
    ring.** Those are the F.1 and F.2 ADRs' work
    respectively. This ADR names the artefacts; it does
    not design them.
  - **The user-control surface choice for F.3.b.** Whether
    ioctl, /dev node, or a different mechanism, is for the
    F.3.b ADR.
  - **The maintenance model.** Still owed per ADR 0008.
    Unaffected by this reconciliation.
  - **The chipset list final discharge.** Still owed per
    AD-3's 2026-05-17 status update. Unaffected.

## What this document is not

  - Not a claim that the vertical-slice path was wrong. The
    path produced legitimate substrate evidence; the
    audible-output milestone is real. The reconciliation
    records that the path was different from ADR 0008's
    sequencing, not that the path should not have been
    taken.
  - Not a retroactive ADR for commits 1-6g. Those commits
    had their own justifications (recorded in their commit
    messages and in the AD-3 2026-05-20 status update).
    This ADR is forward-looking: it sets up the next
    several ADRs and the closure criteria they need to
    meet.
  - Not a softening of the F.1, F.2, F.3 substantive
    requirements. The state file, the events ring, the
    full data path with user control and clock writing
    are all still owed. The reframing makes the closure
    criteria reflect what is actually in audiofs.c today
    plus what is missing; it does not claim that what is
    missing has been done.
  - Not an F-stage map rewrite. ADR 0008's overall map
    stands. What changes is F.1/F.2/F.3 closure criteria
    plus the F.3 internal decomposition. F.4, F.5, F.6,
    F.7 are unchanged.
  - Not a replacement for the per-sub-milestone ADRs that
    follow. Each of F.1, F.2, F.3.a through F.3.f, F.4
    still needs its own ADR before implementation. This
    ADR names them and orders them; the ADR-per-substage
    discipline continues.
