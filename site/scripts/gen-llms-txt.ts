#!/usr/bin/env bun
/**
 * Render `public/llms.txt` from the repository's `llms.txt` so pulshealth.com
 * serves it at https://pulshealth.com/llms.txt.
 *
 * The repository file is the one source (`copy-blog-images` is the same
 * arrangement for `../blog/images`). Its links are repo-relative Markdown
 * links, which mean nothing once the file is served from the site, so each
 * one is rewritten the way `resolveRepoLink` in `src/lib/markdown.tsx`
 * rewrites links inside a rendered document: to the page on pulshealth.com
 * when the docs manifest (`src/lib/docs.ts`) renders that file, otherwise to
 * the file on GitHub. Absolute URLs pass through untouched.
 *
 * Runs before every dev run and build (`predev`, `prebuild` in package.json);
 * the output is gitignored. `bun scripts/gen-llms-txt.ts` runs it by hand.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { docRoutes } from "../src/lib/docs";

const SITE_URL = "https://pulshealth.com";
const GITHUB_BLOB = "https://github.com/PulsHealth/pulshealth/blob/main";

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = path.join(siteDir, "..", "llms.txt");
const target = path.join(siteDir, "public", "llms.txt");

/** A repo-relative link target → its absolute URL once served from the site. */
function resolveLlmsLink(href: string): string {
  if (/^(https?:|mailto:|#)/.test(href)) return href;
  const [file, hash] = href.split("#");
  const resolved = path.posix.normalize(file);
  const route = docRoutes[resolved];
  const url = route ? `${SITE_URL}${route}` : `${GITHUB_BLOB}/${resolved}`;
  return hash ? `${url}#${hash}` : url;
}

/** Rewrite every `[text](target)` Markdown link; code spans and bare URLs are left alone. */
function renderLlmsTxt(markdown: string): string {
  return markdown.replace(/\[([^\]]*)\]\(([^)\s]+)\)/g, (_match, text: string, href: string) => `[${text}](${resolveLlmsLink(href)})`);
}

let markdown: string;
try {
  markdown = fs.readFileSync(source, "utf8");
} catch (error) {
  console.error(`gen-llms-txt: repository llms.txt not found at ${source}`, error);
  process.exit(1);
}
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, renderLlmsTxt(markdown));
const links = markdown.match(/\]\([^)\s]+\)/g)?.length ?? 0;
console.log(`gen-llms-txt: wrote ${path.relative(siteDir, target)} (${links} links rewritten)`);
