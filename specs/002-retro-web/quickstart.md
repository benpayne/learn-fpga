# Quickstart: Retro-Active Website

**Feature**: 002-retro-web  
**Audience**: Site maintainer / content author

## Prerequisites

- Node.js 22+ (`node --version`)
- npm 10+
- Git

## Initial Setup

```bash
# From the worktree root
cd ~/wip/learn-fpga-web/retroweb

# Install dependencies
npm install

# Start dev server (hot reload)
npm run dev
# → http://localhost:4321
```

## Common Tasks

### Add a blog post

1. Create `src/content/blog/my-post.md`
2. Add frontmatter:
   ```yaml
   ---
   title: "My Post Title"
   pubDate: 2026-04-20
   summary: "One-line hook."
   tags: [fpga, verilog]
   ---
   ```
3. Write markdown body.
4. Save — dev server hot-reloads.
5. Post appears automatically on `/blog/` and at `/blog/my-post/`.

### Add a project

1. Create `src/content/projects/my-project.md`
2. Add frontmatter (see `contracts/content-schemas.md` for full schema)
3. Add representative image to `public/images/projects/`
4. Save.

### Build for production

```bash
npm run build
# Output: retroweb/dist/
```

### Preview production build locally

```bash
npm run preview
```

### Deploy to GitHub Pages

Automatic on push to `master` via `.github/workflows/deploy-retroweb.yml`. Manual trigger:

```bash
gh workflow run deploy-retroweb.yml
```

## Acceptance Walkthrough (maps to User Stories)

Run these manually after `npm run dev` to validate the spec:

1. **US1 (Landing)**: Visit `/` — hero visible, pillars section present, nav has all 6 links.
2. **US2 (Blog)**: Visit `/blog/` — see post list. Click a post — full article renders with code highlighting.
3. **US3 (Architecture)**: Visit `/architecture/` — bus overview + memory map visible.
4. **US4 (Getting Started)**: Visit `/getting-started/` — 3 audience paths shown.
5. **US5 (Projects)**: Visit `/projects/` — at least one project card, clickable to detail.
6. **US6 (Deploy)**: `npm run build` succeeds; `dist/` contains HTML for all routes.

## Quality Gates

```bash
# Accessibility + performance (target: 90+ on each)
npx @lhci/cli autorun

# Broken link check
npx linkinator dist/
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Build fails on content schema | Check frontmatter matches `src/content.config.ts` |
| Images broken in production | Use `image()` helper from schema, not raw `/images/` paths |
| Wrong base path on deploy | Verify `base` in `astro.config.mjs` matches repo name |

## Deployment Status

- **Status**: Pending first deploy (requires push to remote + Pages enablement).
- **Expected URL**: https://benpayne.github.io/learn-fpga/
- **Workflow**: `.github/workflows/deploy-retroweb.yml`

### Human verification checklist

- [ ] Push changes to `origin/master`.
- [ ] Enable GitHub Pages (**Settings → Pages → Source: GitHub Actions**).
- [ ] Workflow **"Deploy Retro-Active website"** runs green.
- [ ] Landing page loads at the expected URL.

---

## Polish Results (Phase 9)

Recorded 2026-04-19 after running Phase 9 automated tasks.

### Build

`npm run build` produces 10 static pages, no errors, ~1.8 s build time. Four
font-preload warnings (inter-400, inter-700, jetbrains-mono-400, and
plex-mono variants) are expected — Vite flags them because font binaries are
resolved at runtime, not build time. Cosmetic only.

### Lighthouse (SC-002, SC-003)

Ran `lighthouse@12` against a local `astro preview` server
(127.0.0.1:4321) with `--headless --no-sandbox`, only
accessibility+performance categories.

| Page                                            | Accessibility | Performance | Target |
|-------------------------------------------------|:-------------:|:-----------:|:------:|
| `/learn-fpga/`                                  |      96       |     100     | ≥ 90   |
| `/learn-fpga/blog/`                             |      96       |      99     | ≥ 90   |
| `/learn-fpga/blog/why-retro-needs-common-bus/`  |      96       |      99     | ≥ 90   |

All three pages exceed the 90-point bar for both categories. **PASS.**

### linkinator (internal link check)

Initial run surfaced three absolute `/blog/`, `/architecture/`,
`/getting-started/` links in `src/components/Footer.astro` that bypassed the
`/learn-fpga` base path. Fixed to use `${base}` like the other components.
Post-fix run: **16/16 links scanned, 0 broken.**

Note: `linkinator dist/` on the raw filesystem reports many false-positive
404s because the `base: '/learn-fpga'` config makes every link look like
`dist/learn-fpga/...` which does not exist on disk. Running against the
preview server (`http://127.0.0.1:4321/learn-fpga/`) is the correct
approach for this project.

### Responsive breakpoints (T041, automated portion)

`grep` confirms 12 source files (global.css + 11 components/pages) contain
`min-width: 768px` or `min-width: 1024px` media queries — the two
non-mobile breakpoints declared in `global.css`.

### Open Graph

- `public/images/og/og-default.svg` created (1200×630, CRT terminal
  theme: phosphor-green heading, amber `>_` prompt, scanline pattern,
  dashed border).
- `BaseLayout.astro` now defaults `og:image` to that SVG via `BASE_URL`.
  A code comment documents that many crawlers (Facebook, LinkedIn) prefer
  PNG/JPG, so a production deployment may want to convert the SVG to PNG
  (e.g. `rsvg-convert` or `sharp`).

### Acceptance walkthrough (T044, US1-US6)

Checks run against `retroweb/dist/` after `npm run build`.

| Story | Check                                                                 | Result |
|-------|-----------------------------------------------------------------------|:------:|
| US1   | `dist/index.html` contains "Retro-Active" and four pillars (Build/Share/Run/Connect) — 7 matches | PASS |
| US2   | `dist/blog/index.html` exists; two post dirs (`why-retro-needs-common-bus`, `fpgas-as-coprocessors`) present; sample post has two `astro-code` syntax-highlighted blocks (Shiki) | PASS |
| US3   | `dist/architecture/index.html` contains "Bus Overview" and memory-map addresses (`0x000000`, `0x400000`, `0x800000`) — 4 matches | PASS |
| US4   | `dist/getting-started/index.html` contains all three on-ramp paths — "build hardware", "write software", "vintage" (7 matches). Note: the spec originally said "Hardware Builder" / "Software Developer"; the final copy uses sentence-style "I want to build hardware" / "I want to write software". Intent is preserved. | PASS |
| US5   | `dist/projects/index.html` and `dist/projects/femtorv-coprocessor/index.html` both present | PASS |
| US6   | `.github/workflows/deploy-retroweb.yml` exists at repo root | PASS |

### Pending human verification

The following cannot be automated and are still open:

- **T041 (viewport visual check)** — responsive breakpoints are wired, but a
  human should resize Chrome/Firefox at 375/768/1024 and verify each page
  renders without overflow or layout breakage.
- **T042 (cross-browser)** — needs a human with Chrome, Firefox, Safari,
  and Edge to spot-check the six main pages.
- **T045 (user test)** — 3–5 people should read the landing page for 60
  seconds and then articulate what Retro-Active is. Revise hero/pillar
  copy if most miss the mark.
- [ ] Update this section of `quickstart.md` with the confirmed live URL once verified.
