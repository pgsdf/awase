# ADR 0011: Console navigation model (view and focus as separate axes)

## Status

**Accepted. Ratified 2026-07-12 (operator). Implemented, and the
centered layout is RETIRED.**

The ADR set itself a falsifiable test in section 2: `pre_power_field`
and the modal-unwind special cases must be DELETED, not ported, or the
peer-view model is not more natural than the modal one it replaces.

It passed, and then the retirement of the centered layout removed the
field from the codebase entirely. The net change was 121 lines added
and 1,277 removed: the model paid for itself by deleting the machinery
that existed only to unwind modality.

Scoped deliberately: this ADR settles the STATE MODEL, which is
architectural, and explicitly does not settle the header contents,
which are a UX tradeoff that should evolve through prototypes rather
than be fixed by argument. See section 7.

## 1. Context

`pgsd-sessiond` presents a centered login card. A flagged prototype
(`PGSD_SESSIOND_LAYOUT=console`) renders the same state as a two-pane
operating-system console: a status header, a persistent left rail
naming Login / Session / Power, a content pane, and a legend footer.
The prototype's rail is decorative. This ADR is about what it would
take to make it real.

The renderer is not the obstacle and was never the question. It is
monospace (8x16 glyphs scaled) with `fillRect`, `drawText`, and
`drawBorder`, so a grid-snapped console is what those primitives are
for; the prototype needed zero renderer changes. The obstacle is the
state model.

**Today's model is modal.** `FieldState` is
`{identify, password, picker, power_menu, submitting}`, a single enum
in which `picker` and `power_menu` are overlays that SHADOW the login
rather than sitting beside it. That forces bookkeeping whose only
purpose is to unwind modality:

- `pre_power_field`, remembering what the power menu covered so ESC can
  return to it.
- The special case where Ctrl-Q from inside the picker must close the
  picker first and then open the power menu.

Neither exists because the domain requires it. Both exist because an
overlay must remember what it was on top of.

## 2. Decision

Separate **view** from **focus**, as two axes rather than one enum.

    focus:  { rail, content }
    view:   { login, session, power, ... }
    field:  per-view (login has identify / password / submitting)

The rail becomes persistent navigation over PEER views. Session and
Power stop being interruptions of the login and become places you
navigate to and back from.

The expected result is that the state machine gets SMALLER.
`pre_power_field` and the modal-unwind special cases are deleted, not
ported: peer views have nothing to remember, because navigating away
from a view and back is not an interruption. If the revision does not
delete that bookkeeping, the model is not actually more natural than
the one it replaces, and that is the test this ADR should be judged by.

## 3. What stays modal, deliberately

**Authentication in flight.** `submitting` locks the UI: PAM is being
called, and neither the fields nor the rail may be mutated under it.
This is correct today and survives unchanged. The rail is not navigable
while submitting.

**Confirmation of destructive actions.** Navigating to Power and
pressing Enter on Shutdown must NOT shut the machine down. The
power menu's confirm phase (`confirming_shutdown`, `confirming_restart`)
stays. Peer-view navigation makes reaching the action easier, which
makes the confirm step more necessary, not less.

Modality is not the enemy. Modality *as a substitute for structure* is.

## 4. Views, and what is not one

Views in scope now:

- **Login**: the fields. The default view; the one the greeter opens on.
- **Session**: the session-type selection, currently the picker overlay.
- **Power**: shutdown / restart / suspend, currently the power overlay.

Views deferred, with reasons:

- **Diagnostics**: valuable, probably the most valuable after Login on
  a machine where the session layer is still moving, because a failed
  session launch currently returns the user to a login screen with no
  explanation. Deferred only because it needs a failure-reason channel
  that does not exist yet, not because it is unwanted. Section 6.
- **Keyboard**: NOT built here, and not because it is unwanted either.
  Keyboard layout is a substrate capability, not a login-manager
  feature (audit SA-5): two clients already hardcode US layouts
  independently, and a selection view in pgsd-sessiond would mean
  semadraw-term needs its own and NDE needs its own and they would
  disagree. The view waits until the substrate owns layout. The
  header display of the ACTIVE layout does not wait: it is cheap and
  explains a whole class of failed password attempts at a glance.
- **Accessibility**: a placeholder for work nobody has scoped. An empty
  view is worse than no view.

