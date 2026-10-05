#!/usr/bin/env node
// Builds the app icon from the chosen concept in logos.js:
//   Design/app-icon/AppIcon-ios.svg     full-bleed square (iOS masks it itself)
//   Design/app-icon/AppIcon-macos.svg   824 px rounded rect with shadow on a 1024 canvas (macOS icon grid)
//   App/Resources/Assets.xcassets/AppIcon.appiconset/*.png + Contents.json
//   App/Resources/Assets.xcassets/AppIconImage.imageset (the iOS icon for the setup screens)
// Usage: node app-icon.js   (needs rsvg-convert and ImageMagick)
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { CONCEPTS, PALETTES, fullSVG } = require('./logos.js');

const CONCEPT = '07', PALETTE = 'night';

const project = path.resolve(__dirname, '../..');
const srcDir = path.join(project, 'Design/app-icon');
const setDir = path.join(project, 'App/Resources/Assets.xcassets/AppIcon.appiconset');
fs.mkdirSync(srcDir, { recursive: true });

const concept = CONCEPTS.find(c => c.id === CONCEPT);
const bg = PALETTES[PALETTE].bg;
const ios = fullSVG(concept, PALETTE);

// macOS: artwork inside the standard 824×824 body (radius 185.4) with the system-style drop shadow
const body = 'x="100" y="100" width="824" height="824" rx="185.4"';
const inner = ios.replace('width="1024" height="1024"', 'x="100" y="100" width="824" height="824"');
const macos = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
  <clipPath id="body"><rect ${body}/></clipPath>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="12"/><feOffset dy="10" result="blur"/>
    <feFlood flood-color="#000" flood-opacity=".32"/><feComposite in2="blur" operator="in"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
</defs>
<rect ${body} fill="${bg}" filter="url(#shadow)"/>
<g clip-path="url(#body)">${inner}</g>
<rect x="101" y="101" width="822" height="822" rx="184.4" fill="none" stroke="#fff" stroke-opacity=".08" stroke-width="2"/>
</svg>`;

fs.writeFileSync(path.join(srcDir, 'AppIcon-ios.svg'), ios);
fs.writeFileSync(path.join(srcDir, 'AppIcon-macos.svg'), macos);

for (const f of fs.readdirSync(setDir)) if (f.endsWith('.png')) fs.unlinkSync(path.join(setDir, f));
const render = (svgFile, size, out) => execFileSync('rsvg-convert', ['-w', String(size), '-h', String(size), '-o', path.join(setDir, out), svgFile]);

// iOS: App Store rejects icons with an alpha channel
render(path.join(srcDir, 'AppIcon-ios.svg'), 1024, 'AppIcon-ios-1024.png');
execFileSync('magick', [path.join(setDir, 'AppIcon-ios-1024.png'), '-background', bg, '-alpha', 'remove', '-alpha', 'off', '-strip', '-define', 'png:exclude-chunks=date,time', path.join(setDir, 'AppIcon-ios-1024.png')]);

// The same picture as an image for the iPhone welcome and sign-in screens (an app icon set can't be shown in the UI).
const imageDir = path.join(project, 'App/Resources/Assets.xcassets/AppIconImage.imageset');
fs.mkdirSync(imageDir, { recursive: true });
fs.copyFileSync(path.join(setDir, 'AppIcon-ios-1024.png'), path.join(imageDir, 'AppIcon.png'));
fs.writeFileSync(path.join(imageDir, 'Contents.json'), JSON.stringify({ images: [{ filename: 'AppIcon.png', idiom: 'universal' }], info: { author: 'xcode', version: 1 } }, null, 2) + '\n');

const images = [{ filename: 'AppIcon-ios-1024.png', idiom: 'universal', platform: 'ios', size: '1024x1024' }];
for (const pt of [16, 32, 128, 256, 512]) for (const scale of [1, 2]) {
  const px = pt * scale, file = `AppIcon-mac-${px}.png`;
  if (!fs.existsSync(path.join(setDir, file))) render(path.join(srcDir, 'AppIcon-macos.svg'), px, file);
  images.push({ filename: file, idiom: 'mac', scale: `${scale}x`, size: `${pt}x${pt}` });
}
fs.writeFileSync(path.join(setDir, 'Contents.json'), JSON.stringify({ images, info: { author: 'xcode', version: 1 } }, null, 2) + '\n');

console.log(`App icon: ${CONCEPT} / ${PALETTE} → ${path.relative(project, setDir)} (${images.length} images)`);
