const pages: Record<string, { title: string; body: string }> = {
  "/": {
    title: "LokalBot for ChatGPT — preview",
    body: `<p>Recall decisions and commitments from your recorded meetings in ChatGPT.</p>
<p>This is an early preview. It requires an Apple Silicon Mac, macOS 15 or later, LokalBot, Node.js 22.12 or later, and a running connection helper. A public ChatGPT listing is not available yet.</p>
<h2>Connect your own Mac</h2>
<ol><li>Download the signed companion from the <a href="https://github.com/stevyhacker/LokalBot/releases/tag/chatgpt-plugin-v0.1.0-preview.1">preview release</a> and follow its README.</li>
<li>Start the companion and connect the MCP endpoint <code>https://mcp.lokalbot.com/mcp</code> in a supported client.</li>
<li>Enter your Mac's one-time pairing code on this site's consent page. Never paste a pairing code into a chat.</li>
<li>Enable meeting-library access in LokalBot when you are ready to share requested results.</li></ol>
<p>The library stays on your Mac. Requested results pass through Cloudflare to your connected client. This service cannot read screen history or edit your library.</p>
<p><a href="https://github.com/stevyhacker/LokalBot/pull/224">Preview source and validation</a></p>`,
  },
  "/privacy": {
    title: "LokalBot connection privacy",
    body: `<p>Effective October 9, 2026. This notice covers the optional ChatGPT connection operated by the LokalBot project (<a href="https://github.com/stevyhacker">stevyhacker</a>).</p>
<h2>What you share</h2><p>After you pair a Mac and allow external meeting-library access in LokalBot, your connected client can request meeting titles, dates, summaries, selected transcript excerpts, saved commitments, and people. The complete library is not synchronized. Screen history, recordings, library writes, remote inference, and Agent Mode are not exposed.</p>
<h2>Where results go</h2><p>The companion makes an outbound encrypted connection from your Mac to this Cloudflare-hosted relay. Requested results pass through the relay to ChatGPT or the client you authorized. The relay can process their plaintext; this is not end-to-end encryption against the operator. Cloudflare and your client's own terms and data controls apply. LokalBot does not use these results to train models.</p>
<h2>Storage and retention</h2><p>The application does not persist meeting payloads or application request logs. It stores device identifiers, hashed device credentials, OAuth client registrations, consent transactions, and grants needed to route and authorize requests. Cloudflare processes network metadata to provide and protect its service. We do not promise that the infrastructure retains no network metadata.</p>
<p>Pairing codes expire after ten minutes and work once. Access tokens last fifteen minutes; refresh grants last up to thirty days. Unused devices expire after one day, and previously connected devices expire after up to ninety days offline. Revocation deletes the device record immediately and denies subsequent reads; remaining OAuth records follow the provider's retention rules.</p>
<h2>Your controls</h2><p>Stop the helper, disable meeting-library access in LokalBot, or run the helper's <code>revoke</code> command to block future reads. Disconnect LokalBot in your client as well. These actions cannot recall results already shared; use that client's controls for its saved conversations.</p>
<h2>Questions and deletion requests</h2><p>Use <a href="https://www.lokalbot.com/support">LokalBot support</a> to request a private contact channel for account metadata questions or deletion. Do not post pairing codes, credentials, device files, or meeting content in a public issue. There is no self-service OAuth metadata deletion page in this preview.</p>`,
  },
};

export function publicPage(path: string): Response | undefined {
  const page = pages[path];
  if (!page) return;
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${page.title}</title><style>body{font:17px/1.6 system-ui,sans-serif;max-width:760px;margin:48px auto;padding:0 24px;color:#192b28;background:#f8faf8}h1{line-height:1.15}h2{font-size:1.2em;margin-top:32px}a{color:#165c4e}code{font-size:.9em;overflow-wrap:anywhere}footer{border-top:1px solid #cddbd5;margin-top:40px;padding-top:20px;display:flex;flex-wrap:wrap;gap:20px}</style>
<main><h1>${page.title}</h1>${page.body}</main><footer><a href="/">Connection preview</a><a href="/privacy">Privacy</a><a href="https://www.lokalbot.com/terms">Terms</a><a href="https://www.lokalbot.com/support">Support</a></footer></html>`, {
    headers: {
      "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'",
      "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
    },
  });
}
