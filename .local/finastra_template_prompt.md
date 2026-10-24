# Template: a troubleshooting document as one HTML page, in the Finastra documentation style

Write the documentation of a troubleshooting activity as one self-contained HTML file, in the look described here. It comes from an existing set of documentation pages, and your page must look as if it belongs to that set. The stylesheet and the small script are given in full at the end: copy them as they are, and do not restyle anything.

## The file

- One `.html` file with everything inside: the stylesheet in a `<style>` element in `<head>`, the script in a `<script>` element at the end of `<body>`.
- Nothing loaded from outside: no web font, image, script or stylesheet from another site. The page must open the same on a network that blocks them.
- Light only: `<meta name="color-scheme" content="light">`. The stylesheet sets `color-scheme: light`. No dark variant.
- ASCII only: "--" or ":" in place of a long dash, straight quotes, "x" for "times". Where a symbol is needed, an HTML entity (`&middot;`, `&micro;`, `&plusmn;`).
- It works in any current browser, at phone width and in print: the stylesheet handles all three.

## The look

| Colour | Value | Used for |
|---|---|---|
| Charcoal | `#414141` | Body text |
| Violet | `#694ED6` | Page title, headings, links, list markers, table header rows |
| Fuchsia | `#C137A2` | The introduction under the title, and bold text |
| Pink | `#EF5DA8` | Small accents drawn by the stylesheet; never for text |
| Gradient | `#C137A2` to `#694ED6`, left to right | The wordmark, the line under the top bar, the short bar above each section heading |

Around them: a white page, a muted grey (`#6B6A73`) for secondary text, light lilac tints for hovers and every other table row, dark charcoal-violet blocks for commands and their output. Text in Roboto or Segoe UI, 16 px; code in Cascadia Mono or Consolas. The stylesheet carries all of it: use its classes, add no colour of your own.

The wordmark FINASTRA is SVG text stretched to the logo's proportions and filled with the gradient (exact markup in the skeleton below). Never use a logo image. Each wordmark on the page needs its own gradient id (`wm-top`, `wm-foot`).

## The page, top to bottom

1. **The top bar** (`header.brandbar`): the wordmark, then the name of the system or product (`span.product`), then on the right the documents of the set as tabs (`nav.docs`), the current one marked with `aria-current="page"`. For a single document, one tab: its own name.
2. **The page header** (`header.top`): a small label (`p.kicker`, such as "Troubleshooting"), the title (`h1`), then one introduction paragraph (`p.intro`, shown in fuchsia). Two to four sentences: what happened, its impact, the cause, the fix. A reader who stops there knows the story.
3. **The contents** (`nav.toc`): a link to every section (`h2`) and subsection (`h3`) of the page, in order, the subsections in a list nested under their section. On a wide screen it stays in view on the left as the page scrolls, and the script marks the section being read.
4. **The text** (`main`): sections (`h2`) and subsections (`h3`). Each heading has an `id` (lower case, words joined by hyphens) that the contents link to, and an anchor link inside it.
5. **The footer** (`footer.pagefoot`), after the `div.layout` and not inside it: the wordmark, small, and one line (the system, the date, where the source of the page lives).

## The parts, with their markup

- **A heading:** `<h2 id="root-cause">Root cause<a class="anchor" href="#root-cause" aria-label="Link to this section">#</a></h2>` (an `h3` likewise).
- **Text:** `<p>`, `<ul>` and `<ol>` with `<li>`. `<strong>` for the few words of a sentence that matter most (they show in fuchsia): a few per section, not whole sentences. `<a href>` for links, `href="#id"` for a section of the page.
- **A name in a sentence:** `<code>` for commands, files, parameters, error codes.
- **A command to run:** `<div class="code"><div class="code-head"><span>Command</span><button class="copy" type="button">Copy</button></div><pre><code>the command</code></pre></div>`. The label names the language: Command, PowerShell, SQL. The Copy button works through the script.
- **Output, a log, an error, a screen** (nothing to copy): `<div class="code"><pre class="plain"><code>the text</code></pre></div>`.
- **In both:** keep the text verbatim, escaped: `&lt;` `&gt;` `&amp;`.
- **A table:** `<div class="table-wrap"><table><thead><tr><th>Time</th><th>Event</th></tr></thead><tbody><tr><td data-label="Time">09:12</td><td data-label="Event">...</td></tr></tbody></table></div>`. Every `td` has `data-label` set to its column's header: on a phone each row becomes a block labelled that way.

## What a troubleshooting document holds

These sections, named for the case, in this order; leave out one that has nothing to say:

