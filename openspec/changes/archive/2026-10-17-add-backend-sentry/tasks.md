## 1. Research and scaffold

- [x] 1.1 ctx7 bundle: `/getsentry/sentry-go` — init-via-DSN+Flush, sentryhttp middleware, manual capture w/ context, mock transport (weak hit → D5)
- [x] 1.2 Worktree `timeOfLife.wt/add-backend-sentry` from fresh `origin/main`, session moved, `openspec new change add-backend-sentry`
- [x] 1.3 Corrected scope: Stage-0 SDK already on `origin/main`; change enriches handled-500s (proposal + delta + design rewritten)
- [x] 1.4 Sentry deep-dive recorded: LIFIO-BACKEND-1..3 message-only, no stack/breadcrumbs/spans/logs; -2/-3 share trace (common-cause pattern)

## 2. Backend implementation

- [x] 2.1 New `internal/observe` package: Sentry core moved from `internal/server` (same names), `ReportError(r, op, err)` added; `server/sentry.go` deleted
- [x] 2.2 `server.go` (middleware) + `main.go` (init/flush) repointed to `observe`
- [x] 2.3 `writeInternalError(w, r, msg, err)` helper; all 14 `internal_error` sites converted; `writeCatalogStoreErr` gains `r`
- [x] 2.4 Sentry suite moved to `observe` + fake-`Transport` test for `ReportError` (tags/fingerprint/error context)
- [x] 2.5 Handlers envelope test: closed-store `GET /categories` → 500 + `internal_error` with Sentry disabled and enabled
- [x] 2.6 `context.Canceled` guard: `ReportError` + middleware 5xx capture skip client-disconnect 500s (LIFIO-BACKEND-1..3 class); `DeadlineExceeded` still reports

## 3. Quality gates

- [x] 3.1 `gofmt -l .` empty, `go vet ./...`, `golangci-lint run` clean
- [x] 3.2 `go test ./... -race` green (58.8% total, observe 78.6%); FURPS auth/catalog rows re-checked (envelopes byte-identical)
- [x] 3.3 `openspec validate --all` green (28 passed)
- [ ] 3.4 Human follow-ups (post-merge, no VM SSH from here): pull prod logs around 2026-10-16T09:50:25Z + 2026-10-17T06:51:02Z, force a staging 500 to confirm the rich issue, resolve LIFIO-BACKEND-1..3
