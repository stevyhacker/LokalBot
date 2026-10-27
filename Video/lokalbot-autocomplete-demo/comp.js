// LokalBot autocomplete demo. Every value on screen is a function of time:
// `window.__seek(t)` lays the frame out, waits for the footage frames it
// needs, and renders once. render.cjs steps it frame by frame.
import * as THREE from 'three';
import { EffectComposer } from './vendor/jsm/postprocessing/EffectComposer.js';
import { RenderPass } from './vendor/jsm/postprocessing/RenderPass.js';
import { UnrealBloomPass } from './vendor/jsm/postprocessing/UnrealBloomPass.js';
import { OutputPass } from './vendor/jsm/postprocessing/OutputPass.js';

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
const hdr = (hex, k) => new THREE.Color(hex).multiplyScalar(k);
const MINT = 0x6ef2dc, TEAL = 0x23c4ae, AMBER = 0xfbbf24, INK = 0xeaf6f3;

// ---------------------------------------------------------------- renderer
const canvas = document.getElementById('gl');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);
renderer.setSize(W, H, false);
renderer.toneMapping = THREE.NoToneMapping;
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x070b10);
scene.fog = new THREE.FogExp2(0x070b10, 0.006);
const camera = new THREE.PerspectiveCamera(38, W / H, 0.1, 600);
const composer = new EffectComposer(renderer);
composer.addPass(new RenderPass(scene, camera));
// Threshold 1: footage and UI (at most 1.0) never bloom; HDR accents do, softly.
const bloom = new UnrealBloomPass(new THREE.Vector2(W / 2, H / 2), 0.4, 0.4, 1.0);
composer.addPass(bloom);
composer.addPass(new OutputPass());

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
function panelTexture({ label, text, width = 1600, accent = '#6ef2dc', caret = false, size = 58 }) {
  const c = document.createElement('canvas'), ctx = c.getContext('2d');
  const pad = 48;
  ctx.font = `600 ${size}px Inter`;
  const lines = wrap(ctx, text, width - pad * 2);
  const lineH = size * 1.32;
  const h = pad * 2 + 54 + lines.length * lineH;
  c.width = width; c.height = Math.ceil(h);
  roundRect(ctx, 2, 2, width - 4, h - 4, 34);
  ctx.fillStyle = 'rgba(14, 21, 30, 0.94)'; ctx.fill();
  ctx.lineWidth = 3; ctx.strokeStyle = accent + '88'; ctx.stroke();
  ctx.font = '600 32px "JetBrains Mono"'; ctx.fillStyle = accent; ctx.textBaseline = 'top';
  ctx.fillText(label.toUpperCase().split('').join(' '), pad, pad - 4);
  ctx.font = `600 ${size}px Inter`; ctx.fillStyle = '#eaf6f3';
  lines.forEach((line, i) => ctx.fillText(line, pad, pad + 54 + i * lineH));
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
function chipTexture(text, { font = '600 64px "JetBrains Mono"', fg = '#eaf6f3', bg = 'rgba(14,21,30,0.92)', border = '#6ef2dc' } = {}) {
  const c = document.createElement('canvas'), ctx = c.getContext('2d');
  ctx.font = font;
  const w = Math.ceil(ctx.measureText(text).width) + 64, h = 110;
  c.width = w; c.height = h;
  roundRect(ctx, 2, 2, w - 4, h - 4, 24);
  ctx.fillStyle = bg; ctx.fill(); ctx.lineWidth = 3; ctx.strokeStyle = border; ctx.stroke();
  ctx.font = font; ctx.fillStyle = fg; ctx.textBaseline = 'middle'; ctx.fillText(text, 32, h / 2 + 3);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return { tex, aspect: h / w };
}
function texturedPlane(tex, width, aspect) {
  const mat = new THREE.MeshBasicMaterial({ map: tex, transparent: true, depthWrite: false, fog: false });
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
const sky = (() => {
  const random = rng(7), n = 3400;
  const pos = new Float32Array(n * 3), col = new Float32Array(n * 3), size = new Float32Array(n), phase = new Float32Array(n);
  const palette = [new THREE.Color(MINT), new THREE.Color(TEAL), new THREE.Color(0xffffff), new THREE.Color(0x7d9ec2)];
  for (let i = 0; i < n; i++) {
    pos[i * 3] = lerp(-70, 150, random());
    pos[i * 3 + 1] = lerp(-45, 45, random());
    pos[i * 3 + 2] = lerp(60, -300, random());
    const c = palette[Math.floor(random() * palette.length)];
    col.set([c.r, c.g, c.b], i * 3);
    size[i] = lerp(0.6, 2.6, random() ** 2);
    phase[i] = random() * 6.28;
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  geo.setAttribute('color', new THREE.BufferAttribute(col, 3));
  geo.setAttribute('size', new THREE.BufferAttribute(size, 1));
  geo.setAttribute('phase', new THREE.BufferAttribute(phase, 1));
  const mat = new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 }, uMap: { value: GLOW }, uBoost: { value: 1 } },
    vertexShader: `attribute float size; attribute float phase; attribute vec3 color; varying vec3 vColor; varying float vA;
      uniform float uTime;
      void main(){ vec3 p = position; p.y += sin(uTime*0.35 + phase)*0.6; p.x += cos(uTime*0.27 + phase)*0.6;
        vec4 mv = modelViewMatrix*vec4(p,1.); gl_Position = projectionMatrix*mv;
        gl_PointSize = size * 260. / -mv.z; vColor = color; vA = 0.7 + 0.3*sin(uTime*0.8 + phase*3.); }`,
    fragmentShader: `uniform sampler2D uMap; uniform float uBoost; varying vec3 vColor; varying float vA;
      void main(){ float a = texture2D(uMap, gl_PointCoord).a; gl_FragColor = vec4(vColor*uBoost, a*vA*0.75); }`,
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
  });
  const points = new THREE.Points(geo, mat);
  points.frustumCulled = false;
  scene.add(points);
  return { points, mat };
})();
// Soft colour behind each part of the film.
const nebulae = [[0, 0, -40, 0x0c8275, 90], [40, 4, -50, 0x23c4ae, 70], [80, -4, -40, 0x0c8275, 110],
  [80, 0, -120, 0x0c8275, 140], [80, 6, -230, 0x23c4ae, 120]].map(([x, y, z, color, s]) => {
  const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: GLOW, color, transparent: true, opacity: 0.06, depthWrite: false, blending: THREE.AdditiveBlending, fog: false }));
  sprite.position.set(x, y, z); sprite.scale.set(s, s * 0.7, 1);
  scene.add(sprite);
  return sprite;
});

