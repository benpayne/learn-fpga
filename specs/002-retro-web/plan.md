# Implementation Plan: Retro-Active Community Website

**Branch**: `002-retro-web` | **Date**: 2026-04-19 | **Spec**: [spec.md](./spec.md)  
**Input**: Feature specification from `/specs/002-retro-web/spec.md`

## Summary

Build a static Astro 6 website at `retroweb/` within the repo that promotes the retro computing co-processor ecosystem. The site uses content collections for blog posts and project entries (authored in Markdown), a CRT/terminal-inspired custom theme (global CSS tokens + scoped component styles), and deploys to GitHub Pages via GitHub Actions. Hand-authored pages cover landing, about, architecture, getting-started, and project showcase. Zero client-side JavaScript by default; syntax highlighting is server-rendered via Shiki.

## Technical Context

**Language/Version**: TypeScript 5.x / JavaScript, Node.js 22+  
**Primary Dependencies**: Astro 6.1.x, Shiki (bundled), Zod (bundled)  
**Storage**: Markdown files in `src/content/` (content collections); images in `public/images/`  
**Testing**: Lighthouse CI (accessibility + performance gates), `linkinator` (broken link check), manual acceptance walkthrough from `quickstart.md`  
**Target Platform**: Static HTML/CSS deployed to GitHub Pages; browsers: latest 2 versions of Chrome, Firefox, Safari, Edge  
**Project Type**: Static website (single project, self-contained in `retroweb/`)  
**Performance Goals**: Page load <3s on broadband (SC-002); Lighthouse Performance ≥90  
**Constraints**: Lighthouse Accessibility ≥90 / WCAG AA (SC-003); responsive at 375px/768px/1024px (FR-010); no server runtime (FR-011); self-contained in `retroweb/` (FR-015)  
**Scale/Scope**: 5 static pages + 3-5 initial blog posts + 1-3 projects at launch; system should handle 100 posts / 50 projects without degradation

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

No `.specify/memory/constitution.md` exists in this repository. No constitution-derived gates to evaluate.

**Self-imposed gates** (derived from spec success criteria):

| Gate | Status | Notes |
|------|--------|-------|
| All FRs have testable acceptance | PASS | Walkthrough in `quickstart.md` covers US1-US6 |
| No unresolved NEEDS CLARIFICATION | PASS | Spec has none; research.md closes remaining unknowns |
| Tech choices justified in research | PASS | See research.md decisions 1-9 |
| Accessibility baked in, not retrofitted | PASS | Color palette pre-validated for WCAG AA |
| Deploy path defined before writing pages | PASS | GitHub Actions + project base path documented |

**Re-check after Phase 1**: PASS — no new violations introduced.

## Project Structure

### Documentation (this feature)

```text
specs/002-retro-web/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 — framework/tooling decisions
├── data-model.md        # Phase 1 — content schemas, page inventory
├── quickstart.md        # Phase 1 — maintainer onboarding
├── contracts/
│   └── content-schemas.md  # Zod schemas for blog/project collections
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
retroweb/
├── astro.config.mjs         # site, base, integrations
├── package.json
├── tsconfig.json
├── src/
│   ├── content.config.ts    # Zod schemas for blog + projects collections
│   ├── content/
│   │   ├── blog/            # *.md blog posts
│   │   └── projects/        # *.md project entries
│   ├── pages/
│   │   ├── index.astro            # Landing (US1)
│   │   ├── about.astro            # Vision (FR-005)
│   │   ├── architecture.astro     # Bus spec (US3)
│   │   ├── getting-started.astro  # Onboarding paths (US4)
│   │   ├── 404.astro              # Custom error (FR-012)
│   │   ├── blog/
│   │   │   ├── index.astro        # Post list (US2)
│   │   │   └── [...slug].astro    # Post detail
│   │   └── projects/
│   │       ├── index.astro        # Card grid (US5)
│   │       └── [slug].astro       # Project detail
│   ├── layouts/
│   │   ├── BaseLayout.astro       # HTML shell, meta tags (FR-013), nav, footer
│   │   ├── PageLayout.astro       # Static pages
│   │   └── PostLayout.astro       # Blog post rendering
│   ├── components/
│   │   ├── Header.astro           # Nav bar (FR-002)
│   │   ├── Footer.astro
│   │   ├── Hero.astro             # Landing hero
│   │   ├── PillarGrid.astro       # Build/Share/Run/Connect
│   │   ├── BlogCard.astro
│   │   ├── ProjectCard.astro
│   │   └── ThemeTokens.astro      # CSS custom property definitions
│   └── styles/
│       ├── global.css             # Tokens (colors, fonts, spacing)
│       └── prose.css              # Blog post typography
├── public/
│   ├── fonts/                     # Self-hosted IBM Plex Mono, Inter
│   ├── images/
│   │   ├── blog/
│   │   └── projects/
│   ├── favicon.svg
│   └── robots.txt
└── README.md                      # Pointer to quickstart.md
```

**Build output** (gitignored): `retroweb/dist/`

**Deployment workflow**: `.github/workflows/deploy-retroweb.yml` (added at repo root, builds `retroweb/` and deploys to GitHub Pages)

**Structure Decision**: Single self-contained project in `retroweb/` satisfies FR-015. Page routes in `src/pages/` map 1:1 to the six static pages required by FR-001–FR-008. Content collections in `src/content/` cleanly separate author-contributed markdown from site code (SC-004 — add a post in under 10 minutes without code changes).

## Complexity Tracking

> No Constitution Check violations. No entries required.

## Phase 0 — Research Output

See [research.md](./research.md). Key decisions:

1. **Astro 6.1.x** with Node 22+ — user-requested, latest stable
2. **Content Collections + Zod** — typed frontmatter, build-time validation
3. **Shiki** for syntax highlighting — server-rendered, zero JS
4. **Global CSS tokens + scoped styles** — custom theme without framework bloat
5. **Palette**: near-black bg, off-white body, phosphor-green / amber accents — all WCAG AA compliant
6. **GitHub Pages deploy** via `actions/deploy-pages@v4`, base path `/learn-fpga`
7. **Typography**: IBM Plex Mono (heads), Inter (body), JetBrains Mono (code), self-hosted
8. **Testing**: Lighthouse CI + linkinator + manual walkthrough (no unit tests — nothing meaningfully unit-testable in templates)

## Phase 1 — Design Output

### Content schemas
See [contracts/content-schemas.md](./contracts/content-schemas.md) — defines the Zod schema for blog posts and projects, plus example frontmatter authors can copy.

### Data model
See [data-model.md](./data-model.md) — entities are content collections (Blog Post, Project), derived Tag, and hand-written Pages. Includes validation rules and build-time queries.

### Maintainer quickstart
See [quickstart.md](./quickstart.md) — install, run dev server, add a post, build, deploy, acceptance walkthrough mapping to each user story.

### Agent context update
The existing `CLAUDE.md` already documents the hardware project; this website feature is additive and self-contained in `retroweb/`. Agent context update can be run if needed:

```bash
bash .specify/scripts/bash/update-agent-context.sh claude
```

## Next Steps

Run `/speckit.tasks` to generate `tasks.md` — the dependency-ordered implementation task list derived from this plan.
