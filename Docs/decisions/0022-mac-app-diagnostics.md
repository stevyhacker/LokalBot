# 0022. Mac app: Diagnostics

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Diagnostics/`, `LokalBotTests/Services/Diagnostics/`.

## Decisions

### `LokalBot/Services/Diagnostics/DiagnosticsExporter.swift`

#### Export never reads meetings, screenshots or OCR so no content leaks into archive
`DiagnosticsExporter`: Builds the Export Diagnostics archive: recent logs, health reports,
settings without secrets, library row counts, and capture traces (already
scrubbed when written). It never reads the meetings folder, screenshots, or
OCR text, so meeting audio, transcripts, notes, and screen content cannot
end up in the archive.

#### Build archive then swap so an earlier archive is replaced only after the new exists
`DiagnosticsExporter.export`: Build the archive beside the staging folder, then swap it in: an
earlier archive is replaced only once the new one exists.

#### Only row counts, never row contents
`DiagnosticsExporter.libraryCounts`: Row counts only; never row contents.

### `LokalBot/Services/Diagnostics/DiagnosticsSettingsSanitizer.swift`

#### Drop credential-named keys and strip URL user info and query before export
`DiagnosticsSettingsSanitizer`: Removes secrets from encoded settings before they leave the Mac in a
diagnostics archive: any key that names a credential is dropped, and URLs
lose their user info and query.

### `LokalBotTests/Services/Diagnostics/DiagnosticsExporterTests.swift`

#### Exporting diagnostics to a folder like Desktop must never delete it
`testExportRefusesAnExistingFolderAndLeavesItIntact`: `--export-diagnostics ~/Desktop` must never delete the Desktop.

#### An earlier archive is replaced only once the new one exists
`testExportReplacesAnEarlierArchiveFile`: Replacing an earlier archive happens only once the new one exists.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
