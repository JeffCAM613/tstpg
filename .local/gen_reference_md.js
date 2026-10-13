// Builds docs/REFERENCE.md once from the README as it was before it became
// the user guide (the commit given, e6ad891 by default): the sections the
// guide does not replace, with their links. After that the reference is
// edited by hand like any other file; this script is kept as the record of
// what was moved. Usage: node .local\gen_reference_md.js [commit]
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const repo = path.join(__dirname, '..');
const commit = process.argv[2] || 'e6ad891';
const old = execFileSync('git', ['show', commit + ':README.md'], { cwd: repo, encoding: 'utf8' }).replace(/\r\n/g, '\n');

// The README by section (## title) and, inside "Purge", by subsection.
const sections = [];
for (const line of old.split('\n')) {
  const m = /^## (.*)$/.exec(line);
  if (m) sections.push({ title: m[1], lines: [] });
  else if (sections.length) sections[sections.length - 1].lines.push(line);
}
const get = (title) => {
  const s = sections.find((x) => x.title === title);
  if (!s) throw new Error('section not found: ' + title);
  return s.lines.join('\n').replace(/^\n+/, '').replace(/\n+$/, '');
};
function subsections(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const m = /^### (.*)$/.exec(line);
    if (m) out.push({ title: m[1], lines: [] });
    else if (out.length) out[out.length - 1].lines.push(line);
  }
  return out;
}
const purge = subsections(get('Purge'))
  .filter((s) => !/^[12]\. /.test(s.title))
  .map((s) => '### ' + s.title + '\n' + s.lines.join('\n').replace(/\n+$/, ''))
  .join('\n\n');

const keep = [
  ['What it does', get('What it does')],
  ['Requirements', get('Requirements')],
  ['Purge', 'The steps of a purge are in the [user guide](../README.md#getting-started). This part is what lies behind them.\n\n' + purge],
  ['Large purges: a plan of smaller runs', get('Large purges: a plan of smaller runs')],
  ['Reclaim disk space', get('Reclaim disk space')],
  ['Runs, reports and logs', get('Runs, reports and logs')],
  ['Status and recovery', get('Status and recovery')],
  ['Settings', get('Settings')],
  ['SQL*Plus scripts', get('SQL*Plus scripts')],
  ['Repository layout', get('Repository layout')],
  ['Testing', get('Testing')]
];
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9 _-]/g, '').trim().replace(/ /g, '-');
let text = '# EPF Data Purge: reference\n\n' +
  'What lies behind the [user guide](../README.md): how a purge chooses its rows, the requirements it checks, undo tuning, ' +
  'a purge planned in several runs, how a reclaim works, the files of a run, what can be left pending and what clears it, ' +
  'the settings, the SQL*Plus scripts and the tests. Start with the user guide; come here for the detail.\n\n' +
  'This reference is also available as a web page: [REFERENCE.html](REFERENCE.html).\n\n' +
  '## Contents\n\n' + keep.map(([t]) => '- [' + t + '](#' + slug(t) + ')').join('\n') + '\n\n' +
  keep.map(([t, body]) => '## ' + t + '\n\n' + body).join('\n\n') + '\n';

// What changes with the move: links to sections that are now in the guide,
// paths seen from docs\, and where the tool runs.
function rep(a, b) {
  const n = text.split(a).length - 1;
  if (n !== 1) throw new Error('anchor found ' + n + ' times: ' + a.slice(0, 70));
  text = text.replace(a, () => b);
}
rep('- Oracle Database 12.2 or later (developed on 19c). In a multitenant database, connect to the PDB service.',
    '- Oracle Database 12.2 or later (developed on 19c), single instance. A purge that deletes does not run in a multitenant database yet (a pluggable database of a container database), nor on RAC: its undo tuning needs the instance to itself and refuses both.');
rep('src\\bin\\epf_purge.bat    the tool (its code is in src\\bin\\lib: epf.ps1, the screen in\n' +
    '                         epf_screen.ps1, the HTML report in epf_html.ps1)',
    'README.md                the user guide\n' +
    'src\\bin\\epf_purge.bat    the tool (its code is in src\\bin\\lib: epf.ps1, the screen in\n' +
    '                         epf_screen.ps1, the HTML report in epf_html.ps1)');
rep('docs\\README.html         this guide as a web page',
    'docs\\                    this reference (REFERENCE.md), the scenarios (SCENARIOS.md), and\n' +
    '                         the user guide, the reference and the scenarios as web pages');
// Links to sections that moved to the guide.
const moved = { 'passwords': 'passwords', 'stop-a-run': 'stop-a-run', 'configure': 'parameters', 'install': 'the-first-time-on-a-database',
                'run-it': 'getting-started', 'command-reference': 'parameters' };
text = text.replace(/\]\(#([a-z0-9-]+)\)/g, (m, a) => (moved[a] ? '](../README.md#' + moved[a] + ')' : m));
// Every link inside the page must have its section.
const ids = new Set([...text.matchAll(/^#{2,3} (.*)$/gm)].map((m) => slug(m[1])));
const missing = [...new Set([...text.matchAll(/\]\(#([a-z0-9-]+)\)/g)].map((m) => m[1]))].filter((a) => !ids.has(a));
if (missing.length) throw new Error('links to missing sections: ' + missing.join(', '));
if (/[^\x00-\x7F]/.test(text)) throw new Error('non-ASCII in the reference');
fs.mkdirSync(path.join(repo, 'docs'), { recursive: true });
fs.writeFileSync(path.join(repo, 'docs', 'REFERENCE.md'), text, 'ascii');
console.log('docs/REFERENCE.md: ' + text.split('\n').length + ' lines, ' + keep.length + ' sections');