// ---------------------------------------------------------------- footage cards
const CARD_VERT = `
  attribute vec3 aCenter; attribute vec3 aRand;
  uniform float uShatter; varying vec2 vUv; varying float vFade;
  mat3 rot(vec3 a, float t){ a = normalize(a); float s = sin(t), c = cos(t), o = 1. - c;
    return mat3(o*a.x*a.x + c, o*a.x*a.y + a.z*s, o*a.z*a.x - a.y*s,
                o*a.x*a.y - a.z*s, o*a.y*a.y + c, o*a.y*a.z + a.x*s,
                o*a.z*a.x + a.y*s, o*a.y*a.z - a.x*s, o*a.z*a.z + c); }
  void main(){
    vUv = uv;
    float p = clamp(uShatter * (1.0 + aRand.z * 0.8) - aRand.x * 0.25, 0., 1.);
    vec3 local = position - aCenter;
    local = rot(aRand - 0.5, p * 7.0 * (aRand.y + 0.3)) * local * (1.0 - p * 0.4);
    vec3 dir = normalize(vec3(aCenter.xy * 0.18 + (aRand.xy - 0.5) * 1.6, 1.5 + aRand.z * 2.5));
    vec3 pos = aCenter + local + dir * (p * p * (26.0 + aRand.y * 30.0));
    vFade = 1.0 - smoothstep(0.2, 0.6, p);  // gone before the shards fill the screen
    gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
  }`;
const CARD_FRAG = `
  uniform sampler2D uMap; uniform float uOpacity; uniform vec2 uSize; uniform float uRadius; uniform float uRim; uniform float uDim;
  varying vec2 vUv; varying float vFade;
  float sdRound(vec2 p, vec2 b, float r){ vec2 q = abs(p) - b + r; return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r; }
  void main(){
    vec2 p = (vUv - 0.5) * uSize;
    float d = sdRound(p, uSize * 0.5, uRadius);
    float aa = fwidth(d);
    float inside = 1.0 - smoothstep(-aa, aa, d);
    vec3 c = texture2D(uMap, vUv).rgb * (1.0 - uDim);
    float rim = (1.0 - smoothstep(0.0, uRadius * 0.6, abs(d))) * uRim;
    c += vec3(0.43, 0.95, 0.86) * rim * 1.6;
    // Kept under the bloom threshold: a white window would otherwise glow.
    gl_FragColor = vec4(min(c, vec3(0.96)), inside * uOpacity * vFade);
  }`;
