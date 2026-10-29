// LokalBot UGC demo, the over-the-top cut, 1080 × 1920. Every value on screen
// is a function of time: `window.__seek(t)` lays the frame out and waits for
// the footage frames it shows. render.cjs steps it frame by frame; edit.json
// (from build_edit.py) holds the timeline, every cue, and per frame each
// visible app window's footage frame, camera and pointer.
const E = await (await fetch('edit.json')).json();
await Promise.all(['600', '800', '850', '900'].map(w => document.fonts.load(`${w} 60px Inter`)));

const VW = 1080;
const [AX, AY] = E.anchor;
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, t) => a + (b - a) * t;
const inv = (a, b, x) => clamp((x - a) / (b - a));
const ease = {
  outCubic: t => 1 - (1 - t) ** 3,
  inCubic: t => t * t * t,
  inOutCubic: t => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2),
  outBack: (t, s = 1.7) => 1 + (s + 1) * (t - 1) ** 3 + s * (t - 1) ** 2,
};
const seg = (t, a, b, e = ease.inOutCubic) => e(inv(a, b, t));
const $ = id => document.getElementById(id);
const show = (node, o) => { node.style.opacity = o.toFixed(3); node.style.visibility = o > 0.001 ? 'visible' : 'hidden'; };
const pad = n => String(n).padStart(4, '0');
const rng = seed => () => { seed = (seed + 0x6d2b79f5) | 0; let x = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x; return ((x ^ (x >>> 14)) >>> 0) / 4294967296; };

/** Piecewise-linear lookup in [[t, value], ...], held at both ends. */
function along(points, t) {
  if (t <= points[0][0]) return points[0][1];
  for (let i = 1; i < points.length; i++) {
    const [t0, v0] = points[i - 1], [t1, v1] = points[i];
    if (t <= t1) return t1 === t0 ? v1 : lerp(v0, v1, (t - t0) / (t1 - t0));
  }
  return points[points.length - 1][1];
}

// Hits: a zoom punch, a shake that dies away, a white flash, a pulse on each beat.
function punch(t) {
  let p = 0;
  for (const [s, a] of E.punches) {
    const k = t - s;
    if (k >= 0 && k < 0.42) p += a * (k < 0.04 ? k / 0.04 : 1 - ease.outCubic((k - 0.04) / 0.38));
  }
  return p;
}
function shake(t) {
  let x = 0, y = 0, r = 0;
  for (const [s, amp, dur] of E.shakes) {
    const k = t - s;
    if (k < 0 || k > dur) continue;
    const a = amp * (1 - k / dur) ** 2;
    x += a * Math.sin(k * 71 + s * 13);
    y += a * Math.sin(k * 59 + s * 7 + 1.3);
    r += a * 0.05 * Math.sin(k * 43 + s);
  }
  return [x, y, r];
}
function flash(t) {
  let f = 0;
  for (const [s, a] of E.flashes) {
    const k = t - s;
    if (k >= 0 && k < 0.2) f = Math.max(f, a * (1 - k / 0.2) ** 2);
  }
  return f;
}
function beat(t) {
  let last = -1e9;
  for (const b of E.music.beats) { if (b <= t) last = b; else break; }
  return Math.exp(-(t - last) / 0.11);
}
// Red marker circles, drawn on in footage pixels so they ride with the camera.
const SVG = 'http://www.w3.org/2000/svg';
function ringPath(r, i) {
  const [cx, cy, rx, ry] = r.ring, rand = rng(i + 7);
  if (r.under) {
    // An underline instead, for text with lines close above and below it:
    // one stroke that lifts a little at its end, like a quick marker swipe.
    const pts = [];
    for (let j = 0; j <= 40; j++) {
      const u = j / 40;
      pts.push([cx - rx + 2 * rx * u, cy + ry + 4 * Math.sin(u * 5 + i) - 14 * u ** 3]);
    }
    return 'M' + pts.map(p => p.map(v => v.toFixed(1)).join(' ')).join(' L');
  }
  // A wide, flat ring tilts less, so its arc stays off the lines above and below.
  const th0 = -Math.PI * (0.62 + 0.2 * rand()), span = Math.PI * 2.16,
    tilt = (-4 + 3 * rand()) * Math.PI / 180 * Math.min(1, 3 * ry / rx);
  const pts = [];
  for (let j = 0; j <= 90; j++) {
    const th = th0 + span * j / 90, g = 1 + 0.045 * Math.sin(th * 1.7 + i) + 0.07 * j / 90;
    const x = rx * g * Math.cos(th), y = ry * g * Math.sin(th);
    pts.push([cx + x * Math.cos(tilt) - y * Math.sin(tilt), cy + x * Math.sin(tilt) + y * Math.cos(tilt)]);
  }
  return 'M' + pts.map(p => p.map(v => v.toFixed(1)).join(' ')).join(' L');
}

