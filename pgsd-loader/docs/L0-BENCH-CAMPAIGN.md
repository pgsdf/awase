# L0 bench campaign: presence and chainload

Closure evidence for ADR 0003 (ratified rev 2), gathered on
bare-metal-test-bench. The record for each criterion stays open
until the operator judges it boring; no criterion closes on an
arbitrary count. The operator appends entries; observations and
dispositions are recorded explicitly rather than left implicit
in the logs.

Deployment state at campaign start: pgsd-loader.efi published to
EFI/pgsd/ on gpt/efiboot0 (reused fstab mount at /boot/efi);
Boot0003 PGSD primary, Boot0002 PGSD-fallback (stock loader.efi,
untouched); boot order 0003, 0002 with pre-existing entries
retained behind. Two pre-existing entries noted at deploy time,
left alone per L0 scope: Boot0000 FreeBSD (duplicate path to the
stock loader; harmless, a third recovery route) and Boot0001
"Awase fallback (stock loader)" referencing partition GUID
72d0af4a... which does not match the current ESP; apparently
stale from the deploy-loader.sh era. Disposition, 2026-07-07:
operator removed Boot0001 (efibootmgr -B), which also dropped it
from BootOrder; verified clean afterward (0003, 0002, 0000,
0080, no dangling tokens). Boot0000 retained deliberately as a
third route to the stock loader.

## Criterion 3: cold boots, indistinguishable operation

### Cold boot #1, 2026-07-07

BootCurrent: 0003, the objective proof the boot ran through
pgsd-loader. dmesg establishes: inputfs devices attached and
registered; audiofs0 full attach walk on the CS4206 clean,
including the D0 power-up sequence (events 88 through 92) and
the GPIO platform policy match (Apple iMac CS4206 speaker amp
enable, gpio_data=0x08); state, events, and clock surfaces
opened; output stream configured and RUN set; cdev_open
following, consistent with the broker admitting the chime
client.

The remaining observation for cold boot #1 is whether the boot
chime was audible. The logs establish the attach sequence, D0
transition, GPIO programming, and stream startup, but they
cannot attest to audibility, so that observation is recorded
explicitly: REPORTED, chime audible, level acceptable at the
0.15 gain (first ride of the ADR 0032 chime through the new boot
path).

### Boot, 2026-07-07 22:38 (warm reboot)

BootCurrent: 0003 after the criterion 6 close: the healed boot
order (F5) boots through pgsd-loader correctly. Warm reboot, so
recorded as supporting evidence rather than a cold-boot count
entry; chime observation not reported for this boot.

### Cold boots via fallback, drills 1 through 3, 2026-07-07

Three cold boots, each landing on BootCurrent 0002 by design
(criterion 4 drills, cross-recorded here per the ledger's rule:
each demonstrates the fallback path remains healthy). Chime
observations not reported for these boots. Note the chime plays
on fallback boots too, the rc.d anchor being loader-independent,
so future drill entries should record it.

### Subsequent cold boots

(append: date, BootCurrent, chime audible yes/no, anomalies;
primary entry is Boot0001 as of the drill 1 restore)

## Criterion 4: recovery, three ways

The recovery drills naturally interleave with the remaining cold
boots. A corrupted-loader boot that falls through to Boot0002 is
both a criterion 4 validation and another successful cold boot
demonstrating that the fallback path remains healthy; entries
here should be cross-recorded above when they are.

1. Entry removed: PASSED 2026-07-07. Boot0003 deleted, cold
   boot landed on BootCurrent 0002 with no pgsd-loader banner
   (firmware never invoked it, entry absent). Restore recreated
   the primary as Boot0001, firmware reusing the slot freed by
   the stale-entry removal: the entry-renumber case exercised
   and handled by the F3 parser and order logic without
   incident. Incidental: zig-out was absent at restore, build.sh
   regenerated it, and the canonical pinned binary is deployed
   from this point (see provenance note below).
