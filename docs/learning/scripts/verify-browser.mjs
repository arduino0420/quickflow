import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { mkdirSync, readFileSync, existsSync } from 'node:fs';
import assert from 'node:assert/strict';
import { load } from 'cheerio';
import { siteRoot, repoRoot } from './build-site.mjs';

// Migration keeps every explanatory sentence, table and code block from the original page.
const old = load(readFileSync(join(repoRoot, 'assignment_explainer.html'), 'utf8'));
const migrated = load(readFileSync(join(siteRoot, 'dist/articles/issue-11-assignment-creation.html'), 'utf8'));
const normalize = (s) => s.replace(/\s+/g, ' ').trim();
assert(normalize(migrated('main').text()).includes(normalize(old('main').text())), 'Migration omitted original explanatory content');
mkdirSync(join(siteRoot, '.tmp'), { recursive: true });
const chromePath = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const executablePath = process.env.LEARNING_BROWSER_EXECUTABLE ?? (existsSync(chromePath) ? chromePath : undefined);
const browser = await chromium.launch({ headless: true, executablePath });
try {
  for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
    const page = await browser.newPage({ viewport });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(pathToFileURL(join(siteRoot, 'dist/index.html')).href);
    await page.screenshot({ path: join(siteRoot, '.tmp', `index-${viewport.width}.png`), fullPage: true });
    await page.getByRole('link', { name: /教師の小テスト登録/ }).click();
    await page.getByRole('heading', { name: '教師の小テスト登録は、どう動く？', exact: true }).waitFor();
    assert.equal(await page.locator('.flow li').count(), 14);
    assert.equal(await page.locator('section').count(), 9);
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'Page overflows viewport');
    await page.screenshot({ path: join(siteRoot, '.tmp', `article-top-${viewport.width}.png`) });
    await page.getByRole('link', { name: '保存までの一本道' }).click();
    assert(page.url().endsWith('#flow'));
    await page.screenshot({ path: join(siteRoot, '.tmp', `article-${viewport.width}.png`), fullPage: true });
    await page.getByRole('link', { name: '← 記事一覧へ' }).click();
    assert(page.url().endsWith('/index.html'));
    assert.deepEqual(errors, []);
    await page.close();
  }
  console.log('Browser checks passed: full migration, index/article navigation, anchors, 1280px and 390px layout, no page errors.');
} finally { await browser.close(); }