- **What happened:** the impact, how long it lasted, who or what was affected, when it began and ended.
- **Environment:** the systems, versions, hosts and settings involved. A table reads well.
- **Symptoms:** what was seen, errors and messages verbatim in output blocks.
- **Timeline:** a table of time, event, and what or who.
- **Investigation:** one subsection per step: what was checked and why, the command, what it showed, what it ruled in or out.
- **Root cause:** the cause in plain words, and the evidence for it.
- **Fix:** what was changed, in order, with the commands.
- **Verification:** how the fix was confirmed: the figures or output before and after.
- **Prevention and follow-ups:** what keeps it from happening again, with owners and dates when known.
- **Commands and references:** every command used, and links to tickets, documents and logs.

Write plainly and directly: what happened and why, figures with their units, errors and commands verbatim. No filler, no marketing words.

## Before you hand it over

- Every contents link finds its heading, and every heading is in the contents.
- The introduction says the whole story in two to four sentences.
- Commands have a Copy button; output, logs and errors do not.
- Every `td` has its `data-label`.
- ASCII only, nothing loaded from outside, the stylesheet and the script as given.

## A skeleton to start from

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>Troubleshooting: short name of the problem</title>
<style>
/* the whole stylesheet below, as it is */
</style>
</head>
<body>
<header class="brandbar">
<div class="brandbar-in">
<svg class="wordmark" viewBox="0 -74 520 76" role="img" aria-label="Finastra"><defs><linearGradient id="wm-top"><stop offset="0" stop-color="#c137a2"/><stop offset="1" stop-color="#694ed6"/></linearGradient></defs><text x="0" y="0" textLength="520" lengthAdjust="spacingAndGlyphs" fill="url(#wm-top)">FINASTRA</text></svg>
<span class="product">Name of the system or product</span>
<nav class="docs" aria-label="Documents"><a href="troubleshooting.html" aria-current="page">Troubleshooting</a></nav>
</div>
</header>
<div class="layout">
<header class="top">
<p class="kicker">Troubleshooting</p>
<h1>Short name of the problem</h1>
<p class="intro">What happened, what it affected, why it happened and how it was fixed, in two to four sentences.</p>
</header>
<nav class="toc" aria-label="Contents"><p class="toc-title">Contents</p><ol>
<li><a href="#symptoms">Symptoms</a></li>
<li><a href="#investigation">Investigation</a><ol><li><a href="#first-check">First check</a></li></ol></li>
<li><a href="#root-cause">Root cause</a></li>
</ol></nav>
<main>
<h2 id="symptoms">Symptoms<a class="anchor" href="#symptoms" aria-label="Link to this section">#</a></h2>
<p>What was seen, with <strong>the key words</strong> in bold and <code>names</code> in code.</p>
<div class="code"><pre class="plain"><code>ORA-01652: unable to extend temp segment by 128 in tablespace TEMP</code></pre></div>
<h2 id="investigation">Investigation<a class="anchor" href="#investigation" aria-label="Link to this section">#</a></h2>
<h3 id="first-check">First check<a class="anchor" href="#first-check" aria-label="Link to this section">#</a></h3>
<p>What was checked and why.</p>
<div class="code"><div class="code-head"><span>SQL</span><button class="copy" type="button">Copy</button></div><pre><code>SELECT tablespace_name, SUM(bytes) FROM dba_temp_files GROUP BY tablespace_name;</code></pre></div>
<div class="table-wrap"><table><thead><tr><th>Time</th><th>Event</th></tr></thead><tbody>
<tr><td data-label="Time">09:12</td><td data-label="Event">First error in the job log</td></tr>
</tbody></table></div>
<h2 id="root-cause">Root cause<a class="anchor" href="#root-cause" aria-label="Link to this section">#</a></h2>
<p>The cause, in plain words.</p>
</main>
</div>
<footer class="pagefoot">
<div class="pagefoot-in"><svg class="wordmark" viewBox="0 -74 520 76" role="img" aria-label="Finastra"><defs><linearGradient id="wm-foot"><stop offset="0" stop-color="#c137a2"/><stop offset="1" stop-color="#694ed6"/></linearGradient></defs><text x="0" y="0" textLength="520" lengthAdjust="spacingAndGlyphs" fill="url(#wm-foot)">FINASTRA</text></svg><span>Name of the system. Troubleshooting of 2026-10-24.</span></div>
</footer>
<script>
/* the whole script below, as it is */
</script>
</body>
</html>
```

## The stylesheet (into `<style>`, as it is)

```css
/* ============================================================================
   Finastra template for HTML documents (light only)
   ============================================================================
   The design is described in finastra_template.md, beside this file:
   charcoal for the text, violet for the headings and the links, fuchsia for
   the introduction and the highlighted words, pink as an accent used
   sparingly; the wordmark is text stretched to the logo's proportions, in
   the logo's gradient, fuchsia to violet (an SVG, see .wordmark).
   .local/gen_readme_html.js puts this file into the pages of docs\.
   ASCII only; no font, image or other file is loaded from outside.
   ============================================================================ */
