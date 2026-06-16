# Survey: pgsd-sessiond P3 filesystem tranche

Status: Proposed, pending operator ratification.
Basis: real Zig 0.16.0, site classification by enclosing function, and the
std.Io.Dir surface. Reconciled against ADR shared 0001 (compat.io / compat.fs).
Scope: the 14 std.fs.cwd / std.fs.File sites left after Tranche 1, plus the
compat.fs growth they require.

## 1. The routing question is largely pre-settled by ADR shared 0001

Two ratified decisions remove most of the per-site debate:

- Decision 2 (Option B): Awase tools construct a local blocking std.Io from
  their own allocator through `compat.io`
  (`var io_ctx = try compat.io.open(gpa); const io = io_ctx.io();`). The io
  handle is a solved problem, not a new decision.
- Decision 3: filesystem helpers live ONLY in compat.fs, explicitly so the tree
  does not grow a second filesystem layer. compat.io "deliberately exposes no
  filesystem helpers."

Consequence: directory operations must be added to compat.fs. Routing the dir
ops through raw posix (mkdir/rmdir) or through std.Io at the call sites would
violate Decision 3. So P3 is not a per-site routing choice; it is (a) a bounded
compat.fs growth and (b) one open decision about how io reaches the call sites.

## 2. Site inventory (14 sites, three classes)

```
class            file:line                 op                 compat.fs status
read (prod)      attribute_file:148        readFileAlloc      openFile+readToEndAlloc exist; convenience TBD
read (prod)      session_file:355          openFile+stat      openFile exists; File.stat() missing
traversal (prod) session_file:391          openDir(.iterate)  MISSING (openDir + iterate)
test scaffold    session_file:698,712,     makeDir            MISSING (-> std.Io createDir)
                 753,786,817 (x5)
test scaffold    session_file:702,716,     deleteTree         MISSING
                 757,790,821 (x5)
test scaffold    session_file:836          openDir            MISSING (same as traversal)
```

attribute_file:148, session_file:355/391 are production (loadFromDir,
lookupByIdFrom, enumerateFrom); all carry an allocator already. The remaining
ten are test-block scaffolding (tmp-dir create/clean).

## 3. compat.fs growth scope (thin wrappers over std.Io.Dir, io hidden)

All wrappers store and pass the Dir's existing `io` field, so call sites never
see std.Io or thread io (the compat.fs contract). Exact 0.16 targets:

- `Dir.openDir(sub_path, options) !Dir`        -> inner.openDir(io, sub_path, opts)
- `Dir.iterate() Iterator` + `Iterator.next() !?Entry`
                                                -> inner.iterate(); Iterator.next(io)
  (re-expose Entry.kind / Entry.name; the loop uses only those)
- `Dir.makeDir(sub_path) !void`                -> inner.createDir(io, sub_path, perms)
  (0.16 renamed makeDir to createDir and added a Permissions arg; the wrapper
   keeps the makeDir name for readable call sites and supplies a default perm)
- `Dir.deleteTree(sub_path) !void`             -> inner.deleteTree(io, sub_path)

Two reads need a small decision, not new surface necessarily:

- attribute_file:148 readFileAlloc: either add a `Dir.readFileAlloc(gpa, sub,
  max)` convenience, or inline the existing openFile + readToEndAlloc + close at
  the one call site. Recommendation: inline (one site; avoids a convenience that
  only one caller uses, consistent with prefer-duplication).
- session_file:355 file.stat().size precheck: compat.fs File has no stat().
  Either add `File.stat()`, or drop the explicit precheck and let
  readToEndAlloc(gpa, FILE_MAX) enforce the bound (behavior shifts from a
  FileTooLarge error to the allocRemaining limit error). Recommendation: add a
  minimal `File.stat()` so the FileTooLarge semantics and ADR 0004 error mapping
  are preserved exactly.

Net growth: 4 Dir methods + 1 Iterator type + 1 File.stat(). All mechanical
wrappers; no logic.

## 4. The one genuine open decision: how io reaches the call sites

Every production fs function already holds an allocator, so two approaches exist:

Option 1 (local bootstrap, recommended): each fs function opens its own io_ctx
from the allocator it already has:
    var io_ctx = try compat.io.open(allocator);
    defer io_ctx.deinit();
    var dir = compat.fs.cwd(io_ctx.io());
No signature changes, no threading. A login tool reads a handful of files, so a
per-call Threaded context is negligible, and each function stays self-contained.
Tests do the same with testing.allocator. Mirrors the ratified time-route call:
file-local during migration, consolidate later if a hot path appears.

Option 2 (threaded from main): main constructs one io_ctx and threads io (or a
compat.fs.Dir) as a parameter into loadFromDir / lookupByIdFrom / enumerateFrom.
Honors "one context per tool" but ripples signatures through every caller and
every test, mid-migration.

Recommendation: Option 1. It keeps P3 a localized change and defers the
single-context consolidation until the closure is green, consistent with the
prefer-duplication discipline.

## 5. Tranche plan

P3-T1 (compat.fs growth): add the four Dir methods, the Iterator, and File.stat
to shared/src/compat/fs.zig. Shared-module change; validate it compiles for
freebsd. Reusable by semadraw P3 later (socket_server's deleteFile, main's
fs.File, etc.), so this is leverage, not just sessiond plumbing.

P3-T2 (sessiond production reads): attribute_file.loadFromDir (readFileAlloc
inlined) and session_file.lookupByIdFrom (openFile + stat + readToEndAlloc),
each bootstrapping io locally. Greens attribute_file, and transitively user_enum
and launch.

P3-T3 (sessiond traversal + test scaffolding): session_file.enumerateFrom
(openDir + iterate) and the ten test-block sites (makeDir -> Dir.makeDir,
deleteTree -> Dir.deleteTree) plus writeTestSession. Greens session_file.

After P3 the entire sessiond standalone track is green. Remaining: ui
(milliTimestamp time class + semadraw gate) and main (its own fs.File at 233,
plus the semadraw gate).

## 6. Open items for ratification

1. Confirm the compat.fs growth surface in section 3 (4 Dir methods + Iterator +
   File.stat), and the two read decisions (inline readFileAlloc; add File.stat
   to preserve FileTooLarge semantics).
2. Confirm the io-delivery approach: Option 1 (local bootstrap, recommended) vs
   Option 2 (threaded from main).
3. ADR posture: the growth implements ADR shared 0001 Decision 3 rather than
   making a new architectural choice, so I read it as not needing a new ADR, but
   it is a notable surface extension to compat.fs. Recommendation: a short errata
   note appended to ADR shared 0001 recording the directory-operations addition
   (openDir / iterate / makeDir->createDir / deleteTree / File.stat). Confirm
   whether you want that errata before P3-T1, or treated as mechanical.
4. Confirm the tranche order (growth first, then reads, then traversal+tests).
