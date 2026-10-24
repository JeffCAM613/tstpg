# Finastra template for HTML documents

The look of the web pages of this tool's documents (docs\README.html, REFERENCE.html and SCENARIOS.html), written down to be used again in another project. The styles are in `finastra_template.css` beside this file; `.local/gen_readme_html.js` puts them into each page.

Decided with the user on 2026-10-19: light only, for consistency; the logo as a reference only, its wordmark set in text.

## To use it in another project

1. Copy `finastra_template.css` and this note.
2. Put the stylesheet into the page (inline in a `<style>` element, so the page stays one file), and declare light only: `<meta name="color-scheme" content="light">`.
3. Build the page on the skeleton below. Its classes are the ones the stylesheet knows.

To have another AI write a document in this look, paste it the whole of `finastra_template_prompt.md` beside this note: the look, the parts of a page with their markup, what a troubleshooting document holds, a skeleton, and the stylesheet and the script as the pages use them. `node .local\make_template_prompt.js` writes it from `finastra_template.css` and `gen_readme_html.js`: run it again after either changes.

## Colours

| Name | Value | What it is for | On white |
|---|---|---|---|
| Charcoal | `#414141` | Body text | 10.2:1 |
| Violet | `#694ED6` | Page title, headings, links, list markers, table heads, focus ring | 5.7:1 |
| Violet, deep | `#5136C2` | A link under the pointer | |
| Fuchsia | `#C137A2` | The introduction of a page, bold text, a button just used (Copied) | 4.8:1 |
| Pink | `#EF5DA8` | Accent, sparingly: the bar before a page's label, the current entry of the contents, a heading's link under the pointer. Never for text | 3.1:1 |
| Gradient | `#C137A2` to `#694ED6`, left to right | The wordmark, the lower edge of the brand bar, the bar above each section heading, the dot by a command's label | |

Fuchsia and violet were measured on the Finastra logo: `#BF38A1` to `#C23AA3` at its left, `#6A4FD9` at its right. Charcoal and pink were chosen to go with them; check both against the brand guide when it is at hand, each is one line in the stylesheet.

Neutrals and tints of violet:

| Name | Value | Where |
|---|---|---|
| Page, surfaces | `#FFFFFF` | Background of the page, the brand bar, the tables |
| Muted | `#6B6A73` (5.3:1) | The contents, the footer, small labels |
| Line | `#E6E2EF` | Borders and rules |
| Lilac | `#F5F2FD` | Hover, the current entry of the contents, a table row under the pointer |
| Lilac, strong | `#E9E3FB` | The current document tab, the border of inline code |
| Row | `#FAF9FE` | Every other table row |
| Inline code | `#F3F0FB` background, `#36353B` text | Commands and names in a sentence |
| Commands and screens | `#24212D` body, `#2F2B3B` label bar, `#EDEBF3` text, `#B8B1CC` label | The dark blocks |

## Type

