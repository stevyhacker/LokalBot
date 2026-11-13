# OCR benchmark data boundary

Use the checked-in `synthetic/` corpus first. These tools are manual experiments;
they do not run as part of application capture or retention.

Download the selected Hugging Face model and tokenizer at a reviewed, immutable
40-character commit SHA **before** decrypting private fixtures. Pass that SHA as
`--revision` to `run_transformers_ocr_benchmark.py`. The runner loads only cached
files, disables Hub networking/telemetry, and records the revision in `run.json`.
It does not silently fetch model code. `--allow-reviewed-remote-code` is an
explicit option for synthetic fixtures only.

`run_unlimited_ocr_mps.py` is a legacy model-specific path whose architecture
requires custom Python. It accepts only images beneath a
`.synthetic-ocr-fixtures` marker and only a local Hugging Face
`snapshots/<40-character-revision>` directory. Pass the matching `--revision`,
`--corpus-kind synthetic`, and `--allow-reviewed-local-code` only after reviewing
that snapshot. The runner denies network access before importing the model,
loads cached files only, creates a new owner-only output directory, and records
the revision in `run.json`. It refuses private fixture markers entirely; do not
use it for decrypted screen exports.

Private exports require `--allow-decrypt-private-screen-data` after the manifest
and a new output-directory argument. This exports ordinary PNG and text files,
not encrypted app artifacts. The directory is owner-only (0700) and files are
owner-only (0600). Use a local, unsynced temporary location. The exporter marks the
directory `.private-screen-fixtures`; do not remove that marker while using it.

Run private fixtures with `--corpus-kind private`. The runner applies the macOS
network-denied sandbox to its process before importing model libraries. Private
runs refuse remote model code and fail on hosts without that sandbox. A missing
cached model is an error; prepare it separately rather than allowing network
access during the private run.

Treat the input TSV, exported images/text, terminal reports, and model outputs as
private data. Do not commit or upload them. Delete the export and result directories
and their TSVs after review, including after a failed run. Application retention
does not remove benchmark copies. Use your normal backup/sync deletion controls
if you chose a backed-up or synced location; removing a local file is not secure
erasure of other copies.
