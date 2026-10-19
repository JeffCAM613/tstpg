// Builds the web pages of docs\ from the Markdown documents: README.md (the
// user guide), docs/REFERENCE.md and docs/SCENARIOS.md. It reads the Markdown
// subset they use: headings, paragraphs, lists, fenced code, tables, inline
// code, bold, links. A link from one document to another goes to its page.
// Usage: node .local\gen_readme_html.js
const fs = require('fs');
const path = require('path');
const repo = path.join(__dirname, '..');
const docs = [
  { source: 'README.md', target: 'README.html', kicker: 'User guide' },
  { source: 'docs/REFERENCE.md', target: 'REFERENCE.html', kicker: 'Reference' },
  { source: 'docs/SCENARIOS.md', target: 'SCENARIOS.html', kicker: 'Scenarios' }
];

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9 _-]/g, '').trim().replace(/ /g, '-');

// One document as the parts of its page: title, intro, navigation, body, the
// sections it links to in itself (anchors) and in the other pages (cross).
function parse(doc) {
  const md = fs.readFileSync(path.join(repo, doc.source), 'ascii').replace(/\r\n/g, '\n');
  const inDocs = doc.source.startsWith('docs/');
  const anchors = [];
  const cross = [];

  function inline(text) {
    const codes = [];
    let s = text.replace(/`([^`]+)`/g, (m, c) => { codes.push(c); return '\u0000' + (codes.length - 1) + '\u0000'; });
    s = esc(s);
    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (m, t, href) => {
      if (href.startsWith('#')) {
        // Checked once the page is built.
        anchors.push(href.slice(1));
      } else if (!/^[a-z]+:/.test(href)) {
        // Another document: its page, which lies next to this one. Any other
        // file of the repository: relative to docs/.
        const other = /^(?:docs\/|\.\.\/)?([A-Za-z_]+)\.md(#.*)?$/.exec(href);
        const page = other ? docs.find((d) => path.basename(d.source, '.md') === other[1]) : null;
        if (page) {
          href = page.target + (other[2] || '');
          if (other[2]) cross.push({ page: page.target, anchor: other[2].slice(1) });
        } else if (!inDocs) {
          href = '../' + href;
        }
      }
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
    // The Markdown says where its page is; the page does not.
    if (/also available as a web page/.test(text)) continue;
    if (!intro) { intro = text; continue; }
    out.push('<p>' + inline(text) + '</p>');
  }

  const nav = '<nav class="toc" aria-label="Contents"><p class="toc-title">Contents</p><ol>' +
    toc.map((t) => '<li><a href="#' + t.id + '">' + inline(t.text) + '</a>' +
      (t.subs.length ? '<ol>' + t.subs.map((s) => '<li><a href="#' + s.id + '">' + inline(s.text) + '</a></li>').join('') + '</ol>' : '') +
      '</li>').join('') + '</ol></nav>';
  return { title, intro: inline(intro), nav, body: out.join('\n'), anchors, cross, sections: toc.length };
}

const css = `
/* Finastra: charcoal for the text, violet for the headings and the links,
   fuchsia for the introduction and the highlighted words, pink as an accent
   used sparingly. The wordmark is text with the logo's gradient, fuchsia to
   violet; where a browser cannot fill text with a gradient it is violet. */
:root {
  --charcoal: #414141; --violet: #694ed6; --violet-deep: #5136c2; --fuchsia: #c137a2; --pink: #ef5da8;
  --bg: #ffffff; --surface: #ffffff; --muted: #6b6a73; --line: #e6e2ef; --lilac: #f5f2fd; --lilac-strong: #e9e3fb;
  --code-bg: #f3f0fb; --code-fg: #36353b; --pre-bg: #24212d; --pre-head: #2f2b3b; --pre-fg: #edebf3; --pre-muted: #b8b1cc;
  --th-bg: #694ed6; --th-fg: #ffffff; --row-alt: #faf9fe;
  --brand: linear-gradient(90deg, #c137a2 0%, #694ed6 100%);
  --wordmark: linear-gradient(90deg, #c137a2 0%, #694ed6 100%);
  --shadow: 0 1px 2px rgba(65, 65, 65, 0.06), 0 6px 18px rgba(105, 78, 214, 0.07);
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --charcoal: #e7e5ee; --violet: #a796f4; --violet-deep: #c5b9f9; --fuchsia: #e77fce; --pink: #f592c0;
    --bg: #17161c; --surface: #1f1d26; --muted: #a29fae; --line: #34303f; --lilac: #262236; --lilac-strong: #322b4a;
    --code-bg: #2a2537; --code-fg: #e7e5ee; --pre-bg: #111016; --pre-head: #1b1922; --pre-fg: #edebf3; --pre-muted: #a59ebc;
    --th-bg: #4f3aa8; --th-fg: #ffffff; --row-alt: #1b1921;
    --wordmark: linear-gradient(90deg, #e061c4 0%, #9a85f3 100%);
    --shadow: none;
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
html { scroll-padding-top: 16px; }
body {
  margin: 0; background: var(--bg); color: var(--charcoal);
  font: 16px/1.65 "Roboto", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
}

/* The brand bar: the wordmark, the product, the three documents; the
   logo's gradient as its lower edge. */
.brandbar { position: relative; background: var(--surface); box-shadow: var(--shadow); }
.brandbar::after { content: ""; position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: var(--brand); }
.brandbar-in { max-width: 1180px; margin: 0 auto; padding: 16px 24px 19px; display: flex; flex-wrap: wrap; align-items: center; gap: 12px 20px; }
.wordmark {
  font: 900 1.6rem/1 "Futura", "Century Gothic", "Segoe UI Black", "Segoe UI", "Arial Black", sans-serif;
  letter-spacing: 0.08em; color: var(--violet); white-space: nowrap;
}
@supports ((-webkit-background-clip: text) or (background-clip: text)) {
  .wordmark { background: var(--wordmark); -webkit-background-clip: text; background-clip: text; color: transparent; }
}
.product { padding-left: 20px; border-left: 1px solid var(--line); font-weight: 600; font-size: 1.02rem; white-space: nowrap; }
.docs { margin-left: auto; display: flex; flex-wrap: wrap; gap: 6px; }
.docs a { padding: 6px 14px; border-radius: 999px; color: var(--charcoal); font-size: 0.92rem; font-weight: 500; text-decoration: none; }
.docs a:hover { color: var(--violet); background: var(--lilac); }
.docs a[aria-current="page"] { color: var(--violet); background: var(--lilac-strong); font-weight: 600; }

/* The page: its title and introduction, the contents, the text. */
.layout { max-width: 1180px; margin: 0 auto; padding: 40px 24px 64px; display: grid; grid-template-columns: 240px minmax(0, 1fr); gap: 40px; }
header.top { grid-column: 1 / -1; padding-bottom: 28px; border-bottom: 1px solid var(--line); }
header.top .kicker { margin: 0 0 12px; font-size: 0.78rem; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--violet); }
header.top .kicker::before { content: ""; display: inline-block; width: 28px; height: 3px; margin-right: 10px; border-radius: 2px; background: var(--pink); vertical-align: middle; }
header.top h1 { margin: 0 0 14px; font-size: 2.4rem; line-height: 1.15; font-weight: 700; letter-spacing: -0.01em; color: var(--violet); text-wrap: balance; }
header.top p.intro { margin: 0; max-width: 70ch; font-size: 1.16rem; line-height: 1.6; color: var(--fuchsia); }
.toc { position: sticky; top: 16px; align-self: start; max-height: calc(100vh - 32px); overflow-y: auto; font-size: 0.92rem; }
.toc .toc-title { margin: 0 0 10px; font-size: 0.75rem; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--muted); }
.toc ol { list-style: none; margin: 0; padding: 0; }
.toc ol ol { padding-left: 12px; margin: 2px 0 6px; font-size: 0.88rem; }
.toc a { display: block; padding: 4px 10px; border-left: 3px solid transparent; border-radius: 0 6px 6px 0; color: var(--muted); text-decoration: none; }
.toc a:hover { color: var(--violet); background: var(--lilac); }
.toc a.active { color: var(--violet); background: var(--lilac); border-left-color: var(--pink); font-weight: 600; }
main { min-width: 0; }
main > :first-child { margin-top: 0; }
h2 { margin: 2.2em 0 0.6em; font-size: 1.55rem; line-height: 1.3; font-weight: 700; color: var(--violet); text-wrap: balance; }
h2::before { content: ""; display: block; width: 40px; height: 3px; margin-bottom: 12px; border-radius: 2px; background: var(--brand); }
h3 { margin: 1.8em 0 0.5em; font-size: 1.15rem; font-weight: 600; color: var(--violet); text-wrap: balance; }
h2, h3 { position: relative; }
.anchor { margin-left: 8px; color: var(--line); font-weight: 400; text-decoration: none; opacity: 0; }
h2:hover .anchor, h3:hover .anchor, .anchor:focus { opacity: 1; color: var(--pink); }
p, ul, ol { max-width: 75ch; }
main ul, main ol { padding-left: 1.4em; }
main li::marker { color: var(--violet); }
main ol > li::marker { font-weight: 700; }
li { margin: 0.3em 0; }
a { color: var(--violet); text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; }
a:hover { color: var(--violet-deep); text-decoration-thickness: 2px; }
a:focus-visible, button:focus-visible { outline: 2px solid var(--violet); outline-offset: 2px; border-radius: 4px; }
strong { font-weight: 650; color: var(--fuchsia); }
th strong { color: inherit; }
code {
  font-family: "Cascadia Mono", Consolas, "Courier New", monospace; font-size: 0.86em; white-space: nowrap;
  background: var(--code-bg); color: var(--code-fg); border: 1px solid var(--lilac-strong); border-radius: 4px; padding: 0.1em 0.38em;
}

/* Commands and screens: dark, with a dot of the brand by their label. */
.code { margin: 1em 0 1.3em; border-radius: 10px; overflow: hidden; box-shadow: var(--shadow); }
.code-head {
  display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 6px 8px 6px 16px;
  background: var(--pre-head); color: var(--pre-muted); font-size: 0.74rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase;
}
.code-head span::before { content: ""; display: inline-block; width: 8px; height: 8px; margin-right: 9px; border-radius: 50%; background: var(--brand); vertical-align: 1px; }
pre { margin: 0; padding: 14px 16px 16px; background: var(--pre-bg); color: var(--pre-fg); line-height: 1.5; overflow-x: auto; }
pre code { padding: 0; border: 0; background: none; color: inherit; font-size: 0.86rem; white-space: pre; }
.copy {
  font: 600 0.75rem/1 "Segoe UI", system-ui, sans-serif; letter-spacing: 0.02em; text-transform: none;
  color: #ece8f8; background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.2); border-radius: 6px;
  padding: 5px 10px; cursor: pointer;
}
.copy:hover { color: #ffffff; background: #694ed6; border-color: #694ed6; }
.copy.done { color: #ffffff; background: #c137a2; border-color: #c137a2; }

/* Tables: a violet head, light rows. */
.table-wrap { overflow-x: auto; margin: 1em 0 1.4em; border: 1px solid var(--line); border-radius: 10px; background: var(--surface); box-shadow: var(--shadow); }
table { border-collapse: collapse; width: 100%; font-size: 0.92rem; }
th, td { text-align: left; vertical-align: top; padding: 9px 14px; border-bottom: 1px solid var(--line); }
th { background: var(--th-bg); color: var(--th-fg); font-weight: 600; white-space: nowrap; border-bottom: 0; }
th code { color: #ffffff; background: rgba(255, 255, 255, 0.16); border-color: rgba(255, 255, 255, 0.3); }
/* A long command in a cell wraps at its spaces, so the text beside it keeps room. */
td code { white-space: normal; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
tbody tr:nth-child(even) td { background: var(--row-alt); }
tbody tr:hover td { background: var(--lilac); }
tbody tr:last-child td { border-bottom: none; }
footer { grid-column: 1 / -1; display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; border-top: 1px solid var(--line); padding-top: 18px; color: var(--muted); font-size: 0.85rem; }
footer .wordmark { font-size: 0.95rem; }

@media (max-width: 900px) {
  .brandbar-in { padding: 12px 16px 15px; }
  .docs { margin-left: 0; width: 100%; }
  .layout { grid-template-columns: minmax(0, 1fr); gap: 24px; padding: 28px 16px 48px; }
  header.top h1 { font-size: 2rem; }
  .toc { position: static; max-height: none; border: 1px solid var(--line); border-radius: 10px; padding: 12px; background: var(--surface); }
}
@media (max-width: 640px) {
  .product { padding-left: 0; border-left: 0; }
  table, tbody, tr, td { display: block; width: 100%; }
  thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
  tr { padding: 10px 12px; border-bottom: 1px solid var(--line); }
  tbody tr:last-child { border-bottom: none; }
  tbody tr:nth-child(even) td, tbody tr:hover td { background: none; }
  td { border: none; padding: 2px 0; overflow-wrap: anywhere; }
  td::before { content: attr(data-label); display: block; margin-top: 4px; font-size: 0.72rem; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--violet); }
  td:first-child::before { margin-top: 0; }
  code { white-space: normal; overflow-wrap: anywhere; }
}
@media (forced-colors: active) {
  .wordmark { background: none; color: CanvasText; -webkit-text-fill-color: CanvasText; }
}
@media print {
  body { background: #ffffff; color: #414141; }
  .brandbar { box-shadow: none; }
  .docs, .toc, .copy, .anchor { display: none; }
  .wordmark { background: none; color: #694ed6; -webkit-text-fill-color: #694ed6; }
  .layout { display: block; max-width: none; padding: 0; }
  header.top { margin: 16px 0 8px; }
  .code, .table-wrap { box-shadow: none; }
  .code-head { background: #ece8f6; color: #414141; }
  pre { background: #f6f4fb; color: #222222; border: 1px solid #dddddd; }
  pre code { white-space: pre-wrap; }
  th { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
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

// The pages, each checked: ASCII only, and every link to a section finds it,
// in its own page or in another.
const ids = {};
const crosses = [];
fs.mkdirSync(path.join(repo, 'docs'), { recursive: true });
for (const doc of docs) {
  if (!fs.existsSync(path.join(repo, doc.source))) { console.log(doc.source + ': not there, skipped'); continue; }
  const p = parse(doc);
  const present = docs.filter((d) => fs.existsSync(path.join(repo, d.source)));
  const others = present.filter((d) => d !== doc).map((d) => '<a href="' + d.target + '">' + d.kicker + '</a>').join(' &middot; ');
  // The brand bar: the wordmark (text, with the logo's gradient), the product,
  // and the three documents with the current one marked.
  const brand = '<header class="brandbar">\n<div class="brandbar-in">\n<span class="wordmark">FINASTRA</span>\n' +
    '<span class="product">EPF Data Purge</span>\n<nav class="docs" aria-label="Documents">' +
    present.map((d) => '<a href="' + d.target + '"' + (d === doc ? ' aria-current="page"' : '') + '>' + d.kicker + '</a>').join('') +
    '</nav>\n</div>\n</header>\n';
  const html = '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n' +
    '<title>' + esc(p.title) + '</title>\n' +
    '<!-- Generated from ' + doc.source + ' by .local/gen_readme_html.js: change that file, then run it again. -->\n' +
    '<style>' + css + '</style>\n</head>\n<body>\n' + brand + '<div class="layout">\n' +
    '<header class="top">\n<p class="kicker">' + doc.kicker + '</p>\n<h1>' + esc(p.title) + '</h1>\n<p class="intro">' + p.intro + '</p>\n</header>\n' +
    p.nav + '\n<main>\n' + p.body + '\n</main>\n' +
    '<footer><span class="wordmark">FINASTRA</span><span>EPF Data Purge. This page is the HTML version of ' + doc.source + ' in the tool\'s folder.' +
    (others ? ' See also: ' + others + '.' : '') + '</span></footer>\n' +
    '</div>\n<script>' + js + '</script>\n</body>\n</html>\n';
  if (/[^\x00-\x7F]/.test(html)) { throw new Error(doc.source + ': non-ASCII in the page'); }
  ids[doc.target] = new Set([...html.matchAll(/ id="([^"]+)"/g)].map((m) => m[1]));
  const missing = [...new Set(p.anchors)].filter((a) => !ids[doc.target].has(a));
  if (missing.length) { throw new Error(doc.source + ': links to missing sections: #' + missing.join(', #')); }
  for (const c of p.cross) crosses.push({ from: doc.source, page: c.page, anchor: c.anchor });
  fs.writeFileSync(path.join(repo, 'docs', doc.target), html, 'ascii');
  console.log('docs/' + doc.target + ': ' + html.length + ' characters, ' + p.sections + ' sections');
}
const lost = crosses.filter((c) => ids[c.page] && !ids[c.page].has(c.anchor)).map((c) => c.from + ' -> ' + c.page + '#' + c.anchor);
if (lost.length) { throw new Error('links to missing sections of another page: ' + lost.join('; ')); }