// The two window layers. Each shows one take's frame through its camera, the
// drawn pointer (a vector arrow, sharp at any zoom), and ripples where it clicked.
const pointerSrc = E.cursor.file || 'data:image/svg+xml,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="68" height="92" viewBox="0 0 17 23"><path d="M1 1v18.5l4.6-4.4 2.9 6.6 2.9-1.3-2.8-6.5H15z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>');
const [PW, PH] = E.cursor.size || [17, 23], [HX, HY] = E.cursor.hot || [1, 1], PS = E.cursor.scale || 3;
const layers = ['L0', 'L1'].map((id, n) => {
  const node = $(id), cam = node.querySelector('.cam'), win = node.querySelector('.win');
  const img = win.querySelector('img'), svg = node.querySelector('.rings'), pointer = node.querySelector('.pointer');
  pointer.src = pointerSrc;
  pointer.style.width = `${PW * PS}px`;
  pointer.style.height = `${PH * PS}px`;
  return { n, node, cam, win, img, svg, pointer, take: null, shown: '', rings: [], ripples: [] };
});

function dress(layer, take) {
  if (layer.take === take) return;
  layer.take = take;
  const [fw, fh] = E.takes[take].size;
  layer.win.style.width = `${fw}px`;
  layer.win.style.height = `${fh}px`;
  layer.win.style.borderRadius = `${E.takes[take].radius || 40}px`;
  layer.svg.setAttribute('width', fw);
  layer.svg.setAttribute('height', fh);
  layer.svg.innerHTML = '';
  layer.rings = E.rings.map((r, i) => ({ ...r, i })).filter(r => r.take === take).map(r => {
    const el = document.createElementNS(SVG, 'path');
    el.setAttribute('d', ringPath(r, r.i));
    layer.svg.appendChild(el);
    const len = el.getTotalLength();
    el.style.strokeDasharray = `${len}`;
    return { ...r, el, len };
  });
  layer.ripples = [0, 1].map(() => {
    const el = document.createElementNS(SVG, 'circle');
    layer.svg.appendChild(el);
    return el;
  });
}

async function paint(layer, spec, t, zoom) {
  if (!spec) { show(layer.node, 0); return; }
  show(layer.node, 1);
  dress(layer, spec.take);
  const src = `footage/${spec.take}/${pad(spec.n)}.jpg`;
  if (src !== layer.shown) {
    layer.shown = src;
    layer.img.src = src;
    await layer.img.decode();
  }
  const [cx, cy, k0] = spec.cam, k = k0 * zoom;
  layer.cam.style.transform = `translate(${(AX - cx * k).toFixed(2)}px, ${(AY - cy * k).toFixed(2)}px) scale(${k.toFixed(4)})`;
  // Flying out upwards, or in from below with a little overshoot.
  let oy = 0, rot = 0, sc = 1, blur = 0;
  if (spec.fly) {
    const [way, u] = spec.fly, v = clamp(u);
    if (way === 'out') { oy = -ease.inCubic(v) * 1700; rot = -7 * v; sc = 1 - 0.12 * v; blur = 34 * v; }
    else { oy = (1 - ease.outBack(v, 1.3)) * 1900; rot = 8 * (1 - v); sc = 1 - 0.1 * (1 - v); blur = 34 * (1 - ease.outCubic(v)); }
  }
  layer.node.style.transform = `translateY(${oy.toFixed(1)}px) rotate(${rot.toFixed(2)}deg) scale(${sc.toFixed(4)})`;
  const filter = $(`mb${layer.n}`).firstElementChild;
  filter.setAttribute('stdDeviation', `0 ${blur.toFixed(1)}`);
  layer.node.style.filter = blur > 0.5 ? `url(#mb${layer.n})` : 'none';
  // The pointer dips as it clicks.
  if (spec.cursor) {
    const [x, y, down] = spec.cursor, s = 1 - 0.16 * down;
    layer.pointer.style.transform = `translate(${(x - HX * PS * s).toFixed(1)}px, ${(y - HY * PS * s).toFixed(1)}px) scale(${s.toFixed(3)})`;
    show(layer.pointer, 1);
  } else show(layer.pointer, 0);
  layer.ripples.forEach((el, i) => {
    const r = spec.ripples[i];
    if (!r) { el.style.opacity = '0'; return; }
    const [x, y, age] = r, k = clamp(age / 0.6);
    el.setAttribute('cx', x);
    el.setAttribute('cy', y);
    el.setAttribute('r', (14 + 86 * ease.outCubic(k)).toFixed(1));
    el.setAttribute('stroke-width', (14 * (1 - k) + 2).toFixed(1));
    el.style.opacity = (1 - k).toFixed(3);
  });
  for (const r of layer.rings) {
    const on = t >= r.from && t < r.to;
    const k = seg(t, r.from, r.from + 0.3, ease.outCubic);
    r.el.style.strokeDashoffset = `${(r.len * (1 - k)).toFixed(1)}`;
    r.el.style.opacity = on ? (1 - inv(r.to - 0.1, r.to, t)).toFixed(3) : '0';
  }
}