:root {
  /* The brand */
  --charcoal: #414141; --violet: #694ed6; --violet-deep: #5136c2; --fuchsia: #c137a2; --pink: #ef5da8;
  --brand: linear-gradient(90deg, #c137a2 0%, #694ed6 100%);
  /* Neutrals and tints of violet */
  --bg: #ffffff; --surface: #ffffff; --muted: #6b6a73; --line: #e6e2ef; --lilac: #f5f2fd; --lilac-strong: #e9e3fb;
  --row-alt: #faf9fe; --code-bg: #f3f0fb; --code-fg: #36353b;
  /* Commands and screens */
  --pre-bg: #24212d; --pre-head: #2f2b3b; --pre-fg: #edebf3; --pre-muted: #b8b1cc;
  --shadow: 0 1px 2px rgba(65, 65, 65, 0.06), 0 6px 18px rgba(105, 78, 214, 0.07);
  color-scheme: light;
}
* { box-sizing: border-box; }
html { scroll-padding-top: 16px; }
body {
  margin: 0; background: var(--bg); color: var(--charcoal);
  font: 16px/1.65 "Roboto", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
}

/* The brand bar: the wordmark, the product, the documents; the logo's
   gradient as its lower edge. */
.brandbar { position: relative; background: var(--surface); box-shadow: var(--shadow); }
.brandbar::after { content: ""; position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: var(--brand); }
.brandbar-in { max-width: 1180px; margin: 0 auto; padding: 16px 24px 19px; display: flex; flex-wrap: wrap; align-items: center; gap: 12px 20px; }
/* The wordmark: the text FINASTRA in an SVG whose text is stretched to the
   logo's proportions (textLength 520 in a view 76 high, lengthAdjust
   spacingAndGlyphs), so that its letters are as wide as the logo's whatever
   font the machine has; filled with the logo's gradient. */
.wordmark { display: block; flex: none; height: 1.6rem; width: calc(1.6rem * 520 / 76); overflow: visible; }
.wordmark text { font: 900 100px "Futura", "Century Gothic", "Segoe UI Black", "Segoe UI", "Arial Black", sans-serif; letter-spacing: 12px; }
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
.toc {
  position: sticky; top: 16px; align-self: start; max-height: calc(100vh - 32px); overflow-y: auto; font-size: 0.92rem;
  scrollbar-width: thin; scrollbar-color: var(--lilac-strong) transparent;
}
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
.copy:hover { color: #ffffff; background: var(--violet); border-color: var(--violet); }
.copy.done { color: #ffffff; background: var(--fuchsia); border-color: var(--fuchsia); }

/* Tables: a violet head, light rows. */
.table-wrap { overflow-x: auto; margin: 1em 0 1.4em; border: 1px solid var(--line); border-radius: 10px; background: var(--surface); box-shadow: var(--shadow); }
table { border-collapse: collapse; width: 100%; font-size: 0.92rem; }
th, td { text-align: left; vertical-align: top; padding: 9px 14px; border-bottom: 1px solid var(--line); }
th { background: var(--violet); color: #ffffff; font-weight: 600; white-space: nowrap; border-bottom: 0; }
th code { color: #ffffff; background: rgba(255, 255, 255, 0.16); border-color: rgba(255, 255, 255, 0.3); }
/* A long command in a cell wraps at its spaces, so the text beside it keeps room. */
td code { white-space: normal; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
tbody tr:nth-child(even) td { background: var(--row-alt); }
tbody tr:hover td { background: var(--lilac); }
tbody tr:last-child td { border-bottom: none; }
/* The footer: under the page and the width of the window, as the brand bar;
   outside the layout, so that the contents stop above it. */
.pagefoot { border-top: 1px solid var(--line); background: var(--row-alt); }
.pagefoot-in {
  max-width: 1180px; margin: 0 auto; padding: 20px 24px 28px; display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px;
  color: var(--muted); font-size: 0.85rem;
}
.pagefoot .wordmark { height: 0.95rem; width: calc(0.95rem * 520 / 76); }

@media (max-width: 900px) {
  .brandbar-in { padding: 12px 16px 15px; }
  .docs { margin-left: 0; width: 100%; }
  .layout { grid-template-columns: minmax(0, 1fr); gap: 24px; padding: 28px 16px 48px; }
  .pagefoot-in { padding: 18px 16px 24px; }
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
  .wordmark text { fill: CanvasText; }
}
@media print {
  .brandbar { box-shadow: none; }
  .pagefoot { background: none; }
  .docs, .toc, .copy, .anchor { display: none; }
  .layout { display: block; max-width: none; padding: 0; }
  header.top { margin: 16px 0 8px; }
  .code, .table-wrap { box-shadow: none; }
  .code-head { background: #ece8f6; color: var(--charcoal); }
  pre { background: #f6f4fb; color: #222222; border: 1px solid #dddddd; }
  pre code { white-space: pre-wrap; }
  th { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  h2 { break-after: avoid; }
}
```

## The script (into `<script>` at the end of `<body>`, as it is)

```js
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
```
