# pulshealth.com — marketing site

Next.js (App Router, static export) site for pulshealth.com: the product
pages, the blog, and the HealthKit knowledge-base viewer. It is a separate
thing from [`web/`](../web/README.md), which is the self-hosted viewer that
reads your own Postgres.

It reads content from the **repository around it**, by relative path, so
`site/` and the things it reads must stay where they are:

| Source | Read by | How |
|---|---|---|
| [`../knowledge-base/`](../knowledge-base/README.md) | `src/lib/api.ts` | `path.join(process.cwd(), "..", "knowledge-base")` — 178 YAML type files become `/knowledge-base/types/<slug>/` |
| [`../blog/`](../blog/BLOG_SYSTEM.md) | `src/lib/blog.ts`, `package.json` | `../blog/articles/*.mdx` become `/blog/<slug>/`; `copy-blog-images` copies `../blog/images` into `public/blog/` before every dev run and build |
| [`../llms.txt`](../llms.txt) | `scripts/gen-llms-txt.ts`, `package.json` | `gen-llms-txt` renders it to `public/llms.txt` before every dev run and build, so the site serves it at `/llms.txt`. Its repo-relative Markdown links are rewritten the way links inside a rendered document are: to `https://pulshealth.com/docs/<slug>/` for a file in the docs manifest below, otherwise to the file on GitHub; absolute URLs pass through. The output is gitignored; the repository file is the only source |
| Eleven Markdown documents: `server/README.md`, `docs/protocol/README.md`, `docs/database-guide.md`, `docs/export.md`, `docs/ai.md`, `server/mcp/README.md`, `web/README.md`, `PulsHealthSync/README.md`, `SECURITY.md`, `CHANGELOG.md`, `docs/roadmap.md` (and `docs/privacy-policy.md` for `/privacy`) | `src/lib/docs.ts` (the registry), `src/lib/markdown.tsx` (the renderer) | Each becomes `/docs/<slug>/`, rendered at build time from the file itself. Relative links inside a document resolve to the other rendered documents where there is one, otherwise to the file on GitHub |

Moving `site/` (or anything it reads) breaks the loaders without a build
error — they log "not found" and simply emit fewer pages. The page count is
the tell: a full build exports **214** static pages, 178 of them under
`knowledge-base/types/` and 11 under `docs/`. (The one exception is
`llms.txt`: `gen-llms-txt` fails the build when the repository file is
missing, since there is no page count to notice it by.) The `site` job in
`.github/workflows/ci.yml` asserts the counts and that `out/llms.txt` exists.

Two of those pages are not PulsHealth: `/fun100/` and `/fun100/privacy/` are
the App Store support and privacy-policy URLs for Fun100, a separate app by
the same developer. They are unlisted (not in the navigation, search or
sitemap); the policy is `content/fun100/privacy-policy.md`, rendered the same
way as `/privacy`.

## Develop

```bash
cd site
bun install
bun run dev        # localhost:3000
```

## Build and lint

```bash
bun run build      # static export to site/out/ (214 pages)
bun run lint       # ESLint (2 known warnings, no errors)
```

`make site-dev`, `make site-build` and `make site-lint` from the repository
root do the same.

## Deploy

```bash
scripts/deploy-site.sh    # or: make deploy-site
```

Builds, syncs `out/` to the `pulshealth.com` S3 bucket and invalidates the
CloudFront distribution. Needs AWS credentials with rights to both; run it
from anywhere, it locates the repository itself.

## Configuration

`.env.production` carries the one public build-time value, the endpoint the
two forms post to, and is tracked, since a static export bakes it into the
HTML anyway. `.env.example` documents it for a local `.env.local`. The site
loads no analytics and sets no cookies; `docs/privacy-policy.md` says so in
its website section, and `/privacy` renders that file, so keep the two true
together.