// Captions: an outline made of shadows, so it reads over the light screen.
const outline = Array.from({ length: 16 }, (_, i) => {
  const a = i / 16 * 2 * Math.PI;
  return `${(8 * Math.cos(a)).toFixed(1)}px ${(8 * Math.sin(a)).toFixed(1)}px 0 #000`;
}).join(', ') + ', 0 14px 0 #000';
document.head.insertAdjacentHTML('beforeend', `<style>#caps .w { text-shadow: ${outline}; }</style>`);

function captions(t) {
  const box = $('caps');
  const i = E.captions.findIndex(c => t >= c.from && t < c.to);
  const c = E.captions[i];
  const key = c ? String(c.from) : '';
  if (box.dataset.key !== key) {
    box.dataset.key = key;
    box.innerHTML = c ? `<div class="chunk">${c.words.map(w => `<span class="w ${w[3] || ''}">${w[0]}</span>`).join(' ')}</div>` : '';
  }
  if (!c) return;
  const chunk = box.firstElementChild;
  chunk.style.transform = `rotate(${((i * 37) % 7 - 3) * 0.8}deg)`;
  [...chunk.children].forEach((node, j) => {
    const [, s, e] = c.words[j];
    const next = c.words[j + 1] ? c.words[j + 1][1] : e + 0.3;
    const k = c.from === 0 && j === 0 ? 1 : inv(s - 0.04, s + 0.12, t);
    const on = t >= s - 0.02 && t < Math.max(e, next - 0.02);
    const sc = lerp(1.7, 1, ease.outBack(k)) * (on ? 1.06 : 1);
    node.style.opacity = Math.min(1, k * 3).toFixed(3);
    node.style.transform = `scale(${sc.toFixed(4)}) rotate(${lerp((j % 2 ? 9 : -9), 0, ease.outCubic(k)).toFixed(2)}deg)`;
  });
}

function emoji(t) {
  const node = $('emoji');
  const i = E.emojis.findIndex(m => t >= m.from && t < m.to);
  if (i < 0) { show(node, 0); return; }
  const m = E.emojis[i], right = i % 2 === 0;
  if (node.textContent !== m.emoji) node.textContent = m.emoji;
  node.style.left = right ? '820px' : '40px';
  const k = m.from === 0 ? 1 : inv(m.from, m.from + 0.24, t), out = inv(m.to - 0.12, m.to, t);
  const sc = Math.max(0, ease.outBack(k, 2.4)) * (1 - ease.inCubic(out));
  const rot = (right ? 14 : -14) + 7 * Math.sin((t - m.from) * 9);
  node.style.transform = `scale(${sc.toFixed(4)}) rotate(${rot.toFixed(2)}deg)`;
  show(node, Math.min(1, k * 4));
}