2. Binary corrupted in place: PASSED 2026-07-07. Four bytes over
   the PE header; cold boot fell through to BootCurrent 0002.
   Firmware behavior observed: silent and fast, messages too
   quick to read, no dwell on the rejected image. As predicted
   for this variant, no pgsd-loader failure report appears,
   since the firmware's own LoadImage rejects the image before
   any loader code runs; the loader's own report path is covered
   by qemu-smoke pass 2. Restore published over the corrupted
   file, provenance log capturing its hash as replaced.
3. Binary deleted: fall-through VALIDATED 2026-07-07 (cold boot
   to BootCurrent 0002 with the entry dangling); restore deploy
   ran clean (published, entry present, order begins 0001) but
   the confirming cold boot LANDED ON 0002, opening finding F7.
   Drill 3 does not close until a boot reaches the primary.

Provenance note, first field outing of the deploy log: three
hashes told the whole story. 1287401e... was the pre-pin binary
(wall-clock PE stamps, built before SOURCE_DATE_EPOCH; its
difference from the canonical build is expected and now
explained). 38d9c6c8... is the canonical pinned hash for the
current loader source, published identically in both restores.
b2232083... is the corrupted file drill 2 replaced. The F4
instrumentation answering exactly the question operator recall
could not.

Observability note: at this firmware's boot speed, console
output including the healthy-boot banner is effectively
unreadable in real time. Recorded as an observation only; any
banner dwell is a behavior change gated on ADR revision.

## Criterion 5: load-option forwarding

Set an option string on the PGSD entry; confirm loader.efi
receives it intact.

Method finding, 2026-07-07: FreeBSD 15.1's efibootmgr has no
flag to set load options on an entry (usage verified on the
bench), so the criterion as written assumes a capability the OS
tooling does not provide. Evidence obtained instead: an
emulation-only launcher harness (never deployed) starts
pgsd-loader with the option string "pgsd-opt-test alpha beta",
standing in for a firmware entry carrying options; pgsd-loader
forwards; the chainload target echoes the string intact
(qemu-smoke pass 3, all checks green). The forwarding code path
is thereby verified end to end on real UEFI firmware code.
OPERATOR TO RULE: whether this evidence satisfies the criterion,
or the criterion is amended by ratified ADR revision to name the
end-to-end emulation verification as its method. PENDING that
ruling.

## Criterion 6: deploy idempotence

Two consecutive deploys; the second reports unchanged/present
throughout and no-op.

First attempt, 2026-07-07: FAILED, and productively (finding F3).

Second attempt, 2026-07-07, after the F3 fix: pair behavior
CORRECT (run one published and reported present entries, run two
reported unchanged/present throughout and no-op), but the state
was not fully healed, exposing F5: BootOrder still carried the
dangling 000B tokens twice because the order check compared only
a prefix. The duplicate entry itself was already gone (deleted by
an unknown actor, shown as MISSING; our reap printed nothing).
Run one also republished a binary expected unchanged, a second F4
data point (mechanism later proven and closed under F4).

Third attempt, 2026-07-07, after the F5 fix: CLOSED. Run one
healed the order tail exactly as specified (boot order set:
0003,0002,0000,0001,0080, was: with 000B twice), binary
unchanged; run two the true no-op. efibootmgr -v confirms fully
clean state: no MISSING references, single PGSD, single
PGSD-fallback, expected order. The attempt also bench-confirmed
two fixes previously verified only against captured output: the
F3 parser handled the live +Boot0002 decoration, and F5's
self-healing worked on real firmware first try.

CRITERION 6: CLOSED, 2026-07-07, third attempt, with findings
F3, F4, and F5 produced along the way.

## Criteria 1 and 2

1. Reproducible build via the vendored toolchain: DEMONSTRATED
   at the byte level, 2026-07-07, after the F4 investigation:
   with SOURCE_DATE_EPOCH pinned (build.sh, the canonical build
   path), two clean-cache builds hash identically. Without the
   pin, clean-cache builds differ in exactly two bytes, the PE
   COFF TimeDateStamp and its debug-directory duplicate; the
   code itself was deterministic throughout.