## 5. Navigation

- Up/Down move the rail cursor when focus is `rail`.
- Enter or Right moves focus to `content` for the selected view.
- ESC or Left returns focus to `rail`.
- Ctrl-Q remains a global accelerator to the Power view, from anywhere,
  because it is muscle memory and it works today.
- The legend footer continues to name the keys available in the current
  (focus, view) pair. It is already per-state and already the
  discoverability surface; it simply gains a second axis.

Bare Tab is deliberately NOT used for navigation. It is not currently
delivered to this daemon (audit SA-5), which is why the session picker
was rebound to Ctrl-S.

## 6. The submit affordance, and diagnostics tiering

**A visible submit affordance is kept.** An earlier draft argued that a
keyboard-first console should not render a button nobody clicks. That
does not follow: discoverability and keyboard-first are not in tension,
and a framed label naming the action that authenticates is a console
idiom rather than a GUI habit. The legend already does exactly this at
the footer. The pane may carry the same cue where the action is.

**Diagnostics, when built, are tiered.** The login screen shows a
high-level reason ("Session launch failed") and a pointer to the log.
Internal detail (the error union, the exec failure, the PAM return
code) belongs behind the Diagnostics view, not on the greeter. A
development-grade error message on a user-facing login screen is a
defect, not a feature.

## 7. What this ADR does not decide

**Header contents.** Which status fields appear (hostname, product
name, network, keyboard layout, tty, time, memory, kernel identity) is
a UX tradeoff, not an architectural decision, and it should be settled
by looking at prototypes rather than by argument. Recorded so it is not
mistaken for an omission:

- The product name is system identity, not branding, provided it is
  rendered as a status field and not as a title. It answers "what
  operating system is this" beside the hostname's "which machine".
- Keyboard layout in the header is the single highest-value item and
  should land regardless of everything else here.
- Kernel identity is enormously useful during active kernel development
  and will be noise to an ordinary user later. It belongs in a
  developer mode or the Diagnostics view, not the permanent greeter
  header. (An earlier draft argued for the header; that was optimising
  the product for the current maintainer's debugging convenience, which
  is a bias worth naming.)
- Memory is the metric that is easy to obtain rather than the one that
  is useful at a login prompt.

**Persistence of the layout setting.** Recorded as a recommendation in
audit SA-5, not decided here: the greeter's layout is a machine
setting (a property of the keyboard plugged into this machine, not of
any user) and should persist globally; after authentication the session
adopts the user's preferred layout. That handover falls naturally on a
boundary that already exists, since pgsd-sessiond runs as root and
drops privilege per-session after auth.

## 8. Consequences

- `FieldState` is replaced by a `(focus, view, field)` triple.
- `pre_power_field` and the modal-unwind special cases are deleted.
- `drawPicker` and `drawPowerMenu` stop being overlays and become pane
  renderers. The prototype currently calls them as overlays; that is
  the scaffold, not the destination.
- The rail becomes navigable, which is the point.
- Adding a future view (Diagnostics, Keyboard, Accessibility) becomes
  an addition rather than a redesign. That is the property being bought
  and the reason the model is worth the revision.
- The centered layout was retired on ratification (2026-07-12). Its
  renderer (draw, drawField, drawPicker, drawPowerMenu, legendFor), its
  modal handlers (handleAction, handlePowerMenuInput,
  handlePowerMenuChoosing, handlePowerMenuConfirming, openPowerMenu),
  the PGSD_SESSIOND_LAYOUT flag, and pre_power_field are all gone.
  Net: 121 lines added, 1,277 removed.

## 9. Bench requirements

1. Rail navigation: Up/Down moves the cursor, Enter enters the view,
   ESC returns to the rail. No view is reachable that cannot be left.
2. Session selection through the Session view produces the same
   `selected_session` result as the old picker overlay did.
3. Power confirmation still gates destructive actions: navigating to
   Power and pressing Enter on Shutdown reaches a confirm step and does
   not shut down.
4. `submitting` locks both the fields and the rail. Nothing is
   navigable while PAM is in flight.
5. Ctrl-Q reaches the Power view from every other view.
6. `pre_power_field` no longer exists in the source. If it survives the
   revision, the model did not simplify anything and this ADR failed
   its own test.
