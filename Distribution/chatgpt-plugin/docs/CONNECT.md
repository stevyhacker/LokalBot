# Connect your Mac to LokalBot for ChatGPT

This companion requires Node 22.12+ and a compatible LokalBot app with the interactive MCP pipe-reader fix. Version 0.10.2 was observed timing out during that handshake. Use the release named in the eventual plugin listing, or a helper built from this source for development. The companion is currently a foreground command, not an app login item.

Your meeting library stays on your Mac. Requested titles, summaries, transcript excerpts, commitments, and people pass through the service operator's Cloudflare relay to ChatGPT. Pair only with the official HTTPS origin shown in the plugin listing. Do not paste pairing codes or credentials into chat, and do not use a code someone sent you.

1. Keep the complete companion folder in a stable location. In Terminal, change into that folder.
2. Start pairing with the real origin from the listing:

   ```sh
   node dist/device.js pair --relay https://RELAY_ORIGIN_FROM_THE_LISTING
   ```

3. Start the connection in the same folder:

   ```sh
   node dist/device.js run
   ```

4. Choose **Connect** for LokalBot in ChatGPT. Confirm the relay domain, requesting client, and return domain. Enter your Mac's pairing code on that consent page. It expires in ten minutes and works once.
5. When ready to share requested meeting results, enable **Allow external agents to read your meeting library** in LokalBot's privacy settings. Screen memory and Agent Mode are separate permissions and are not used by this plugin.

The Mac must be awake, online, and running the companion. For an expired code or another client, run `node dist/device.js code` in a second Terminal. Stopping the running process disconnects it; restart with `run`. Another process using the same credential replaces the older connection.

To remove all relay access for this Mac:

```sh
node dist/device.js revoke
```

Revocation closes the connection and deletes its local credential file after the relay confirms it. If offline, stop the companion and turn off meeting-library access immediately; revoke when the relay is reachable. Disconnect the plugin in ChatGPT as well to remove its saved connection. Content already returned to ChatGPT is governed by that client's data controls.

The default credential path is `~/.config/lokalbot-chatgpt/device.json`, with owner-only permissions. For a separate test device, pass the same `--config /absolute/path/device.json` to **every** command. Treat that file like a password. Do not add it to the plugin folder, source control, backups shared with others, or support reports.

For a development installation, set `LOKALBOT_CLI_PATH` to the absolute helper path before `run`. Missing permission, an unavailable Mac, and an empty meeting library are different states; permission must be enabled by the user inside LokalBot. No command here enables it.

Read the [LokalBot privacy contract](https://github.com/stevyhacker/LokalBot/blob/master/PRIVACY.md). The service must publish current privacy, support, and release information before public launch.
