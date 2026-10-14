# Verification evidence (task 4.2) — recorded on the fixed tree

> Note: frame/video files were removed from the repo during pre-archive
> cleanup (binaries don't belong in the repo); the analysis below covers the
> superseded veil direction and is preserved as the record. The final
> optimistic direction was verified on-device by the human (cold boot:
> solid launch background → complete Track in one cut, no waiting UI).

Device: iPhone 17 simulator (iOS 27.0, light appearance), Debug build with
the change. Signed in as `repro-steady@test.example`; the local account file
carries the "Morning run" entry (pulled from the relay on the previous
session and persisted locally). App terminated, then relaunched via
`simctl launch` under `screen-recording-start` (`trimStatic: false`).
Full video: `coldboot-after.mp4`.

Frame-by-frame (launch ≈ t+50 s — the gap before it is tool round-trip
latency, not app time):

| Frame | Screen |
|---|---|
| OS launch white zoom | system app-open animation |
| `5-after-splash.png` | Continuous branded splash (BrandMark + "Lifio" + spinner) — restore and bind phases are visually identical; **no bare-spinner phase anywhere** |
| `6-after-fade.png` | Opacity fade in progress: splash veil lifting over the mounted shell |
| `7-after-track.png` | Complete Track (timer, name row, Start, Recents chip) — stable from here; **no second jump after the fade settles** |

Before/after diff against `REPRO.md`:
- Bare-spinner hard cut: GONE (splash is continuous through binding).
- Empty→filled hard cut on a bare screen: GONE (the shell is never visible
  unready; at most, on a saturated main thread, content resolves under the
  fading veil — see note below).
- Few-point layout shift after reveal: GONE (upper content holds identical
  frames across the fade; verified by frame comparison).
- Fade: PRESENT (0.25 s ease-out opacity transition; instant under
  Reduce Motion by construction).

Note on slow first render: on this heavily loaded simulator host the loaded
Recents paint can commit up to ~0.3 s after the fade starts (first-render
main-thread saturation — the same load that once tripped the 10 s
scene-create watchdog on this box), so chips may resolve during the fade
tail. The signal path was proven with a temporary 10 s timeout experiment
(splash held, then unveiled to a complete Track — timeout never needed);
the production 2 s bound only ever fires against a hung read (measured
local cost: 21 ms prepare, ≤11 ms first load). On a normal device the whole
launch takes ~1 s and the fade reveals final content. Relay-only data still
converges via the unchanged sync-exit reload (out of scope by design).

## Fade correction (device finding → research → fix)

The user's device video then showed Track elements crisp *under* a
non-dimming splash ghost with no fade at all. Root cause, found on re-read:
`restoringSplash` is a transparent VStack (brand + spinner only) — in the
gate branches the root paints the background behind it, but in the shell
ZStack nothing did, so the "cover" covered nothing and the mounted Track
painted straight through. Fixed by filling the overlay with
`Theme.backgroundPrimary` (with a comment naming the trap).

A second finding from the same video round: even the glyph fade never
played (single-frame swap). Researched best practices (Apple HIG
"Launching"; Stack Overflow swiftui/57730074; sarunw.com ZStack transition
piece): a conditional overlay in a ZStack without explicit `zIndex` can
lose its disappearance transition and vanish instantly. Fixed with
`.zIndex(1)` on the shell and `.zIndex(2)` on the overlay.

Re-verified on simulator (`coldboot-fade.mp4`): `8-fade-midpoint.png`
catches the cross-dissolve mid-flight — dimmed complete Track (timer,
name row, Start, Recents chip all present) under the dissolving brand mark
and spinner. The fade plays; the first paint is complete; nothing moves
after it settles. (Apple HIG advises against logo splashes entirely —
launch visuals should mirror the first screen; retained here only because
the product explicitly wants brand continuity plus a smoothness fade.)
