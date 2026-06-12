# inputdump

`inputdump` reads and prints the inputfs publication regions: the
materialised state region at `/var/run/sema/input/state`, and the
event ring at `/var/run/sema/input/events`. It is the canonical
diagnostic tool for the inputfs kernel module.

## Synopsis

```
inputdump <subcommand> [options]
```

Subcommands:

- `state` print the materialised state region (one-shot or watch).
- `events` drain and print the event ring.
- `watch` live tail of state and events together.
- `devices` print only the device inventory.

Run `inputdump --help` for top-level usage, or `inputdump
<subcommand> --help` for the full option list of a subcommand.

## Common options

These are accepted by every subcommand:

- `--json` emit JSON instead of human-readable text.
- `--verbose` multi-line per record with field names.
- `--help`, `-h` print help.

## state

Print one snapshot of the state region:

```
inputdump state
```

Watch for changes:

```
inputdump state --watch
inputdump state --watch --interval-ms 100
```

By default only populated device slots are shown. Add `--all-slots`
to include empty slots (useful when verifying that `state_valid` and
the bitmap agree about which slots are in use).

## events

Drain everything currently in the ring:

```
inputdump events
```

Stream live:

```
inputdump events --watch
```

Resume from a known sequence (useful for test harnesses that capture
a known event window):

```
inputdump events --from-seq 100
```

If the requested sequence has already been overwritten, the next
drain reports a ring overrun and resynchronises to the earliest
available sequence.

### Filters

Filter by source role:

```
inputdump events --role pointer
inputdump events --role lifecycle
```

Filter by device slot:

```
inputdump events --device 3
```

Filter by event type within a role (requires `--role`):

```
inputdump events --role pointer --event motion
inputdump events --role pointer --event button_down
inputdump events --role lifecycle --event attach
```

Filters compose; an event is printed only if every active filter
accepts it.

### Statistics

`--stats` prints aggregate counters: total events, ring overruns,
elapsed time, average rate, breakdown by role and device slot. With
`--watch`, stats are reprinted every five seconds.

```
inputdump events --stats
inputdump events --watch --stats
```

## watch

Live tail of state and events together:

```
inputdump watch
```

State changes are reported as compact `[state]` summary lines
interleaved with the event stream. Existing event backlog is
skipped: the tool starts at the current `writer_seq`, so output
shows what happens from the moment `inputdump watch` started.

The events portion accepts the same `--role`, `--device`, `--event`
filters as `inputdump events`.

## devices

Print only the device inventory from the state region:

```
inputdump devices
```

Equivalent to `inputdump state` with everything except the device
list filtered out. Useful for shell pipelines: `inputdump devices
--json | jq '.devices[] | select(.roles == 1)'` lists every pointer
device.

## JSON output

All four subcommands accept `--json`. The schema is:

- `state` and `devices` emit one JSON object covering the snapshot.
- `events` emits one JSON object per line, suitable for streaming
  consumers (`jq`, log ingestion, etc.).
- `watch` interleaves state objects and event objects as they
  arrive.

Field names mirror the human-readable output. Numeric values are
emitted as JSON numbers (no quoting). Strings are escaped per
RFC 8259.

## Exit codes

- 0 normal exit.
- 1 publication region is invalid (file absent, wrong magic or
  version, or `valid` byte clear).
- 2 argument parsing error.

## See also

- `shared/INPUT_STATE.md` byte layout of the state region.
- `shared/INPUT_EVENTS.md` byte layout of the event ring and the
  per-slot seq protocol.
- `inputfs/docs/adr/0002-shared-memory-regions.md` design decision
  for the shared-memory regions.
