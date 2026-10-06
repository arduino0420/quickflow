import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { mkdirSync, readFileSync, existsSync } from 'node:fs';
import assert from 'node:assert/strict';
import { siteRoot } from './build-site.mjs';

// Verify the current article using its metadata, without old migration assumptions.
const metadata = JSON.parse(readFileSync(join(siteRoot, 'articles/issue-11-assignment-creation/metadata.json'), 'utf8'));
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
    await page.locator(`a[href="articles/${metadata.id}.html"]`).click();
    await page.getByRole('heading', { name: metadata.title, exact: true }).waitFor();
    assert.equal(await page.locator('details').count(), 5);
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'Page overflows viewport');
    await page.screenshot({ path: join(siteRoot, '.tmp', `article-top-${viewport.width}.png`) });
    await page.getByRole('heading', { name: '保存と表示の一本道', exact: true }).scrollIntoViewIfNeeded();
    await page.locator('details').first().locator('summary').click();
    await page.screenshot({ path: join(siteRoot, '.tmp', `article-${viewport.width}.png`), fullPage: true });
    await page.getByRole('link', { name: '← 記事一覧へ' }).click();
    assert(page.url().endsWith('/index.html'));
    assert.deepEqual(errors, []);
    await page.close();
  }
  console.log('Browser checks passed: index/article navigation, summary expansion, 1280px and 390px layout, no page errors.');
} finally { await browser.close(); }
