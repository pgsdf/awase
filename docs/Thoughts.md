# Chronofs: A Temporal Substrate for Multimodal Systems

## Core Insight

The real problem is not threading or concurrency.

It is **time coherence across modalities**.

What this system introduces is a **shared temporal semantics layer**—a unifying abstraction that aligns audio, visual, and input domains under a single notion of time.

> A **time-aware semantic substrate spanning audio, visual, and interaction domains**

---

## Naming Alignment: drawfs / semadraw / chronofs

To stay consistent with your existing system:

- **drawfs** → spatial substrate  
- **chronofs** → temporal substrate  
- **semadraw** → semantic rendering layer  

This creates a clean, orthogonal architecture:

| Layer     | Responsibility            |
|----------|---------------------------|
| drawfs   | Spatial organization      |
| chronofs | Temporal coordination     |
| semadraw | Semantic interpretation   |

---

## Why `chronofs`

`chronofs` implies:

- Time as a **first-class, addressable medium**
- Filesystem-like semantics applied to time
- Ordered, queryable, append-only structures

> Not just *when things happen* — but **time as something you can read, write, and resolve against**

---

## Architectural Model

### Core Principle

> Everything is scheduled, resolved, and observed against a **global monotonic timeline**

Instead of imperative actions:

- “play audio”
- “render frame”
- “handle input”

The system operates as:

- **Commit events into time**
- **Resolve state at time `t`**

---

## Core Primitives

### 1. Clock

A single global source of truth:

```

t ∈ ℝ  (monotonic, high-resolution)

```

- Driven by audio hardware (in practice)
- Never rewinds
- Universally accessible

---

### 2. Timeline Events

All activity becomes time-indexed:

```

Event {
time: t
domain: audio | visual | input
payload: …
}

```

Examples:

- Audio sample block
- Draw command
- Input event (mouse, keyboard)

---

### 3. Streams

Domain-specific, but unified by time:

```

/chronofs/audio/stream
/chronofs/visual/stream
/chronofs/input/stream

```

Each stream is:

- Append-only  
- Time-ordered  
- Queryable at arbitrary `t`  

---

### 4. State Resolution

The defining abstraction:

```

State(t) = resolve(all events ≤ t)

````

Implications:

- Rendering = evaluate visual state at `t`
- Audio = sample signal at `t`
- Input = query latest events ≤ `t`

> Eliminates ordering ambiguity between subsystems

---

## Coordination Model

No thread races. No implicit ordering.

Everything aligns to **time windows**:

- Audio: requests samples for `[t, t + Δ]`
- Renderer: queries world state at `t`
- Input: writes timestamped events at `tₑ`

---

## Drift Handling (First-Class, Not a Hack)

### Policy: Audio as Source of Truth

- Clock is driven by audio hardware
- Other domains adapt

### Graphics Strategy

- Frame interpolation
- Frame skipping
- Time snapping

### Input Strategy

- Timestamped events
- No "immediate" ambiguity

---

### Optional: Dynamic Resampling

```text
audio_out = resample(audio_in, clock_delta)
````

* Smooth corrections
* No discontinuities
* Proven pattern (e.g., emulators)

---

## API Surface

Minimal and composable:

```text
chronofs.now() -> t

chronofs.write(stream, event)
chronofs.read(stream, t_range)

chronofs.resolve(domain, t) -> state
```

Filesystem-style interface:

```text
/chronofs/clock
/chronofs/audio/…
/chronofs/visual/…
/chronofs/input/…
```

---

## Integration with semadraw

This is where the model becomes powerful.

```text
t = chronofs.now()
frame = semadraw.resolve(scene, t)
```

Rendering becomes:

> Not “latest state”
> But **state at time `t`**

This enables:

* Deterministic rendering
* Precise synchronization
* Temporal querying of visuals

---

## Architectural Shift

Traditional systems:

* Treat time as implicit
* Synchronize after the fact
* Fight drift and ordering bugs

This system:

* Makes time **explicit and first-class**
* Forces all subsystems to align to it
* Encodes synchronization into the model itself

---

## Conceptual Model

> All modalities are projections of a shared, time-indexed state.

This aligns closely with **synchronous dataflow systems**, adapted for real-time media.

---

## Next Steps

### 1. Minimal Implementation Sketch

* Global monotonic clock (audio-driven)
* Lock-free append-only buffers per stream
* Time-windowed reads
* Deterministic resolver

### 2. Systems Integration

Map to real APIs:

* Audio: low-latency callback (e.g., CoreAudio / ALSA)
* Graphics: GPU frame pipeline
* Input: event capture with high-resolution timestamps

### 3. Validation Goals

* No drift between audio and visuals
* Deterministic replay from event logs
* Stable behavior under load

---

## Final Framing

* **drawfs** → space
* **chronofs** → time
* **semadraw** → meaning

Together:

> A system where **space, time, and semantics are composable substrates**