2. Deploy creates both entries, fallback verified before primary
   activation: DEMONSTRATED (first successful deploy,
   2026-07-07; two earlier deploy aborts were clean and
   untouched, see findings).

## Findings

### F1: deployment lessons (closed, fixes landed)

Two deploy aborts preceded the first success, both clean and
complete before any boot-order change, so the fallback-first
ordering earned its first field record before the loader ever
ran. Lesson one: the ESP may already be mounted (fstab at
/boot/efi); deploy must reuse the existing mount. Lesson two:
the mounted provider may be a GEOM alias (gpt/efiboot0) of the
partition gpart names (ada0p1), and GEOM withers the other
aliases while one is open; identity of a partition is not
identity of its name. Both fixes landed same day.

### F3: deploy entry parser corrupted by efibootmgr decorations (closed, fix landed)

Criterion 6's first attempt exposed a parser defect with
compounding damage. After booting through PGSD, efibootmgr
decorates the current/next entry with a leading plus
(+Boot0003*); the parser stripped the trailing star but not the
plus, returned the malformed token Boot+Boot0003, and fed it to
-a -b and -o. The corrupted lookup then made the next run
conclude the entry was absent, creating a duplicate (Boot000B),
and the boot-order filter compared tokens as regular expressions,
letting both the malformed token and repeated entries through.
Bench state after three runs: duplicate PGSD entry, 000B twice in
BootOrder. Fix: positional extraction of the 4-hex-digit number
with exact label comparison (decorations and alignment spaces
stripped), literal index() membership in the order filter with
de-duplication, and reap_duplicates so the fixed deploy
self-heals the damage its predecessor made. Parser verified
against the exact corrupted bench output, all five label cases.
Lesson, same family as F1's: field-position string surgery on
tool output is identity-fragile; extract positionally, compare
exactly.

### F5: order healing compared a prefix, not the whole order (closed, fix landed)

The second criterion 6 attempt left BootOrder as
0003,0002,000B,000B,... with both 000B tokens dangling (entry
deleted, references remaining, efibootmgr -v shows MISSING). The
order check passed because the order began with the desired
prefix, so the corrupt tail was never rewritten. Fix: compute the
full desired order (our entries, then every other existing entry
in current relative order, dangling tokens dropped, repeats
de-duplicated) and compare whole strings, rewriting on any
difference. Verified against the exact bench order, dropping both
000B tokens while preserving the tail. Lesson, completing the F3
family: healing that validates a prefix owns only a prefix; own
the whole invariant or none of it.

### F6: boot through the fallback (closed: UNRESOLVED, timeline confirmed, cause unproven)

