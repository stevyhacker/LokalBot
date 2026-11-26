const MEDIA = /\.(mp4|m4a|mp3|webm|mov)$/i;
const MAX_BYTES = 64 * 1024 * 1024;
const RELEASE_LATEST = 'https://github.com/stevyhacker/lokalbot/releases/latest';
const DOWNLOAD_ROUTES = new Map([
  ['/dl/mac', RELEASE_LATEST],
  ['/dl/windows', RELEASE_LATEST],
  ['/dl/linux-deb', RELEASE_LATEST],
  ['/dl/linux-rpm', RELEASE_LATEST],
  ['/dl/linux', RELEASE_LATEST],
]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const normalizedPath = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, '') : url.pathname;
    const downloadTarget = DOWNLOAD_ROUTES.get(normalizedPath);
    if (downloadTarget && (request.method === 'GET' || request.method === 'HEAD')) {
      return new Response(null, {
        status: 302,
        headers: {
          Location: downloadTarget,
          'Cache-Control': 'public, max-age=300',
          'Referrer-Policy': 'no-referrer',
          'X-Robots-Tag': 'noindex',
        },
      });
    }

    if (!MEDIA.test(url.pathname)) {
      return env.ASSETS.fetch(request);
    }

    const range = /^bytes=(\d*)-(\d*)$/.exec((request.headers.get('Range') || '').trim());
    if (request.method !== 'GET' || !range || (range[1] === '' && range[2] === '')) {
      const res = await env.ASSETS.fetch(request);
      if (res.status !== 200) return res;
      const whole = new Response(res.body, res);
      whole.headers.set('Accept-Ranges', 'bytes');
      return whole;
    }

    const res = await env.ASSETS.fetch(new Request(request.url, { method: 'GET' }));
    if (res.status !== 200) return res;

    const rawLength = res.headers.get('Content-Length');
    if (rawLength !== null) {
      const length = Number(rawLength);
      if (!Number.isFinite(length) || length < 0 || length > MAX_BYTES) {
        const whole = new Response(res.body, res);
        whole.headers.set('Accept-Ranges', 'bytes');
        return whole;
      }
    }

    const body = await res.arrayBuffer();
    const size = body.byteLength;
    if (size > MAX_BYTES) {
      const headers = new Headers(res.headers);
      headers.delete('Content-Encoding');
      headers.set('Accept-Ranges', 'bytes');
      headers.set('Content-Length', String(size));
      return new Response(body, { status: 200, headers });
    }

    let start;
    let end;
    if (range[1] === '') {
      const suffix = Number(range[2]);
      if (suffix === 0) {
        return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
      }
      start = Math.max(0, size - suffix);
      end = size - 1;
    } else {
      start = Number(range[1]);
      end = range[2] === '' ? size - 1 : Math.min(Number(range[2]), size - 1);
    }
    if (size === 0 || start > end || start >= size) {
      return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    }

    const headers = new Headers(res.headers);
    headers.delete('Content-Encoding');
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(body.slice(start, end + 1), { status: 206, headers });
  },
};
