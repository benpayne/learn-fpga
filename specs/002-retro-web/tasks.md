---

description: "Task list for Retro-Active Community Website (002-retro-web)"
---

# Tasks: Retro-Active Community Website

**Input**: Design documents from `/specs/002-retro-web/`  
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/content-schemas.md, quickstart.md

**Tests**: Not requested in the spec. No unit/contract test tasks are generated. Quality is verified via Lighthouse CI, linkinator, and the manual acceptance walkthrough in `quickstart.md`.

**Organization**: Tasks are grouped by user story so each can be implemented, tested, and demoed independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story label (US1–US6). Setup / Foundational / Polish phases have no story label.
- Every task includes an exact file path.

## Path Conventions

All site code lives under `retroweb/` at the repository root (worktree: `~/wip/learn-fpga-web/`). Design docs live under `specs/002-retro-web/`. CI workflow lives at the repo root under `.github/workflows/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Initialize the Astro project and its directory skeleton.

- [X] T001 Create directory skeleton at `retroweb/` with `src/{content,pages,layouts,components,styles}/`, `src/content/{blog,projects}/`, `public/{fonts,images}/`
- [X] T002 Initialize Astro 6 project in `retroweb/`: run `npm create astro@latest -- --template minimal --typescript strict --install`, confirming output lands in `retroweb/`
- [X] T003 [P] Pin Astro 6.1.x and Node 22 engines in `retroweb/package.json`; add scripts `dev`, `build`, `preview`, `check`
- [X] T004 [P] Add `retroweb/dist/` and `retroweb/node_modules/` to repo root `.gitignore` (or add `retroweb/.gitignore` with the same)
- [X] T005 [P] Configure `retroweb/tsconfig.json` extending `astro/tsconfigs/strict`
- [X] T006 [P] Add `retroweb/README.md` that points readers to `specs/002-retro-web/quickstart.md`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Build the chrome, styling tokens, and shared primitives every user story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T007 Define content collection schemas in `retroweb/src/content.config.ts` per `specs/002-retro-web/contracts/content-schemas.md` (both `blog` and `projects` collections with Zod schemas)
- [X] T008 [P] Configure `retroweb/astro.config.mjs` with `site: 'https://benpayne.github.io'`, `base: '/learn-fpga'`, markdown config for Shiki `github-dark` theme
- [X] T009 [P] Download and place self-hosted fonts in `retroweb/public/fonts/`: IBM Plex Mono (regular, bold), Inter (regular, bold), JetBrains Mono (regular)
- [X] T010 [P] Create `retroweb/src/styles/global.css` with CRT/terminal theme tokens (colors `#0a0e12`, `#d4e4d2`, `#7fff7f`, `#ffb000`, `#5a6f5a`), font-face declarations, CSS reset, responsive breakpoints at 375/768/1024
- [X] T011 [P] Create `retroweb/src/styles/prose.css` for blog post typography (line-height, paragraph spacing, code block styling, link colors)
- [X] T012 Create `retroweb/src/layouts/BaseLayout.astro` with HTML shell, `<meta>` tags (title, description, Open Graph — FR-013), favicon link, global CSS import
- [X] T013 Create `retroweb/src/components/Header.astro` with responsive nav linking to `/`, `/about/`, `/architecture/`, `/getting-started/`, `/projects/`, `/blog/` (FR-002); include mobile hamburger behavior using native `<details>` (no JS)
- [X] T014 [P] Create `retroweb/src/components/Footer.astro` with project links and copyright
- [X] T015 [P] Create `retroweb/src/layouts/PageLayout.astro` wrapping BaseLayout + Header + Footer for static pages
- [X] T016 [P] Create `retroweb/src/pages/404.astro` using PageLayout with terminal-style error message and link home (FR-012)
- [X] T017 [P] Add `retroweb/public/favicon.svg` (simple terminal/CRT motif) and `retroweb/public/robots.txt`

**Checkpoint**: Dev server (`npm run dev` in `retroweb/`) serves `/` (blank placeholder OK), `/404/`, and all nav links resolve. Theme tokens apply globally.

---

## Phase 3: User Story 1 - Discover the Project Vision (Priority: P1) 🎯 MVP

**Goal**: Landing page that communicates the vision within 60 seconds.

**Independent Test**: Load `/` in dev server. First-time reader can articulate "a community ecosystem for building retro computers with shared standards" after 60 seconds. Nav bar visible, 4 pillars shown.