BootCurrent: 0002 at the second criterion 6 attempt: the most
recent boot ran through PGSD-fallback with Boot0003 present and
the binary in place. Either the operator rebooted deliberately,
or pgsd-loader failed and fell through by design. If the latter,
a plausible chain ties F4 and F6 together: the root-owned-cache
incident left a stale or partial zig-out binary, the earlier
deploy published it, that boot fell through to 0002 (the fallback
invariant's first unplanned field save), and the next deploy
replaced it with a good rebuild. Operator to confirm: was a
reboot performed since the failed attempt, was the pgsd-loader
failure report observed on console, and did any build run between
deploys. Operator recall could not resolve
this ("I don't recall"), so F6 stays open on forensics instead:
last reboot and uptime establish whether and when a boot
occurred between the attempts; whether pgsd-loader printed a
failure report on that boot is unrecoverable (pre-kernel console
output persists nowhere). If the timeline confirms a boot in the
window, the fall-through hypothesis stands as plausible but
unproven, and F6 closes as UNRESOLVED with both hypotheses
recorded rather than a cause claimed. Prevention: deploy logging
(F4 fix) timestamps every publish, narrowing future windows; a
loader-written boot-evidence UEFI variable would answer the
"did pgsd-loader run" question directly but is a behavior change
under the ADR 0003 authority statement, recorded here as a
deferred proposal for the operator, not implemented.

Closure, 2026-07-07: forensics confirmed five boots on the bench
day (21:40, 21:45, 22:25, 22:35, 22:38), establishing that boots
occurred in the window; the cause of the boot that landed on
Boot0002 is not determinable (pre-kernel console output persists
nowhere, and the binary that was installed at the time was
replaced). Closed UNRESOLVED per the ledger's own rule: both
hypotheses stand recorded, deliberate reboot or the fallback
invariant's first unplanned field save, and no cause is claimed.

### F4: unexplained republishes (closed: mechanism proven, timeline unrecoverable)

Runs reported "published" for binaries expected unchanged, twice
across the criterion 6 attempts. Operator recall could not
establish which builds ran between deploys, so the finding was
closed by experiment instead: warm-cache rebuilds are
byte-identical, clean-cache rebuilds differ in exactly two bytes
(PE COFF TimeDateStamp at file offset 128 and its
debug-directory duplicate), and pinning SOURCE_DATE_EPOCH makes
clean-cache builds byte-identical (two wiped-cache builds, same
sha256). The bench sequence is consistent with the root-cache
cleanup forcing a cold rebuild whose fresh timestamps made cmp
legitimately differ; the exact bench build timeline is
unrecoverable and is not claimed. Fixes: build.sh is the
canonical byte-reproducible build path (qemu-smoke routes
through it), and deploy.sh now appends every run to
/var/log/pgsd-deploy.log with the binary sha256 and per-member
action, so binary provenance is answerable from the machine
record rather than from memory. Lesson: operator recall is not
an evidence source; instrument so the question answers itself.

### F7: post-restore boots do not reach the primary (OPEN, under diagnosis)

The campaign's first genuine anomaly. After drill 3's restore,
with the binary published (verified output of deploy), Boot0001
pointing at it, and the order beginning 0001, a cold boot landed
on BootCurrent 0002: firmware tried or skipped the primary and
fell through. Confounded pair: during drill 1's restore, the
deployed binary became the SOURCE_DATE_EPOCH pinned build AND
the entry was recreated as Boot0001 in the same operation, and
no boot has reached the primary since; the pinned binary
(38d9c6c8...) has never successfully booted, every prior success
having run the pre-pin binary. Candidate causes, none asserted:
firmware rejection of the pinned image (a zero PE TimeDateStamp
offending this Apple EFI); firmware treatment of a recreated
boot entry during order processing (Apple EFI is nonstandard
about boot variables); or an unidentified third change in the
window. Diagnosis plan, cheapest first: (1) hash the installed
file against zig-out and the deploy log; (2) BootNext -n -b 0001
to force one-shot selection, isolating entry processing from
image rejection; (3) if the image is implicated, boot an
unpinned wall-clock build to test the stamp as the variable,
with the reproducibility mechanism adjustable to a fixed nonzero
epoch if zero is the offender. Criterion 4 drill 3 and the
criterion 3 count are blocked on this finding's disposition.

### F2: audiofs path_dead_end repetition (closed: disposed to BACKLOG as AD-60)

Not a loader finding; the first non-loader observation of the
campaign, present before L0 and surfaced by reading the cold
boot dmesg closely. The path_dead_end events for nids
0xc/0xd/0xe/0xf/0x12 repeat in identical groups of five at
roughly 21 ms intervals well after attach completes (12.398,
12.419, 12.441, 12.462, ...), a cadence suggesting something in
the running stream path re-walks codec topology and re-emits the
same findings every cycle, which would flood the events ring
with duplicates. Operator disposition, 2026-07-07: BACKLOG entry.
Recorded as AD-60 with the cadence evidence and the
investigation questions; closed here.
