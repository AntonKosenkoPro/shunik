## Context

See proposal.md (Why) for motivation. Current state: no `web/` directory exists; no Pages project; `lifio.antonkosenko.pro` has no address records (verified SES DKIM CNAMEs + DMARC TXT only). Workflows are path-filtered (`backend/**`, `ios/**`), so a new top-level `web/` directory triggers no existing CI. DNS zone `antonkosenko.pro` is Cloudflare-managed (cf. `blog.antonkosenko.pro` → github.io, proxied). Constraints: English-only v1; zero dependencies/no build step; sender-aligned domain already decided (`noreply@lifio.antonkosenko.pro`); repo going private one day.

## Goals / Non-Goals

**Goals:**
- Three static files serving the spec contract with no runtime beyond the CDN.
- Git-connected deploys (push to `main` publishes) surviving a future private-repo flip.
- Custom domain live with automatic TLS before the Beta-review submission.

**Non-Goals:**
- No framework, bundler, or CI workflow of our own (Pages' built-in Git integration is the pipeline).
- No content beyond the spec (no screenshots gallery, no changelog, no RU).
- No API/backend/iOS/docs-contract changes beyond recording the site URL.

## Decisions

- **D1 — Plain static files in `web/` (`index.html`, `privacy.html`, `styles.css`), Pages framework preset "None".** No build command, output directory `web/`. Alternative (Vite/Astro/Next) rejected: three pages need no toolchain, and every dependency is a future breakage surface for a page whose job is to sit still during review. Cite: `/websites/developers_cloudflare_pages` — "custom domain setup" (static output serves identically behind a custom domain; no framework requirement).
- **D2 — Cloudflare Pages Git integration (not Wrangler uploads, not GitHub Pages).** Connect the repo once via the Cloudflare GitHub App; production branch `main`, root `web/`. Alternative (GitHub Pages) rejected by explicit user decision: free-tier Pages assumes a public repo and the repo will go private. Alternative (manual `wrangler pages deploy`) rejected: human-driven uploads drift from `main` and can't be re-verified by reviewers. Private-repo survival: the GitHub App model grants per-repo access including private repos; flipping the repo private needs only re-authorizing private-repo access, no rebuild. Cite: `/websites/developers_cloudflare_pages` — "Git integration private repository".
- **D3 — Custom domain via dashboard "Set up a custom domain" for `lifio.antonkosenko.pro`, letting Cloudflare create the DNS record automatically.** Because the zone is Cloudflare-managed, activation is automatic (CNAME flattening + TLS issuance with no manual record). Manual CNAME is the fallback only if activation stalls. Coexistence: the Pages record (proxied address record) shares the name with the SES DKIM CNAMEs (`*._domainkey`, grey) and `_dmarc` TXT (grey) — different types/hosts, no conflict; the DKIM rows MUST stay DNS-only (grey), the site record MUST stay proxied (orange), mirroring the existing `blog` vs DKIM split. CAA only if issuance fails. Cite: `/websites/developers_cloudflare_pages` — "custom domain setup" (automatic setup for Cloudflare-managed zones; CAA `letsencrypt.org`/`pki.goog`/`ssl.com` records as the issuance-failure remedy).
- **D4 — Dead TestFlight slot, not a removed one.** The slot renders in place labeled forthcoming so the post-public flip is a one-line `href` change, and reviewers never meet a 404 posing as a join link. Alternative (hide until public) rejected: a second deploy to *add* the section risks landing mid-review; a visible honest slot is review-safe.
- **D5 — Privacy copy drafted against deletion-v1 truth.** The `/privacy` claims (email as identifier, EU relay storage, local-first device files, in-app deletion incl. server wipe) MUST match the shipped account-deletion behavior at submission time; if deletion-v1 slips, the policy ships with the local-erase-only wording and is amended with the feature — never ahead of it.

## Risks / Trade-offs

- [Risk] Repo-private flip breaks the Pages connection → Mitigation: re-authorize the Cloudflare GitHub App for private repos (one click, documented in tasks); verify with a no-op deploy right after flipping.
- [Risk] Custom-domain TLS stalls (CAA or propagation) → Mitigation: check CAA records, add the documented `issue`/`issuewild` set if present-but-restrictive; `*.pages.dev` preview URL stays the working fallback and is itself submittable in a pinch.
- [Risk] Policy claims drift from shipped deletion behavior → Mitigation: tasks gate the policy wording on the deletion-v1 contract; reviewer-facing text is re-read against the submitted build before upload.
- [Trade-off] No preview-per-PR workflow configured — accepted: three static pages get full-file review in the PR diff itself; Pages' automatic preview deployments still exist as a backstop.