function tiledPlane(w, h, nx, ny) {
  const pos = [], uv = [], center = [], rand = [], index = [];
  const random = rng(nx * 131 + ny);
  for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) {
    const x0 = -w / 2 + (i / nx) * w, x1 = -w / 2 + ((i + 1) / nx) * w;
    const y0 = -h / 2 + (j / ny) * h, y1 = -h / 2 + ((j + 1) / ny) * h;
    const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, r = [random(), random(), random()];
    const base = pos.length / 3;
    for (const [x, y] of [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]) {
      pos.push(x, y, 0); uv.push((x + w / 2) / w, (y + h / 2) / h); center.push(cx, cy, 0); rand.push(...r);
    }
    index.push(base, base + 1, base + 2, base, base + 2, base + 3);
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  geo.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
  geo.setAttribute('aCenter', new THREE.Float32BufferAttribute(center, 3));
  geo.setAttribute('aRand', new THREE.Float32BufferAttribute(rand, 3));
  geo.setIndex(index);
  return geo;
}

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
        uRadius: { value: this.width * 0.014 }, uRim: { value: 0 }, uShatter: { value: 0 }, uDim: { value: 0 },
      },
      vertexShader: CARD_VERT, fragmentShader: CARD_FRAG, transparent: true, depthWrite: false,
    });
    this.group = new THREE.Group();
    this.mesh = new THREE.Mesh(tiledPlane(this.width, this.height, 30, Math.max(6, Math.round(30 * this.height / this.width))), this.material);
    this.mesh.frustumCulled = false;
    this.shadow = new THREE.Sprite(new THREE.SpriteMaterial({ map: GLOW, color: 0x000000, transparent: true, opacity: 0.85, depthWrite: false, fog: false }));
    this.shadow.scale.set(this.width * 1.5, this.height * 2.0, 1);
    this.shadow.position.set(0, -this.height * 0.08, -0.6);
    this.halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: GLOW, color: TEAL, transparent: true, opacity: 0.0, depthWrite: false, blending: THREE.AdditiveBlending, fog: false }));
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
card.word.group.position.set(44, 1.5, -6);
const LANGS = [[card.de, 'Deutsch'], [card.fr, 'Français'], [card.es, 'Español']];

// ---- keycap, shared by the footage and the explainer
const key = el(`<span>tab</span>${TAB_ICON}`, 'key');
key.style.left = `${W / 2 - 100}px`; key.style.top = '900px'; key.style.minWidth = '200px';

// ---- hook
const hook = layer();
const hookKicker = el('<img src="assets/lokalbot-icon.svg" alt="">LokalBot', 'abs', hook); hookKicker.id = 'hook-kicker';
const hookLine = el('', 'abs center', hook); hookLine.id = 'hook-line';
const HOOK = EDIT.hook;

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
realtime.style.left = '120px'; realtime.style.top = '975px'; realtime.style.fontSize = '22px'; realtime.style.padding = '10px 20px';

// ---- explainer titles
const howTitle = el('How does it work?', 'abs center shadowed', ui);
Object.assign(howTitle.style, { top: '470px', fontSize: '120px', fontWeight: 800, letterSpacing: '-0.04em' });
const ctxTitle = titleLayer('How it works · 1', 'Reads what’s around <em>your cursor</em>.');
const modelTitle = titleLayer('How it works · 2', 'A small model runs <em>on your Mac</em>.');
const pickTitle = titleLayer('How it works · 3', 'It weighs <em>every next word</em>.');
const ghostTitle = titleLayer('How it works · 4', 'Ghost text. <em>Tab</em> takes a word.');

// ---- 1: the prompt, assembled from what is around the caret
const CONTEXT_Z = -62, CX = 88;
const ctxGroup = new THREE.Group();
ctxGroup.position.set(CX, 0, CONTEXT_Z);
scene.add(ctxGroup);
const layers = EDIT.prompt.map((part, i) => {
  const { tex, aspect } = panelTexture({ label: part.label, text: part.text, caret: i === EDIT.prompt.length - 1, accent: part.accent || '#6ef2dc' });
  const mesh = texturedPlane(tex, 21, aspect);
  ctxGroup.add(mesh);
  return { mesh, h: 21 * aspect, from: part.from || [0, -14, 6] };
});
const ctxTags = EDIT.prompt.map(part => el(part.source, 'abs tag', ui));
const slabGlow = new THREE.Sprite(new THREE.SpriteMaterial({ map: GLOW, color: hdr(MINT, 1.1), transparent: true, opacity: 0, depthWrite: false, blending: THREE.AdditiveBlending, fog: false }));
slabGlow.scale.set(26, 5, 1);
ctxGroup.add(slabGlow);

