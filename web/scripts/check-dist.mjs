// Post-build checks for web/dist, run in CI and by the release build.
//  - index.html has no inline <script> or <style> (a strict CSP would block them)
//  - index.html contains the <div id="root"> mount point
//  - total gzipped JS + CSS stays under the 200 KB budget
// It prints the hashed asset file names, which cutover gate G6 compares across stacks.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const dist = new URL("../dist/", import.meta.url).pathname;
const BUDGET_BYTES = 200 * 1024;
const problems = [];

const html = readFileSync(join(dist, "index.html"), "utf8");
if (!html.includes('<div id="root">')) problems.push('index.html is missing <div id="root">');
for (const match of html.matchAll(/<script\b([^>]*)>/gi)) {
  if (!/\bsrc=/.test(match[1])) problems.push("index.html has an inline <script>");
}
if (/<style\b/i.test(html)) problems.push("index.html has an inline <style>");
if (/\sstyle=/i.test(html)) problems.push("index.html has an inline style attribute");
if (/https?:\/\//i.test(html.replace(/<!doctype[^>]*>/i, ""))) {
  problems.push("index.html references an external URL");
}

const assets = readdirSync(join(dist, "assets")).sort();
let gzipped = 0;
for (const name of assets) {
  if (!/\.(js|css)$/.test(name)) continue;
  gzipped += gzipSync(readFileSync(join(dist, "assets", name))).length;
}
if (gzipped > BUDGET_BYTES) {
  problems.push(`bundle is ${gzipped} bytes gzipped; budget is ${BUDGET_BYTES}`);
}

console.log(`gzipped JS+CSS: ${(gzipped / 1024).toFixed(1)} KB (budget ${BUDGET_BYTES / 1024} KB)`);
for (const name of assets) console.log(`asset ${name}`);

if (problems.length > 0) {
  for (const problem of problems) console.error(`FAIL: ${problem}`);
  process.exit(1);
}
