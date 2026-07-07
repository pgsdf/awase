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
stale from the deploy-loader.sh era. Disposition of the stale
entry is deferred, recorded here so it is decided rather than
forgotten.

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
explicitly: PENDING operator report (first ride of the ADR 0032
chime through the new boot path, at the 0.15 gain).

### Subsequent cold boots

(append: date, BootCurrent, chime audible yes/no, anomalies)

## Criterion 4: recovery, three ways

The recovery drills naturally interleave with the remaining cold
boots. A corrupted-loader boot that falls through to Boot0002 is
both a criterion 4 validation and another successful cold boot
demonstrating that the fallback path remains healthy; entries
here should be cross-recorded above when they are.

1. Entry removed (efibootmgr -B -b 0003; boot; expect
   BootCurrent 0002; re-deploy): PENDING
2. Binary corrupted in place (boot; expect the LoadImage failure
   report on console, three second stall, fall-through;
   re-deploy): PENDING
3. Binary deleted (boot; expect fall-through; re-deploy):
   PENDING

## Criterion 5: load-option forwarding

Set an option string on the PGSD entry; confirm loader.efi
receives it intact. PENDING

## Criterion 6: deploy idempotence

Two consecutive deploys; the second reports unchanged/present
throughout and no-op.

First attempt, 2026-07-07: FAILED, and productively (finding F3).
Re-run PENDING after the F3 fix, expected shape: run one reaps
the duplicate Boot000B entries and normalizes the boot order
(changed); run two is the true no-op that closes the criterion.
One unexplained observation from the failed attempt is held open
in F4.

## Criteria 1 and 2

1. Reproducible build via the vendored toolchain: DEMONSTRATED
   (qemu-smoke builds on the bench host, 2026-07-07).
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

### F4: unexplained republish on deploy run three (open)

Run three of the failed criterion 6 attempt reported "published"
for a binary runs one and two had reported "unchanged", with no
known rebuild in between. Hypothesis: a zig build (for example
via qemu-smoke) between runs producing a byte-different .efi
through PE header variance, which would make cmp legitimately
differ. Operator to confirm whether any build ran between the
deploys; if none did, this needs investigation before criterion 6
closes, since content-addressed publication is the mechanism
idempotence rests on.

### F2: audiofs path_dead_end repetition (open, disposition pending)

Not a loader finding; the first non-loader observation of the
campaign, present before L0 and surfaced by reading the cold
boot dmesg closely. The path_dead_end events for nids
0xc/0xd/0xe/0xf/0x12 repeat in identical groups of five at
roughly 21 ms intervals well after attach completes (12.398,
12.419, 12.441, 12.462, ...), a cadence suggesting something in
the running stream path re-walks codec topology and re-emits the
same findings every cycle, which would flood the events ring
with duplicates. Even if this is expected audiofs behavior it
deserves explicit disposition rather than disappearing into the
logs. Operator to rule: known behavior, or BACKLOG entry.