// ---- 2: the model, a tunnel of layers the prompt passes through
const NET = { z0: -100, layers: 9, gap: 9.5, radius: 6.4 };
const net = (() => {
  const random = rng(42), nodes = [];
  for (let l = 0; l < NET.layers; l++) {
    const count = 34;
    for (let i = 0; i < count; i++) {
      const a = (i / count) * Math.PI * 2 + l * 0.37, r = NET.radius * (0.35 + 0.65 * Math.sqrt(random()));
      nodes.push({ l, p: v3(CX + Math.cos(a) * r, Math.sin(a) * r * 0.78, NET.z0 - l * NET.gap), k: random() });
    }
  }
  const sphere = new THREE.IcosahedronGeometry(0.17, 1);
  const mat = new THREE.MeshBasicMaterial({ color: 0xffffff, fog: false });
  const mesh = new THREE.InstancedMesh(sphere, mat, nodes.length);
  const m = new THREE.Matrix4();
  nodes.forEach((n, i) => { m.makeTranslation(n.p.x, n.p.y, n.p.z); mesh.setMatrixAt(i, m); mesh.setColorAt(i, new THREE.Color(TEAL)); });
  scene.add(mesh);
  // Connections to three nodes of the next layer.
  const lines = [], lineCol = [], edges = [];
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i];
    if (n.l === NET.layers - 1) continue;
    const next = nodes.filter(o => o.l === n.l + 1);
    for (let k = 0; k < 3; k++) {
      const o = next[Math.floor(random() * next.length)];
      lines.push(n.p.x, n.p.y, n.p.z, o.p.x, o.p.y, o.p.z);
      lineCol.push(0.14, 0.77, 0.68, 0.14, 0.77, 0.68);
      edges.push([n.p, o.p, random()]);
    }
  }
  const lgeo = new THREE.BufferGeometry();
  lgeo.setAttribute('position', new THREE.Float32BufferAttribute(lines, 3));
  lgeo.setAttribute('color', new THREE.Float32BufferAttribute(lineCol, 3));
  const lmat = new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.22, blending: THREE.AdditiveBlending, depthWrite: false, fog: false });
  const segs = new THREE.LineSegments(lgeo, lmat);
  scene.add(segs);
  // Signals riding the connections.
  const nPulse = 700;
  const pgeo = new THREE.BufferGeometry();
  const ppos = new Float32Array(nPulse * 3);
  pgeo.setAttribute('position', new THREE.BufferAttribute(ppos, 3));
  const pmat = new THREE.PointsMaterial({ map: GLOW, color: hdr(MINT, 1.4), size: 0.3, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, fog: false });
  const pulses = new THREE.Points(pgeo, pmat);
  pulses.frustumCulled = false;
  scene.add(pulses);
  // Rings marking each layer.
  const rings = [];
  for (let l = 0; l < NET.layers; l++) {
    const ring = new THREE.Mesh(new THREE.RingGeometry(NET.radius * 1.08, NET.radius * 1.12, 96),
      new THREE.MeshBasicMaterial({ color: TEAL, transparent: true, opacity: 0.3, side: THREE.DoubleSide, depthWrite: false, blending: THREE.AdditiveBlending, fog: false }));
    ring.position.set(CX, 0, NET.z0 - l * NET.gap);
    ring.scale.set(1, 0.78, 1);
    scene.add(ring);
    rings.push(ring);
  }
  return { nodes, mesh, segs, lmat, pulses, ppos, pmat, edges, rings };
})();
const modelPills = el(EDIT.model.map(p => `<span class="pill"><span class="dot"></span>${p}</span>`).join(''), 'abs', ui);
Object.assign(modelPills.style, { left: '120px', top: '300px', display: 'flex', flexDirection: 'column', gap: '18px', alignItems: 'flex-start' });

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
  ctx.fillStyle = chosen ? 'rgba(40, 30, 6, 0.95)' : 'rgba(14, 21, 30, 0.94)'; ctx.fill();
  ctx.lineWidth = 4; ctx.strokeStyle = chosen ? '#fbbf24' : 'rgba(110, 242, 220, 0.55)'; ctx.stroke();
  ctx.textBaseline = 'middle';
  ctx.font = big; ctx.fillStyle = chosen ? '#fde68a' : '#eaf6f3'; ctx.fillText(token, 30, h / 2 + 3);
  if (pct) { ctx.font = small; ctx.fillStyle = chosen ? '#fbbf24' : '#8ca3a0'; ctx.fillText(pct, 30 + tw + 22, h / 2 + 4); }
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return { tex, w: w / 112 * 0.92, h: 0.92 };
}
const tree = (() => {
  const group = new THREE.Group();
  group.position.set(CX, 0, PICK_Z);
  scene.add(group);
  const plane = (tex, w, h) => new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: tex, transparent: true, depthWrite: false, fog: false }));
  const root = tokenChip(EDIT.pickPrefix, '', false);
  const rootMesh = plane(root.tex, root.w, root.h);
  let x = -root.w / 2;
  rootMesh.position.set(x, 0, 0);
  group.add(rootMesh);
  let prevRight = x + root.w / 2;
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
      const edge = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.MeshBasicMaterial({ color: TEAL, transparent: true, opacity: 0, depthWrite: false, blending: THREE.AdditiveBlending, fog: false }));
      edge.geometry.translate(0.5, 0, 0);
      const from = v3(prevRight + 0.05, 0, -0.01), to = v3(left - c.plain.w / 2 - 0.05, y, -0.01);
      edge.position.copy(from);
      edge.rotation.z = Math.atan2(to.y - from.y, to.x - from.x);
      edge.userData.length = from.distanceTo(to);
      group.add(edge, mesh, litMesh);
      return { ...c, mesh, litMesh, edge, y, left };
    });
    const chosen = items.find(i => i.chosen) || items[0];
    prevRight = chosen.left + chosen.plain.w / 2;
    return { items, cx, chosen };
  });
  return { group, rootMesh, columns, rootX: x };
})();
const gateLabel = el(EDIT.gateLabel, 'abs tag', ui);
Object.assign(gateLabel.style, { color: 'var(--amber)', fontSize: '32px' });

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
const swirl = (() => {
  const random = rng(99), n = 900;
  const from = [], to = [];
  for (let i = 0; i < n; i++) {
    from.push(v3(CX + lerp(-40, 40, random()), lerp(-24, 24, random()), -232 + lerp(-30, 30, random())));
    const a = random() * Math.PI * 2, r = 1.62 + random() * 0.26;
    to.push([Math.cos(a) * r, Math.sin(a) * r]);
  }
  const geo = new THREE.BufferGeometry();
  const pos = new Float32Array(n * 3);
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  const mat = new THREE.PointsMaterial({ map: GLOW, color: hdr(MINT, 1.4), size: 0.35, transparent: true, opacity: 0, depthWrite: false, blending: THREE.AdditiveBlending, fog: false });
  const points = new THREE.Points(geo, mat);
  points.frustumCulled = false;
  scene.add(points);
  return { from, to, pos, geo, mat };
})();

