// LokalBot autocomplete demo. Every value on screen is a function of time:
// `window.__seek(t)` lays the frame out, waits for the footage frames it
// needs, and renders once. render.cjs steps it frame by frame.
import * as THREE from 'three';

const W = 1920, H = 1080;
const EDIT = await (await fetch('edit.json')).json();
const FPS = EDIT.fps, DURATION = EDIT.duration;
// Canvas text needs the faces loaded first; the DOM alone loads them lazily.
await Promise.all(['400', '500', '600', '700', '800'].map(w => document.fonts.load(`${w} 40px Inter`))
  .concat(['400', '600', '700'].map(w => document.fonts.load(`${w} 40px "JetBrains Mono"`))));

// ---------------------------------------------------------------- helpers
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, t) => a + (b - a) * t;
const inv = (a, b, x) => clamp((x - a) / (b - a));
const ease = {
  linear: t => t,
  outCubic: t => 1 - (1 - t) ** 3,
  inCubic: t => t * t * t,
  inOutCubic: t => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2),
  outExpo: t => (t >= 1 ? 1 : 1 - 2 ** (-10 * t)),
  inExpo: t => (t <= 0 ? 0 : 2 ** (10 * t - 10)),
  inOutExpo: t => (t <= 0 ? 0 : t >= 1 ? 1 : t < 0.5 ? 2 ** (20 * t - 10) / 2 : (2 - 2 ** (-20 * t + 10)) / 2),
  outQuart: t => 1 - (1 - t) ** 4,
  outBack: (t, s = 1.7) => 1 + (s + 1) * (t - 1) ** 3 + s * (t - 1) ** 2,
  inOutSine: t => -(Math.cos(Math.PI * t) - 1) / 2,
};
const seg = (t, a, b, e = ease.inOutCubic) => e(inv(a, b, t));
/** 0 → 1 → 0 window: in over [a, a+i], out over [b-o, b]. */
const win = (t, a, b, i = 0.25, o = 0.25) => Math.min(seg(t, a, a + i, ease.outCubic), 1 - seg(t, b - o, b, ease.inCubic));
function rng(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let r = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}
const v3 = (x, y, z) => new THREE.Vector3(x, y, z);
const MINT = 0x6ef2dc, TEAL = 0x23c4ae;
// Where the second clip, the languages and the explainer sit (timeline.py aims the camera there).
const X_WORD = 24, X_LANG = 48, CX = 48;

// ---------------------------------------------------------------- renderer
const canvas = document.getElementById('gl');
// Transparent: the page behind it is lokalbot.com's navy gradient.
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);
renderer.setSize(W, H, false);
renderer.setClearColor(0x000000, 0);
renderer.toneMapping = THREE.NoToneMapping;
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(38, W / H, 0.1, 600);

const ui = document.getElementById('ui');
const el = (html, cls = '', parent = ui) => {
  const node = document.createElement('div');
  if (cls) node.className = cls;
  node.innerHTML = html;
  parent.appendChild(node);
  return node;
};
const layer = () => el('', 'layer');
const show = (node, o) => { node.style.opacity = o.toFixed(3); node.style.visibility = o > 0.001 ? 'visible' : 'hidden'; };
/** show(), rising into place as it fades in. */
const rise = (node, o, px = 22) => { show(node, o); node.style.transform = `translateY(${(px * (1 - o)).toFixed(1)}px)`; };
/** Screen position of a world point. */
function project(p) {
  const q = p.clone().project(camera);
  return { x: (q.x + 1) / 2 * W, y: (1 - q.y) / 2 * H, behind: q.z > 1 };
}
const TAB_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="#0e141c" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h15"/><path d="M13 6l6 6-6 6"/><path d="M21 5v14"/></svg>';

// ---------------------------------------------------------------- text textures
function wrap(ctx, text, width) {
  const lines = [];
  for (const paragraph of text.split('\n')) {
    let line = '';
    for (const word of paragraph.split(' ')) {
      const next = line ? line + ' ' + word : word;
      if (ctx.measureText(next).width > width && line) { lines.push(line); line = word; } else line = next;
    }
    lines.push(line);
  }
  return lines;
}
function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}
/** A rounded panel with a mono label and wrapped text, as a texture. */
function panelTexture({ label, text, width = 1600, accent = '#6ef2dc', caret = false, size = 58, mark = '' }) {
  const c = document.createElement('canvas'), ctx = c.getContext('2d');
  const pad = 48;
  ctx.font = `600 ${size}px Inter`;
  const lines = wrap(ctx, text, width - pad * 2);
  const lineH = size * 1.32;
  const h = pad * 2 + 54 + lines.length * lineH;
  c.width = width; c.height = Math.ceil(h);
  roundRect(ctx, 2, 2, width - 4, h - 4, 34);
  ctx.fillStyle = 'rgba(18, 28, 40, 0.94)'; ctx.fill();
  ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(255, 255, 255, 0.12)'; ctx.stroke();
  ctx.font = '600 32px "JetBrains Mono"'; ctx.fillStyle = accent; ctx.textBaseline = 'top';
  ctx.fillText(label.toUpperCase().split('').join(' '), pad, pad - 4);
  ctx.font = `600 ${size}px Inter`;
  lines.forEach((line, i) => {
    // `mark` is drawn in amber where it appears, as the memory card marks the decision.
    const y = pad + 54 + i * lineH, at = mark ? line.indexOf(mark) : -1;
    if (at < 0) { ctx.fillStyle = '#ecf3f7'; ctx.fillText(line, pad, y); return; }
    const before = line.slice(0, at);
    ctx.fillStyle = '#ecf3f7'; ctx.fillText(before, pad, y);
    ctx.fillStyle = '#fbbf24'; ctx.fillText(mark, pad + ctx.measureText(before).width, y);
    ctx.fillStyle = '#ecf3f7'; ctx.fillText(line.slice(at + mark.length), pad + ctx.measureText(before + mark).width, y);
  });
  if (caret) {
    const last = lines[lines.length - 1] || '';
    const x = pad + ctx.measureText(last).width + 8, y = pad + 54 + (lines.length - 1) * lineH;
    ctx.fillStyle = accent; ctx.fillRect(x, y + 2, 6, size * 1.05);
  }
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return { tex, aspect: c.height / c.width };
}
function texturedPlane(tex, width, aspect) {
  const mat = new THREE.MeshBasicMaterial({ map: tex, transparent: true, depthWrite: false });
  return new THREE.Mesh(new THREE.PlaneGeometry(width, width * aspect), mat);
}
function glowTexture() {
  const c = document.createElement('canvas'); c.width = c.height = 256;
  const ctx = c.getContext('2d');
  const g = ctx.createRadialGradient(128, 128, 0, 128, 128, 128);
  g.addColorStop(0, 'rgba(255,255,255,1)'); g.addColorStop(0.25, 'rgba(255,255,255,0.45)'); g.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = g; ctx.fillRect(0, 0, 256, 256);
  const tex = new THREE.CanvasTexture(c);
  return tex;
}
const GLOW = glowTexture();

