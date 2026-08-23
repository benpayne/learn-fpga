# Retro-Active Website

Static Astro 6 site for the retro computing co-processor community.

See [specs/002-retro-web/quickstart.md](../specs/002-retro-web/quickstart.md) for setup and maintenance instructions.

## Quick commands

```bash
cd retroweb
npm install
npm run dev      # http://localhost:4321
npm run build    # output to dist/
npm run preview
```

## Deployment

The site is deployed to GitHub Pages via GitHub Actions.

- **Workflow**: [`.github/workflows/deploy-retroweb.yml`](../.github/workflows/deploy-retroweb.yml) (at the repo root). It runs on every push to `master` or `main` that touches `retroweb/**` (or the workflow file itself), and can also be triggered manually via `workflow_dispatch`.
- **Pipeline**: `npm ci` → `npm run build` in `retroweb/` → upload `retroweb/dist/` as a Pages artifact → deploy.
- **Target URL**: https://benpayne.github.io/learn-fpga/
- **Base path**: `astro.config.mjs` sets `base: '/learn-fpga'` so generated links resolve correctly under the repo-name subpath.

### Manual setup step (one-time)

The repository owner must enable GitHub Pages in the repository settings before the first deploy will succeed:

1. Open **Settings → Pages**.
2. Under **Build and deployment → Source**, select **GitHub Actions**.
3. Push to `master` (or run the workflow manually) to trigger the first build and deploy.

### Custom domain (optional)

To serve the site from a custom domain instead of `benpayne.github.io/learn-fpga/`:

1. Add a `CNAME` file containing the hostname to `retroweb/public/` (it will be copied to `dist/CNAME` on build).
2. Update `site:` in `astro.config.mjs` to the custom origin and either drop or adjust `base` to match the domain's path.
3. Configure the DNS records and custom-domain field under **Settings → Pages**.