- **Text**: Roboto where installed, otherwise Segoe UI (then the system's sans-serif); 16 px, line height 1.65; lines of 75 characters at most.
- **Wordmark**: "FINASTRA" in capitals, weight 900, as SVG text stretched to the logo's proportions: `textLength="520"` with `lengthAdjust="spacingAndGlyphs"` in a view 76 high (`viewBox="0 -74 520 76"`, letters 100 px, letter spacing 12 px), so that its letters are as wide and heavy as the logo's whatever font the machine has; filled with the gradient (an SVG `linearGradient`, its id unique in the page). The logo's face is a geometric sans: Futura or Century Gothic where installed, otherwise Segoe UI Black, the closest of the fonts every Windows has. 1.6 rem high in the brand bar, 0.95 rem in the footer; the system's text colour in high-contrast mode. Set as plain CSS text, the letters came out narrow and far apart: the user found it too thin.
- **Page title** (h1): 2.4 rem, weight 700, violet. **Section** (h2): 1.55 rem, weight 700, violet, under a bar of the gradient 40 x 3 px. **Subsection** (h3): 1.15 rem, weight 600, violet.
- **Label above the title**: 0.78 rem, weight 700, capitals spaced 0.1 em, violet, after a pink bar 28 x 3 px.
- **Introduction**: 1.16 rem, fuchsia, 70 characters at most.
- **Code**: Cascadia Mono, otherwise Consolas.

## Parts of a page

- **Brand bar**: white, a light shadow, its lower edge the gradient (3 px). In it the wordmark, a thin rule, the product's name in charcoal (weight 600), and on the right the documents as rounded tabs; the current one violet on lilac strong.
- **Page header**: the label, the title, the introduction, then a rule.
- **Contents**: a column of 240 px on the left that stays in view; its entries muted, violet under the pointer; the section in view violet on lilac with a pink bar on its left. Taller than the window, it scrolls on its own with a thin lilac scrollbar, and keeps the entry of the section in view in sight.
- **Links**: violet, underlined (1 px, 2 px below the text); under the pointer deep violet, underline 2 px. Focus: a violet ring of 2 px.
- **Lists**: their markers violet, numbers bold.
- **Bold text**: fuchsia, weight 650 (white in a table head).
- **Inline code**: a lilac chip with a lilac-strong border, corners 4 px.
- **Commands and screens**: corners 10 px, a light shadow. A command has a label bar ("COMMAND", capitals, with a dot of the gradient) and a Copy button: translucent, violet under the pointer, fuchsia with "Copied" once used. A screen has no label bar.
- **Tables**: a border and corners of 10 px, a light shadow; the head row violet with white text, weight 600; every other row tinted; the row under the pointer lilac. A long command in a cell wraps at its spaces.
- **Footer**: under the page and the width of the window, as the brand bar; the row tint, a rule above; the wordmark small, the rest muted. It lies outside the layout: inside it, the contents that stay in view would slide over it at the end of the page.

## Layout

- Content at most 1180 px wide; 40 px above, 24 px at the sides; the contents (240 px) and the text side by side, 40 px apart.
- Up to 900 px wide: one column; the contents in a bordered box above the text; the document tabs on their own line.
- Up to 640 px wide: each table row becomes a block whose cells carry their column's name as a small violet label.
- Print: the tabs, the contents and the Copy buttons left out; commands and screens on a light background.

## Rules

- **Light only.** No dark variant: `color-scheme: light` in the stylesheet and the meta element in the page.
- **Nothing loaded from outside**: no web font, image or script from another site, so that a page opens the same on a client's network that blocks them.
- **The logo is not embedded.** The wordmark is text (in an SVG), with the logo as a reference.
- **Pink is never text**, and appears a few times a page at most. Links are violet, never fuchsia, so that they stay apart from the highlighted words.
- **ASCII only** in the stylesheet and the pages.

## Skeleton of a page

```text
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>Title of the page</title>
<style> ... finastra_template.css ... </style>
</head>
<body>
<header class="brandbar">
<div class="brandbar-in">
<svg class="wordmark" viewBox="0 -74 520 76" role="img" aria-label="Finastra"><defs><linearGradient id="wm-top"><stop offset="0" stop-color="#c137a2"/><stop offset="1" stop-color="#694ed6"/></linearGradient></defs><text x="0" y="0" textLength="520" lengthAdjust="spacingAndGlyphs" fill="url(#wm-top)">FINASTRA</text></svg>
<span class="product">Name of the product</span>
<nav class="docs" aria-label="Documents"><a href="README.html" aria-current="page">User guide</a><a href="REFERENCE.html">Reference</a></nav>
</div>
</header>
<div class="layout">
<header class="top">
<p class="kicker">User guide</p>
<h1>Title of the page</h1>
<p class="intro">One or two sentences that say what the page is for.</p>
</header>
<nav class="toc" aria-label="Contents"><p class="toc-title">Contents</p><ol><li><a href="#first">First section</a></li></ol></nav>
<main>
<h2 id="first">First section</h2>
<p>Text, with <a href="#first">a link</a>, <strong>a highlighted word</strong> and <code>a command</code>.</p>
<div class="code"><div class="code-head"><span>Command</span><button class="copy" type="button">Copy</button></div><pre><code>a command</code></pre></div>
<div class="table-wrap"><table><thead><tr><th>Name</th><th>Meaning</th></tr></thead><tbody><tr><td data-label="Name">a</td><td data-label="Meaning">b</td></tr></tbody></table></div>
</main>
</div>
<footer class="pagefoot"><div class="pagefoot-in"><svg class="wordmark" ...>(as above, with its own gradient id: wm-foot)</svg><span>Name of the product.</span></div></footer>
</body>
</html>
```

The Copy buttons, and the contents that mark and keep in sight the section being read, need the small script at the end of the pages that `.local/gen_readme_html.js` writes (the `js` constant there).
