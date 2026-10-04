#!/usr/bin/env node
// Generates the logo files from logos.js:
//   svg/<id>-<slug>.svg                       default palette, square, ready for an app icon
//   svg/all-palettes/<id>-<slug>-<palette>.svg every concept in every palette
//   png/<id>-<slug>.png                       1024 px renders of the default palette (needs rsvg-convert)
//   sheets/<mix|palette>.svg + .png            contact sheets with rounded iOS-style previews
// Usage: node build.js
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { PALETTES, CONCEPTS, fullSVG, viewOf } = require('./logos.js');

for (const d of ['svg', 'png', 'sheets']) fs.rmSync(path.join(__dirname, d), { recursive: true, force: true });
const out = d => { const p = path.join(__dirname, d); fs.mkdirSync(p, { recursive: true }); return p; };
const svgDir = out('svg'), allDir = out('svg/all-palettes'), pngDir = out('png'), sheetDir = out('sheets');
const name = c => `${c.id}-${c.slug}`;
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

let rsvg = true;
try { execFileSync('rsvg-convert', ['--version']); } catch { rsvg = false; console.warn('rsvg-convert not found: PNG output skipped'); }
const toPNG = (svgFile, pngFile, width) => rsvg && execFileSync('rsvg-convert', ['-w', String(width), '-o', pngFile, svgFile]);

for (const c of CONCEPTS) {
  const file = path.join(svgDir, name(c) + '.svg');
  fs.writeFileSync(file, fullSVG(c, c.pal));
  toPNG(file, path.join(pngDir, name(c) + '.png'), viewOf(c)[0]);
  for (const k of Object.keys(PALETTES)) fs.writeFileSync(path.join(allDir, `${name(c)}-${k}.svg`), fullSVG(c, k));
}

// contact sheets
const COLS = 6, CELL = 300, ICON = 236, PAD = 32, LABEL = 54;
function sheet(key) {
  const rows = Math.ceil(CONCEPTS.length / COLS);
  const W = COLS * CELL + PAD * 2, Hh = rows * (CELL + LABEL - 40) + PAD * 2 + 50;
  const title = key === 'mix' ? 'Микс палитр' : PALETTES[key].name;
  let body = `<rect width="${W}" height="${Hh}" fill="#141416"/>
    <text x="${PAD}" y="${PAD + 18}" font-family="Arial" font-size="24" font-weight="bold" fill="#eee">Waiting Paws · логотипы v2 · ${esc(title)}</text>`;
  CONCEPTS.forEach((c, i) => {
    const col = i % COLS, row = Math.floor(i / COLS);
    const x = PAD + col * CELL + (CELL - ICON) / 2, y = PAD + 50 + row * (CELL + LABEL - 40);
    const [w, h] = viewOf(c), ih = ICON * h / w, oy = (ICON - ih) / 2;
    const svg = fullSVG(c, key === 'mix' ? c.pal : key, { mask: true, size: ICON, uid: 's' });
    body += `<g transform="translate(${x} ${y + oy})">${svg}</g>
      <text x="${x}" y="${y + (c.wide ? oy + ih : ICON) + 28}" font-family="Arial" font-size="17" fill="#ddd"><tspan font-weight="bold" fill="#888">${c.id}</tspan>  ${esc(c.name)}</text>`;
  });
  const file = path.join(sheetDir, key + '.svg');
  fs.writeFileSync(file, `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${Hh}" viewBox="0 0 ${W} ${Hh}">${body}</svg>`);
  toPNG(file, path.join(sheetDir, key + '.png'), W);
}
['mix', ...Object.keys(PALETTES)].forEach(sheet);

console.log(`${CONCEPTS.length} concepts × ${Object.keys(PALETTES).length} palettes → ${path.relative(process.cwd(), __dirname) || '.'}/{svg,png,sheets}`);