// ---------------------------------------------------------------- camera path
const KEYS = EDIT.camera.map(k => ({ t: k[0], pos: v3(...k[1]), look: v3(...k[2]), fov: k[3] ?? 38, e: k[4] || 'inOutCubic' }));
function pickFollow(t) {
  const [p0, p1] = T.pick;
  if (t < p0 - 0.6 || t > p1 + 0.6 || !tree.columns.length) return 0;
  const starts = EDIT.pickSteps.map(s => p0 + s);
  let x = tree.rootX + 2;
  tree.columns.forEach((col, k) => { x = lerp(x, col.cx - 1.5, seg(t, starts[k], starts[k] + 0.55, ease.inOutCubic)); });
  return x * seg(t, p0 - 0.6, p0 + 0.3) * (1 - seg(t, p1 - 0.2, p1 + 0.6));
}
function placeCamera(t) {
  let a = KEYS[0], b = KEYS[KEYS.length - 1];
  for (let i = 1; i < KEYS.length; i++) if (t <= KEYS[i].t) { a = KEYS[i - 1]; b = KEYS[i]; break; }
  const k = b.t === a.t ? 1 : ease[b.e](inv(a.t, b.t, t));
  camera.position.lerpVectors(a.pos, b.pos, k);
  const look = new THREE.Vector3().lerpVectors(a.look, b.look, k);
  // A little life: slow drift, never more than a few centimetres.
  camera.position.x += Math.sin(t * 0.9) * 0.08; camera.position.y += Math.cos(t * 0.7) * 0.06;
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
  hookLine.innerHTML = ghostLine(HOOK.typed, shown, HOOK.ghost, lit, seg(t, HOOK.ghostAt, HOOK.ghostAt + 0.18), blink);
}

function layoutHook(t) {
  const o = win(t, T.hook[0], T.hook[1], 0.3, 0.35);
  show(hook, o);
  if (o <= 0) return;
  typedHook(t);
  const out = seg(t, T.hook[1] - 0.45, T.hook[1], ease.inCubic);
  hook.style.transform = `scale(${1 + out * 0.9})`;
  hook.style.filter = `blur(${out * 10}px)`;
  hookKicker.style.opacity = seg(t, 0.1, 0.6).toFixed(3);
}

function cardEnter(c, t, t0, from, to, rotFrom, rotTo, dur = 0.8) {
  const k = seg(t, t0, t0 + dur, ease.outExpo);
  c.group.position.lerpVectors(from, to, k);
  c.group.rotation.set(lerp(rotFrom[0], rotTo[0], k), lerp(rotFrom[1], rotTo[1], k), lerp(rotFrom[2], rotTo[2], k));
}