// ---------------------------------------------------------------- background
// Drifting teal dust and soft colour behind each part of the film, as in the first cut.
const sky = (() => {
  const random = rng(7), n = 2400;
  const pos = new Float32Array(n * 3), col = new Float32Array(n * 3), size = new Float32Array(n), phase = new Float32Array(n);
  const palette = [new THREE.Color(MINT), new THREE.Color(TEAL), new THREE.Color(0xffffff), new THREE.Color(0x7d9ec2)];
  for (let i = 0; i < n; i++) {
    pos[i * 3] = lerp(-60, 110, random());
    pos[i * 3 + 1] = lerp(-40, 40, random());
    pos[i * 3 + 2] = lerp(60, -300, random());
    const c = palette[Math.floor(random() * palette.length)];
    col.set([c.r, c.g, c.b], i * 3);
    size[i] = lerp(0.6, 2.4, random() ** 2);
    phase[i] = random() * 6.28;
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  geo.setAttribute('color', new THREE.BufferAttribute(col, 3));
  geo.setAttribute('size', new THREE.BufferAttribute(size, 1));
  geo.setAttribute('phase', new THREE.BufferAttribute(phase, 1));
  const mat = new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 }, uMap: { value: GLOW } },
    vertexShader: `attribute float size; attribute float phase; attribute vec3 color; varying vec3 vColor; varying float vA;
      uniform float uTime;
      void main(){ vec3 p = position; p.y += sin(uTime*0.35 + phase)*0.6; p.x += cos(uTime*0.27 + phase)*0.6;
        vec4 mv = modelViewMatrix*vec4(p,1.); gl_Position = projectionMatrix*mv;
        gl_PointSize = size * 260. / -mv.z; vColor = color; vA = 0.7 + 0.3*sin(uTime*0.8 + phase*3.); }`,
    fragmentShader: `uniform sampler2D uMap; varying vec3 vColor; varying float vA;
      void main(){ float a = texture2D(uMap, gl_PointCoord).a; gl_FragColor = vec4(vColor, a*vA*0.55); }`,
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
  });
  const points = new THREE.Points(geo, mat);
  points.frustumCulled = false;
  scene.add(points);
  return { points, mat };
})();
[[0, 0, -40, 0x0c8275, 90], [24, 4, -50, 0x23c4ae, 70], [48, -4, -40, 0x0c8275, 110],
  [48, 0, -120, 0x0c8275, 140], [48, 6, -230, 0x23c4ae, 120]].forEach(([x, y, z, color, size]) => {
  const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: GLOW, color, transparent: true, opacity: 0.07, depthWrite: false, blending: THREE.AdditiveBlending }));
  sprite.position.set(x, y, z); sprite.scale.set(size, size * 0.7, 1);
  scene.add(sprite);
});

