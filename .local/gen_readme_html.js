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

// The styles: the Finastra template, light only (finastra_template.css and
// finastra_template.md beside this file).
const css = fs.readFileSync(path.join(__dirname, 'finastra_template.css'), 'ascii').replace(/\r\n/g, '\n');

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
  // The contents scroll on their own when taller than the window: the entry
  // of the section in view is kept in sight there.
  var toc = document.querySelector('.toc');
  function reveal(a) {
    if (!toc || toc.scrollHeight <= toc.clientHeight) { return; }
    var top = a.offsetTop;
    var bottom = top + a.offsetHeight;
    if (top < toc.scrollTop + 8) { toc.scrollTop = Math.max(0, top - 8); }
    else if (bottom > toc.scrollTop + toc.clientHeight - 8) { toc.scrollTop = bottom - toc.clientHeight + 8; }
  }
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting && links[entry.target.id]) {
        if (current) { current.classList.remove('active'); }
        current = links[entry.target.id];
        current.classList.add('active');
        reveal(current);
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
    '<meta name="color-scheme" content="light">\n' +
    '<title>' + esc(p.title) + '</title>\n' +
    '<!-- Generated from ' + doc.source + ' by .local/gen_readme_html.js: change that file, then run it again. -->\n' +
    '<style>' + css + '</style>\n</head>\n<body>\n' + brand + '<div class="layout">\n' +
    '<header class="top">\n<p class="kicker">' + doc.kicker + '</p>\n<h1>' + esc(p.title) + '</h1>\n<p class="intro">' + p.intro + '</p>\n</header>\n' +
    p.nav + '\n<main>\n' + p.body + '\n</main>\n</div>\n' +
    // The footer lies outside the layout: the contents, which stay in view
    // as the page scrolls, stop above it instead of sliding over it.
    '<footer class="pagefoot">\n<div class="pagefoot-in"><span class="wordmark">FINASTRA</span><span>EPF Data Purge. This page is the HTML version of ' +
    doc.source + ' in the tool\'s folder.' + (others ? ' See also: ' + others + '.' : '') + '</span></div>\n</footer>\n' +
    '<script>' + js + '</script>\n</body>\n</html>\n';
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