async function layoutFootage(t) {
  const jobs = [];
  // Memory
  const [m0, m1] = T.memory;
  const mo = clamp(seg(t, m0, m0 + 0.3) * (1 - seg(t, m1 - 0.15, m1 + 0.1)));
  if (mo > 0) {
    cardEnter(card.memory, t, m0, v3(0, -2, -30), v3(0, 0, 0), [0.35, -0.75, 0.08], [0.02, -0.12, 0], 0.9);
    card.memory.group.rotation.y += seg(t, m0 + 0.9, m1, ease.linear) * 0.08;
    card.memory.halo.material.opacity = 0.25 * mo;
    card.memory.material.uniforms.uRim.value = 0.12;
  }
  jobs.push(card.memory.show(t - m0, mo));
  show(memTitle, win(t, m0 + 0.35, m1, 0.35, 0.25));
  // The fact the suggestion came from, once the suggestion is on screen.
  const ghostAt = m0 + EDIT.clips.memory.ghostAt;
  const mc = win(t, ghostAt - 0.05, m1 - 0.05, 0.35, 0.25);
  show(memcard, mc);
  if (mc > 0) {
    const k = seg(t, ghostAt - 0.05, ghostAt + 0.45, ease.outBack);
    memcard.style.left = `${lerp(1950, 1240, k)}px`;
    memcard.style.top = `${lerp(640, 600, k)}px`;
    memcard.style.transform = `rotate(${lerp(8, -2, k)}deg)`;
  }

  // The second clip
  const [w0, w1] = T.word;
  const wo = clamp(seg(t, w0, w0 + 0.2) * (1 - seg(t, w1 - 0.15, w1 + 0.1)));
  if (wo > 0) {
    cardEnter(card.word, t, w0, v3(56, 1.5, -16), v3(44, 1.5, -6), [0, 0.9, -0.05], [0.02, 0.1, 0], 0.7);
    card.word.halo.material.opacity = 0.25 * wo;
    card.word.material.uniforms.uRim.value = 0.12;
  }
  jobs.push(card.word.show(t - w0, wo));
  show(wordTitle, win(t, w0 + 0.25, w1, 0.3, 0.25));

  // Three languages, one after another: each swipes in over the last.
  const [l0] = T.langs;
  const shatter = seg(t, T.dive[0], T.dive[0] + 1.1, ease.inCubic);
  LANGS.forEach(([c], i) => {
    const s = l0 + EDIT.langStarts[i];
    const next = i + 1 < LANGS.length ? l0 + EDIT.langStarts[i + 1] : DURATION + 1;
    const enter = seg(t, s - 0.14, s + 0.22, ease.outExpo);
    const leave = seg(t, next - 0.14, next + 0.22, ease.inCubic);
    // The shattering window fades as it breaks, so it never fills the screen with white.
    const o = clamp(seg(t, s - 0.14, s) * (1 - leave)) * (1 - seg(t, T.dive[0] + 0.05, T.dive[0] + 0.4));
    if (o > 0) {
      c.group.position.set(88 + lerp(26, 0, enter) - 26 * leave, 0, -8 - 6 * leave);
      c.group.rotation.set(0, lerp(-0.55, 0, enter) + 0.55 * leave, 0);
      c.material.uniforms.uShatter.value = shatter;
      c.material.uniforms.uRim.value = 0.12 * (1 - shatter);
      c.halo.material.opacity = 0.22 * (1 - shatter) * o;
      c.shadow.material.opacity = 0.85 * (1 - shatter);
    }
    jobs.push(c.show(t - s, o));
    const tag = langTags[i];
    const p = project(c.group.position.clone().add(v3(-c.width / 2 + 0.2, -c.height / 2 - 0.55, 0)));
    tag.style.left = `${p.x}px`; tag.style.top = `${p.y}px`;
    show(tag, o * enter * (1 - seg(t, T.dive[0], T.dive[0] + 0.3)));
  });
  show(langTitle, win(t, l0 + 0.3, T.dive[0] + 0.25, 0.3, 0.25));

  // The keycap, pressed on every real accept in the footage.
  const langs = langCues();
  const presses = [...HOOK.presses, ...EDIT.clips.memory.accepts.map(a => m0 + a), ...EDIT.clips[EDIT.wordClip].accepts.map(a => w0 + a),
    ...langs.flatMap(l => l.accepts)];
  const keyO = Math.max(win(t, HOOK.ghostAt + 0.05, T.hook[1] - 0.3, 0.2, 0.2),
    win(t, m0 + EDIT.clips.memory.accepts[0] - 0.4, m1 - 0.1, 0.2, 0.2),
    win(t, w0 + EDIT.clips[EDIT.wordClip].accepts[0] - 0.4, w1 - 0.1, 0.2, 0.2),
    win(t, langs[0].ghost, T.dive[0], 0.2, 0.2),
    win(t, T.ghost[0] + 0.6, T.ghost[1] - 0.1, 0.2, 0.2));
  const ghostPresses = EDIT.ghostScene.presses.map(p => T.ghost[0] + p);
  show(key, keyO);
  key.classList.toggle('down', keyState(t, [...presses, ...ghostPresses]));
  show(realtime, win(t, m0 + 0.6, T.dive[0] + 0.1, 0.3, 0.3));
  await Promise.all(jobs);
}

function layoutDive(t) {
  const [d0, d1] = T.dive;
  const o = win(t, d0 + 0.05, d1 + 0.1, 0.25, 0.3);
  show(howTitle, o);
  howTitle.style.transform = `scale(${lerp(0.82, 1.18, seg(t, d0, d1 + 0.1, ease.linear))})`;
  howTitle.style.filter = `blur(${seg(t, d1 - 0.2, d1 + 0.1) * 8}px)`;
}

function layoutContext(t) {
  const [c0, c1] = T.context;
  ctxGroup.visible = t > c0 - 0.1 && t < c1 + 0.6;
  show(ctxTitle, win(t, c0 + 0.25, c1, 0.3, 0.2));
  if (!ctxGroup.visible) { ctxTags.forEach(tag => show(tag, 0)); return; }
  const gap = 0.9, total = layers.reduce((s, l) => s + l.h, 0) + gap * (layers.length - 1);
  let y = total / 2;
  const fly = seg(t, c1 - 0.45, c1 + 0.5, ease.inExpo);
  layers.forEach((l, i) => {
    const s = c0 + 0.25 + i * 0.42;
    const k = seg(t, s, s + 0.7, ease.outExpo);
    const target = v3(-3.5, y - l.h / 2, 0);
    y -= l.h + gap;
    l.mesh.position.lerpVectors(v3(...l.from).add(target), target, k);
    l.mesh.rotation.set((1 - k) * 0.9, (1 - k) * (i % 2 ? -0.7 : 0.7), 0);
    // Squeeze into one slab and shoot into the model.
    const squeeze = seg(t, c1 - 0.8, c1 - 0.3, ease.inOutCubic);
    l.mesh.position.y = lerp(l.mesh.position.y, 0, squeeze);
    l.mesh.position.z = -fly * 70 + i * 0.05;
    l.mesh.scale.set(1 - squeeze * 0.15, 1 - squeeze * 0.85, 1);
    l.mesh.material.opacity = k * (1 - seg(t, c1 + 0.1, c1 + 0.5));
    const tag = ctxTags[i];
    const p = project(ctxGroup.localToWorld(l.mesh.position.clone().add(v3(10.5 + 0.7, 0, 0))));
    tag.style.left = `${p.x}px`; tag.style.top = `${p.y}px`; tag.style.transform = 'translateY(-50%)';
    show(tag, seg(t, s + 0.45, s + 0.8) * (1 - seg(t, c1 - 0.9, c1 - 0.6)));
  });
  slabGlow.material.opacity = seg(t, c1 - 0.6, c1 - 0.3) * (1 - seg(t, c1 + 0.2, c1 + 0.6)) * 0.35;
  slabGlow.position.set(-3.5, 0, -fly * 70 - 0.5);
}

