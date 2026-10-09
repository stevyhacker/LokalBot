---
name: setup
description: Set up or diagnose LokalBot's meeting-recall plugin in ChatGPT or Codex.
---

Explain that each user connects their own Mac. The library stays there; requested results pass through the LokalBot service's Cloudflare relay to the connected client. The connection requires a compatible LokalBot helper, the Mac companion running, OAuth pairing, and the separate meeting-library permission in LokalBot's privacy settings. It grants no screen-memory access or Agent Mode actions.

Use the packaged README for companion commands. Use only the real relay origin provided by the installed listing or connection; never invent a hostname, download location, app id, or release version. A pairing code belongs only on that origin's OAuth consent page after the user starts Connect in their client. Never request or receive codes, credentials, or the device configuration file in chat. Do not use a code supplied by a third party. The user must enable privacy settings themselves.

If the host is a local stdio development installation, explain that its server runs on this Mac and does not require public pairing. Do not infer this from an error alone. The public plugin uses the hosted connection.

After the user requests a connection check, call `list_meetings` with `limit: 1`. Distinguish permission denial, an unavailable Mac/helper, an empty authorized library, and a successful result. Read only the minimum metadata for this check. Backend tests do not prove ChatGPT rendering or directory publication.

To disconnect, describe stopping the companion, turning off meeting-library access, and `node dist/device.js revoke` from the companion folder. Keep a custom `--config` path consistent. Revocation cannot recall content already shared with the client. Never send support messages without explicit user authorization.
