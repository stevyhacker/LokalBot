# LokalBot for ChatGPT — preview companion

Requires Apple Silicon, macOS 15+, LokalBot, and Node.js 22.12+ (Node 24 LTS recommended). This is a foreground Terminal helper. The ChatGPT public listing is still pending; test connections require a client that supports custom remote MCP connections with OAuth.

This download includes a separate, compatible `lokalbot-cli`. It reads the same library under LokalBot's existing meeting-library permission. It does not replace or modify the installed app, enable permissions, or expose screen memory. Its source revision is recorded in `SOURCE.json`.

1. Open the signed DMG and copy the **LokalBot-ChatGPT** folder to a location you control, then eject the DMG. Keep the whole folder together.
2. Open Terminal in that copied folder. Pair your Mac:

   ```sh
   ./lokalbot-connect pair --relay https://mcp.lokalbot.com
   ```

3. Keep the connection running:

   ```sh
   ./lokalbot-connect run
   ```

4. Connect `https://mcp.lokalbot.com/mcp` in your client with OAuth. The consent page must be on `mcp.lokalbot.com`. Enter the pairing code there, never in chat. Check the requesting client and return domain before approving.
5. Enable **Allow external agents to read your meeting library** in LokalBot's privacy settings when ready to share requested results. Ask about a meeting or a saved commitment.

The Mac must stay awake and online, with the Terminal helper running. A code expires in ten minutes and works once; get another with `./lokalbot-connect code`. Stop the connection with Control-C. Restart with `./lokalbot-connect run`.

To revoke this Mac's connection:

```sh
./lokalbot-connect revoke
```

Disable meeting-library access in LokalBot and disconnect the client as well. Revocation cannot recall results already sent to ChatGPT.

The full library stays on the Mac, but requested meeting information passes through Cloudflare to your client. Read [connection privacy](https://mcp.lokalbot.com/privacy), [terms](https://www.lokalbot.com/terms), and [support](https://www.lokalbot.com/support).

Credentials are stored in `~/.config/lokalbot-chatgpt/device.json` with owner-only permissions. Treat it like a password. For a separate synthetic test device, pass the same `--config /absolute/path/device.json` to every command and set `LOKALBOT_STORAGE_ROOT` to the test library before running. Do not share real meeting data, device files, or pairing codes in support reports.

This preview uses an unmerged source branch. It has no automatic updater; replace the complete companion folder when installing a newer verified preview. Do not bypass macOS security checks if an artifact fails verification.
