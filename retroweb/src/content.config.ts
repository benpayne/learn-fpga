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
    // url accepts either an absolute URL (https://...) or a site-relative
    // path (/learn-fpga/...) so projects can link to other content on the site.
    links: z.array(z.object({
      label: z.string(),
      url: z.string().refine(
        (s) => /^https?:\/\//.test(s) || s.startsWith('/'),
        { message: 'must be an absolute URL or a path starting with /' },
      ),
    })).optional(),
    order: z.number().default(100),
  }),
});

export const collections = { blog, projects };
