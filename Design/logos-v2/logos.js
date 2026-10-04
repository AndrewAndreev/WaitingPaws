// Waiting Paws — logo concepts as code.
// Shared by index.html (gallery) and build.js (node: writes SVG files and PNG sheets).
// Every concept draws into a 1024×1024 canvas (wordmark: 1600×560) using colour tokens
// var(--fg) etc.; fullSVG() resolves them into concrete colours for a given palette.
(function (root) {
  const PALETTES = {
    night:   { name: 'Ночь (как в приложении)', bg: '#0B0B0C', fg: '#FFB8CC', acc2: '#E8799C', mid: '#2A2A30', ink: '#0B0B0C', hi: '#FFE6EE', eye: '#0B0B0C' },
    pink:    { name: 'Розовый',     bg: '#FFB8CC', fg: '#1A1215', acc2: '#8E3D57', mid: '#F49AB5', ink: '#FFB8CC', hi: '#FFF3F7', eye: '#FFB8CC' },
    sunset:  { name: 'Закат',       bg: ['#FF9C8C', '#FF5C88'], fg: '#FFFFFF', acc2: '#FFD0DC', mid: 'rgba(255,255,255,.26)', ink: '#F4607F', hi: '#FFF4F6', eye: '#7C1D3C' },
    apricot: { name: 'Абрикос',     bg: '#FFF1E3', fg: '#EE7A3B', acc2: '#B5502A', mid: '#F8D8BB', ink: '#FFF1E3', hi: '#FFFFFF', eye: '#3A2114' },
    sky:     { name: 'Ночное небо', bg: ['#2C3C6E', '#131A35'], fg: '#FFD36B', acc2: '#F09F38', mid: '#36477F', ink: '#1A2346', hi: '#FFF2CC', eye: '#1A2346' },
    mint:    { name: 'Мята',        bg: '#DDF4EA', fg: '#1E6B57', acc2: '#3EA182', mid: '#B4E2CF', ink: '#DDF4EA', hi: '#FFFFFF', eye: '#0B2E25' },
    violet:  { name: 'Фиалка',      bg: ['#8D6EFF', '#4A2CD0'], fg: '#FFFFFF', acc2: '#D5CBFF', mid: 'rgba(255,255,255,.22)', ink: '#5B3CE2', hi: '#FFFFFF', eye: '#2A1580' },
    mono:    { name: 'Моно',        bg: '#FFFFFF', fg: '#121212', acc2: '#5C5C5C', mid: '#E6E6E6', ink: '#FFFFFF', hi: '#FFFFFF', eye: '#FFFFFF' },
  };
  const TOKENS = ['fg', 'acc2', 'mid', 'ink', 'hi', 'eye']; // eye: facial features drawn on top of fg

  // ---------- drawing helpers ----------
  const F = 'var(--fg)', A = 'var(--acc2)', M = 'var(--mid)', K = 'var(--ink)', H = 'var(--hi)', E = 'var(--eye)';
  const FONT = 'font-family="Arial Rounded MT Bold, SF Pro Rounded, ui-rounded, system-ui, sans-serif"';
  const r1 = n => Math.round(n * 10) / 10;
  const P = (cx, cy, r, deg) => [r1(cx + r * Math.cos(deg * Math.PI / 180)), r1(cy + r * Math.sin(deg * Math.PI / 180))];
  const arc = (cx, cy, r, a0, a1) => {
    const [x0, y0] = P(cx, cy, r, a0), [x1, y1] = P(cx, cy, r, a1);
    return `M${x0} ${y0}A${r} ${r} 0 ${Math.abs(a1 - a0) > 180 ? 1 : 0} 1 ${x1} ${y1}`;
  };
  const range = n => Array.from({ length: n }, (_, i) => i);

  // paw print centred on (0,0), about 230×218 at scale 1
  const PAD = 'M0 -2C40 -2 78 32 82 66C86 98 60 112 38 106C22 102 12 94 0 94C-12 94 -22 102 -38 106C-60 112 -86 98 -82 66C-78 32 -40 -2 0 -2Z';
  const TOES = '<ellipse cx="-88" cy="-22" rx="27" ry="35" transform="rotate(-30 -88 -22)"/><ellipse cx="-34" cy="-72" rx="29" ry="38" transform="rotate(-10 -34 -72)"/><ellipse cx="34" cy="-72" rx="29" ry="38" transform="rotate(10 34 -72)"/><ellipse cx="88" cy="-22" rx="27" ry="35" transform="rotate(30 88 -22)"/>';
  const paw = (x, y, s = 1, rot = 0, fill = F, op = 1) =>
    `<g transform="translate(${x} ${y}) rotate(${rot}) scale(${s})" fill="${fill}"${op < 1 ? ` opacity="${op}"` : ''}><path d="${PAD}"/>${TOES}</g>`;

  // dog sitting with its back to us; base at y=862, centred on x=512
  const dogBack = (fill, { tail = 'M630 850C700 866 770 840 782 776', ears = 'floppy', collar = null } = {}) => {
    const earsSVG = ears === 'floppy'
      ? `<ellipse cx="428" cy="524" rx="38" ry="76" transform="rotate(16 428 524)"/><ellipse cx="596" cy="524" rx="38" ry="76" transform="rotate(-16 596 524)"/>`
      : `<path d="M444 470L438 356L506 430Z" stroke="${fill}" stroke-width="30" stroke-linejoin="round"/><path d="M580 470L586 356L518 430Z" stroke="${fill}" stroke-width="30" stroke-linejoin="round"/>`;
    return `<g fill="${fill}">${earsSVG}<circle cx="512" cy="508" r="94"/>
      <path d="M456 574C398 640 358 740 366 802C371 848 410 862 512 862C614 862 653 848 658 802C666 740 626 640 568 574Z"/></g>
      <path d="${tail}" fill="none" stroke="${fill}" stroke-width="34" stroke-linecap="round"/>
      ${collar ? `<path d="M452 594Q512 622 572 594" fill="none" stroke="${collar}" stroke-width="20" stroke-linecap="round"/>` : ''}`;
  };

  // paws poking out from under a door (door bottom at y=650)
  const underDoorPaws = () => `
    ${paw(420, 712, .7, 180)}${paw(604, 712, .7, 180)}
    <rect x="300" y="650" width="424" height="20" fill="${K}"/>
    <rect x="196" y="814" width="632" height="18" rx="9" fill="${F}" opacity=".3"/>`;

  // letters spaced around a circle, reading clockwise; baseline radius r, glyphs grow outward
  const W = { W: .94, A: .72, I: .3, T: .62, N: .72, G: .78, P: .67, S: .67, ' ': .3, '•': .45 };
  const ringText = (str, cx, cy, r, size, fill, startDeg = 0) => {
    const ws = [...str].map(ch => (W[ch] || .7) * size), circ = 2 * Math.PI * r;
    const extra = (circ - ws.reduce((a, b) => a + b, 0)) / ws.length;
    let s = 0;
    return [...str].map((ch, i) => {
      const deg = startDeg + (s + ws[i] / 2) / circ * 360; s += ws[i] + extra;
      if (ch === ' ') return '';
      const [x, y] = P(cx, cy, r, deg - 90);
      return `<text transform="translate(${x} ${y}) rotate(${r1(deg)})" text-anchor="middle" font-size="${size}" fill="${fill}" ${FONT}>${ch}</text>`;
    }).join('');
  };

  // simple stroke "z" for the sleeping dog
  const zee = (x, y, s, op = 1) => `<path d="M${x - s} ${y - s}H${x + s}L${x - s} ${y + s}H${x + s}" fill="none" stroke="${F}" stroke-width="${r1(s * .5)}" stroke-linecap="round" stroke-linejoin="round"${op < 1 ? ` opacity="${op}"` : ''}/>`;

  // stroke digits for "0:30" (height 144, centred at x,y)
  const digit0 = (x, y) => `<ellipse cx="${x}" cy="${y}" rx="44" ry="70"/>`;
  const digit3 = (x, y) => `<path d="M${x - 44} ${y - 46}C${x - 36} ${y - 64} ${x - 20} ${y - 72} ${x} ${y - 72}C${x + 28} ${y - 72} ${x + 44} ${y - 56} ${x + 44} ${y - 36}C${x + 44} ${y - 14} ${x + 26} ${y - 2} ${x + 2} ${y - 2}C${x + 30} ${y - 2} ${x + 48} ${y + 16} ${x + 48} ${y + 38}C${x + 48} ${y + 60} ${x + 28} ${y + 72} ${x} ${y + 72}C${x - 22} ${y + 72} ${x - 38} ${y + 62} ${x - 48} ${y + 46}"/>`;

  // ---------- concepts ----------
  const C = [];
  const add = (id, name, pal, idea, svg, extra = {}) => C.push({ id, name, pal, idea, svg, ...extra });

  add('01a', 'Лапки под дверью', 'night', 'Пёс ждёт по ту сторону: из-под закрытой двери видны только лапы.', () => `<g transform="translate(0 22)">
    ${underDoorPaws()}
    <path d="M312 650V206Q312 150 368 150H656Q712 150 712 206V650Z" fill="${F}"/>
    <g fill="none" stroke="${K}" stroke-width="14" opacity=".3"><rect x="362" y="204" width="254" height="188" rx="18"/><rect x="362" y="436" width="254" height="166" rx="18"/></g>
    <circle cx="664" cy="420" r="20" fill="${K}"/></g>`);

  add('01b', 'Лапки под дверью · арка', 'mint', 'Тот же сюжет с арочной дверью — мягче и дружелюбнее.', () => `<g transform="translate(0 22)">
    ${underDoorPaws()}
    <path d="M322 650V340A190 190 0 0 1 702 340V650Z" fill="${F}"/>
    <path d="M384 600V352A128 128 0 0 1 640 352V600Z" fill="none" stroke="${K}" stroke-width="14" opacity=".3"/>
    <circle cx="664" cy="470" r="18" fill="${K}"/></g>`);

  add('02', 'Скважина-собака', 'apricot', 'Замочная скважина, которая на самом деле — сидящая собака с висячими ушами.', () => `
    <rect x="317" y="122" width="390" height="780" rx="195" fill="${F}"/>
    <g fill="${K}">
      <ellipse cx="420" cy="432" rx="44" ry="86" transform="rotate(14 420 432)"/>
      <ellipse cx="604" cy="432" rx="44" ry="86" transform="rotate(-14 604 432)"/>
      <circle cx="512" cy="414" r="100"/>
      <path d="M462 496H562L624 744Q630 774 600 774H424Q394 774 400 744Z"/>
    </g>
    <g fill="${F}"><circle cx="474" cy="408" r="13"/><circle cx="550" cy="408" r="13"/><path d="M490 446Q512 438 534 446Q536 462 512 474Q488 462 490 446Z"/></g>
    <circle cx="512" cy="200" r="15" fill="${K}" opacity=".35"/><circle cx="512" cy="836" r="15" fill="${K}" opacity=".35"/>`);

  add('03a', 'Секундомер', 'sunset', 'Лапа внутри секундомера — таймеры выходов и перерывов.', () => `
    <rect x="452" y="148" width="120" height="64" rx="24" fill="${F}"/>
    <rect x="490" y="200" width="44" height="60" fill="${F}"/>
    <rect x="718" y="296" width="76" height="52" rx="18" fill="${F}" transform="rotate(45 756 322)"/>
    <circle cx="512" cy="566" r="292" fill="none" stroke="${F}" stroke-width="54"/>
    <g stroke="${F}" stroke-width="14" stroke-linecap="round" opacity=".45">${range(12).map(i => { const [a, b] = P(512, 566, 222, i * 30 - 90), [c, d] = P(512, 566, 244, i * 30 - 90); return `<line x1="${a}" y1="${b}" x2="${c}" y2="${d}"/>`; }).join('')}</g>
    ${paw(512, 574, .92)}`);

  add('03b', 'Секундомер · прогресс', 'night', 'Вместо циферблата — кольцо прогресса, как полоска выходов в приложении.', () => `
    <rect x="452" y="148" width="120" height="64" rx="24" fill="${F}"/>
    <rect x="490" y="200" width="44" height="60" fill="${F}"/>
    <circle cx="512" cy="566" r="292" fill="none" stroke="${M}" stroke-width="58"/>
    <path d="${arc(512, 566, 292, -90, 150)}" fill="none" stroke="${F}" stroke-width="58" stroke-linecap="round"/>
    ${paw(512, 574, .98)}`);

  add('04', 'Объектив', 'night', 'Камера смотрит за питомцем: лапа в зрачке объектива и точка записи.', () => `
    <circle cx="512" cy="512" r="372" fill="${M}"/>
    <circle cx="512" cy="512" r="318" fill="none" stroke="${F}" stroke-width="34"/>
    <circle cx="512" cy="512" r="262" fill="${K}"/>
    ${paw(512, 518, 1.12)}
    <path d="${arc(512, 512, 226, 196, 246)}" fill="none" stroke="${H}" stroke-width="22" stroke-linecap="round" opacity=".45"/>
    <circle cx="832" cy="194" r="44" fill="#FF5A6A"/>`);

  add('05a', 'Ждёт у двери', 'night', 'Собака сидит спиной к нам и смотрит на дверь — главный сюжет тренировки.', () => `
    <path d="M302 842V372A210 210 0 0 1 722 372V842Z" fill="${M}"/>
    <circle cx="670" cy="640" r="16" fill="${F}" opacity=".55"/>
    <rect x="170" y="842" width="684" height="24" rx="12" fill="${F}" opacity=".5"/>
    ${dogBack(F, { collar: A })}`);

  add('05b', 'Ждёт у двери · часы', 'night', 'Тот же сюжет, а над собакой часы — сколько ещё ждать.', () => `
    <path d="M302 842V372A210 210 0 0 1 722 372V842Z" fill="${M}"/>
    <circle cx="512" cy="300" r="74" fill="${K}" stroke="${F}" stroke-width="18"/>
    <path d="M512 300V256M512 300L544 318" fill="none" stroke="${F}" stroke-width="14" stroke-linecap="round"/>
    <circle cx="670" cy="640" r="16" fill="${F}" opacity=".55"/>
    <rect x="170" y="842" width="684" height="24" rx="12" fill="${F}" opacity=".5"/>
    ${dogBack(F, { collar: A })}`, { chosen: 'night' });

  add('06', 'Лапа-многоточие', 'violet', 'Индикатор «печатает…» превращается в лапу: ожидание.', () => `
    <path d="M330 690L248 852L476 726Z" fill="${F}"/>
    <rect x="160" y="200" width="704" height="540" rx="210" fill="${F}"/>
    <circle cx="372" cy="420" r="58" fill="${K}"/>
    <circle cx="512" cy="394" r="58" fill="${K}" opacity=".7"/>
    <circle cx="652" cy="420" r="58" fill="${K}" opacity=".4"/>
    <path d="${PAD}" transform="translate(512 512) scale(1.2)" fill="${K}"/>`);

  add('07', 'Песочные часы', 'mint', 'Время утекает, а внизу остаётся след лапы.', () => `
    <rect x="270" y="176" width="484" height="58" rx="29" fill="${F}"/>
    <rect x="270" y="790" width="484" height="58" rx="29" fill="${F}"/>
    <path d="M336 234C336 400 474 456 474 512C474 568 336 624 336 790M688 234C688 400 550 456 550 512C550 568 688 624 688 790" fill="none" stroke="${F}" stroke-width="30" stroke-linecap="round"/>
    <path d="M420 380Q512 408 604 380C580 440 528 466 520 506H504C496 466 444 440 420 380Z" fill="${F}" opacity=".5"/>
    <line x1="512" y1="520" x2="512" y2="628" stroke="${F}" stroke-width="10" stroke-linecap="round" stroke-dasharray="1 22"/>
    ${paw(512, 706, .6)}`);

  add('08', 'Пёс в окне', 'apricot', 'Знакомая картина: морда и лапы на подоконнике — ждёт хозяина.', u => `
    <defs><clipPath id="w${u}"><circle cx="512" cy="480" r="300"/></clipPath></defs>
    <g clip-path="url(#w${u})">
      <rect width="1024" height="1024" fill="${M}"/>
      <ellipse cx="512" cy="690" rx="196" ry="180" fill="${F}"/>
      <ellipse cx="335" cy="640" rx="62" ry="118" transform="rotate(25 335 640)" fill="${A}"/>
      <ellipse cx="689" cy="640" rx="62" ry="118" transform="rotate(-25 689 640)" fill="${A}"/>
      <circle cx="442" cy="616" r="24" fill="${E}"/><circle cx="582" cy="616" r="24" fill="${E}"/>
      <circle cx="450" cy="608" r="7" fill="${H}"/><circle cx="590" cy="608" r="7" fill="${H}"/>
      <path d="M470 666Q512 652 554 666Q558 694 512 712Q466 694 470 666Z" fill="${E}"/>
    </g>
    <circle cx="512" cy="480" r="300" fill="none" stroke="${F}" stroke-width="44"/>
    <rect x="190" y="770" width="644" height="60" rx="30" fill="${F}"/>
    ${[410, 614].map(x => `<path d="M${x - 70} 800V762A70 54 0 0 1 ${x + 70} 762V800Z" fill="${H}"/><g stroke="${A}" stroke-width="10" stroke-linecap="round"><line x1="${x - 24}" y1="770" x2="${x - 24}" y2="800"/><line x1="${x + 24}" y1="770" x2="${x + 24}" y2="800"/></g>`).join('')}`);

  add('09', 'Дверь с ушами', 'pink', 'Дверь сама становится собакой: уши, глаза и нос.', () => `<g transform="translate(0 -36)">
    <rect x="210" y="858" width="604" height="24" rx="12" fill="${M}"/>
    <path d="M342 862V430A170 170 0 0 1 682 430V862Z" fill="${F}"/>
    <rect x="412" y="586" width="200" height="226" rx="16" fill="none" stroke="${K}" stroke-width="14" opacity=".3"/>
    <circle cx="646" cy="700" r="17" fill="${E}"/>
    <ellipse cx="334" cy="452" rx="58" ry="126" transform="rotate(20 334 452)" fill="${A}"/>
    <ellipse cx="690" cy="452" rx="58" ry="126" transform="rotate(-20 690 452)" fill="${A}"/>
    <circle cx="456" cy="440" r="21" fill="${E}"/><circle cx="568" cy="440" r="21" fill="${E}"/>
    <path d="M476 494Q512 482 548 494Q551 518 512 534Q473 518 476 494Z" fill="${E}"/></g>`);

  add('10', 'Спокойный пёс', 'sky', 'Цель тренировок — пёс спокойно спит, пока никого нет дома.', () => `<g transform="translate(0 -30)">
    <rect x="140" y="772" width="744" height="20" rx="10" fill="${M}"/>
    <path d="M742 712C820 712 856 650 830 596" fill="none" stroke="${F}" stroke-width="34" stroke-linecap="round"/>
    <rect x="300" y="562" width="470" height="210" rx="105" fill="${F}"/>
    <circle cx="340" cy="582" r="122" fill="${F}"/>
    <ellipse cx="250" cy="642" rx="80" ry="58" fill="${F}"/>
    <rect x="168" y="704" width="236" height="68" rx="34" fill="${F}" stroke="${K}" stroke-width="12"/>
    <ellipse cx="396" cy="604" rx="50" ry="104" transform="rotate(-22 396 604)" fill="${A}"/>
    <path d="M274 600Q298 622 322 600" fill="none" stroke="${E}" stroke-width="13" stroke-linecap="round"/>
    <ellipse cx="182" cy="628" rx="22" ry="17" fill="${E}"/>
    ${zee(650, 430, 40)}${zee(740, 330, 28, .6)}</g>`);

  add('11', 'Будильник-пёс', 'mint', 'Будильник, у которого вместо звонков — висячие уши, а ось стрелок — нос.', () => `<g transform="translate(0 -52)">
    <ellipse cx="292" cy="412" rx="66" ry="132" transform="rotate(28 292 412)" fill="${A}"/>
    <ellipse cx="732" cy="412" rx="66" ry="132" transform="rotate(-28 732 412)" fill="${A}"/>
    <ellipse cx="404" cy="846" rx="72" ry="40" fill="${F}"/><ellipse cx="620" cy="846" rx="72" ry="40" fill="${F}"/>
    <circle cx="512" cy="572" r="282" fill="${F}"/>
    <circle cx="512" cy="572" r="226" fill="${K}"/>
    <g stroke="${F}" stroke-linecap="round">${range(12).map(i => { const big = i % 3 === 0; const [a, b] = P(512, 572, big ? 176 : 188, i * 30 - 90), [c, d] = P(512, 572, 204, i * 30 - 90); return `<line x1="${a}" y1="${b}" x2="${c}" y2="${d}" stroke-width="${big ? 16 : 10}" opacity="${big ? 1 : .5}"/>`; }).join('')}</g>
    <path d="M512 572V430M512 572L612 626" fill="none" stroke="${F}" stroke-width="26" stroke-linecap="round"/>
    <path d="M470 556Q512 538 554 556Q558 586 512 606Q466 586 470 556Z" fill="${F}"/></g>`);

  add('12', 'Циферблат следов', 'night', 'Двенадцать следов вместо часовых меток: пройденные выходы яркие, впереди — приглушённые.', () => `
    ${range(12).map(i => { const t = -90 + i * 30; const [x, y] = P(512, 512, 330, t); return paw(x, y, .38, t + 180, F, i < 5 ? 1 : .28); }).join('')}
    <path d="M512 512V292M512 512L612 685" fill="none" stroke="${F}" stroke-width="30" stroke-linecap="round"/>
    <circle cx="512" cy="512" r="36" fill="${F}"/>`);

  add('13', 'Нос у стекла', 'night', 'Нос и лапы прижаты к стеклянной двери, от дыхания запотело.', () => `
    <rect width="1024" height="1024" fill="${F}"/>
    <ellipse cx="512" cy="676" rx="262" ry="176" fill="${H}" opacity=".3"/>
    ${paw(296, 322, .62, -16, E)}${paw(728, 322, .62, 16, E)}
    <path d="M512 548C612 548 700 570 700 640C700 718 600 758 512 806C424 758 324 718 324 640C324 570 412 548 512 548Z" fill="${E}"/>
    <ellipse cx="446" cy="664" rx="40" ry="22" transform="rotate(24 446 664)" fill="${F}" opacity=".45"/>
    <ellipse cx="578" cy="664" rx="40" ry="22" transform="rotate(-24 578 664)" fill="${F}" opacity=".45"/>
    <ellipse cx="560" cy="590" rx="66" ry="20" fill="${H}" opacity=".35"/>`);

  const recToes = () => [-150, -110, -70, -30].map(t => { const [x, y] = P(512, 612, 322, t); return `<circle cx="${x}" cy="${y}" r="64" fill="${F}"/>`; }).join('');
  add('14a', 'Лапа-запись', 'mono', 'Подушечка — кнопка записи, пальцы — чистые круги. Отлично читается в мелком размере.', () => `<g transform="translate(0 -28)">
    <circle cx="512" cy="612" r="208" fill="none" stroke="${F}" stroke-width="26"/>
    <circle cx="512" cy="612" r="166" fill="${F}"/>${recToes()}</g>`);

  add('14b', 'Лапа-таймер', 'night', 'Та же геометрическая лапа, но вокруг подушечки бежит таймер.', () => `<g transform="translate(0 -28)">
    <circle cx="512" cy="612" r="206" fill="none" stroke="${M}" stroke-width="34"/>
    <path d="${arc(512, 612, 206, -90, 160)}" fill="none" stroke="${F}" stroke-width="34" stroke-linecap="round"/>
    <circle cx="512" cy="612" r="150" fill="${F}"/>${recToes()}</g>`);

  add('15', 'Свет из двери', 'sky', 'Тёмная комната, открытый проём и силуэт собаки в полосе света.', () => `
    <path d="M362 700H662L860 1024H164Z" fill="${F}" opacity=".35"/>
    <rect x="362" y="150" width="300" height="550" fill="${F}"/>
    <path d="M362 150L284 198V690L362 700Z" fill="${M}"/>
    <g transform="translate(512 880) scale(.8) translate(-512 -862)">${dogBack(K, { tail: 'M628 852C690 866 742 846 750 800' })}</g>`);

  add('16', 'Лапа-сердце', 'sunset', 'Подушечка в форме сердца — про заботу и связь с собакой.', () => `<g fill="${F}">
    <path d="M512 800C380 700 300 630 300 545C300 480 350 440 405 440C455 440 495 470 512 505C529 470 569 440 619 440C674 440 724 480 724 545C724 630 644 700 512 800Z"/>
    <ellipse cx="276" cy="408" rx="58" ry="74" transform="rotate(-32 276 408)"/>
    <ellipse cx="418" cy="290" rx="62" ry="80" transform="rotate(-12 418 290)"/>
    <ellipse cx="606" cy="290" rx="62" ry="80" transform="rotate(12 606 290)"/>
    <ellipse cx="748" cy="408" rx="58" ry="74" transform="rotate(32 748 408)"/></g>`);

  add('17', 'Будка', 'mint', 'Будка с глазами в темноте проёма: «я дома, я жду».', () => `
    <rect x="244" y="460" width="536" height="386" fill="${F}"/>
    <path d="M512 196L846 476H178Z" fill="${A}" stroke="${A}" stroke-width="36" stroke-linejoin="round"/>
    ${paw(512, 384, .34, 0, K)}
    <path d="M394 846V664A118 118 0 0 1 630 664V846Z" fill="${E}"/>
    <ellipse cx="470" cy="690" rx="19" ry="25" fill="${F}"/><ellipse cx="554" cy="690" rx="19" ry="25" fill="${F}"/>`);

  add('18', 'Морда с ушами', 'violet', 'Дружелюбный портрет: висячие уши, пятно у глаза.', () => `<g transform="translate(0 -24)">
    <circle cx="512" cy="540" r="250" fill="${F}"/>
    <ellipse cx="590" cy="500" rx="86" ry="96" fill="${A}"/>
    <ellipse cx="512" cy="668" rx="142" ry="104" fill="${H}"/>
    <ellipse cx="282" cy="520" rx="88" ry="188" transform="rotate(16 282 520)" fill="${A}"/>
    <ellipse cx="742" cy="520" rx="88" ry="188" transform="rotate(-16 742 520)" fill="${A}"/>
    <circle cx="432" cy="514" r="30" fill="${E}"/><circle cx="592" cy="514" r="30" fill="${E}"/>
    <circle cx="442" cy="504" r="9" fill="${H}"/><circle cx="602" cy="504" r="9" fill="${H}"/>
    <path d="M466 614Q512 596 558 614Q562 646 512 668Q462 646 466 614Z" fill="${E}"/>
    <path d="M512 668V696M470 708Q492 728 512 698Q532 728 554 708" fill="none" stroke="${E}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/></g>`);

  add('19', 'Сиба', 'apricot', 'Стоячие уши и светлая мордочка — более «характерный» портрет.', () => `<g transform="translate(0 -14)">
    <path d="M318 430L338 196L488 330Z" fill="${F}" stroke="${F}" stroke-width="44" stroke-linejoin="round"/>
    <path d="M706 430L686 196L536 330Z" fill="${F}" stroke="${F}" stroke-width="44" stroke-linejoin="round"/>
    <path d="M356 372L364 270L432 330Z" fill="${A}" stroke="${A}" stroke-width="22" stroke-linejoin="round"/>
    <path d="M668 372L660 270L592 330Z" fill="${A}" stroke="${A}" stroke-width="22" stroke-linejoin="round"/>
    <path d="M512 300C680 300 772 410 772 560C772 720 660 806 512 806C364 806 252 720 252 560C252 410 344 300 512 300Z" fill="${F}"/>
    <path d="M512 562C604 562 668 614 668 684C668 754 594 796 512 796C430 796 356 754 356 684C356 614 420 562 512 562Z" fill="${H}"/>
    <ellipse cx="430" cy="454" rx="26" ry="15" fill="${H}"/><ellipse cx="594" cy="454" rx="26" ry="15" fill="${H}"/>
    <ellipse cx="430" cy="522" rx="25" ry="30" fill="${E}"/><ellipse cx="594" cy="522" rx="25" ry="30" fill="${E}"/>
    <path d="M470 618Q512 602 554 618Q558 646 512 664Q466 646 470 618Z" fill="${E}"/>
    <path d="M512 664V690M474 702Q494 720 512 694Q530 720 550 702" fill="none" stroke="${E}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/></g>`);

  add('20a', 'Ожидание', 'night', 'Системный индикатор загрузки вокруг лапы: «подожди немного».', () => `
    <g stroke="${F}" stroke-width="46" stroke-linecap="round">${range(12).map(i => { const t = -90 + i * 30; const [a, b] = P(512, 512, 270, t), [c, d] = P(512, 512, 370, t); return `<line x1="${a}" y1="${b}" x2="${c}" y2="${d}" opacity="${r1(1 - i * .068)}"/>`; }).join('')}</g>
    ${paw(512, 516, 1.02)}`);

  add('20b', 'Ожидание · точки', 'sunset', 'Тот же индикатор из точек, которые уменьшаются по кругу.', () => `
    ${range(12).map(i => { const t = -90 + i * 30; const [x, y] = P(512, 512, 330, t); return `<circle cx="${x}" cy="${y}" r="${r1(44 - i * 2.4)}" fill="${F}" opacity="${r1(1 - i * .06)}"/>`; }).join('')}
    ${paw(512, 516, 1.08)}`);

  add('21', 'Повтор', 'violet', 'Цикл «выход — перерыв — выход»: две стрелки по кругу.', () => {
    const R = 318;
    const head = a => { const [x, y] = P(512, 512, R, a); const [tx, ty] = P(x, y, 62, a + 90); const [o1x, o1y] = P(x, y, 62, a), [o2x, o2y] = P(x, y, -62, a); return `<path d="M${o1x} ${o1y}L${tx} ${ty}L${o2x} ${o2y}Z" fill="${F}" stroke="${F}" stroke-width="22" stroke-linejoin="round"/>`; };
    return `<g fill="none" stroke="${F}" stroke-width="58" stroke-linecap="round"><path d="${arc(512, 512, R, -62, 54)}"/><path d="${arc(512, 512, R, 118, 234)}"/></g>${head(54)}${head(234)}${paw(512, 516, 1.02)}`;
  });

  add('22', 'Жетон 0:30', 'pink', 'Адресник на ошейник с таймером первого выхода.', () => `
    <circle cx="512" cy="590" r="290" fill="${F}"/>
    <circle cx="512" cy="346" r="28" fill="${K}"/>
    <circle cx="512" cy="270" r="74" fill="none" stroke="${M}" stroke-width="26"/>
    ${paw(512, 466, .4, 0, K)}
    <g fill="none" stroke="${K}" stroke-width="32" stroke-linecap="round">${digit0(368, 652)}${digit3(532, 652)}${digit0(656, 652)}</g>
    <circle cx="450" cy="624" r="16" fill="${K}"/><circle cx="450" cy="686" r="16" fill="${K}"/>`);

  add('23', 'Эмблема', 'sky', 'Круглый знак с надписью — для сайта, наклеек, сплэша.', () => `
    <circle cx="512" cy="512" r="420" fill="${F}"/>
    <circle cx="512" cy="512" r="296" fill="${K}"/>
    ${ringText('WAITING PAWS • WAITING PAWS • ', 512, 512, 334, 72, K, -96)}
    ${paw(512, 520, 1.1)}`);

  add('24', 'Лапа-часы', 'sunset', 'Большая лапа, подушечка — циферблат со стрелками.', () => `${paw(512, 500, 1.9)}
    <path d="M512 612V530M512 612L572 646" fill="none" stroke="${K}" stroke-width="24" stroke-linecap="round"/>
    <circle cx="512" cy="612" r="20" fill="${K}"/>`);

  add('25', 'Выглядывает', 'night', 'Из-за приоткрытой двери выглядывает любопытная морда.', () => `
    <rect x="236" y="140" width="560" height="780" rx="28" fill="none" stroke="${M}" stroke-width="28"/>
    <circle cx="430" cy="470" r="148" fill="${F}"/>
    <ellipse cx="322" cy="476" rx="48" ry="114" transform="rotate(18 322 476)" fill="${A}"/>
    <circle cx="390" cy="446" r="24" fill="${E}"/><circle cx="397" cy="439" r="7" fill="${H}"/>
    <ellipse cx="468" cy="532" rx="38" ry="28" fill="${E}"/>
    <ellipse cx="444" cy="736" rx="64" ry="44" fill="${F}"/>
    <rect x="490" y="154" width="292" height="752" rx="14" fill="${M}"/>
    <g fill="none" stroke="${K}" stroke-width="12" opacity=".5"><rect x="534" y="206" width="180" height="276" rx="14"/><rect x="534" y="532" width="180" height="310" rx="14"/></g>
    <circle cx="748" cy="540" r="17" fill="${F}"/>`);

  add('26', 'Wordmark', 'night', 'Надпись с лапками вместо точек над «i» — для сплэша и сайта. Шрифт Arial Rounded; для продакшена перевести в кривые.', () => `
    <text x="116" y="360" font-size="220" fill="${F}" letter-spacing="-4" ${FONT}>Waıtıng Paws</text>
    ${paw(469, 192, .27)}${paw(599, 192, .27)}`, { wide: true, view: [1600, 560] });

  const SLUG = {
    '01a': 'door-paws', '01b': 'door-paws-arch', '02': 'keyhole-dog', '03a': 'stopwatch', '03b': 'stopwatch-progress', '04': 'lens',
    '05a': 'dog-at-door', '05b': 'dog-at-door-clock', '06': 'typing-paw', '07': 'hourglass', '08': 'window-dog', '09': 'door-with-ears',
    '10': 'sleeping-dog', '11': 'alarm-dog', '12': 'paw-clock', '13': 'nose-on-glass', '14a': 'rec-paw', '14b': 'timer-paw',
    '15': 'doorway-light', '16': 'heart-paw', '17': 'doghouse', '18': 'face-floppy', '19': 'face-shiba', '20a': 'spinner',
    '20b': 'spinner-dots', '21': 'repeat', '22': 'tag-0-30', '23': 'emblem', '24': 'paw-clock-pad', '25': 'peek', '26': 'wordmark',
  };
  C.forEach(c => { c.slug = SLUG[c.id] || c.id; });

  // ---------- output ----------
  const bgFill = (p, w, h, id) => Array.isArray(p.bg)
    ? `<defs><linearGradient id="${id}" x1="0.33" y1="0" x2="0.67" y2="1"><stop offset="0" stop-color="${p.bg[0]}"/><stop offset="1" stop-color="${p.bg[1]}"/></linearGradient></defs><rect width="${w}" height="${h}" fill="url(#${id})"/>`
    : `<rect width="${w}" height="${h}" fill="${p.bg}"/>`;
  const resolve = (s, p) => s.replace(/var\(--(\w+)\)/g, (m, k) => (TOKENS.includes(k) ? p[k] : m));
  const viewOf = c => c.view || [1024, 1024];

  // Standalone SVG with concrete colours. opts.mask rounds the corners like an iOS icon (previews only).
  function fullSVG(c, palKey, opts = {}) {
    const p = PALETTES[palKey], [w, h] = viewOf(c), u = 'x' + c.id + palKey + (opts.uid || '');
    const body = bgFill(p, w, h, 'bg' + u) + resolve(c.svg(u), p);
    const rx = c.wide ? 40 : 229;
    const content = opts.mask
      ? `<defs><clipPath id="m${u}"><rect width="${w}" height="${h}" rx="${rx}"/></clipPath></defs><g clip-path="url(#m${u})">${body}</g>`
      : body;
    const size = opts.size ? ` width="${opts.size * w / Math.max(w, h)}" height="${opts.size * h / Math.max(w, h)}"` : ` width="${w}" height="${h}"`;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}"${size}>${content.replace(/\s*\n\s*/g, '')}</svg>`;
  }

  const api = { PALETTES, CONCEPTS: C, fullSVG, viewOf };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.WP = api;
})(this);