// Confetti: two bursts on the end card, from a fixed seed.
const confetti = (() => {
  const rand = rng(23), colors = ['#6ef2dc', '#23c4ae', '#ffd23f', '#ffffff', '#ff3b5c'];
  const burst = (at, n, x, y) => Array.from({ length: n }, () => {
    const a = -Math.PI / 2 + (rand() - 0.5) * Math.PI * 1.15, v = 900 + rand() * 1300;
    return { at, x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, w: 14 + rand() * 14, h: 8 + rand() * 8,
             spin: (rand() - 0.5) * 18, rot: rand() * 6, color: colors[Math.floor(rand() * colors.length)] };
  });
  const endFrom = E.shots.find(s => s.id === 'end').from;
  return [...burst(endFrom, 60, 540, 640), ...burst(E.end_cues.name, 120, 540, 900)];
})();
function drawConfetti(t) {
  const cv = $('confetti'), g = cv.getContext('2d');
  g.clearRect(0, 0, cv.width, cv.height);
  for (const p of confetti) {
    const k = t - p.at;
    if (k < 0 || k > 2.6) continue;
    const drag = (1 - Math.exp(-2.2 * k)) / 2.2;
    const x = p.x + p.vx * drag, y = p.y + p.vy * drag + 900 * k * k;
    g.save();
    g.translate(x, y);
    g.rotate(p.rot + p.spin * k);
    g.globalAlpha = clamp(1 - (k - 1.8) / 0.8);
    g.fillStyle = p.color;
    g.fillRect(-p.w / 2, -p.h / 2, p.w, p.h * Math.abs(Math.cos(k * 7 + p.rot)) + 2);
    g.restore();
  }
}

const endShot = E.shots.find(s => s.id === 'end');
const shock = (node, at, t) => {
  const k = inv(at, at + 0.55, t);
  const size = 40 + 1500 * ease.outCubic(k);
  node.style.width = node.style.height = `${size.toFixed(1)}px`;
  node.style.transform = `translate(${(-size / 2).toFixed(1)}px, ${(-size / 2).toFixed(1)}px)`;
  node.style.borderWidth = `${(2 + 22 * (1 - k)).toFixed(1)}px`;
  show(node, t >= at && k < 1 ? 1 - k : 0);
};

