## Why

External TestFlight (Apple Beta review) requires live support and privacy-policy URLs, and the SES production-access request asks for a website. No Lifio web presence exists today. A minimal static landing at `lifio.antonkosenko.pro` satisfies all three with one artifact, and its sender-aligned domain (`noreply@lifio.antonkosenko.pro`) keeps inbox-to-page branding consistent.

## What Changes

- Add a static, dependency-free landing site under `web/` (`index.html`, `privacy.html`, `styles.css`): hero with product one-liner, 3-step how-it-works, privacy teaser linking to the full policy, support contact, TestFlight slot (dead link marked "coming soon" until the public link exists).
- Host on Cloudflare Pages via Git integration watching `main` with root `web/`; attach custom domain `lifio.antonkosenko.pro` (Cloudflare-managed DNS, automatic activation).
- English-only v1 (app ships en+ru; RU is an explicit fast-follow, stated on the page scope, not a silent gap).
- Non-goals: no backend/API changes, no iOS changes, no OpenAPI changes; no blog/CMS, no analytics, no JS framework, no build step; no API rename (`timeoflife-api.antonkosenko.pro` untouched); no custom SES MAIL FROM subdomain (deferred mail upgrade).

## Capabilities

### New Capabilities

- `landing-page`: the public web presence contract — pages served, content guarantees (support contact, privacy policy), brand/domain rules, and language scope.

### Modified Capabilities

None — greenfield surface; no baseline requirement changes.

## Impact

- Affected systems: new `web/` top-level directory (outside backend/iOS CI path filters — no existing workflow triggers); Cloudflare Pages project + `lifio.antonkosenko.pro` DNS (CNAME, proxied) coexisting with the SES DKIM CNAMEs + DMARC TXT on the same name; docs (`README.md`, `docs/project-context.md`) gain the site URL.
- Affected baseline capabilities: none behaviorally.
- Authoritative docs: Cloudflare Pages `/websites/developers_cloudflare_pages` — "custom domain setup" (Workers & Pages → Custom domains → automatic activation when the zone is Cloudflare-managed; CAA records only if issuance fails), "Git integration private repository" (GitHub App connection; private repos supported). Pin: docs fetched 2026-10-19, current Cloudflare docs. Waivers: HIG N/A — web-only static page, no iOS UI surface; Apple app-framework API N/A — no Apple SDK touched (diff is static HTML/CSS + Pages/DNS config).
- Risk: repo going private later needs a one-click GitHub App re-authorization for Pages — accepted (documented in design); TestFlight slot ships dead until the public link exists — accepted (labeled "coming soon", not a broken link).