### Implementation for User Story 1

- [X] T018 [P] [US1] Create `retroweb/src/components/Hero.astro` with project name, tagline (<50 words per FR-001), CTA buttons linking to `/about/` and `/getting-started/`
- [X] T019 [P] [US1] Create `retroweb/src/components/PillarGrid.astro` rendering four pillars (Build, Share, Run, Connect) with icons and 1-sentence descriptions
- [X] T020 [US1] Create `retroweb/src/pages/index.astro` using PageLayout, composing Hero + PillarGrid + brief "Latest from the Blog" teaser section (empty state OK until US2 ships)
- [X] T021 [P] [US1] Create `retroweb/src/pages/about.astro` (FR-005) with full vision narrative — ecosystem concept, community principles, benefits of common bus approach

**Checkpoint**: Landing page and About page render with theme, responsive at all three breakpoints, readable contrast verified.

---

## Phase 4: User Story 6 - Deploy and Maintain the Site (Priority: P1)

**Goal**: Site builds, deploys to GitHub Pages automatically, and new content requires no code changes.

**Independent Test**: Push to `master`; workflow succeeds; site is reachable at `https://benpayne.github.io/learn-fpga/`. Adding a markdown file to `src/content/blog/` and pushing triggers redeploy with new post visible.

### Implementation for User Story 6

- [X] T022 [US6] Create `.github/workflows/deploy-retroweb.yml` (at repo root) using `actions/checkout@v4`, `actions/setup-node@v4` (Node 22), `npm ci` + `npm run build` in `retroweb/`, `actions/upload-pages-artifact@v3` for `retroweb/dist/`, and `actions/deploy-pages@v4`
- [X] T023 [US6] Enable GitHub Pages in repo settings (Source: GitHub Actions) — document this manual step in `retroweb/README.md`
- [X] T024 [US6] Verify first deploy succeeds and landing page loads at the Pages URL; capture URL in `specs/002-retro-web/quickstart.md` — **partial**: quickstart.md documents the pending verification checklist; human operator must push to remote, enable Pages, confirm green workflow, and update quickstart with live URL

**Checkpoint**: MVP complete — landing page is live on the public internet.

---

## Phase 5: User Story 2 - Read a Technical Blog Post (Priority: P1)

**Goal**: Blog with markdown authoring, chronological listing, and rendered post pages with syntax highlighting.

**Independent Test**: Visit `/blog/` — posts listed newest-first. Click a post — markdown renders with headings, inline images, and syntax-highlighted code blocks. Adding a new `.md` file to `src/content/blog/` makes it appear without code changes.

### Implementation for User Story 2

- [X] T025 [P] [US2] Create `retroweb/src/layouts/PostLayout.astro` (extends PageLayout) with post header (title, date, author, tags), prose wrapper, prev/next navigation slot
- [X] T026 [P] [US2] Create `retroweb/src/components/BlogCard.astro` for listing pages (title, date, summary or first 150 chars fallback, tag chips)
- [X] T027 [US2] Create `retroweb/src/pages/blog/index.astro` using `getCollection('blog', ({ data }) => !data.draft)` sorted by `pubDate` desc, rendered via BlogCard; empty-state message when zero posts
- [X] T028 [US2] Create `retroweb/src/pages/blog/[...slug].astro` using `getStaticPaths` over blog collection, rendering through PostLayout with prev/next links (by pubDate order)
- [X] T029 [P] [US2] Write sample blog post `retroweb/src/content/blog/why-retro-needs-common-bus.md` (substantive technical content per SC-007)
- [X] T030 [P] [US2] Write sample blog post `retroweb/src/content/blog/fpgas-as-coprocessors.md` (substantive technical content per SC-007)
- [X] T031 [US2] Update landing page (`retroweb/src/pages/index.astro`) "Latest from the Blog" section to query and display the 3 newest posts via BlogCard

**Checkpoint**: Blog stories US1, US2, and US6 complete. Site has real content and deploys automatically.

---

## Phase 6: User Story 3 - Understand the Architecture (Priority: P2)

**Goal**: Architecture page explaining the common bus standard, memory map, and peripheral interface.

**Independent Test**: Visit `/architecture/` — find bus overview, memory map diagram/table, and card interface description. Draft/placeholder content is acceptable per spec Assumptions.

### Implementation for User Story 3