window.__fps = E.fps;
window.__duration = E.duration;
window.__seek = async t => {
  const shot = E.shots.find(s => t >= s.from && t < s.to) || E.shots[E.shots.length - 1];
  const end = shot.id === 'end';
  const b = beat(t);

  const [sx, sy, sr] = shake(t);
  $('world').style.transform = `translate(${sx.toFixed(2)}px, ${sy.toFixed(2)}px) rotate(${sr.toFixed(3)}deg)`;
  $('glowA').style.transform = `scale(${(1 + 0.08 * b).toFixed(4)})`;
  $('glowB').style.transform = `scale(${(1 + 0.08 * b).toFixed(4)})`;
  $('glowA').style.opacity = (0.45 + 0.45 * b).toFixed(3);
  $('glowB').style.opacity = (0.4 + 0.4 * b).toFixed(3);
  $('progress').style.width = `${(VW * t / E.duration).toFixed(1)}px`;
  show($('flash'), flash(t));

  show($('title'), end ? 0 : 1);
  $('title').querySelector('.sticker').style.transform = `rotate(-2deg) scale(${(1 + 0.025 * b).toFixed(4)})`;

  // The app windows; a new shot opens with a small push in.
  const specs = end ? [] : E.frames[Math.min(E.frames.length - 1, Math.round(t * E.fps))];
  const zoom = 1 + punch(t) + 0.012 * b + 0.05 * (1 - seg(t, shot.from, shot.from + 0.3, ease.outCubic));
  await Promise.all(layers.map((layer, i) => paint(layer, specs[i], t, zoom)));

  // Tab keycap: pops in for the run of presses, dips and bursts on each one.
  const keys = E.keys, kc = $('keycap');
  const kIn = inv(keys[0] - 0.2, keys[0] - 0.02, t), kOut = inv(keys[keys.length - 1] + 0.4, keys[keys.length - 1] + 0.55, t);
  show(kc, kIn > 0 && kOut < 1 ? 1 : 0);
  const press = Math.max(0, ...keys.map(k => (t >= k - 0.02 && t < k + 0.14 ? 1 - inv(k + 0.03, k + 0.14, t) : 0)));
  const kScale = ease.outBack(kIn, 2.2) * (1 - ease.inCubic(kOut)) * (1 - 0.06 * press);
  kc.style.transform = `translateX(-50%) translateY(${(press * 12).toFixed(2)}px) scale(${kScale.toFixed(4)}) rotate(-3deg)`;
  kc.style.boxShadow = `0 ${(14 - press * 11).toFixed(1)}px 0 #9aa7b5, 0 34px 50px -18px rgba(11,16,22,0.6)`;
  const lastPress = keys.filter(k => k <= t).pop();
  const bk = lastPress === undefined ? 1 : inv(lastPress, lastPress + 0.3, t);
  const bs = 60 + 520 * ease.outCubic(bk);
  const burst = $('keyburst');
  burst.style.width = burst.style.height = `${bs.toFixed(1)}px`;
  burst.style.transform = `translate(${(-bs / 2).toFixed(1)}px, ${(-bs / 2).toFixed(1)}px)`;
  show(burst, bk < 1 && !end ? 0.9 * (1 - bk) : 0);

  const sped = E.sped_up.find(([s0, s1]) => t >= s0 && t < s1);
  if (sped) {
    const [s0, s1] = sped, sk = inv(s0, s0 + 0.2, t), so = inv(s1 - 0.12, s1, t);
    $('sped').style.transform = `rotate(5deg) scale(${(ease.outBack(sk, 2.2) * (1 - so)).toFixed(4)})`;
  }
  show($('sped'), sped ? 1 : 0);

  // End card: the mark and name slam in on the cut, a chip slams on each fact, the name again on "LokalBot".
  const endEl = $('end');
  show(endEl, end ? 1 : 0);
  if (end) {
    const a = endShot.from, cue = E.end_cues;
    $('rays').style.transform = `rotate(${(t * 22).toFixed(2)}deg) scale(${(1 + 0.04 * b).toFixed(4)})`;
    shock($('shockA'), a, t);
    shock($('shockB'), cue.name, t);
    const mk = inv(a, a + 0.16, t), land = t - (a + 0.16);
    const bounce = land > 0 ? 0.09 * Math.sin(land * 26) * Math.exp(-land * 7) : 0;
    const mark = $('mark');
    mark.style.opacity = Math.min(1, mk * 5).toFixed(3);
    mark.style.transform = `scale(${(lerp(3, 1, ease.inCubic(mk)) * (1 + bounce + 0.035 * b)).toFixed(4)})`;
    const slam = (node, at, from = 2.2, rot = 0) => {
      const k = inv(at - 0.03, at + 0.14, t);
      node.style.opacity = Math.min(1, k * 4).toFixed(3);
      node.style.transform = `scale(${lerp(from, 1, ease.inCubic(k)).toFixed(4)}) rotate(${lerp(rot * 3, rot, k).toFixed(2)}deg)`;
    };
    endEl.querySelectorAll('.chip').forEach((chip, i) => slam(chip, cue[chip.dataset.cue], 2.0, [-4, 3, -3][i]));
    // The name lands with the mark and slams again as it is said.
    slam($('name'), a + 0.1, 2.4);
    const nk = t - cue.name;
    const again = nk >= 0 && nk < 0.42 ? 0.28 * (nk < 0.05 ? nk / 0.05 : 1 - ease.outCubic((nk - 0.05) / 0.37)) : 0;
    if (again) $('name').style.transform += ` scale(${(1 + again).toFixed(4)})`;
    const uk = seg(t, cue.name + 0.25, cue.name + 0.55, ease.outCubic);
    $('url').style.opacity = uk.toFixed(3);
    $('url').style.transform = `translateX(-50%) translateY(${((1 - uk) * 30).toFixed(1)}px)`;
    drawConfetti(t);
  }

  captions(t);
  emoji(t);
};

window.__ready = true;
if (!navigator.webdriver) {
  // Opened in a browser: play it.
  const t0 = performance.now();
  const tick = async () => { await window.__seek(((performance.now() - t0) / 1000) % E.duration); requestAnimationFrame(tick); };
  tick();
}