// ---------------------------------------------------------------- footage cards
const CARD_VERT = `
  varying vec2 vUv;
  void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;
const CARD_FRAG = `
  uniform sampler2D uMap; uniform float uOpacity; uniform vec2 uSize; uniform float uRadius; uniform float uRim;
  varying vec2 vUv;
  float sdRound(vec2 p, vec2 b, float r){ vec2 q = abs(p) - b + r; return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r; }
  void main(){
    vec2 p = (vUv - 0.5) * uSize;
    float d = sdRound(p, uSize * 0.5, uRadius);
    float aa = fwidth(d);
    float inside = 1.0 - smoothstep(-aa, aa, d);
    // A thin mint rim light, as in the first cut.
    float rim = (1.0 - smoothstep(0.0, uRadius * 0.6, abs(d))) * uRim;
    vec3 c = mix(texture2D(uMap, vUv).rgb, vec3(0.43, 0.95, 0.86), clamp(rim, 0., 1.));
    gl_FragColor = vec4(c, inside * uOpacity);
    #include <colorspace_fragment>
  }`;

const images = new Map();
function image(url) {
  if (!images.has(url)) {
    images.set(url, new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => img.decode().then(() => resolve(img), () => resolve(img));
      img.onerror = () => reject(new Error('missing ' + url));
      img.src = url;
    }));
    if (images.size > 900) images.delete(images.keys().next().value);
  }
  return images.get(url);
}
/** Source time for a time into a clip's slot: piecewise linear over `map` [[out, src], ...]. */
function sourceTime(map, t) {
  if (t <= map[0][0]) return map[0][1] + (t - map[0][0]) * 0;
  for (let i = 1; i < map.length; i++) {
    const [o0, s0] = map[i - 1], [o1, s1] = map[i];
    if (t <= o1) return o1 === o0 ? s1 : lerp(s0, s1, (t - o0) / (o1 - o0));
  }
  return map[map.length - 1][1];
}

class Card {
  constructor(name, width) {
    this.clip = EDIT.clips[name];
    this.name = name;
    const [pw, ph] = this.clip.size;
    this.width = width;
    this.height = width * ph / pw;
    this.texture = new THREE.Texture();
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.texture.minFilter = THREE.LinearMipmapLinearFilter;
    this.texture.anisotropy = 8;
    this.material = new THREE.ShaderMaterial({
      uniforms: {
        uMap: { value: this.texture }, uOpacity: { value: 1 }, uSize: { value: new THREE.Vector2(this.width, this.height) },
        uRadius: { value: this.width * 0.014 }, uRim: { value: 0.5 },
      },
      vertexShader: CARD_VERT, fragmentShader: CARD_FRAG, transparent: true, depthWrite: false,
    });
    this.group = new THREE.Group();
    this.mesh = new THREE.Mesh(new THREE.PlaneGeometry(this.width, this.height), this.material);
    this.shadow = new THREE.Sprite(new THREE.SpriteMaterial({ map: GLOW, color: 0x000000, transparent: true, opacity: 0.7, depthWrite: false }));
    this.shadow.scale.set(this.width * 1.4, this.height * 1.9, 1);
    this.shadow.position.set(0, -this.height * 0.1, -0.6);
    // A soft teal glow under the card.
    this.halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: GLOW, color: TEAL, transparent: true, opacity: 0, depthWrite: false, blending: THREE.AdditiveBlending }));
    this.halo.scale.set(this.width * 1.6, this.height * 2.2, 1);
    this.halo.position.set(0, 0, -0.8);
    this.group.add(this.shadow, this.halo, this.mesh);
    this.group.visible = false;
    scene.add(this.group);
    this.frame = -1;
  }
  /** World position of a point on the card given as fractions of its width and height from the top left. */
  point(u, v) {
    return this.mesh.localToWorld(v3((u - 0.5) * this.width, (0.5 - v) * this.height, 0));
  }
  async show(t, opacity = 1) {
    this.group.visible = opacity > 0.001;
    if (!this.group.visible) return;
    this.material.uniforms.uOpacity.value = opacity;
    this.shadow.material.opacity = 0.7 * opacity;
    this.halo.material.opacity = 0.22 * opacity;
    const src = sourceTime(this.clip.map, t);
    const frame = clamp(Math.round(src * FPS), 0, this.clip.frames - 1);
    if (frame !== this.frame) {
      this.frame = frame;
      this.texture.image = await image(`${this.clip.src}/${String(frame + 1).padStart(4, '0')}.jpg`);
      this.texture.needsUpdate = true;
    }
  }
}

// ---------------------------------------------------------------- the edit
const T = EDIT.timeline;
const card = {
  memory: new Card('memory', 18),
  word: new Card(EDIT.wordClip, 18),
  de: new Card('german', 18),
  fr: new Card('french', 18),
  es: new Card('spanish', 18),
};
card.memory.group.position.set(0, 0, 0);
card.word.group.position.set(X_WORD, 1.5, -6);
const LANGS = [[card.de, 'Deutsch'], [card.fr, 'Français'], [card.es, 'Español']];

// ---- keycap, shared by the footage and the explainer
const key = el(`<span>tab</span>${TAB_ICON}`, 'key');
key.style.left = `${W / 2 - 100}px`; key.style.top = '760px'; key.style.minWidth = '200px';

// ---- brand: the logo lockup opens the film, then sits in the corner
const LOCKUP = '<img src="assets/lokalbot-icon.svg" alt="">LokalBot';
const hook = layer();
const hookBrand = el(LOCKUP, 'abs brand', hook); hookBrand.id = 'hook-brand';
const hookLine = el('', 'abs center', hook); hookLine.id = 'hook-line';
const HOOK = EDIT.hook;
const corner = el(LOCKUP, 'abs brand', ui); corner.id = 'corner';
const caption = el('<span></span>', 'abs', ui); caption.id = 'caption';
const bg = document.getElementById('bg');

// ---- footage titles
function titleLayer(kicker, title) {
  const node = layer();
  el(`<small>${kicker}</small>${title}`, 'abs title', node);
  return node;
}
const memTitle = titleLayer(EDIT.clips.memory.kicker, EDIT.clips.memory.title);
const wordTitle = titleLayer(EDIT.clips[EDIT.wordClip].kicker, EDIT.clips[EDIT.wordClip].title);
const langTitle = titleLayer('Any language', 'Writes the way <em>you</em> write.');
const langTags = LANGS.map(([, label]) => el(label, 'abs lang', ui));
/** Each language clip's suggestion and accepts in video time, while its card is up. */
const langCues = () => ['german', 'french', 'spanish'].map((name, i) => {
  const s = T.langs[0] + EDIT.langStarts[i];
  const until = i + 1 < 3 ? T.langs[0] + EDIT.langStarts[i + 1] : T.dive[0];
  const clip = EDIT.clips[name];
  return { ghost: s + clip.ghostAt, accepts: clip.accepts.map(a => s + a).filter(a => a < until - 0.05) };
});
const memcard = el(`<div class="head"><span class="dot"></span>From your meeting</div>
  <div class="meet">${EDIT.memory.meeting}</div><div class="quote">${EDIT.memory.quote}</div>`, 'abs memcard', ui);
const realtime = el(EDIT.footageNote, 'abs pill', ui);
Object.assign(realtime.style, { right: '72px', top: '128px', fontSize: '22px', padding: '9px 18px' });

// ---- explainer titles
const howTitle = el('How does it work?', 'abs center shadowed', ui);
Object.assign(howTitle.style, { top: '470px', fontSize: '120px', fontWeight: 800, letterSpacing: '-0.04em' });
const ctxTitle = titleLayer('How it works · 1', 'Reads what’s around <em>your cursor</em>.');
const modelTitle = titleLayer('How it works · 2', 'A small model runs <em>on your Mac</em>.');
const pickTitle = titleLayer('How it works · 3', 'It weighs <em>every next word</em>.');
const ghostTitle = titleLayer('How it works · 4', 'Ghost text. <em>Tab</em> takes a word.');

// ---- 1: the prompt, assembled from what is around the caret
const CONTEXT_Z = -62;
const ctxGroup = new THREE.Group();
ctxGroup.position.set(CX, 0, CONTEXT_Z);
scene.add(ctxGroup);
const layers = EDIT.prompt.map((part, i) => {
  const style = { label: part.label, text: part.text, caret: i === EDIT.prompt.length - 1, accent: part.accent || '#6ef2dc' };
  const { tex, aspect } = panelTexture(style);
  const mesh = texturedPlane(tex, 21, aspect);
  ctxGroup.add(mesh);
  // The saved fact the suggestion comes from, marked when the voice names it.
  let marked = null;
  if (part.mark) {
    marked = texturedPlane(panelTexture({ ...style, mark: part.mark }).tex, 21, aspect);
    marked.position.z = 0.01;
    mesh.add(marked);
  }
  return { mesh, marked, h: 21 * aspect, from: part.from || [0, -6, 4] };
});
const ctxTags = EDIT.prompt.map(part => el(part.source, 'abs tag', ui));

// ---- 2: the model, as lokalbot.com lists it, running in the app
const SPARKLES = '<svg viewBox="0 0 24 24" fill="none" stroke="#6ef2dc" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14a.5.5 0 0 1 .96 0l1.58 6.14a2 2 0 0 0 1.44 1.44l6.14 1.58a.5.5 0 0 1 0 .96l-6.14 1.58a2 2 0 0 0-1.44 1.44l-1.58 6.14a.5.5 0 0 1-.96 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/><path d="M4 17v2"/><path d="M5 18H3"/></svg>';
const LAPTOP = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16"/></svg>';
const M = EDIT.model;
const mac = el(`<div class="bar"><i></i><i></i><i></i></div><div class="where">${LAPTOP}${M.where}</div>
  <div class="modelcard"><div class="tile">${SPARKLES}</div><div>
    <div class="name">${M.name}</div><div class="what">${M.what}</div>
    <div class="chips">${M.chips.map(c => `<span class="chip">${c}</span>`).join('')}</div></div></div>
  <div class="out"><span class="label">${M.outLabel}</span><span class="text"></span></div>
  <div class="pills">${M.pills.map(p => `<span class="pill"><span class="dot"></span>${p}</span>`).join('')}</div>`, 'abs', ui);
mac.id = 'mac';
const macOut = mac.querySelector('.out .text');
const macPills = [...mac.querySelectorAll('.pills .pill')];

// ---- 3: the candidates for each next word, as a growing tree
const PICK_Z = -205;
const STEPS = EDIT.candidates;
const shown = tok => tok.replace(/^ /, '').replace(/\n/g, '↵') || '␣';
function tokenChip(token, pct, chosen) {
  const c = document.createElement('canvas'), ctx = c.getContext('2d');
  const big = '600 64px "JetBrains Mono"', small = '600 36px "JetBrains Mono"';
  ctx.font = big; const tw = ctx.measureText(token).width;
  ctx.font = small; const pw = pct ? ctx.measureText(pct).width + 22 : 0;
  const w = Math.ceil(tw + pw + 60), h = 112;
  c.width = w; c.height = h;
  roundRect(ctx, 3, 3, w - 6, h - 6, 26);
  ctx.fillStyle = chosen ? 'rgba(20, 70, 66, 0.96)' : 'rgba(18, 28, 40, 0.94)'; ctx.fill();
  ctx.lineWidth = 3; ctx.strokeStyle = chosen ? '#6ef2dc' : 'rgba(255, 255, 255, 0.14)'; ctx.stroke();
  ctx.textBaseline = 'middle';
  ctx.font = big; ctx.fillStyle = chosen ? '#effffb' : '#ecf3f7'; ctx.fillText(token, 30, h / 2 + 3);
  if (pct) { ctx.font = small; ctx.fillStyle = chosen ? '#6ef2dc' : '#8ba2b0'; ctx.fillText(pct, 30 + tw + 22, h / 2 + 4); }
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return { tex, w: w / 112 * 0.92, h: 0.92 };
}
const tree = (() => {
  const group = new THREE.Group();
  group.position.set(CX, 0, PICK_Z);
  scene.add(group);
  const plane = (tex, w, h) => new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: tex, transparent: true, depthWrite: false }));
  const root = tokenChip(EDIT.pickPrefix, '', false);
  const rootMesh = plane(root.tex, root.w, root.h);
  let x = -root.w / 2;
  rootMesh.position.set(x, 0, 0);
  group.add(rootMesh);
  // Columns sit side by side; each edge leaves from the word picked before it.
  let prevRight = x + root.w / 2, prevEdge = prevRight;
  const SLOT = [0, 1.32, -1.32, 2.64, -2.64];
  const columns = STEPS.map(step => {
    const options = step.options.slice(0, 3);
    const pct = q => `${(q * 100).toFixed(q < 0.1 ? 1 : 0)}%`;
    const chips = options.map(([tok, q]) => {
      const chosen = tok === step.chosen;
      return { tok, q, chosen, plain: tokenChip(shown(tok), pct(q), false), lit: tokenChip(shown(tok), pct(q), true) };
    });
    const width = Math.max(...chips.map(c => c.plain.w));
    const cx = prevRight + 1.15 + width / 2;
    let slot = 1;
    const items = chips.map(c => {
      const y = c.chosen ? 0 : SLOT[slot++] ?? 0;
      const mesh = plane(c.plain.tex, c.plain.w, c.plain.h);
      const litMesh = plane(c.lit.tex, c.lit.w, c.lit.h);
      const left = cx - width / 2 + c.plain.w / 2;
      mesh.position.set(left, y, 0); litMesh.position.set(left, y, 0.01);
      const edge = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.MeshBasicMaterial({ color: TEAL, transparent: true, opacity: 0, depthWrite: false }));
      edge.geometry.translate(0.5, 0, 0);
      const from = v3(prevEdge + 0.05, 0, -0.01), to = v3(left - c.plain.w / 2 - 0.05, y, -0.01);
      edge.position.copy(from);
      edge.rotation.z = Math.atan2(to.y - from.y, to.x - from.x);
      edge.userData.length = from.distanceTo(to);
      group.add(edge, mesh, litMesh);
      return { ...c, mesh, litMesh, edge, y, left };
    });
    const chosen = items.find(i => i.chosen) || items[0];
    prevEdge = chosen.left + chosen.plain.w / 2;
    prevRight = cx + width / 2;
    return { items, cx, chosen };
  });
  return { group, rootMesh, columns, rootX: x };
})();
const gateLabel = el(EDIT.gateLabel, 'abs tag', ui);
Object.assign(gateLabel.style, { left: '120px', top: '232px', color: 'var(--amber)', fontSize: '30px' });

// ---- 4: ghost text and Tab, then the end card
const ghostLayer = layer();
const sentence = el('', 'abs center', ghostLayer); sentence.id = 'sentence';
sentence.style.top = '520px';
const end = layer();
end.innerHTML = `<img id="end-logo" class="abs" src="assets/lokalbot-icon.svg">
  <div id="end-name" class="abs center">LokalBot</div>
  <div id="end-tag" class="abs center">${EDIT.end.tag}</div>
  <div id="end-sub" class="abs center">${EDIT.end.sub}</div>
  <div id="end-url" class="abs center">${EDIT.end.url}</div>`;
// ---------------------------------------------------------------- camera path
const KEYS = EDIT.camera.map(k => ({ t: k[0], pos: v3(...k[1]), look: v3(...k[2]), fov: k[3] ?? 38, e: k[4] || 'inOutCubic' }));
function pickFollow(t) {
  const [p0, p1] = T.pick;
  if (t < p0 - 0.6 || t > p1 + 0.6 || !tree.columns.length) return 0;
  const starts = EDIT.pickSteps.map(s => p0 + s);
  let x = tree.rootX + 2;
  tree.columns.forEach((col, k) => { x = lerp(x, col.cx - 1.5, seg(t, starts[k], starts[k] + 0.6, ease.inOutCubic)); });
  return x * seg(t, p0 - 0.6, p0 + 0.3) * (1 - seg(t, p1 - 0.2, p1 + 0.6));
}
function placeCamera(t) {
  let a = KEYS[0], b = KEYS[KEYS.length - 1];
  for (let i = 1; i < KEYS.length; i++) if (t <= KEYS[i].t) { a = KEYS[i - 1]; b = KEYS[i]; break; }
  const k = b.t === a.t ? 1 : ease[b.e](inv(a.t, b.t, t));
  camera.position.lerpVectors(a.pos, b.pos, k);
  const look = new THREE.Vector3().lerpVectors(a.look, b.look, k);
  // A little life: slow drift, never more than a few centimetres.
  camera.position.x += Math.sin(t * 0.5) * 0.06; camera.position.y += Math.cos(t * 0.4) * 0.05;
  const follow = pickFollow(t);
  camera.position.x += follow; look.x += follow;
  camera.fov = lerp(a.fov, b.fov, k);
  camera.updateProjectionMatrix();
  camera.lookAt(look);
}

// ---------------------------------------------------------------- per-scene layout
function keyState(t, presses) {
  // Down for 120 ms after each press.
  return presses.some(p => t >= p && t < p + 0.12);
}
const caretAt = on => `<span style="display:inline-block;position:relative;width:0"><span class="caret" style="position:absolute;left:-2px;bottom:-0.16em;margin:0;opacity:${on ? 1 : 0}"></span></span>`;
/** typed + ghost words on one stable line; `lit` ghost words accepted. */
/** `ghost` is the suggestion, or the pieces Tab accepts it in. */
function ghostLine(typed, shown, ghost, lit, ghostOpacity, blinkOn) {
  const words = Array.isArray(ghost) ? ghost : ghost.split(/(?=\s)/);
  const accepted = words.slice(0, lit).join('');
  const rest = words.slice(lit).map(w => `<span class="ghostw" style="color:var(--ghost);opacity:${ghostOpacity}">${w}</span>`).join('');
  const typing = shown < typed.length;
  return `<span>${typed.slice(0, shown)}</span>${typing ? caretAt(blinkOn) : ''}<span style="visibility:hidden">${typed.slice(shown)}</span>`
    + `<span style="color:var(--ink)">${accepted}</span>${typing ? '' : caretAt(blinkOn)}${rest}`;
}
function typedHook(t) {
  const shown = Math.floor(clamp((t - HOOK.typeFrom) / (HOOK.typeTo - HOOK.typeFrom)) * HOOK.typed.length + 1e-6);
  const lit = HOOK.presses.filter(p => t >= p).length;
  const blink = t < HOOK.typeTo + 0.1 || Math.floor(t * 2.4) % 2 === 0;
  hookLine.innerHTML = ghostLine(HOOK.typed, shown, HOOK.ghost, lit, seg(t, HOOK.ghostAt, HOOK.ghostAt + 0.3), blink);
}

function layoutHook(t) {
  const [, h1] = T.hook;
  const o = 1 - seg(t, h1 - 0.3, h1 + 0.05);
  show(hook, o);
  if (o <= 0) return;
  typedHook(t);
  // It flies past the camera as the first clip comes in, as in the first cut.
  const out = seg(t, h1 - 0.5, h1 + 0.05, ease.inCubic);
  hook.style.transform = `scale(${(1 + out * 0.9).toFixed(4)})`;
  hook.style.filter = out > 0.001 ? `blur(${(out * 10).toFixed(2)}px)` : 'none';
  // On from the first frame, so a muted autoplay or a thumbnail already says what this is.
  const b = seg(t, 0, 0.45, ease.outBack);
  hookBrand.style.opacity = '1';
  hookBrand.style.transform = `scale(${lerp(0.9, 1, b).toFixed(4)})`;
}

function cardEnter(c, t, t0, from, to, rotFrom, rotTo, dur, e = ease.outCubic) {
  const k = seg(t, t0, t0 + dur, e);
  c.group.position.lerpVectors(from, to, k);
  c.group.rotation.set(lerp(rotFrom[0], rotTo[0], k), lerp(rotFrom[1], rotTo[1], k), lerp(rotFrom[2], rotTo[2], k));
}

async function layoutFootage(t) {
  const jobs = [];
  // Memory
  const [m0, m1] = T.memory;
  const mo = clamp(seg(t, m0, m0 + 0.35) * (1 - seg(t, m1 - 0.35, m1 + 0.15)));
  if (mo > 0) {
    cardEnter(card.memory, t, m0, v3(0, -2, -30), v3(0, 0, 0), [0.35, -0.75, 0.08], [0.02, -0.08, 0], 0.9, ease.outExpo);
    card.memory.group.rotation.y += seg(t, m0 + 0.9, m1, ease.linear) * 0.06;
  }
  jobs.push(card.memory.show(t - m0, mo));
  rise(memTitle, win(t, m0 + 0.35, m1 - 0.1, 0.35, 0.3));
  // The fact the suggestion came from, once the suggestion is on screen.
  const ghostAt = m0 + EDIT.clips.memory.ghostAt;
  const mc = win(t, ghostAt - 0.1, m1 - 0.1, 0.3, 0.3);
  show(memcard, mc);
  if (mc > 0) {
    const k = seg(t, ghostAt - 0.1, ghostAt + 0.4, ease.outBack);
    memcard.style.left = `${lerp(1950, 1250, k)}px`;
    memcard.style.top = `${lerp(640, 676, k)}px`;
    memcard.style.transform = `rotate(${lerp(8, -1.5, k).toFixed(2)}deg)`;
  }

  // The second clip
  const [w0, w1] = T.word;
  const wo = clamp(seg(t, w0, w0 + 0.35) * (1 - seg(t, w1 - 0.35, w1 + 0.15)));
  if (wo > 0) cardEnter(card.word, t, w0, v3(X_WORD + 4, 1.5, -9), v3(X_WORD, 1.5, -6), [0, 0.3, 0], [0.02, 0.08, 0], 0.8);
  jobs.push(card.word.show(t - w0, wo));
  rise(wordTitle, win(t, w0 + 0.2, w1 - 0.1, 0.3, 0.3));

  // Three languages, one after another: each slides off before the next slides in.
  const [l0] = T.langs;
  LANGS.forEach(([c], i) => {
    const s = l0 + EDIT.langStarts[i];
    const next = i + 1 < LANGS.length ? l0 + EDIT.langStarts[i + 1] : T.dive[0] + 0.1;
    const enter = i === 0 ? seg(t, s - 0.25, s + 0.3, ease.outQuart) : seg(t, s, s + 0.3, ease.outQuart);
    const leave = i + 1 < LANGS.length ? seg(t, next - 0.3, next, ease.inCubic) : seg(t, next - 0.25, next + 0.15);
    const o = clamp(enter * (1 - leave));
    if (o > 0) {
      c.group.position.set(X_LANG + lerp(3, 0, enter) - 3 * leave, 0, -8 - 2 * leave);
      c.group.rotation.set(0, lerp(-0.12, 0, enter) + 0.12 * leave, 0);
    }
    jobs.push(c.show(t - s, o));
    const tag = langTags[i];
    const p = project(c.group.position.clone().add(v3(-c.width / 2 + 0.2, -c.height / 2 - 0.55, 0)));
    tag.style.left = `${p.x}px`; tag.style.top = `${p.y}px`;
    show(tag, o);
  });
  rise(langTitle, win(t, l0 + 0.2, T.dive[0] + 0.15, 0.3, 0.3));

  // The keycap, pressed on every real accept in the footage.
  const langs = langCues();
  const G = EDIT.ghostScene;
  const presses = [...HOOK.presses, ...EDIT.clips.memory.accepts.map(a => m0 + a), ...EDIT.clips[EDIT.wordClip].accepts.map(a => w0 + a),
    ...langs.flatMap(l => l.accepts), ...G.presses.map(p => T.ghost[0] + p)];
  const keyO = Math.max(win(t, HOOK.ghostAt + 0.1, T.hook[1] - 0.2, 0.4, 0.4),
    win(t, m0 + EDIT.clips.memory.accepts[0] - 0.8, m1 - 0.2, 0.4, 0.4),
    win(t, w0 + EDIT.clips[EDIT.wordClip].accepts[0] - 0.8, w1 - 0.2, 0.4, 0.4),
    win(t, langs[0].ghost - 0.2, T.dive[0] + 0.2, 0.4, 0.4),
    win(t, T.ghost[0] + G.ghostAt, T.ghost[1] - 0.2, 0.4, 0.4));
  show(key, keyO);
  key.classList.toggle('down', keyState(t, presses));
  show(realtime, win(t, m0 + 0.8, T.dive[0] + 0.3, 0.5, 0.5));
  show(corner, win(t, T.hook[1] - 0.4, T.end[0] + 0.5, 0.6, 0.6));
  await Promise.all(jobs);
}

function layoutDive(t) {
  const [d0, d1] = T.dive;
  show(howTitle, win(t, d0 + 0.25, d1, 0.3, 0.3));
  const land = seg(t, d0 + 0.25, d0 + 0.7, ease.outQuart);
  howTitle.style.transform = `scale(${(lerp(1.14, 1, land) + 0.03 * seg(t, d0 + 0.7, d1, ease.linear)).toFixed(4)})`;
}

function layoutContext(t) {
  const [c0, c1] = T.context;
  const B = EDIT.beats;
  ctxGroup.visible = t > c0 - 0.1 && t < c1 + 0.8;
  rise(ctxTitle, win(t, c0 + 0.2, c1 - 0.1, 0.3, 0.3));
  if (!ctxGroup.visible) { ctxTags.forEach(tag => show(tag, 0)); return; }
  const gap = 0.9, total = layers.reduce((s, l) => s + l.h, 0) + gap * (layers.length - 1);
  let y = total / 2;
  // At the end the two parts close into one prompt, which drifts on into the model.
  const squeeze = seg(t, c1 - 0.9, c1 - 0.45);
  const away = seg(t, c1 - 0.45, c1 + 0.45);
  layers.forEach((l, i) => {
    const s = B[EDIT.prompt[i].beat];
    const k = seg(t, s, s + 0.55, ease.outQuart);
    const target = v3(-3.5, y - l.h / 2, 0);
    y -= l.h + gap;
    l.mesh.position.lerpVectors(v3(...l.from).add(target), target, k);
    l.mesh.rotation.set((1 - k) * 0.25, (1 - k) * (i % 2 ? -0.2 : 0.2), 0);
    l.mesh.position.y = lerp(l.mesh.position.y, 0, squeeze);
    l.mesh.position.z += -away * 60 + i * 0.05;
    const shrink = 1 - away * 0.5;
    l.mesh.scale.set((1 - squeeze * 0.15) * shrink, (1 - squeeze * 0.85) * shrink, 1);
    l.mesh.material.opacity = k * (1 - away);
    if (l.marked) l.marked.material.opacity = k * (1 - away) * seg(t, B.ctxMark, B.ctxMark + 0.5);
    const tag = ctxTags[i];
    const p = project(ctxGroup.localToWorld(l.mesh.position.clone().add(v3(10.5 + 0.7, 0, 0))));
    tag.style.left = `${p.x}px`; tag.style.top = `${p.y}px`; tag.style.transform = 'translateY(-50%)';
    show(tag, seg(t, s + 0.35, s + 0.6) * (1 - seg(t, c1 - 1.0, c1 - 0.8)));
  });
}

function layoutModel(t) {
  const [n0, n1] = T.model;
  const B = EDIT.beats;
  rise(modelTitle, win(t, n0 + 0.2, n1 - 0.1, 0.3, 0.3));
  const o = win(t, n0 + 0.15, n1 - 0.1, 0.4, 0.3);
  show(mac, o);
  if (o <= 0) return;
  const k = seg(t, n0 + 0.15, n0 + 0.7, ease.outQuart);
  mac.style.transform = `translateY(${lerp(60, 0, k).toFixed(1)}px) scale(${lerp(0.94, 1, k).toFixed(4)})`;
  // The model writes the rest of the sentence, a piece at a time.
  const G = EDIT.ghostScene;
  const n = B.modelStream.filter(s => t >= s).length;
  macOut.innerHTML = `${G.typed}<b>${G.chunks.slice(0, n).join('')}</b>${caretAt(Math.floor(t * 2.4) % 2 === 0)}`;
  macPills.forEach((pill, i) => {
    const q = seg(t, B.modelPills[i], B.modelPills[i] + 0.35, ease.outBack);
    pill.style.opacity = q.toFixed(3);
    pill.style.transform = `translateY(${lerp(12, 0, q).toFixed(1)}px)`;
  });
}

function layoutPick(t) {
  const [p0, p1] = T.pick;
  const o = win(t, p0 + 0.1, p1 - 0.1, 0.4, 0.3);
  rise(pickTitle, win(t, p0 + 0.2, p1 - 0.1, 0.3, 0.3));
  tree.group.visible = o > 0;
  if (o <= 0) { show(gateLabel, 0); return; }
  const starts = EDIT.pickSteps.map(s => p0 + s);
  tree.rootMesh.material.opacity = o;
  tree.columns.forEach((col, k) => {
    const local = t - starts[k];
    col.items.forEach((item, j) => {
      const grow = seg(local, 0.03 + j * 0.06, 0.33 + j * 0.06, ease.outBack);
      const decided = seg(local, 0.38, 0.56);
      const visible = local > 0;
      item.mesh.visible = item.litMesh.visible = item.edge.visible = visible;
      if (!visible) return;
      const scale = lerp(0.85, 1, grow);
      item.mesh.scale.setScalar(scale); item.litMesh.scale.setScalar(scale);
      item.mesh.material.opacity = o * grow * (item.chosen ? 1 - decided : lerp(1, 0.32, decided));
      item.litMesh.material.opacity = o * (item.chosen ? decided : 0);
      const reach = seg(local, 0, 0.28 + j * 0.06, ease.outQuart);
      item.edge.scale.set(item.edge.userData.length * reach, item.chosen ? 0.06 : 0.03 + item.q * 0.04, 1);
      item.edge.material.color.setHex(item.chosen && decided > 0.5 ? MINT : TEAL);
      item.edge.material.opacity = o * (item.chosen ? 0.55 + decided * 0.4 : lerp(0.5, 0.2, decided)) * Math.sqrt(Math.max(item.q, 0.04));
    });
  });
  // The first word is checked against the confidence gate, as the voice says.
  rise(gateLabel, o * win(t, EDIT.beats.pickGate, p1, 0.3, 0.3), 14);
}

function layoutGhost(t) {
  const [g0, g1] = T.ghost;
  show(ghostLayer, win(t, g0 + 0.25, g1 - 0.1, 0.3, 0.3));
  rise(ghostTitle, win(t, g0 + 0.2, g1 - 0.1, 0.3, 0.3));
  if (t < g0 || t > g1) return;
  const G = EDIT.ghostScene;
  const lit = G.presses.map(p => g0 + p).filter(p => t >= p).length;
  const blink = Math.floor(t * 2.4) % 2 === 0;
  sentence.innerHTML = ghostLine(G.typed, G.typed.length, G.chunks || G.ghost, lit, seg(t, g0 + G.ghostAt, g0 + G.ghostAt + 0.25), blink);
}

function layoutEnd(t) {
  const [e0] = T.end;
  show(end, seg(t, e0 + 0.2, e0 + 0.45));
  const logo = end.querySelector('#end-logo');
  const k = seg(t, e0 + 0.2, e0 + 0.85, ease.outBack);
  logo.style.transform = `translateY(${lerp(24, 0, k).toFixed(1)}px) scale(${lerp(0.8, 1, k).toFixed(4)})`;
  [['#end-name', 0.35], ['#end-tag', 0.55], ['#end-sub', 0.75], ['#end-url', 0.95]].forEach(([sel, d]) => {
    const node = end.querySelector(sel);
    const q = seg(t, e0 + d, e0 + d + 0.4, ease.outQuart);
    node.style.opacity = q.toFixed(3);
    node.style.transform = `translateY(${lerp(18, 0, q).toFixed(1)}px)`;
  });
  document.getElementById('fade').style.opacity = seg(t, DURATION - 0.6, DURATION).toFixed(3);
}

/** The voice's words at the bottom, lit as they are said, swapped straight over when one line follows another. */
function layoutCaption(t) {
  const caps = EDIT.captions;
  let o = 0;
  for (let i = 0; i < caps.length; i++) {
    const [a, b, text, starts = []] = caps[i];
    const joined = i > 0 && a - caps[i - 1][1] < 0.05;
    const next = i + 1 < caps.length && caps[i + 1][0] - b < 0.05;
    if (t >= a - (joined ? 0 : 0.12) && t < b + (next ? 0 : 0.2)) {
      const words = text.split(' ');
      caption.firstChild.innerHTML = starts.length === words.length
        ? words.map((w, k) => `<b style="opacity:${lerp(0.42, 1, seg(t, starts[k] - 0.04, starts[k] + 0.08, ease.linear)).toFixed(3)}">${w}</b>`).join(' ')
        : text;
      o = Math.min(joined ? 1 : seg(t, a - 0.12, a + 0.03, ease.linear), next ? 1 : 1 - seg(t, b, b + 0.2, ease.linear));
      break;
    }
  }
  show(caption, o);
}

/** The page behind drifts a little with the camera, so the 3D cards sit in it. */
function layoutBackground() {
  const push = 1 + clamp((40 - camera.position.z) / 272) * 0.08;
  bg.style.transform = `translateX(${(-camera.position.x * 3).toFixed(1)}px) scale(${push.toFixed(4)})`;
}

// ---------------------------------------------------------------- grain
const grain = document.getElementById('grain'), gctx = grain.getContext('2d');
const grainImage = gctx.createImageData(480, 270);
function drawGrain(frame) {
  const random = rng(frame * 2654435761);
  const d = grainImage.data;
  for (let i = 0; i < d.length; i += 4) { const v = random() * 255; d[i] = d[i + 1] = d[i + 2] = v; d[i + 3] = 255; }
  gctx.putImageData(grainImage, 0, 0);
}

// ---------------------------------------------------------------- seek
await document.fonts.ready;
await Promise.all([...document.images].map(img => img.decode().catch(() => {})));
window.__duration = DURATION;
window.__fps = FPS;
window.__seek = async t => {
  sky.mat.uniforms.uTime.value = t;
  placeCamera(t);
  layoutBackground();
  layoutHook(t);
  layoutDive(t);
  layoutContext(t);
  layoutModel(t);
  layoutPick(t);
  layoutGhost(t);
  layoutEnd(t);
  layoutCaption(t);
  await layoutFootage(t);
  drawGrain(Math.round(t * FPS));
  renderer.render(scene, camera);
};
// Everything a sound designer needs, in film time.
window.__events = () => {
  const events = [];
  const add = (t, kind) => { if (t >= 0 && t <= DURATION) events.push([Math.round(t * 1000) / 1000, kind]); };
  for (let i = 0; i < HOOK.typed.length; i++) add(HOOK.typeFrom + (i / HOOK.typed.length) * (HOOK.typeTo - HOOK.typeFrom), 'type');
  HOOK.presses.forEach(p => add(p, 'tab'));
  for (const [name, start] of [['memory', T.memory[0]], [EDIT.wordClip, T.word[0]]]) {
    const clip = EDIT.clips[name];
    (clip.keys || []).forEach(k => add(start + k, 'type'));
    clip.accepts.forEach(a => add(start + a, 'tab'));
    add(start + clip.ghostAt, 'ghost');
  }
  langCues().forEach(l => { add(l.ghost, 'ghost'); l.accepts.forEach(a => add(a, 'tab')); });
  EDIT.ghostScene.presses.forEach(p => add(T.ghost[0] + p, 'tab'));
  add(T.ghost[0] + EDIT.ghostScene.ghostAt, 'ghost');
  for (const name of ['memory', 'word', 'langs', 'context', 'model', 'pick', 'ghost']) add(T[name][0], 'whoosh:' + name);
  add(T.end[0] + 0.2, 'reveal');
  EDIT.pickSteps.forEach(s => add(T.pick[0] + s, 'tick'));
  EDIT.beats.modelStream.forEach(s => add(s, 'token'));
  return events.sort((a, b) => a[0] - b[0]);
};
window.__ready = true;
if (!navigator.webdriver) {
  // Preview in a browser: play in real time, ?t= jumps.
  const start = performance.now() - (Number(new URLSearchParams(location.search).get('t')) || 0) * 1000;
  const tick = async () => { await window.__seek(((performance.now() - start) / 1000) % DURATION); requestAnimationFrame(tick); };
  tick();
}
