// Builds docs/README.html from README.md (the Markdown subset the README uses:
// headings, paragraphs, lists, fenced code, tables, inline code, bold, links).
// Usage: node .local\gen_readme_html.js
const fs = require('fs');
const path = require('path');
const repo = path.join(__dirname, '..');
const md = fs.readFileSync(path.join(repo, 'README.md'), 'ascii').replace(/\r\n/g, '\n');

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9 _-]/g, '').trim().replace(/ /g, '-');
const anchors = [];

function inline(text) {
  const codes = [];
  let s = text.replace(/`([^`]+)`/g, (m, c) => { codes.push(c); return '\u0000' + (codes.length - 1) + '\u0000'; });
  s = esc(s);
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (m, t, href) => {
    // Anchors are checked once the page is built; a link to a file of the
    // repository is made relative to docs/.
    if (href.startsWith('#')) anchors.push(href.slice(1));
    else if (!/^[a-z]+:/.test(href)) href = '../' + href;
    return '<a href="' + href + '">' + t + '</a>';
  });
  s = s.replace(/\u0000(\d+)\u0000/g, (m, i) => '<code>' + esc(codes[+i]) + '</code>');
  return s;
}

const lines = md.split('\n');
const out = [];
const toc = [];
let i = 0;
let title = '';
let intro = '';
while (i < lines.length) {
  const line = lines[i];
  if (line.trim() === '') { i++; continue; }
  let m;
  if ((m = /^(#{1,3}) (.*)$/.exec(line))) {
    const level = m[1].length;
    const text = m[2];
    if (level === 1) { title = text; i++; continue; }
    if (level === 2 && text === 'Contents') {
      // The contents list becomes the page's navigation; its links are checked.
      i++;
      while (i < lines.length && (lines[i].trim() === '' || lines[i].startsWith('- '))) {
        for (const a of lines[i].matchAll(/\]\(#([^)]+)\)/g)) anchors.push(a[1]);
        i++;
      }
      continue;
    }
    const id = slug(text);
    if (level === 2) toc.push({ id, text, subs: [] });
    else if (toc.length) toc[toc.length - 1].subs.push({ id, text });
    out.push('<h' + level + ' id="' + id + '">' + inline(text) + '<a class="anchor" href="#' + id + '" aria-label="Link to this section">#</a></h' + level + '>');
    i++;
    continue;
  }
  if (line.startsWith('```')) {
    const lang = line.slice(3).trim();
    const body = [];
    i++;
    while (i < lines.length && !lines[i].startsWith('```')) { body.push(lines[i]); i++; }
    i++;
    const labels = { bat: 'Command', powershell: 'PowerShell', sql: 'SQL' };
    if (labels[lang]) {
      out.push('<div class="code"><div class="code-head"><span>' + labels[lang] + '</span>' +
               '<button class="copy" type="button">Copy</button></div><pre><code>' + esc(body.join('\n')) + '</code></pre></div>');
    } else {
      out.push('<div class="code"><pre class="plain"><code>' + esc(body.join('\n')) + '</code></pre></div>');
    }
    continue;
  }
  if (line.startsWith('|')) {
    const rows = [];
    while (i < lines.length && lines[i].startsWith('|')) { rows.push(lines[i]); i++; }
    const cells = (r) => r.replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
    const head = cells(rows[0]);
    const body = rows.slice(2).map(cells);
    out.push('<div class="table-wrap"><table><thead><tr>' + head.map((h) => '<th>' + inline(h) + '</th>').join('') +
             '</tr></thead><tbody>' + body.map((r) => '<tr>' + r.map((c, k) => '<td data-label="' + esc(head[k].replace(/`/g, '')) + '">' + inline(c) + '</td>').join('') + '</tr>').join('') +
             '</tbody></table></div>');
    continue;
  }
  if (line.startsWith('- ')) {
    const items = [];
    while (i < lines.length && lines[i].startsWith('- ')) { items.push(lines[i].slice(2)); i++; }
    out.push('<ul>' + items.map((t) => '<li>' + inline(t) + '</li>').join('') + '</ul>');
    continue;
  }
  if (/^\d+\. /.test(line)) {
    const items = [];
    while (i < lines.length && /^\d+\. /.test(lines[i])) { items.push(lines[i].replace(/^\d+\. /, '')); i++; }
    out.push('<ol>' + items.map((t) => '<li>' + inline(t) + '</li>').join('') + '</ol>');
    continue;
  }
  const para = [];
  while (i < lines.length && lines[i].trim() !== '' && !/^(#|```|\||- |\d+\. )/.test(lines[i])) { para.push(lines[i]); i++; }
  const text = para.join(' ');
  if (/docs\/README\.html/.test(text)) continue;
  if (!intro) { intro = text; continue; }
  out.push('<p>' + inline(text) + '</p>');
}

const nav = '<nav class="toc" aria-label="Contents"><p class="toc-title">Contents</p><ol>' +
  toc.map((t) => '<li><a href="#' + t.id + '">' + inline(t.text) + '</a>' +
    (t.subs.length ? '<ol>' + t.subs.map((s) => '<li><a href="#' + s.id + '">' + inline(s.text) + '</a></li>').join('') + '</ol>' : '') +
    '</li>').join('') + '</ol></nav>';

const css = `
:root {
  --bg: #f7f8fa; --surface: #ffffff; --fg: #1d2530; --muted: #5a6675; --line: #dde2e8;
  --accent: #0b6e8a; --accent-soft: #e3f1f5; --code-bg: #f1f3f6; --code-fg: #1d2530;
  --pre-bg: #17202b; --pre-fg: #e6edf3; --th-bg: #eef1f5; --shadow: 0 1px 2px rgba(16, 24, 40, 0.06);
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f141a; --surface: #151c24; --fg: #dfe6ee; --muted: #93a1b1; --line: #29333f;
    --accent: #5cc3dd; --accent-soft: #15303a; --code-bg: #1d2630; --code-fg: #dfe6ee;
    --pre-bg: #0b1016; --pre-fg: #e6edf3; --th-bg: #1b242e; --shadow: none;
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
html { scroll-padding-top: 16px; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.6 "Segoe UI", system-ui, -apple-system, Roboto, "Helvetica Neue", Arial, sans-serif;
}
.layout { max-width: 1180px; margin: 0 auto; padding: 32px 24px 64px; display: grid; grid-template-columns: 240px minmax(0, 1fr); gap: 40px; }
header.top { grid-column: 1 / -1; border-bottom: 1px solid var(--line); padding-bottom: 20px; }
header.top h1 { margin: 0 0 6px; font-size: 2rem; line-height: 1.2; letter-spacing: -0.01em; text-wrap: balance; }
header.top .kicker { margin: 0 0 8px; font-size: 0.78rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: var(--accent); }
header.top p.intro { margin: 0; max-width: 72ch; color: var(--muted); font-size: 1.05rem; }
.toc { position: sticky; top: 16px; align-self: start; max-height: calc(100vh - 32px); overflow-y: auto; font-size: 0.92rem; }
.toc .toc-title { margin: 0 0 8px; font-size: 0.78rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
.toc ol { list-style: none; margin: 0; padding: 0; }
.toc ol ol { padding-left: 12px; margin: 2px 0 6px; font-size: 0.88rem; }
.toc a { display: block; padding: 3px 10px; border-left: 2px solid transparent; color: var(--muted); text-decoration: none; border-radius: 0 4px 4px 0; }
.toc a:hover { color: var(--fg); background: var(--accent-soft); }
.toc a.active { color: var(--accent); border-left-color: var(--accent); background: var(--accent-soft); }
main { min-width: 0; }
main > :first-child { margin-top: 0; }
h2 { font-size: 1.45rem; line-height: 1.3; margin: 2.4em 0 0.6em; padding-top: 0.2em; text-wrap: balance; }
h3 { font-size: 1.12rem; margin: 1.8em 0 0.5em; text-wrap: balance; }
h2, h3 { position: relative; }
.anchor { margin-left: 8px; color: var(--line); text-decoration: none; font-weight: 400; opacity: 0; }
h2:hover .anchor, h3:hover .anchor, .anchor:focus { opacity: 1; color: var(--muted); }
p, ul, ol { max-width: 75ch; }
main ul, main ol { padding-left: 1.4em; }
li { margin: 0.3em 0; }
a { color: var(--accent); }
strong { font-weight: 650; }
code { font-family: "Cascadia Mono", Consolas, "Courier New", monospace; font-size: 0.88em; background: var(--code-bg); color: var(--code-fg); padding: 0.1em 0.35em; border-radius: 4px; white-space: nowrap; }
.code { margin: 1em 0 1.2em; }
.code-head {
  display: flex; align-items: center; justify-content: space-between; gap: 12px; background: var(--pre-bg); color: #93a4b5;
  border-radius: 8px 8px 0 0; padding: 6px 8px 6px 16px; border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  font-size: 0.75rem; letter-spacing: 0.04em;
}
pre { margin: 0; background: var(--pre-bg); color: var(--pre-fg); padding: 12px 16px 14px; border-radius: 0 0 8px 8px; overflow-x: auto; line-height: 1.5; }
pre.plain { border-radius: 8px; }
pre code { background: none; color: inherit; padding: 0; font-size: 0.86rem; white-space: pre; }
.copy {
  font: 600 0.75rem/1 "Segoe UI", system-ui, sans-serif; letter-spacing: 0.02em;
  color: #c9d4df; background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.18); border-radius: 5px;
  padding: 5px 9px; cursor: pointer;
}
.copy:hover { background: rgba(255, 255, 255, 0.16); }
.copy.done { color: #8fe3a5; border-color: rgba(143, 227, 165, 0.5); }
.table-wrap { overflow-x: auto; margin: 1em 0 1.4em; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); box-shadow: var(--shadow); }
table { border-collapse: collapse; width: 100%; font-size: 0.92rem; }
th, td { text-align: left; vertical-align: top; padding: 8px 12px; border-bottom: 1px solid var(--line); }
th { background: var(--th-bg); font-weight: 600; white-space: nowrap; }
tbody tr:last-child td { border-bottom: none; }
footer { grid-column: 1 / -1; border-top: 1px solid var(--line); padding-top: 16px; color: var(--muted); font-size: 0.85rem; }
@media (max-width: 900px) {
  .layout { grid-template-columns: minmax(0, 1fr); gap: 24px; padding: 24px 16px 48px; }
  .toc { position: static; max-height: none; border: 1px solid var(--line); border-radius: 8px; padding: 12px; background: var(--surface); }
}
@media (max-width: 640px) {
  table, tbody, tr, td { display: block; width: 100%; }
  thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
  tr { padding: 10px 12px; border-bottom: 1px solid var(--line); }
  tbody tr:last-child { border-bottom: none; }
  td { border: none; padding: 2px 0; overflow-wrap: anywhere; }
  td::before { content: attr(data-label); display: block; font-size: 0.72rem; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); margin-top: 4px; }
  td:first-child::before { margin-top: 0; }
  code { white-space: normal; overflow-wrap: anywhere; }
}
@media print {
  body { background: #fff; color: #000; }
  .toc, .copy, .anchor { display: none; }
  .layout { display: block; max-width: none; padding: 0; }
  .code-head { background: #e8e8e8; color: #333; border: 1px solid #ccc; border-bottom: none; }
  pre { background: #f4f4f4; color: #000; border: 1px solid #ccc; }
  pre code { white-space: pre-wrap; }
  .table-wrap { box-shadow: none; }
  a { color: #000; }
  h2 { break-after: avoid; }
}
`;

const js = `
document.querySelectorAll('.copy').forEach(function (button) {
  button.addEventListener('click', function () {
    var block = button.parentNode.parentNode.querySelector('code');
    var text = block.textContent;
    function done() {
      button.textContent = 'Copied';
      button.classList.add('done');
      setTimeout(function () { button.textContent = 'Copy'; button.classList.remove('done'); }, 1500);
    }
    function fallback() {
      var range = document.createRange();
      range.selectNodeContents(block);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      try { document.execCommand('copy'); done(); } catch (e) { button.textContent = 'Press Ctrl+C'; }
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else {
      fallback();
    }
  });
});
(function () {
  var links = {};
  document.querySelectorAll('.toc a').forEach(function (a) { links[a.getAttribute('href').slice(1)] = a; });
  var heads = document.querySelectorAll('main h2[id], main h3[id]');
  if (!('IntersectionObserver' in window) || !heads.length) { return; }
  var current = null;
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting && links[entry.target.id]) {
        if (current) { current.classList.remove('active'); }
        current = links[entry.target.id];
        current.classList.add('active');
      }
    });
  }, { rootMargin: '0px 0px -75% 0px' });
  heads.forEach(function (h) { observer.observe(h); });
})();
`;

const html = '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n' +
  '<meta name="viewport" content="width=device-width, initial-scale=1">\n' +
  '<title>' + esc(title) + '</title>\n' +
  '<!-- Generated from README.md by .local/gen_readme_html.js: change the README, then run it again. -->\n' +
  '<style>' + css + '</style>\n</head>\n<body>\n<div class="layout">\n' +
  '<header class="top">\n<p class="kicker">User guide</p>\n<h1>' + esc(title) + '</h1>\n<p class="intro">' + inline(intro) + '</p>\n</header>\n' +
  nav + '\n<main>\n' + out.join('\n') + '\n</main>\n' +
  '<footer>This page is the HTML version of README.md in the tool\'s folder.</footer>\n' +
  '</div>\n<script>' + js + '</script>\n</body>\n</html>\n';

if (/[^\x00-\x7F]/.test(html)) { throw new Error('non-ASCII in the page'); }
const ids = new Set([...html.matchAll(/ id="([^"]+)"/g)].map((m) => m[1]));
const missing = [...new Set(anchors)].filter((a) => !ids.has(a));
if (missing.length) { throw new Error('links to missing sections: #' + missing.join(', #')); }
fs.mkdirSync(path.join(repo, 'docs'), { recursive: true });
fs.writeFileSync(path.join(repo, 'docs', 'README.html'), html, 'ascii');
console.log('docs/README.html: ' + html.length + ' characters, ' + toc.length + ' sections');
