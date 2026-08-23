# Content Collection Contracts

**Feature**: 002-retro-web  
**Purpose**: Define the Zod schemas that validate content at build time — the "contract" between content authors and the site.

## Blog Collection Schema

```typescript
// src/content.config.ts
import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: ({ image }) => z.object({
    title: z.string().min(1).max(120),
    pubDate: z.date(),
    updatedDate: z.date().optional(),
    summary: z.string().max(300).optional(),
    author: z.string().default('Ben Payne'),
    tags: z.array(z.string().regex(/^[a-z0-9-]+$/)).default([]),
    heroImage: image().optional(),
    draft: z.boolean().default(false),
  }),
});

const projects = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/projects' }),
  schema: ({ image }) => z.object({
    title: z.string().min(1).max(120),
    description: z.string().max(200),
    image: image(),
    components: z.array(z.string()).optional(),
    links: z.array(z.object({
      label: z.string(),
      url: z.string().url(),
    })).optional(),
    order: z.number().default(100),
  }),
});

export const collections = { blog, projects };
```

## Example Blog Post

```markdown
---
title: "Why Retro Computing Needs a Common Bus"
pubDate: 2026-04-20
summary: "Every retro builder reinvents the wheel. Here's how a shared bus standard changes that."
tags: [community, architecture, bus-standard]
heroImage: "../../../public/images/blog/common-bus-hero.png"
---

# Why Retro Computing Needs a Common Bus

Intro paragraph here...
```

## Example Project Entry

```markdown
---
title: "FemtoRV Retro Co-Processor"
description: "A RISC-V co-processor for vintage computers — HDMI, PS2, FM synth, SD card."
image: "../../../public/images/projects/femtorv-board.jpg"
components:
  - "Colorlight i5 (ECP5 FPGA)"
  - "FemtoRV petitbateau (RV32IMFC)"
  - "8MB SDRAM"
links:
  - label: "GitHub"
    url: "https://github.com/benpayne/learn-fpga"
order: 1
---

Longer project writeup...
```

## Build-Time Validation

Astro runs these schemas at `astro build`. A missing required field or invalid type fails the build with a clear error message, preventing broken content from deploying.

## URL Contract

| Collection | URL Pattern | Source |
|------------|-------------|--------|
| Blog post | `/blog/<slug>/` | `src/content/blog/<slug>.md` |
| Project | `/projects/<slug>/` | `src/content/projects/<slug>.md` |

Slugs are derived from the filename (without `.md`) and must be kebab-case.

## Deployment Contract

- Build output: `retroweb/dist/`
- Deploy target: GitHub Pages via `actions/deploy-pages@v4`
- Base path: `/learn-fpga` (project page) unless custom domain set
- Site URL: configured in `astro.config.mjs` via `site` + `base`
