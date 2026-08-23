# Phase 1 Data Model: Retro-Active Website

**Feature**: 002-retro-web  
**Date**: 2026-04-19

## Overview

This is a static site — "data" means content collection schemas (Zod) validated at build time, not database tables.

## Entities

### Blog Post

**Location**: `src/content/blog/<slug>.md`

**Frontmatter Schema (Zod)**:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `title` | string | yes | Display title |
| `pubDate` | Date | yes | Publication date (ISO 8601) |
| `updatedDate` | Date | no | Last update |
| `summary` | string | no | 1-2 sentence teaser; fallback = first 150 chars of body |
| `author` | string | no | Default: "Ben Payne" |
| `tags` | string[] | no | e.g. ["fpga", "verilog"] |
| `heroImage` | string | no | Path to cover image in `public/images/` |
| `draft` | boolean | no | Default false; drafts excluded from production build |

**Body**: Markdown with code blocks, images, diagrams.

**Validation rules**:
- `pubDate` must be parseable as a Date
- `tags` lowercase, kebab-case enforced by schema transform
- `heroImage`, if present, must start with `/images/`

**Ordering**: Reverse chronological by `pubDate` on listing pages.

**State**: `draft: true` → excluded from production build; visible in dev server only.

---

### Project

**Location**: `src/content/projects/<slug>.md`

**Frontmatter Schema**:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `title` | string | yes | Project name |
| `description` | string | yes | Short (<200 chars) description for card view |
| `image` | string | yes | Representative image path |
| `components` | string[] | no | Hardware/software used |
| `links` | `{label, url}[]` | no | External refs (GitHub, blog post, video) |
| `order` | number | no | Manual ordering; lower = first |

**Body**: Markdown detail for project page.

**Validation rules**:
- `image` must start with `/images/`
- `links[].url` must be a valid absolute URL

---

### Tag (derived)

**Not a content file** — derived from the union of all `tags` fields across blog posts at build time.

**Attributes**:
- `name`: string (kebab-case)
- `posts`: Blog Post[] (computed)

**Usage**: Future filtering page (post-MVP).

---

### Page (static)

**Location**: `src/pages/*.astro`

**Not content-collection-backed** — these are hand-written Astro components:

| Page | Path | Source |
|------|------|--------|
| Landing | `/` | `src/pages/index.astro` |
| About | `/about/` | `src/pages/about.astro` |
| Architecture | `/architecture/` | `src/pages/architecture.astro` |
| Getting Started | `/getting-started/` | `src/pages/getting-started.astro` |
| Projects index | `/projects/` | `src/pages/projects/index.astro` |
| Project detail | `/projects/[slug]/` | `src/pages/projects/[slug].astro` |
| Blog index | `/blog/` | `src/pages/blog/index.astro` |
| Blog post | `/blog/[slug]/` | `src/pages/blog/[...slug].astro` |
| 404 | `/404/` | `src/pages/404.astro` |

## Relationships

```
Blog Post ──has──► Tags (string[])
Tag ──aggregates──► Blog Posts (computed)
Project ──has──► Links
Page ──references──► Blog Posts / Projects (via content collection queries)
```

## Build-Time Queries

- `getCollection('blog', ({ data }) => !data.draft)` → Blog index, sorted by `pubDate` desc
- `getCollection('projects')` → Projects index, sorted by `order` asc then `title`
- All unique `tags` → Tag pages (future)
