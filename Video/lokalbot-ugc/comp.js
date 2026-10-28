// LokalBot UGC demo, 1080 × 1920. Every value on screen is a function of time:
// `window.__seek(t)` lays the frame out and waits for the footage frame it
// shows. render.cjs steps it frame by frame; edit.json (from build_edit.py)
// holds the timeline.
const E = await (await fetch('edit.json')).json();
await Promise.all(['500', '650', '800', '850'].map(w => document.fonts.load(`${w} 60px Inter`)));

const VW = 1080, VH = 1120;
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, t) => a + (b - a) * t;
const inv = (a, b, x) => clamp((x - a) / (b - a));
const ease = {
  outCubic: t => 1 - (1 - t) ** 3,
  inCubic: t => t * t * t,
  inOutCubic: t => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2),
  outBack: (t, s = 1.4) => 1 + (s + 1) * (t - 1) ** 3 + s * (t - 1) ** 2,
};
const seg = (t, a, b, e = ease.inOutCubic) => e(inv(a, b, t));
const $ = id => document.getElementById(id);
const show = (node, o) => { node.style.opacity = o.toFixed(3); node.style.visibility = o > 0.001 ? 'visible' : 'hidden'; };
const pad = n => String(n).padStart(4, '0');

/** Piecewise-linear lookup in [[t, value], ...], held at both ends. */
function along(points, t) {
  if (t <= points[0][0]) return points[0][1];
  for (let i = 1; i < points.length; i++) {
    const [t0, v0] = points[i - 1], [t1, v1] = points[i];
    if (t <= t1) return t1 === t0 ? v1 : lerp(v0, v1, (t - t0) / (t1 - t0));
  }
  return points[points.length - 1][1];
}

/** Camera keyframes [t, cx, cy, scale], eased between neighbours. */
function camera(keys, t) {
  if (t <= keys[0][0]) return keys[0].slice(1);
  for (let i = 1; i < keys.length; i++) {
    const a = keys[i - 1], b = keys[i];
    if (t <= b[0]) {
      const k = seg(t, a[0], b[0]);
      return [lerp(a[1], b[1], k), lerp(a[2], b[2], k), lerp(a[3], b[3], k)];
    }
  }
  return keys[keys.length - 1].slice(1);
}

function footageFrame(shot, t) {
  if (shot.src === 'hero') {
    const n = Math.round(clamp(along(shot.map, t), shot.clamp[0], shot.clamp[1]));
    return `footage/hero/${pad(n)}.jpg`;
  }
  const s = clamp(along(shot.time_map, t), shot.clamp[0], shot.clamp[1]);
  return `footage/tab/${pad(Math.round(s * 30) + 1)}.jpg`;
}

const words = E.captions.flatMap(c => c.words);
const wordAt = (re, after = 0) => words.find(w => w[1] >= after && re.test(w[0]));
const endShot = E.shots.find(s => s.id === 'end');
const endCue = {
  free: wordAt(/^free/i, endShot.from - 0.3)[1],
  open: wordAt(/^open/i, endShot.from - 0.3)[1],
  runs: wordAt(/^runs/i, endShot.from - 0.3)[1],
  name: wordAt(/^called/i, endShot.from - 0.3)[1],
};

const img = $('foot');
let shown = '';
async function setFrame(src) {
  if (src === shown) return;
  shown = src;
  img.src = src;
  await img.decode();
}

