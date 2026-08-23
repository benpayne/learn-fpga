# Phase 0 Research: Retro-Active Website

**Feature**: 002-retro-web  
**Date**: 2026-04-19

## Unknowns from Technical Context

The feature spec is clear on WHAT but leaves framework-level decisions open. This research resolves the HOW.

## Decisions

### 1. Framework & Version

**Decision**: Astro 6.1.x (latest stable, released March 2026)

**Rationale**:
- User explicitly requested Astro 6
- Zero-JS-by-default matches the content-heavy nature of this site
- First-class Markdown + content collections support perfect for blog/project entries
- Mature GitHub Pages deployment path
- Requires Node 22+

**Alternatives considered**:
- Astro 5.x — superseded
- Hugo/Jekyll — less flexible templating
- Next.js — overkill, ships too much JS for a static marketing site

### 2. Content Authoring

**Decision**: Astro Content Collections with Zod schemas

**Rationale**:
- Defines typed frontmatter for blog posts and projects via `src/content.config.ts`
- Automatic TypeScript interfaces and frontmatter validation at build time
- Authors add `.md` files only; no code changes per post (satisfies FR-004, SC-004)
- Supports tags and dates natively

**Alternatives considered**:
- Plain Markdown imports — no schema validation
- MDX — unneeded complexity for initial scope; can add later

### 3. Syntax Highlighting

**Decision**: Shiki (Astro's default), theme `github-dark`

**Rationale**:
- Server-rendered at build time — zero runtime JS
- 100+ languages including Verilog, C, Python
- Matches CRT/terminal aesthetic naturally
- No plugin required

**Alternatives considered**:
- Prism — requires client JS unless manually pre-rendered
- Highlight.js — similar tradeoffs to Prism

### 4. Styling Approach

**Decision**: Global CSS for theme tokens + scoped `<style>` blocks per component

**Rationale**:
- CSS custom properties (variables) defined in `src/styles/global.css` for the CRT/terminal palette
- Scoped styles per `.astro` component prevent leakage
- No CSS framework needed — keeps output small and aesthetic fully custom
- Monospace fonts via web fonts (IBM Plex Mono, JetBrains Mono) loaded from `public/fonts/`

**Alternatives considered**:
- Tailwind — unnecessary for a small site with a bespoke look
- CSS Modules — scoped styles in `.astro` files serve the same purpose natively

### 5. Color Palette (for WCAG AA compliance)

**Decision**:
- Background: `#0a0e12` (near-black)
- Primary text: `#d4e4d2` (off-white, 15:1 contrast)
- Accent (green terminal): `#39ff14` or `#7fff7f` for links/headers
- Accent (amber alternative): `#ffb000` for emphasis
- Muted: `#5a6f5a` for metadata

**Rationale**: All combinations pass WCAG AA (4.5:1 for body text, 3:1 for large text). Green primary evokes phosphor CRT; amber available for variety.

### 6. Deployment

**Decision**: GitHub Actions workflow building to GitHub Pages, project-style path (`username.github.io/learn-fpga/`)

**Rationale**:
- Matches stated FR-011 and SC-006
- Use `@astrojs/github-pages` adapter or Astro's built-in static build + `actions/deploy-pages`
- Set `site: 'https://<user>.github.io'` and `base: '/learn-fpga'` in astro.config.mjs
- Custom domain deferred (can be added later by dropping CNAME file)

**Alternatives considered**:
- Netlify/Vercel — unnecessary; project is already on GitHub
- Self-hosted — adds operational burden

### 7. Font & Typography

**Decision**:
- Headings: `IBM Plex Mono` or `JetBrains Mono` (monospace, terminal feel)
- Body: `Inter` or `IBM Plex Sans` (readable for long-form)
- Code: `JetBrains Mono` or `Fira Code`

**Rationale**: Mix keeps terminal aesthetic in headers while body text stays readable for long blog posts. Self-host fonts in `public/fonts/` for privacy and performance.

### 8. Site Structure within `retroweb/`

**Decision**:
```
retroweb/
├── astro.config.mjs
├── package.json
├── tsconfig.json
├── src/
│   ├── content.config.ts
│   ├── content/
│   │   ├── blog/
│   │   └── projects/
│   ├── pages/
│   ├── layouts/
│   ├── components/
│   └── styles/
└── public/
    ├── fonts/
    └── images/
```

**Rationale**: Standard Astro layout, self-contained as required by FR-015.

### 9. Testing Strategy

**Decision**: Manual visual testing + Lighthouse CI + link checker

**Rationale**:
- Static marketing site doesn't need unit tests
- Lighthouse CI enforces SC-002 (load time) and SC-003 (accessibility ≥90)
- `lychee` or `linkinator` catches broken internal links on build

**Alternatives considered**:
- Playwright — overkill for a static site
- Unit tests — nothing meaningfully unit-testable in templates

## No Remaining NEEDS CLARIFICATION

All unknowns resolved. Ready for Phase 1.
