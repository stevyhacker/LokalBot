# Connect your Mac to LokalBot for ChatGPT

This preview requires Apple Silicon, macOS 15+, LokalBot, and Node.js 22.12+. Download the [signed preview companion](https://github.com/stevyhacker/LokalBot/releases/tag/chatgpt-plugin-v0.1.0-preview.1). It includes a compatible LokalBot helper and runs in a Terminal window. It does not replace your installed app. The public ChatGPT listing is pending; until it is available, use a client that supports custom remote MCP connections with OAuth.

Your meeting library stays on your Mac. Requested titles, summaries, transcript excerpts, commitments, and people pass through the service operator's Cloudflare relay to ChatGPT. Pair only with the official HTTPS origin shown in the plugin listing. Do not paste pairing codes or credentials into chat, and do not use a code someone sent you.

1. Open the DMG, copy the complete **LokalBot-ChatGPT** folder to a location you control, and eject the DMG. In Terminal, change into the copied folder.
2. Pair your Mac with the official connection service:

   ```sh
   ./lokalbot-connect pair --relay https://mcp.lokalbot.com
   ```

3. Start the connection in the same folder:

   ```sh
   ./lokalbot-connect run
   ```

4. Connect `https://mcp.lokalbot.com/mcp` in your client with OAuth, or choose **Connect** for LokalBot when the ChatGPT listing is available. Confirm that the consent page is on `mcp.lokalbot.com`, and check the requesting client and return domain. Enter your Mac's pairing code on that consent page. It expires in ten minutes and works once.
5. When ready to share requested meeting results, enable **Allow external agents to read your meeting library** in LokalBot's privacy settings. Screen memory and Agent Mode are separate permissions and are not used by this plugin.

The Mac must be awake, online, and running the companion. For an expired code or another client, run `./lokalbot-connect code` in a second Terminal in the same folder. Stopping the running process disconnects it; restart with `./lokalbot-connect run`. Another process using the same credential replaces the older connection.

To remove all relay access for this Mac:

```sh
./lokalbot-connect revoke
```

Revocation closes the connection and deletes its local credential file after the relay confirms it. If offline, stop the companion and turn off meeting-library access immediately; revoke when the relay is reachable. Disconnect the plugin in ChatGPT as well to remove its saved connection. Content already returned to ChatGPT is governed by that client's data controls.

The default credential path is `~/.config/lokalbot-chatgpt/device.json`, with owner-only permissions. For a separate test device, pass the same `--config /absolute/path/device.json` to **every** command. Treat that file like a password. Do not add it to the plugin folder, source control, backups shared with others, or support reports.

For a source-built companion without the preview launcher, use `node dist/device.js` in place of `./lokalbot-connect` and set `LOKALBOT_CLI_PATH` to a compatible helper's absolute path before `run`. Version 0.10.2's embedded helper was observed timing out during the interactive MCP handshake; the preview bundles the fix. Missing permission, an unavailable Mac, and an empty meeting library are different states; permission must be enabled by the user inside LokalBot. No command here enables it.

Read [connection privacy](https://mcp.lokalbot.com/privacy), [terms](https://www.lokalbot.com/terms), and [support](https://www.lokalbot.com/support). The preview has no automatic updater; replace the complete companion folder with a newer verified download when updating.
