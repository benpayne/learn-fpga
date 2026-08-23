import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://benpayne.github.io',
  base: '/learn-fpga',
  trailingSlash: 'always',
  markdown: {
    shikiConfig: {
      theme: 'github-dark',
      wrap: true,
    },
  },
});
