// Waiting Paws · training-notes lab · chrome + icons (no framework)
(function () {
  const S = 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
  const ICONS = {
    bolt: '<path d="M13.4 2.2 5.2 13.4h5.6l-1.3 8.4 8.3-11.2h-5.6l1.2-8.4z" fill="currentColor"/>',
    run: '<circle cx="15.2" cy="4.3" r="2.1" fill="currentColor"/><path d="M13.3 8.6 10.9 14M13.3 8.6l-3.2 2-2.6-1.4M13.3 8.6l3 2.5 3.2-.4M10.9 14l3.6 2.6-.9 4.7M10.9 14l-3 3.4-2.4 3" ' + S + '/>',
    stand: '<circle cx="12" cy="4.2" r="2.1" fill="currentColor"/><path d="M12 7.5v6.3M8.6 11.2 12 9.4l3.4 1.8M12 13.8l-2.4 7.4M12 13.8l2.4 7.4" ' + S + '/>',
    bubble: '<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v8a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4h-.5A2.5 2.5 0 0 1 4 13.5z" ' + S + '/><path d="M8 8h8M8 11.5h5" ' + S + '/>',
    note: '<rect x="4" y="3.5" width="16" height="17" rx="3" ' + S + '/><path d="M8 8.5h8M8 12h8M8 15.5h5" ' + S + '/>',
    doc: '<path d="M6.5 3H14l5 5v11.5A1.5 1.5 0 0 1 17.5 21h-11A1.5 1.5 0 0 1 5 19.5v-15A1.5 1.5 0 0 1 6.5 3z" ' + S + '/><path d="M14 3v5h5M8.5 12h7M8.5 15.5h7" ' + S + '/>',
    flag: '<path d="M6 21V4M6 4h11.5l-2.6 4.5 2.6 4.5H6" ' + S + '/>',
    bookmark: '<path d="M6.5 3.5h11v17l-5.5-4-5.5 4z" ' + S + '/>',
    nosign: '<circle cx="12" cy="12" r="8.5" ' + S + '/><path d="M6 6l12 12" ' + S + '/>',
    pause: '<circle cx="12" cy="12" r="8.5" ' + S + '/><path d="M10 8.5v7M14 8.5v7" ' + S + '/>',
    chevD: '<path d="m6.5 9.5 5.5 5.5 5.5-5.5" ' + S + '/>',
    chevU: '<path d="m6.5 14.5 5.5-5.5 5.5 5.5" ' + S + '/>',
    chevR: '<path d="m9.5 6.5 5.5 5.5-5.5 5.5" ' + S + '/>',
    chevL: '<path d="m14.5 6.5-5.5 5.5 5.5 5.5" ' + S + '/>',
    plus: '<path d="M12 5v14M5 12h14" ' + S + '/>',
    minus: '<path d="M5 12h14" ' + S + '/>',
    xmark: '<path d="M6 6l12 12M18 6 6 18" ' + S + '/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7" ' + S + '/>',
    video: '<rect x="3" y="6.5" width="13" height="11" rx="2.5" fill="currentColor"/><path d="M16 10.5l5-3v9l-5-3z" fill="currentColor"/>',
    ellipsis: '<circle cx="6" cy="12" r="1.9" fill="currentColor"/><circle cx="12" cy="12" r="1.9" fill="currentColor"/><circle cx="18" cy="12" r="1.9" fill="currentColor"/>',
    exit: '<path d="M10 4H6.5A1.5 1.5 0 0 0 5 5.5v13A1.5 1.5 0 0 0 6.5 20H10M14 8l4 4-4 4M18 12H9" ' + S + '/>',
    enter: '<path d="M14 4h3.5A1.5 1.5 0 0 1 19 5.5v13a1.5 1.5 0 0 1-1.5 1.5H14M9 8l-4 4 4 4M5 12h10" ' + S + '/>',
    uturn: '<path d="M8 8h7a4 4 0 0 1 0 8H6M9.5 4.5 6 8l3.5 3.5" ' + S + '/>',
    clock: '<circle cx="12" cy="12" r="8.5" ' + S + '/><path d="M12 7.5V12l3 2" ' + S + '/>',
    timer: '<circle cx="12" cy="13" r="7.5" ' + S + '/><path d="M12 9.5V13l2.5 1.5M10 3h4M12 3v2.5" ' + S + '/>',
    bed: '<path d="M3 18v-7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v7M3 15h18M6 9V6.5A1.5 1.5 0 0 1 7.5 5h9A1.5 1.5 0 0 1 18 6.5V9" ' + S + '/>',
    pip: '<rect x="3" y="5" width="18" height="14" rx="2.5" ' + S + '/><rect x="11.5" y="11.5" width="7.5" height="5" rx="1" fill="currentColor"/>',
    split: '<rect x="3" y="5" width="18" height="14" rx="2.5" ' + S + '/><path d="M12 5v14" ' + S + '/>',
    stack: '<rect x="3" y="5" width="18" height="14" rx="2.5" ' + S + '/><path d="M3 12h18" ' + S + '/>',
    grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.5" ' + S + '/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5" ' + S + '/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5" ' + S + '/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5" ' + S + '/>',
    swap: '<path d="M7 7h11M15 4l3 3-3 3M17 17H6M9 14l-3 3 3 3" ' + S + '/>',
    sidebar: '<rect x="3" y="5" width="18" height="14" rx="2.5" ' + S + '/><path d="M15 5v14" ' + S + '/>',
    expand: '<path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7" ' + S + '/>',
    sound: '<path d="M4 9.5v5h3l4 3.5v-12l-4 3.5z" fill="currentColor"/><path d="M15 9l5 6M20 9l-5 6" ' + S + '/>',
    history: '<path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4v4h4M12 8v4.5l3 1.8" ' + S + '/>',
    info: '<circle cx="12" cy="12" r="8.5" ' + S + '/><path d="M12 11v5M12 8v.5" ' + S + '/>',
    text: '<path d="M4 6h16M4 10h10M4 14h16M4 18h10" ' + S + '/>',
    key: '<circle cx="8" cy="12" r="3.5" ' + S + '/><path d="M11.5 12H21M18 12v3M15 12v2.5" ' + S + '/>',
    sliders: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9M4 12h14" ' + S + '/><circle cx="15" cy="7" r="2" fill="currentColor"/><circle cx="9" cy="17" r="2" fill="currentColor"/>',
    finish: '<path d="M5 21V4M5 4h13l-2 4 2 4H5" ' + S + '/><path d="M8 4h3v4H8zM11 8h3v4h-3zM14 4h3v4h-3z" fill="currentColor" opacity=".6"/>',
    hand: '<path d="M8 12V5.5a1.5 1.5 0 0 1 3 0V11M11 10V4.5a1.5 1.5 0 0 1 3 0V11M14 10.5V6a1.5 1.5 0 0 1 3 0v7.5M17 11.5a1.5 1.5 0 0 1 3 1.5v1c0 4.5-3 7-7 7s-5.5-2-8.5-6.5a1.6 1.6 0 0 1 2.6-1.8L8 14" ' + S + '/>',
    lock: '<rect x="5" y="10.5" width="14" height="10" rx="2.5" ' + S + '/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" ' + S + '/>',
    arrowR: '<path d="M5 12h14M13 6l6 6-6 6" ' + S + '/>',
    arrowU: '<path d="M12 19V5M6 11l6-6 6 6" ' + S + '/>',
    arrowDR: '<path d="M7 7l10 10M17 9v8H9" ' + S + '/>',
    walk: '<circle cx="13.5" cy="4.3" r="2.1" fill="currentColor"/><path d="M12.5 8.5 11 14.5M12.5 8.5l-2.8 1.6-1.4 3M12.5 8.5l2.6 2.3 2.5 1M11 14.5l2.8 2.4.3 4.3M11 14.5l-2.2 3-1.3 3.7" ' + S + '/>',
    moon: '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" ' + S + '/>',
    rec: '<circle cx="12" cy="12" r="8.5" ' + S + '/><circle cx="12" cy="12" r="3.5" fill="currentColor"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3" ' + S + '/><path d="M6 11a6 6 0 0 0 12 0M12 17v4" ' + S + '/>',
    dog: '<path d="M4 15.5c0-3 2.5-5.5 6-5.5h4c3.5 0 6 2.5 6 5.5V18H4z" fill="currentColor"/><circle cx="17.5" cy="9" r="3" fill="currentColor"/><path d="M19.5 6.5l1.5-3M15.5 6.5 14 3.5" ' + S + '/>',
    wand: '<path d="M4 20 15 9M13 3l.8 2.2L16 6l-2.2.8L13 9l-.8-2.2L10 6l2.2-.8zM19 11l.5 1.5L21 13l-1.5.5L19 15l-.5-1.5L17 13l1.5-.5z" ' + S + '/>'
  };
  const svg = (name, cls) => '<i class="sf' + (cls ? ' ' + cls : '') + '"><svg viewBox="0 0 24 24" aria-hidden="true">' + (ICONS[name] || ICONS.info) + '</svg></i>';
  window.sf = svg;

  const SCENE = '<svg class="scene" viewBox="0 0 365 205" preserveAspectRatio="xMidYMid slice">' +
    '<rect x="0" y="0" width="365" height="205" fill="url(#g)" opacity="0"/>' +
    '<path d="M0 150 L365 150 L365 205 L0 205 Z" fill="#3a3330" opacity=".9"/>' +
    '<path d="M40 60 L325 60 L365 20 L365 150 L0 150 L0 20 Z" fill="#514b46" opacity=".55"/>' +
    '<rect x="148" y="52" width="70" height="98" rx="2" fill="#2f2d2c" stroke="#8b847c" stroke-width="3"/>' +
    '<rect x="156" y="62" width="54" height="36" rx="1" fill="none" stroke="#5a5753" stroke-width="2"/>' +
    '<rect x="156" y="104" width="54" height="36" rx="1" fill="none" stroke="#5a5753" stroke-width="2"/>' +
    '<circle cx="207" cy="104" r="2" fill="#aaa"/>' +
    '<path d="M70 70 q6 0 6 40 q-16 4 -22 -2 q4 -36 16 -38z" fill="#4f6b95" opacity=".9"/>' +
    '<path d="M88 70 q6 0 6 40 q-16 4 -22 -2 q4 -36 16 -38z" fill="#9b6a5a" opacity=".9"/>' +
    '<rect x="60" y="64" width="40" height="3" rx="1.5" fill="#777"/>' +
    '<rect x="258" y="112" width="48" height="40" rx="2" fill="#4e4541"/>' +
    '<ellipse cx="183" cy="176" rx="64" ry="12" fill="#4b5c73" opacity=".9"/>' +
    '<path d="M136 172 q-16 -4 -18 8" stroke="#ece6dc" stroke-width="5" fill="none" stroke-linecap="round"/>' +
    '<ellipse cx="178" cy="166" rx="34" ry="12" fill="#ece6dc"/>' +
    '<ellipse cx="164" cy="168" rx="11" ry="9" fill="#b98c6e"/>' +
    '<ellipse cx="196" cy="177" rx="10" ry="3.5" fill="#ece6dc"/>' +
    '<circle cx="214" cy="158" r="10" fill="#ece6dc"/>' +
    '<ellipse cx="222" cy="163" rx="7" ry="4.5" fill="#ece6dc"/>' +
    '<path d="M207 151 q-5 -9 2 -13 q5 7 4 12z" fill="#b98c6e"/>' +
    '<circle cx="226" cy="161" r="1.8" fill="#222"/><circle cx="216" cy="156" r="1.3" fill="#222"/>' +
    '</svg>';

  function feed(el) {
    const ts = el.dataset.ts || '2026/10/19 18:29:13';
    const lbl = el.dataset.label;
    el.insertAdjacentHTML('afterbegin', SCENE + '<span class="ts">' + ts + '</span>' + (lbl ? '<span class="lbl">' + lbl + '</span>' : '') + (el.dataset.live ? '<span class="live">LIVE</span>' : ''));
  }

  function phone(p) {
    p.insertAdjacentHTML('afterbegin', '<div class="statusbar"><span>9:41</span><span class="island"></span><span class="st">●●●● ' + '<svg width="16" height="12" viewBox="0 0 16 12"><path d="M8 11.5 6.3 9.8a2.4 2.4 0 0 1 3.4 0zM3.6 7.1a6.2 6.2 0 0 1 8.8 0l-1.3 1.3a4.4 4.4 0 0 0-6.2 0zM1 4.5a10 10 0 0 1 14 0l-1.3 1.3a8.1 8.1 0 0 0-11.4 0z" fill="#fff"/></svg> <svg width="27" height="13" viewBox="0 0 27 13"><rect x=".5" y=".5" width="22" height="12" rx="3.5" stroke="#fff" opacity=".4" fill="none"/><rect x="2" y="2" width="19" height="9" rx="2" fill="#fff"/><path d="M24.5 4.5v4a2 2 0 0 0 0-4z" fill="#fff" opacity=".4"/></svg></span></div>');
    p.insertAdjacentHTML('beforeend', '<div class="homebar"></div>');
  }

  // top bar: data-label, data-rec, data-extra (html for extra pills), data-doc="1" adds the doc.text button
  function topbar(el) {
    const label = el.dataset.label || 'Прихожая';
    let h = '<span class="pill">' + svg('video') + label + '</span>';
    const compact = el.dataset.doc || el.dataset.extra; // a third button: REC keeps only the time
    if (el.dataset.rec) h += '<span class="pill rec"' + (compact ? ' style="padding:0 13px 0 12px"' : '') + '><span class="dot"></span>' + (compact ? '' : 'REC ') + el.dataset.rec + '</span>';
    if (el.dataset.extra) h += el.dataset.extra;
    h += '<span class="sp"></span>';
    if (el.dataset.doc) h += '<span class="pill ic' + (el.dataset.doc === 'on' ? ' on' : '') + '">' + svg('doc') + '</span>';
    h += '<span class="pill ic">' + svg('ellipsis') + '</span>';
    el.innerHTML = h;
  }

  // chips: data-plan="5с,10с,20с*,..." (* = until standing), data-cur (1-based), data-mode outside|break
  function chips(el) {
    const plan = (el.dataset.plan || '').split(',');
    const cur = Number(el.dataset.cur || 1);
    const mode = el.dataset.mode || 'outside';
    let h = '';
    plan.forEach((raw, i) => {
      const n = i + 1;
      const standing = raw.endsWith('*');
      const txt = raw.replace('*', '');
      let cls = 'ch';
      if (mode === 'outside') cls += n < cur ? ' done' : n === cur ? ' cur' : '';
      else cls += n < cur ? ' done' : n === cur ? ' cur' : '';
      if (i > 0) h += '<span class="ln' + (n <= cur - 1 ? ' done' : '') + (mode === 'break' && n === cur ? ' next' : '') + '"></span>';
      h += '<span class="' + cls + '">' + txt + (standing ? svg('stand') : '') + '</span>';
    });
    el.innerHTML = h;
  }

  // ring: data-pct, data-color (pink|blue|yellow), data-time, data-sub, data-inner (second arc pct), data-inner-color
  function ring(el) {
    const pct = Number(el.dataset.pct || 50);
    const col = { pink: '#FFB8CC', blue: '#8CBFFF', yellow: '#FFB84D', green: '#6EE7A0' }[el.dataset.color || 'pink'];
    const r = 60, c = 2 * Math.PI * r;
    let h = '<svg viewBox="0 0 130 130"><circle cx="65" cy="65" r="' + r + '" fill="none" stroke="#3A3A3C" stroke-width="6"/>' +
      '<circle cx="65" cy="65" r="' + r + '" fill="none" stroke="' + col + '" stroke-width="6" stroke-linecap="round" stroke-dasharray="' + (c * pct / 100).toFixed(1) + ' ' + c.toFixed(1) + '"/>';
    if (el.dataset.inner) {
      const r2 = 53, c2 = 2 * Math.PI * r2;
      const col2 = { pink: '#FFB8CC', blue: '#8CBFFF', yellow: '#FFB84D', green: '#6EE7A0' }[el.dataset.innerColor || 'yellow'];
      h += '<circle cx="65" cy="65" r="' + r2 + '" fill="none" stroke="rgba(255,255,255,.08)" stroke-width="4"/>' +
        '<circle cx="65" cy="65" r="' + r2 + '" fill="none" stroke="' + col2 + '" stroke-width="4" stroke-linecap="round" stroke-dasharray="' + (c2 * Number(el.dataset.inner) / 100).toFixed(1) + ' ' + c2.toFixed(1) + '"/>';
    }
    const tight = el.dataset.inner ? ' style="font-size:12px"' : '';
    h += '</svg><div class="tm"><b' + (el.dataset.warn ? ' class="warn"' : '') + (el.dataset.inner ? ' style="font-size:40px"' : '') + '>' + (el.dataset.time || '0:53') + '</b><span' + tight + '>' + (el.dataset.sub || 'осталось') + '</span></div>';
    el.innerHTML = h;
  }

  // buttons: data-state outside|break ; data-size compact ; data-glow
  function btns(el) {
    const st = el.dataset.state || 'outside';
    const left = st === 'outside'
      ? '<span class="b pri blue' + (el.dataset.glow ? ' glow' : '') + '">' + svg('enter') + 'Вернулись</span>'
      : '<span class="b pri pink">' + svg('exit') + 'Вышли</span>';
    el.innerHTML = left + '<span class="b sec">' + svg('uturn') + 'Фальстарт</span>';
  }

  function mbtns(el) {
    const st = el.dataset.state || 'outside';
    const left = st === 'outside'
      ? '<span class="mb pri blue">' + svg('enter') + 'Вернулись<span class="key">Пробел</span></span>'
      : '<span class="mb pri pink">' + svg('exit') + 'Вышли<span class="key">Пробел</span></span>';
    el.innerHTML = left + '<span class="mb sec">' + svg('uturn') + 'Фальстарт<span class="key">⌫</span></span>';
  }

  // Mac toolbar: data-title, data-sub, data-cam (html for the camera control), data-rec, data-extra (html before История)
  function tbar(el) {
    el.innerHTML = '<span class="lights"><i></i><i></i><i></i></span><span class="wt"><b>' + (el.dataset.title || 'Тренировка на понедельник') + '</b><span>' + (el.dataset.sub || 'Аня/Марк · с 18:12') + '</span></span><span class="sp"></span>' +
      (el.dataset.cam || '<span class="tbtn">' + svg('video') + 'Прихожая ⌄</span>') +
      '<span class="tbtn rec"><span class="dot"></span>REC ' + (el.dataset.rec || '1:28') + '</span>' +
      '<span class="tbtn">' + svg('sound') + 'Звук</span>' + (el.dataset.extra || '') +
      '<span class="tbtn">' + svg('history') + 'История</span><span class="tbtn">' + svg('finish') + 'Завершить тренировку и запись</span>';
  }

  // timeline (static)
  function timeline(el) {
    const two = el.dataset.two;
    el.innerHTML = '<div class="h"><b>Таймлайн</b><span class="lg"><i style="background:var(--pink)"></i>выход</span><span class="lg"><i style="background:#5b7799"></i>перерыв</span><span class="lg"><i style="background:var(--yellow)"></i>сверх плана / фальстарт</span><span class="sp"></span>' +
      '<span class="st"><b>7 из 8</b><span>выходов</span></span><span class="st"><b>0</b><span>фальстартов</span></span><span class="st"><b>24:12</b><span>идёт тренировка</span></span><span class="st"><b>≈ 18:46</b><span>конец по плану</span></span><span class="st"><b>+0:14</b><span>от плана</span></span><span class="tbtn">' + svg('sliders') + 'Расписание…</span></div>' +
      '<div class="rows"><span>План</span><div class="track"><div class="now"><b>18:41:08</b></div><i class="ex" style="left:0;width:2%">1</i><i class="br" style="left:2%;width:7%"></i><i class="ex" style="left:9%;width:2%">2</i><i class="br" style="left:11%;width:7%"></i><i class="ex" style="left:18%;width:2.5%">3</i><i class="br" style="left:20.5%;width:7%"></i><i class="ex" style="left:27.5%;width:4%">4</i><i class="br" style="left:31.5%;width:7%"></i><i class="ex" style="left:38.5%;width:2.5%">5</i><i class="br" style="left:41%;width:7%"></i><i class="ex" style="left:48%;width:12%">6</i><i class="br" style="left:60%;width:7%"></i><i class="ex" style="left:67%;width:2.5%">7</i><i class="br" style="left:69.5%;width:7%"></i><i class="ex" style="left:76.5%;width:21%">8</i></div>' +
      '<span>Факт</span><div class="track"><i class="ex" style="left:0;width:2%">1</i><i class="br" style="left:2%;width:7%"></i><i class="ex" style="left:9%;width:2%">2</i><i class="br" style="left:11%;width:7%"></i><i class="ex" style="left:18%;width:2.5%">3</i><i class="br" style="left:20.5%;width:7.5%"></i><i class="ex" style="left:28%;width:3%">4</i><i class="br" style="left:31%;width:7%"></i><i class="ex ghost" style="left:38%;width:62%;border-color:transparent;background:transparent"></i></div>' +
      (two ? '<span>Запись · 2</span>' : '<span>Запись</span>') + '<div class="track"><i class="rec" style="left:0;width:38%">REC 24:12' + (two ? ' · Прихожая' : '') + '</i>' + (two ? '<i class="rec" style="left:0;width:38%;top:16px;opacity:.75;height:10px;font-size:9px">Комната</i>' : '') + '</div></div>';
  }

  document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('i.sf[data-icon]').forEach(i => { i.outerHTML = svg(i.dataset.icon, i.className.replace('sf', '').trim()); });
    document.querySelectorAll('.phone').forEach(phone);
    document.querySelectorAll('.topbar[data-label], .topbar[data-auto]').forEach(topbar);
    document.querySelectorAll('.feed').forEach(feed);
    document.querySelectorAll('.chips[data-plan]').forEach(chips);
    document.querySelectorAll('.ring[data-time]').forEach(ring);
    document.querySelectorAll('.btns[data-state]').forEach(btns);
    document.querySelectorAll('.mbtns[data-state]').forEach(mbtns);
    document.querySelectorAll('.tbar[data-auto]').forEach(tbar);
    document.querySelectorAll('.tl[data-auto]').forEach(timeline);
    // icons inside late-inserted html
    document.querySelectorAll('i.sf[data-icon]').forEach(i => { i.outerHTML = svg(i.dataset.icon, i.className.replace('sf', '').trim()); });
    // collapsibles
    document.querySelectorAll('.coll > .coll-h, .coll > [data-toggle]').forEach(h => h.addEventListener('click', e => { e.stopPropagation(); h.parentElement.classList.toggle('open'); }));
    // generic show/hide demos: [data-show="#id"] toggles .hidden on target
    document.querySelectorAll('[data-show]').forEach(b => b.addEventListener('click', () => {
      document.querySelectorAll(b.dataset.show).forEach(t => t.classList.toggle('hidden'));
      b.classList.toggle('on');
    }));
  });
})();