function captions(t) {
  const box = $('caps');
  const c = E.captions.find(c => t >= c.from && t < c.to);
  const key = c ? String(c.from) : '';
  if (box.dataset.key !== key) {
    box.dataset.key = key;
    box.innerHTML = c ? `<div class="chunk">${c.words.map(w => `<span class="w">${w[0]}</span>`).join(' ')}</div>` : '';
  }
  if (!c) return;
  const chunk = box.firstElementChild;
  const k = c.from === 0 ? 1 : inv(c.from, c.from + 0.14, t);
  chunk.style.transform = `scale(${lerp(0.9, 1, ease.outBack(k)).toFixed(4)})`;
  chunk.style.opacity = Math.min(1, k * 2.5).toFixed(3);
  [...chunk.children].forEach((node, i) => {
    const [, s, e] = c.words[i];
    const next = c.words[i + 1] ? c.words[i + 1][1] : e + 0.3;
    node.classList.toggle('on', t >= s - 0.02 && t < Math.max(e, next - 0.02));
  });
}

window.__fps = E.fps;
window.__duration = E.duration;
window.__seek = async t => {
  const shot = E.shots.find(s => t >= s.from && t < s.to) || E.shots[E.shots.length - 1];
  const end = shot.id === 'end';

  // Top band and viewport cut to the end card.
  const out = t >= endShot.from ? 1 : 0;
  show($('title'), 1 - out);
  show($('viewport'), 1 - out);

  if (!end) {
    await setFrame(footageFrame(shot, t));
    const cam = $('cam');
    cam.className = shot.src === 'tab' ? 'window' : '';
    let [cx, cy, s] = camera(shot.cam, t);
    // A small push on every cut, the way a phone edit punches in.
    s *= 1 + 0.035 * (1 - seg(t, shot.from, shot.from + 0.28, ease.outCubic));
    cam.style.transform = `translate(${(VW / 2 - cx * s).toFixed(2)}px, ${(VH / 2 - cy * s).toFixed(2)}px) scale(${s.toFixed(4)})`;
  }

  // Tab keycap: shows for the run of presses and dips on each one.
  const keys = E.keys;
  const kOn = Math.min(seg(t, keys[0] - 0.22, keys[0] - 0.06, ease.outCubic), 1 - seg(t, keys[keys.length - 1] + 0.45, keys[keys.length - 1] + 0.65));
  show($('keycap'), kOn);
  const press = Math.max(0, ...keys.map(k => (t >= k - 0.02 && t < k + 0.16 ? 1 - inv(k + 0.04, k + 0.16, t) : 0)));
  $('keycap').style.transform = `translateX(-50%) translateY(${(press * 8).toFixed(2)}px)`;
  $('keycap').style.boxShadow = `0 ${(10 - press * 8).toFixed(1)}px 0 #c9d2dc, 0 26px 40px -18px rgba(14,20,28,0.55)`;

  show($('sped'), Math.min(seg(t, E.sped_up[0], E.sped_up[0] + 0.2), 1 - seg(t, E.sped_up[1] - 0.2, E.sped_up[1])));

  // End card: the mark first, a chip on each spoken fact, the name as it is said.
  const endEl = $('end');
  show(endEl, out);
  const rise = (node, at, dur = 0.32) => {
    const k = seg(t, at, at + dur, ease.outCubic);
    node.style.opacity = k.toFixed(3);
    node.style.transform = `translateY(${((1 - k) * 18).toFixed(2)}px)`;
  };
  const mark = endEl.querySelector('img');
  const mk = seg(t, endShot.from, endShot.from + 0.45, ease.outCubic);
  mark.style.opacity = mk.toFixed(3);
  mark.style.transform = `scale(${lerp(0.82, 1, ease.outBack(inv(endShot.from, endShot.from + 0.45, t))).toFixed(4)})`;
  endEl.querySelectorAll('.chip').forEach(chip => rise(chip, endCue[chip.dataset.word] - 0.04, 0.26));
  rise(endEl.querySelector('.name'), endCue.name, 0.38);
  rise(endEl.querySelector('.url'), endCue.name + 0.25, 0.38);

  captions(t);
};

window.__ready = true;
if (!navigator.webdriver) {
  // Opened in a browser: play it.
  const t0 = performance.now();
  const tick = async () => { await window.__seek(((performance.now() - t0) / 1000) % E.duration); requestAnimationFrame(tick); };
  tick();
}
