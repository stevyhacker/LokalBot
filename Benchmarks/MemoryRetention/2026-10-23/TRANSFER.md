# Narrowed remote transfer

Automatic approval review rejected copying the entire directory because it contained the application source snapshot. No transfer occurred. Before inference, frozen.json was amended to exclude that snapshot from runtime inputs. The original local-only manifest is preserved. Only explicitly listed synthetic data, rendered prompts, benchmark scripts, protocol and checksum manifests are sent. The complete application source snapshot stays local.