function layoutModel(t) {
  const [n0, n1] = T.model;
  const o = clamp(seg(t, n0 - 0.3, n0 + 0.2) * (1 - seg(t, n1 + 0.2, n1 + 0.8)));
  net.mesh.visible = net.segs.visible = net.pulses.visible = o > 0;
  net.rings.forEach(r => (r.visible = o > 0));
  show(modelTitle, win(t, n0 + 0.2, n1, 0.3, 0.25));
  show(modelPills, win(t, n0 + 0.55, n1 - 0.05, 0.3, 0.25));
  [...modelPills.children].forEach((pill, i) => {
    const k = seg(t, n0 + 0.55 + i * 0.22, n0 + 0.95 + i * 0.22, ease.outBack);
    pill.style.transform = `translateX(${lerp(-60, 0, k)}px)`;
    pill.style.opacity = k.toFixed(3);
  });
  if (o <= 0) return;
  // Wavefronts: one pass of the prompt, then one per generated token, faster each time.
  const passes = EDIT.modelPasses.map(p => n0 + p);
  const depth = NET.layers * NET.gap;
  const fronts = passes.map((p, i) => (t - p) * (i === 0 ? 34 : 60)).filter(d => d > -2 && d < depth + 6);
  const c = new THREE.Color();
  net.nodes.forEach((n, i) => {
    const d = NET.z0 - n.p.z;
    let glow = 0;
    for (const f of fronts) glow = Math.max(glow, Math.exp(-((d - f) ** 2) / 6) * (0.6 + n.k * 0.8));
    c.setHex(TEAL).lerp(new THREE.Color(MINT), clamp(glow)).multiplyScalar((0.6 + glow * 1.2) * o);
    net.mesh.setColorAt(i, c);
  });
  net.mesh.instanceColor.needsUpdate = true;
  net.rings.forEach((ring, l) => {
    const d = l * NET.gap;
    let glow = 0;
    for (const f of fronts) glow = Math.max(glow, Math.exp(-((d - f) ** 2) / 5));
    ring.material.opacity = (0.14 + glow * 0.3) * o;
    ring.material.color.setHex(TEAL).lerp(new THREE.Color(MINT), glow).multiplyScalar(1 + glow * 0.3);
  });
  net.lmat.opacity = 0.2 * o;
  const nPulse = net.ppos.length / 3;
  for (let i = 0; i < nPulse; i++) {
    const [a, b, k] = net.edges[(i * 7) % net.edges.length];
    const f = (t * (0.9 + k * 1.4) + k * 10 + i * 0.013) % 1;
    net.ppos[i * 3] = lerp(a.x, b.x, f); net.ppos[i * 3 + 1] = lerp(a.y, b.y, f); net.ppos[i * 3 + 2] = lerp(a.z, b.z, f);
  }
  net.pulses.geometry.attributes.position.needsUpdate = true;
  net.pmat.opacity = o * 0.6;
}

