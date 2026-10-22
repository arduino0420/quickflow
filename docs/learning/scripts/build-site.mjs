import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { marked } from 'marked';

export const siteRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const repoRoot = resolve(siteRoot, '../..');
const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
export const hash = (s) => createHash('sha256').update(s).digest('hex');

export function readArticles(root = siteRoot) {
  const articles = readdirSync(join(root, 'articles'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(d.name)) throw new Error(`Invalid article ID: ${d.name}`);
    const dir = join(root, 'articles', d.name);
    const meta = JSON.parse(readFileSync(join(dir, 'metadata.json'), 'utf8'));
    if (meta.id !== d.name || !meta.title || !meta.summary || !/^\d{4}-\d{2}-\d{2}$/.test(meta.updatedAt) || !meta.sourceCommit || !Array.isArray(meta.sourceFiles) || !['limited', 'verified'].includes(meta.verification?.status) || !meta.verification.summary || !Array.isArray(meta.verification.limitations)) throw new Error(`Invalid metadata: ${d.name}`);
    return { dir, meta, source: readFileSync(join(dir, 'README.md'), 'utf8'), checks: JSON.parse(readFileSync(join(dir, 'checks.json'), 'utf8')) };
  });
  return articles.sort((a, b) => b.meta.updatedAt.localeCompare(a.meta.updatedAt) || a.meta.id.localeCompare(b.meta.id));
}

export function renderSite(root = siteRoot) {
  const css = readFileSync(join(root, 'scripts', 'site.css'), 'utf8');
  const articles = readArticles(root);
  const page = (title, body, backlink = '') => `<!doctype html>\n<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)} | QuickFlow学習サイト</title><style>${css}</style></head><body><header><div><div class="eyebrow">QUICKFLOW · LEARNING</div><h1>${escape(title)}</h1>${backlink}</div></header><main>${body}</main><footer>QuickFlowのコードを自分の言葉で説明するための学習資料。Railsから独立した静的サイトです。</footer></body></html>\n`;
  const output = new Map();
  output.set('index.html', page('QuickFlow学習サイト', '<div class="intro"><p>実装した機能の仕組みを、意味・コード・処理の流れで学びます。同じテーマの解説は、この一覧の同じ記事に蓄積されます。</p></div>' + articles.map(({ meta: m }) => `<a class="article-card intro" href="articles/${m.id}.html"><h2>${escape(m.title)}</h2><p>${escape(m.summary)}</p><p class="article-meta">Issue #${escape(m.issue ?? '—')} · 更新 ${escape(m.updatedAt)} · 検証: ${m.verification.status === 'verified' ? '記録された範囲で確認済み' : '未検証事項あり'}</p></a>`).join('')));
  for (const { meta: m, source } of articles) {
    const status = `<aside class="verification" aria-label="検証状況"><strong>検証状況：${m.verification.status === 'verified' ? '記録された範囲で確認済み' : '未検証事項あり'}</strong><p>${escape(m.verification.summary)}</p><ul>${m.verification.limitations.map((s) => `<li>${escape(s)}</li>`).join('')}</ul></aside>`;
    const provenance = `<p class="article-meta">更新 ${escape(m.updatedAt)} · 対象コミット <code>${escape(m.sourceCommit.slice(0, 12))}</code>${m.sourceDirty ? '（対象コードに未commit変更あり）' : ''}</p>`;
    // The article owns its heading; the page title supplies the site header.
    const body = marked.parse(source.replace(/^# .+\r?\n/, ''));
    output.set(`articles/${m.id}.html`, page(m.title, provenance + status + body, '<p><a href="../index.html" style="color:#dfebf5">← 記事一覧へ</a></p>'));
  }
  return output;
}

export function build(root = siteRoot) {
  const pages = renderSite(root);
  for (const [path, html] of pages) {
    const file = join(root, 'dist', path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, html);
  }
  console.log(`Built ${pages.size - 1} article(s) and index.`);
  return pages;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) build();
