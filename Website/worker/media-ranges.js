// Workers static assets answer byte-range requests with the whole file. Safari
// won't play audio or video without ranges, and other browsers can't seek, so
// media requests run through here first (see run_worker_first in
// wrangler.jsonc). Everything else is served by the assets directly.

const MEDIA = /\.(mp4|m4a|mp3|webm|mov)$/i;
const MAX_BYTES = 64 * 1024 * 1024; // larger files are served whole, as before

export default {
  async fetch(request, env) {
    const res = await env.ASSETS.fetch(request);
    if (res.status !== 200 || !MEDIA.test(new URL(request.url).pathname)) return res;

    const range = /^bytes=(\d*)-(\d*)$/.exec((request.headers.get('Range') || '').trim());
    if (request.method !== 'GET' || !range || (range[1] === '' && range[2] === '') || Number(res.headers.get('Content-Length')) > MAX_BYTES) {
      const whole = new Response(res.body, res);
      whole.headers.set('Accept-Ranges', 'bytes');
      return whole;
    }

    // The asset response doesn't always say how long it is, so read it whole.
    const body = await res.arrayBuffer();
    const size = body.byteLength;
    let start, end;
    if (range[1] === '') {
      start = Math.max(0, size - Number(range[2]));
      end = size - 1;
    } else {
      start = Number(range[1]);
      end = range[2] === '' ? size - 1 : Math.min(Number(range[2]), size - 1);
    }
    if (start > end || start >= size) {
      return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    }

    const headers = new Headers(res.headers);
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(body.slice(start, end + 1), { status: 206, headers });
  },
};