function layoutPick(t) {
  const [p0, p1] = T.pick;
  const o = win(t, p0 + 0.05, p1, 0.3, 0.25);
  show(pickTitle, win(t, p0 + 0.05, p1, 0.3, 0.25));
  tree.group.visible = o > 0;
  if (o <= 0) { show(gateLabel, 0); return; }
  const starts = EDIT.pickSteps.map(s => p0 + s);
  tree.rootMesh.material.opacity = o;
  tree.columns.forEach((col, k) => {
    const local = t - starts[k];
    col.items.forEach((item, j) => {
      const grow = seg(local, 0.02 + j * 0.04, 0.26 + j * 0.04, ease.outBack);
      const decided = seg(local, 0.3, 0.42);
      const visible = local > 0;
      item.mesh.visible = item.litMesh.visible = item.edge.visible = visible;
      if (!visible) return;
      const scale = lerp(0.55, 1, clamp(grow, 0, 1.2));
      item.mesh.scale.setScalar(scale); item.litMesh.scale.setScalar(scale);
      item.mesh.material.opacity = o * clamp(grow) * (item.chosen ? 1 - decided : lerp(1, 0.32, decided));
      item.litMesh.material.opacity = o * (item.chosen ? decided : 0);
      const reach = seg(local, 0, 0.22 + j * 0.04, ease.outCubic);
      item.edge.scale.set(item.edge.userData.length * reach, item.chosen ? 0.07 : 0.035 + item.q * 0.05, 1);
      item.edge.material.color.copy(item.chosen && decided > 0.5 ? hdr(AMBER, 1.3) : hdr(TEAL, 0.7 + item.q * 0.8));
      item.edge.material.opacity = o * (item.chosen ? 0.5 + decided * 0.5 : lerp(0.55, 0.22, decided)) * Math.sqrt(Math.max(item.q, 0.04));
    });
  });
  // The first word is checked against the confidence gate.
  const first = tree.columns[0];
  if (first) {
    const pt = project(tree.group.localToWorld(v3(first.cx - 1.2, -3.55, 0)));
    gateLabel.style.left = `${pt.x}px`; gateLabel.style.top = `${pt.y}px`;
    show(gateLabel, o * win(t, starts[0] + 0.45, starts[Math.min(2, starts.length - 1)] + 0.4, 0.25, 0.25));
  }
}

function layoutGhost(t) {
  const [g0, g1] = T.ghost;
  const o = win(t, g0 + 0.05, g1, 0.3, 0.25);
  show(ghostLayer, o);
  show(ghostTitle, o);
  if (o <= 0) return;
  const G = EDIT.ghostScene;
  const lit = G.presses.map(p => g0 + p).filter(p => t >= p).length;
  const blink = Math.floor(t * 2.4) % 2 === 0;
  sentence.innerHTML = ghostLine(G.typed, G.typed.length, G.chunks || G.ghost, lit, seg(t, g0 + G.ghostAt, g0 + G.ghostAt + 0.3), blink);
}

function layoutEnd(t) {
  const [e0] = T.end;
  const o = seg(t, e0 + 0.15, e0 + 0.6);
  show(end, o);
  const logo = end.querySelector('#end-logo');
  const k = seg(t, e0 + 0.15, e0 + 0.9, ease.outBack);
  logo.style.transform = `scale(${lerp(0.6, 1, k)}) rotate(${lerp(-12, 0, k)}deg)`;
  [['#end-name', 0.3], ['#end-tag', 0.55], ['#end-sub', 0.75], ['#end-url', 0.95]].forEach(([sel, d]) => {
    const node = end.querySelector(sel);
    const q = seg(t, e0 + d, e0 + d + 0.45, ease.outCubic);
    node.style.opacity = q.toFixed(3);
    node.style.transform = `translateY(${lerp(30, 0, q)}px)`;
  });
  const s = seg(t, e0 - 0.2, e0 + 1.2, ease.inOutCubic);
  swirl.mat.opacity = Math.min(seg(t, e0 - 0.4, e0), 1 - seg(t, e0 + 1.1, e0 + 1.6)) * 0.7;
  // The ring closes around the logo: its centre is the logo's screen point, 20 units out.
  const centre = v3((960 / W) * 2 - 1, -((306 / H) * 2 - 1), 0.5).unproject(camera).sub(camera.position).normalize()
    .multiplyScalar(20).add(camera.position);
  const right = v3(1, 0, 0).applyQuaternion(camera.quaternion), up = v3(0, 1, 0).applyQuaternion(camera.quaternion);
  swirl.from.forEach((f, i) => {
    const [dx, dy] = swirl.to[i];
    const target = centre.clone().addScaledVector(right, dx).addScaledVector(up, dy);
    const p = f.clone().lerp(target, s);
    const a = (1 - s) * 2.4 + i;
    p.x += Math.cos(a) * (1 - s) * 2; p.y += Math.sin(a) * (1 - s) * 2;
    swirl.pos.set([p.x, p.y, p.z], i * 3);
  });
  swirl.geo.attributes.position.needsUpdate = true;
  document.getElementById('fade').style.opacity = seg(t, DURATION - 0.35, DURATION).toFixed(3);
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
  layoutHook(t);
  layoutDive(t);
  layoutContext(t);
  layoutModel(t);
  layoutPick(t);
  layoutGhost(t);
  layoutEnd(t);
  await layoutFootage(t);
  drawGrain(Math.round(t * FPS));
  composer.render();
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
  for (const name of ['memory', 'word', 'langs', 'dive', 'context', 'model', 'pick', 'ghost', 'end']) add(T[name][0], 'whoosh:' + name);
  EDIT.pickSteps.forEach(s => add(T.pick[0] + s, 'tick'));
  EDIT.modelPasses.forEach(p => add(T.model[0] + p, 'pulse'));
  return events.sort((a, b) => a[0] - b[0]);
};
window.__ready = true;
if (!navigator.webdriver) {
  // Preview in a browser: play in real time, ?t= jumps.
  const start = performance.now() - (Number(new URLSearchParams(location.search).get('t')) || 0) * 1000;
  const tick = async () => { await window.__seek(((performance.now() - start) / 1000) % DURATION); requestAnimationFrame(tick); };
  tick();
}
