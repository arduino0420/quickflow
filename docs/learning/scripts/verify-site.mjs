import { readFileSync, existsSync } from 'node:fs';
import { resolve, join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { load } from 'cheerio';
import { siteRoot, repoRoot, readArticles, renderSite, hash } from './build-site.mjs';

export function verify(root = siteRoot, repo = repoRoot) {
  const expected = renderSite(root);
  for (const { meta, checks } of readArticles(root)) {
    assert(checks.sourceHashes && Array.isArray(checks.snippets), `Missing checks: ${meta.id}`);
    for (const path of meta.sourceFiles) {
      const file = resolve(repo, path);
      assert(!relative(repo, file).startsWith('..') && file !== repo, `Invalid source path: ${path}`);
      assert.equal(hash(readFileSync(file)), checks.sourceHashes[path], `Source changed: ${path}; reread and update the explanation before refreshing its hash`);
    }
    for (const { path, text } of checks.snippets) {
      assert(meta.sourceFiles.includes(path) && text, `Invalid snippet: ${path}`);
      assert(readFileSync(join(repo, path), 'utf8').includes(text), `Snippet mismatch: ${path}`);
    }
  }
  for (const [path, html] of expected) {
    assert.equal(readFileSync(join(root, 'dist', path), 'utf8'), html, `Stale generated page: ${path}`);
    const $ = load(html);
    assert.equal($('html').attr('lang'), 'ja');
    assert.equal($('h1').length, 1);
    assert.equal($('script, link, iframe, object, embed, base').length, 0, `External/active dependency: ${path}`);
    for (const element of $('*').toArray()) {
      for (const [name, value] of Object.entries(element.attribs ?? {})) {
        assert(!name.startsWith('on'), `Event handler: ${path}`);
        assert(!/javascript:/i.test(value), `Script URL: ${path}`);
      }
    }
    const ids = $('[id]').toArray().map((e) => $(e).attr('id'));
    assert.equal(ids.length, new Set(ids).size, `Duplicate anchor: ${path}`);
    for (const element of $('[href], [src]').toArray()) {
      const url = $(element).attr('href') ?? $(element).attr('src');
      if (/^https?:/.test(url)) continue;
      if (url.startsWith('data:')) continue;
      const [target, anchor] = url.split('#');
      const file = target ? resolve(dirname(join(root, 'dist', path)), target) : join(root, 'dist', path);
      assert(!relative(join(root, 'dist'), file).startsWith('..'), `Link escapes site: ${url}`);
      assert(existsSync(file), `Broken link: ${url}`);
      if (anchor) assert(load(readFileSync(file, 'utf8'))('[id]').toArray().some((e) => e.attribs.id === anchor), `Broken anchor: ${url}`);
    }
  }
  console.log(`Verified ${expected.size} pages: sources, snippets, generated content, links and standalone HTML. Browser layout and Rails behavior are separate checks.`);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) verify();
