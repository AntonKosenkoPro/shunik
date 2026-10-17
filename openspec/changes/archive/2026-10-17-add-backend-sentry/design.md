# Design: add-backend-sentry

## Decisions

- **D1 — New leaf package `internal/observe`; move Sentry core out of `internal/server`.** Handlers need the error object at the 500 site but
  cannot import `server` (`server` imports `handlers` — cycle). `observe` depends only on `sentry-go` + chi + stdlib, so both `server`
  (middleware/init/flush) and `handlers` (handled-500 reporting) import it. `sentry.go` + `sentry_test.go` move verbatim (package rename only);
  `server.go`/`main.go` call sites repoint to `observe.InitSentry` et al. (same function names).
- **D2 — `Handler.writeInternalError(w, r, op, err)` helper (in `auth.go`, next to `writeError`).** Reports via `observe.ReportError` (no-op
  unless enabled), keeps the existing `slog` line, writes the existing generic envelope. All 14 handled-500 sites convert:
  `auth.go` ×9 (incl. the three `issueTokens` sites), `catalog.go` ×3 (`ListCategories`, `ListDeletions`, `writeCatalogStoreErr` default branch —
  gains an `r *http.Request` param; its 8 callers already hold `r`), `entries.go` ×2. Byte-identical responses.
- **D3 — `observe.ReportError(r, op, err)`:** clones the current Hub, `applySentryTags` with 500, `SetLevel(error)`,
  `SetFingerprint(["{{ default }}", op])`, `SetContext("error", {"message": err.Error(), "op": op})`, `CaptureException(err)`. Nil-err guarded
  (falls back to `CaptureMessage`). Uses `CurrentHub().Clone()` like the existing panic/5xx paths (no `sentryhttp` dependency — our middleware
  is hand-rolled and stays that way).
- **D4 — Unchanged:** middleware order (`Recoverer` outer → `observe.Middleware` repanic), `Flush(2s)`, empty-DSN noop, tag allowlist, BeforeSend
  scrub, `sentryOperations` map (extended only if new ops appear — the helper takes free-form `op` strings; unknown ops fall back to templated
  `METHOD route`, still PII-free).
- **D5 — Tests:** `observe` package keeps the moved suite + a new fake-`Transport` test (`Flush`/`FlushWithContext`/`Configure`/`SendEvent`/`Close`;
  per `go doc sentry-go.Transport`): `ReportError` through a chi route yields exactly one event with route/op/`5xx` tags, `{{ default }},<op>`
  fingerprint, and the error string in context. Handlers: closed-SQLite-store test through `catalogRouter` proves `GET /categories` still returns
  500 + `internal_error` with Sentry disabled AND enabled (dummy DSN, no Flush → hermetic), i.e. the envelope contract holds on both paths.

## Alternatives considered

- **Report from middleware by status only (status quo):** rejected — the error object never reaches the middleware; this is exactly why today's
  issues are message-only.
- **Pass `err` through a package-global set by `server.New`:** rejected — hidden coupling, race-prone under `-race`, fights the repo's explicit-DI
  style; a leaf package is cheaper and testable.
- **Wrap `writeError` itself (no new helper):** rejected — `writeError` serves 4xx paths that must never report; an explicit 500-only helper keeps
  the reporting boundary visible at each call site.

## Repro & verification

- **Repro (recorded, current tree):** `LIFIO-BACKEND-1..3` in org `antonkosenkopro` — message-only 500 events, no stack/breadcrumb/span, Seer
  `super_low`. After this change + deploy, the next such 500 carries route template + op + error string.
- **Automated:** moved suite + new `observe` fake-transport test + handlers envelope test; full `go test ./... -race`, `gofmt`, `go vet`,
  `golangci-lint` green. iOS untouched (backend-only diff).
- **Manual (human, post-merge):** deploy, force a staging 500, confirm the rich issue, resolve LIFIO-BACKEND-1..3; pull prod container logs around
  2026-10-16T09:50:25Z and 2026-10-17T06:51:02Z for the historical root cause (agent has no VM SSH access).
