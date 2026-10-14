# Repro evidence (task 1.1) — recorded on current tree before the fix

> Note: frame/video files were removed from the repo during pre-archive
> cleanup (binaries don't belong in the repo); the analysis below is
> preserved as the record. Videos held by the human.

Device: iPhone 17 Pro simulator (iOS 26.4, light appearance), Debug build at
`main` head. Signed in as `repro-steady@test.example` against the local dev
backend with one committed entry ("Morning run"). App terminated, then
relaunched via `simctl launch` under `screen-recording-start`
(`trimStatic: false`). Full video: `coldboot-before.mp4` (33 s).

Frame-by-frame (30 fps extraction, launch ≈ t+13 s — the gap before it is
tool round-trip latency, not app time):

| Frame | Time | Screen |
|---|---|---|
| `hi_001`–`hi_010` | launch+0.0–0.3 s | Home screen (app process starting) |
| `hi_011`–`hi_029` | launch+0.4–1.0 s | iOS app-open zoom into the plain-white OS launch screen |
| `1-branded-splash.png` (`hi_033`–`hi_034`) | launch+1.0 s | Branded `restoringSplash` (BrandMark + "Lifio" + spinner) mid system-crossfade in |
| `2-bare-spinner.png` (`hi_036`–`hi_041`) | launch+1.1–1.4 s | **Hard cut 1:** unbranded white screen, lone centered spinner (bind-phase bare `ProgressView`) |
| `3-track-empty.png` (`hi_042`) | launch+1.4 s | **Hard cut 2:** Track paints with the *false* empty hint "Activities you track will appear here." although an entry is committed |
| `4-track-filled.png` (`hi_043`+) | launch+1.5 s | **Hard cut 3:** Recents chip "Morning run" pops in one frame later; name row / Start / header shift a few points as the adaptive spacers re-resolve. Stable from here. |

Confirmed defect: three hard cuts plus one frame of false empty state inside
~1 s — the reported "jump after splashscreen". The branded splash itself
paints for only ~0.1–0.2 s because the session restore wins the first-frame
race on a fast backend; the reliably visible phases are the bare spinner and
the empty→filled Track swap. No post-reveal sync-exit reshuffle was visible
in this run (first sync converged before/with the first paint).