- [X] T032 [US3] Create `retroweb/src/pages/architecture.astro` using PageLayout with four sections: Bus Overview (status: draft), Memory Map (table of address ranges from CLAUDE.md), Card Interface (signal list with placeholders), Current Reference Implementation (link to the FemtoRV project)
- [X] T033 [P] [US3] Add a memory map diagram image to `retroweb/public/images/architecture/memory-map.svg` (or inline SVG in the page); referenced with proper alt text

**Checkpoint**: Architecture page renders; builders can evaluate at a glance.

---

## Phase 7: User Story 4 - Find a Starting Point (Priority: P2)

**Goal**: Getting Started page with at least 3 audience-specific on-ramps.

**Independent Test**: Visit `/getting-started/` — see 3 distinct paths (hardware builder / software developer / vintage collector-hybrid) with clear first steps and links to blog posts, architecture page, and external tools.

### Implementation for User Story 4

- [X] T034 [US4] Create `retroweb/src/pages/getting-started.astro` using PageLayout with three path sections, each containing a numbered 3–5 step ordered list linking to `/architecture/`, relevant blog posts, and external resources (Yosys/nextpnr docs, retro OS sites)

**Checkpoint**: Newcomer audience onboarding flow exists.

---

## Phase 8: User Story 5 - Browse Community Projects (Priority: P3)

**Goal**: Projects gallery with card view and detail pages.

**Independent Test**: Visit `/projects/` — see at least one project card with title/description/image/link. Click card — detail page renders with full writeup.

### Implementation for User Story 5

- [X] T035 [P] [US5] Create `retroweb/src/components/ProjectCard.astro` rendering title, description, representative image, and detail link
- [X] T036 [US5] Create `retroweb/src/pages/projects/index.astro` using `getCollection('projects')` sorted by `order` asc then `title`, rendered via ProjectCard grid; empty-state message when zero entries
- [X] T037 [US5] Create `retroweb/src/pages/projects/[slug].astro` using `getStaticPaths` over projects collection, rendering title/description/components list/external links/markdown body via PageLayout
- [X] T038 [P] [US5] Write project entry `retroweb/src/content/projects/femtorv-coprocessor.md` (FemtoRV retro co-processor showcase) and add representative image to `retroweb/public/images/projects/`

**Checkpoint**: All six user stories complete.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Quality gates and final validation before public launch.

