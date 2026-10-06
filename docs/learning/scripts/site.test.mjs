import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, cpSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build, siteRoot, repoRoot, readArticles } from './build-site.mjs';
import { verify } from './verify-site.mjs';

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'quickflow-learning-'));
  cpSync(join(siteRoot, 'articles'), join(root, 'articles'), { recursive: true });
  mkdirSync(join(root, 'scripts'));
  cpSync(join(siteRoot, 'scripts/site.css'), join(root, 'scripts/site.css'));
  return root;
}
test('adding a topic creates a page and index link; updating it preserves article identity', () => {
  const root = fixture();
  const initialCount = readArticles(root).length;
  const old = join(root, 'articles/issue-11-assignment-creation');
  const next = join(root, 'articles/teacher-login');
  cpSync(old, next, { recursive: true });
  const meta = JSON.parse(readFileSync(join(next, 'metadata.json'), 'utf8'));
  meta.id = 'teacher-login'; meta.title = '教師ログイン';
  writeFileSync(join(next, 'metadata.json'), JSON.stringify(meta));
  build(root); verify(root, repoRoot);
  assert(readFileSync(join(root, 'dist/index.html'), 'utf8').includes('articles/teacher-login.html'));
  writeFileSync(join(next, 'README.md'), '# 教師ログイン\n\n更新した解説です。');
  build(root); verify(root, repoRoot);
  assert.equal(readArticles(root).length, initialCount + 1);
  assert(readFileSync(join(root, 'dist/articles/teacher-login.html'), 'utf8').includes('更新した解説です。'));
});
test('verification rejects stale pages, broken links and source changes', () => {
  const root = fixture(); build(root);
  writeFileSync(join(root, 'dist/index.html'), 'stale');
  assert.throws(() => verify(root, repoRoot), /Stale generated page/);
  const article = join(root, 'articles/issue-11-assignment-creation');
  writeFileSync(join(article, 'README.md'), '# Topic\n\n[broken](missing.html)');
  build(root); assert.throws(() => verify(root, repoRoot), /Broken link/);
  const checks = JSON.parse(readFileSync(join(article, 'checks.json'), 'utf8'));
  checks.sourceHashes['config/routes.rb'] = 'wrong';
  writeFileSync(join(article, 'checks.json'), JSON.stringify(checks));
  assert.throws(() => verify(root, repoRoot), /Source changed/);
});
