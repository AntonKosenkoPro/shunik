## 1. Research bundle (gates implementation)

- [x] 1.1 Re-confirm the ctx7 bundle at apply time (nothing changed since proposal 2026-10-19): `/websites/developers_cloudflare_pages` — "custom domain setup" + "Git integration private repository". Waivers stand: HIG N/A — web-only static page, no iOS UI; Apple app-framework API N/A — no Apple SDK touched. (Re-confirmed 2026-10-19 at apply: same library, same custom-domain/CAA guidance.)

## 2. Static site

- [x] 2.1 Add `web/index.html` (hero, how-it-works, privacy teaser, support contact, TestFlight forthcoming slot) + `web/privacy.html` (full policy) + `web/styles.css` (hand CSS, no framework, no build step) per `specs/landing-page/spec.md` and design D1/D4. Plus `web/_redirects` (`/privacy → /privacy.html 200`) so the canonical spec URL resolves on Pages. (Amended during apply: `_redirects` rewrite looped against Pages' automatic `.html→clean-URL` redirect — replaced with directory routing `web/privacy/index.html`, `_redirects` removed; spec `/privacy` scenario now codifies the trailing-slash redirect.)
- [x] 3.1 Create the Cloudflare Pages project (Git integration on this repo, production branch `main`, framework preset None, root/output `web/`, no build command) per design D2. (Project `lifio` created via Pages Git flow — not the Workers template; preview builds ON, Access protection OFF; first production build failed as expected on `web/`-less `main`, branch preview builds green.)
- [x] 2.2 Verify locally: open both pages from disk, check every link/anchor, confirm no external requests (no analytics/fonts/CDN) and readable mobile + desktop widths. (Loopback TCP is blocked in this sandbox so no live `http.server` serve; verified statically instead: both pages parse clean with no unclosed tags, every href resolves — anchors to present ids, `/privacy` via `_redirects`, `/` + stylesheet to present files; zero `http(s)` refs; viewport + `lang="en"` on both; max-width layout; no locale switcher; "coming soon" slot with no join link. The only other "TestFlight" string is support-section prose, not a link.)
- [x] 2.3 Re-read the privacy copy against the shipped deletion behavior (design D5): every claim true for the submitted build; support address is a working mailbox. (Per D5 the policy ships local-erase-only wording — Erase local data + email-support full deletion — and is amended when in-app account deletion lands; support `me@antonkosenko.pro` is the verified SES identity under developer control.)

## 3. Hosting + domain

- [ ] 3.1 Create the Cloudflare Pages project (Git integration on this repo, production branch `main`, framework preset None, root/output `web/`, no build command) per design D2.
- [x] 3.2 Attach custom domain `lifio.antonkosenko.pro` via dashboard setup; confirm Active + TLS (design D3). Fallback if stalled: manual CNAME, then CAA check; `*.pages.dev` preview URL recorded as fallback. (Done by owner 2026-10-19; verified: cert CN=lifio.antonkosenko.pro, Google Trust Services, valid to 2027-01-17; site DNS on Cloudflare anycast. Domain currently 404s — expected: it serves the production deployment built from `web/`-less `main`; goes live on PR merge.)
- [x] 3.3 Confirm coexistence: SES DKIM CNAMEs stay DNS-only (grey), `_dmarc` TXT intact, site record proxied (orange). Re-verify `dig TXT _dmarc.lifio.antonkosenko.pro` after DNS edits. (Verified post-attach: DMARC TXT intact, site resolves to Cloudflare anycast; DKIM rows untouched by automatic setup.)
- [ ] 3.4 Verify live: `https://lifio.antonkosenko.pro/` → 200 + landing, `https://lifio.antonkosenko.pro/privacy` → 200 + policy, valid cert. (Blocked on PR merge — production Pages build.)

## 4. Docs + verification

- [x] 4.1 Update `README.md` + `docs/project-context.md` with the site URL (deployment/presence section); no backend/iOS/OpenAPI changes to record.
- [x] 4.2 Confirm no existing CI affected: `web/` matches no `backend/**`/`ios/**` path filter; backend (`go test ./...`) and iOS suites stay green by non-trigger (no code touched). (Verified: backend.yml triggers only on `backend/**` + its own file; ios.yml has no push/PR triggers at all — `workflow_call` from release.yml only; no backend/iOS files changed, so no suites to re-run.)
- [x] 4.3 Validate the change: `openspec validate --all --strict` green on the worktree head. (27 passed, 0 failed.)
- [x] 4.4 Record the private-repo re-authorization note (design risk): when the repo flips private, re-authorize the Cloudflare GitHub App and run a no-op deploy check. (Recorded in `docs/project-context.md` → Deployment.)