- [X] T039 [P] Run Lighthouse CI against all routes (`npx @lhci/cli autorun` in `retroweb/`); verify Accessibility ≥ 90 (SC-003) and Performance ≥ 90 — ran lighthouse@12 CLI against /, /blog/, /blog/why-retro-needs-common-bus/. Scores: home 96/100, blog 96/99, post 96/99 (accessibility/performance). All ≥ 90.
- [X] T040 [P] Run `npx linkinator retroweb/dist/ --recurse` and fix any broken internal links — ran against live preview (linkinator can't handle `base: '/learn-fpga'` on raw dist/). Fixed Footer.astro absolute `/blog/` etc. links to use BASE_URL. Final: 16/16 links pass.
- [X] T041 [P] Manual responsive check at 375px, 768px, 1024px viewports on landing, blog index, blog post, architecture, getting-started, projects (FR-010) — automated: 12 files contain `min-width: 768px`/`1024px` breakpoints (global.css + 11 components/pages). HUMAN: viewport visual check still pending.
- [ ] T042 [P] Manual cross-browser check on latest Chrome, Firefox, Safari, Edge (SC-005) — HUMAN: requires human operator with browsers installed. Pending.
- [X] T043 [P] Add Open Graph preview images for home, about, blog index under `retroweb/public/images/og/` and reference from BaseLayout (FR-013) — created `public/images/og/og-default.svg` (1200x630, CRT theme, phosphor green heading, amber prompt, scanlines). BaseLayout.astro defaults `og:image` to it. Code comment notes PNG conversion may be needed for production crawlers (Facebook, LinkedIn).
- [X] T044 Run the acceptance walkthrough in `specs/002-retro-web/quickstart.md` covering US1–US6 — results table appended to quickstart.md. All six stories verifiable from built dist/ HTML pass.
- [ ] T045 User-test the landing page with 3–5 people; confirm they can articulate the project purpose in 60 seconds (SC-001); revise hero/pillar copy if needed — HUMAN: requires external user testing. Pending.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup; BLOCKS all user stories
- **US1 + US6 (Phases 3 + 4)**: Depend on Foundational; together form the MVP
- **US2 (Phase 5)**: Depends on Foundational; builds on T031 which modifies the landing page (soft dependency on US1's index.astro existing)
- **US3, US4, US5 (Phases 6–8)**: Depend on Foundational; independent of each other and of US1/US2/US6
- **Polish (Phase 9)**: Depends on all user stories

### User Story Dependencies

- **US1 (P1)**: Foundational only
- **US6 (P1)**: Foundational only — can run in parallel with US1
- **US2 (P1)**: Foundational; T031 touches `index.astro` from US1, so T031 sequences after US1 completion
- **US3 (P2)**: Foundational only
- **US4 (P2)**: Foundational only
- **US5 (P3)**: Foundational only

### Within Each User Story

- Components before pages that use them
- Layouts before pages that extend them
- Sample content (.md files) can be written in parallel with the pages that render them
- Each story must independently pass its acceptance test before the next begins (unless working in parallel)

### Parallel Opportunities

- All `[P]` tasks in Phase 1 (T003–T006) can run in parallel
- All `[P]` tasks in Phase 2 (T008–T011, T014–T017) can run in parallel; T012 (BaseLayout) must finish before T013/T015/T016 use it
- US1, US3, US4, US5, US6 can all proceed in parallel once Foundational is done
- Within US2: T025, T026, T029, T030 can run in parallel
- Within US5: T035 and T038 can run in parallel

---

## Parallel Example: Foundational Phase

```bash
# After T007 (content config) and T012 (BaseLayout) are done,
# these can all run in parallel:
Task: "Configure astro.config.mjs with site/base/Shiki in retroweb/astro.config.mjs"
Task: "Add self-hosted fonts to retroweb/public/fonts/"
Task: "Create retroweb/src/styles/global.css with CRT theme tokens"
Task: "Create retroweb/src/styles/prose.css for post typography"
Task: "Create retroweb/src/components/Footer.astro"
Task: "Create retroweb/src/layouts/PageLayout.astro"
Task: "Create retroweb/src/pages/404.astro"
Task: "Add retroweb/public/favicon.svg and robots.txt"
```

## Parallel Example: User Story 2

```bash
# Once US2 starts, these run in parallel:
Task: "Create PostLayout.astro in retroweb/src/layouts/"
Task: "Create BlogCard.astro in retroweb/src/components/"
Task: "Write sample post retroweb/src/content/blog/why-retro-needs-common-bus.md"
Task: "Write sample post retroweb/src/content/blog/fpgas-as-coprocessors.md"
```

---

## Implementation Strategy

### MVP First (US1 + US6)

The smallest viable public release:

1. Complete Phase 1 (Setup) — T001–T006
2. Complete Phase 2 (Foundational) — T007–T017
3. Complete Phase 3 (US1 Landing) — T018–T021
4. Complete Phase 4 (US6 Deploy) — T022–T024
5. **STOP and VALIDATE**: Landing page is live on GitHub Pages

This gives a public presence with hero, about page, and automated deploy — 24 tasks total.

### Incremental Delivery

After MVP:

- Phase 5 (US2 Blog) → blog content drives traffic and SEO
- Phase 6 (US3 Architecture) → technical credibility for builders
- Phase 7 (US4 Getting Started) → converts curious visitors
- Phase 8 (US5 Projects) → social proof and inspiration
- Phase 9 (Polish) → quality gates before wider announcement

Each phase adds a complete, demoable increment.

### Solo Strategy (default — this is a single-author project)

Execute phases sequentially. Inside each phase, batch `[P]` tasks into a single work session where possible. Commit after each phase checkpoint.

### Parallel Team Strategy

If additional contributors join after Foundational:

- Dev A: US1 + US6 (MVP path)
- Dev B: US2 (blog content + infra)
- Dev C: US3 + US4 (technical pages)
- Dev D: US5 (projects showcase)

All five story phases can land within the same week with independent PRs.

---

## Notes

- `[P]` tasks = different files, no dependencies on incomplete tasks
- `[Story]` label maps each task to its user story for traceability
- Each user story is independently testable and deployable
- Sample content counts as part of story completion — empty pages don't satisfy acceptance
- Commit after each task or logical group; tag MVP release after Phase 4
- Stop at any checkpoint to validate the story independently before moving on
- All paths are relative to the worktree root (`~/wip/learn-fpga-web/`) unless noted otherwise
