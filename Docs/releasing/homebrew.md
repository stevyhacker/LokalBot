# Homebrew synchronization after a stable release

Part of the [release runbook](../../RELEASING.md).

The public `stevyhacker/homebrew-tap` owns an hourly `Sync LokalBot release`
workflow. It verifies downloaded release assets and their appcast relationship
before updating the live cask; it does not require a cross-repository secret.
For immediate synchronization after publication:

```sh
gh workflow run sync-lokalbot.yml --repo stevyhacker/homebrew-tap --ref main
```

Confirm the run succeeded and the live cask's version/SHA-256 match the published
DMG before announcing Homebrew availability. Do not treat `brew livecheck` or a
dispatched workflow as synchronization proof. See
[the Homebrew runbook](../../Distribution/homebrew/README.md#3-shipping-path-own-tap).
