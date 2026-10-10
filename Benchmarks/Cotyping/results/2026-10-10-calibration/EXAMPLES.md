Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Paired examples

Illustrative wins and losses from the same matched-frequency confirmation run. The score table in REPORT.md uses every case. These examples are selected in corpus order within language, checkpoint type and win/loss strata, not an additional test. `▌` marks the caret; append the suffix exactly. Claude utility is −2…+2; silence is zero.

## 1. en · boundary

Typed: `I have attached the updated ▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | Silence | +0 |
| Luchador E4B hybrid | `document.` | +1 |
| Stock Gemma E4B IT hybrid | `document.` | +1 |

## 2. en · boundary

Typed: `The delivery driver called to say ▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | `he was at the` | +1 |
| Luchador E4B hybrid | `they were running late.` | +2 |
| Stock Gemma E4B IT hybrid | `they were running late.` | +2 |

## 3. en · boundary

Typed: `Could we move the discussion online since the meeting ▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | `is` | +1 |
| Luchador E4B hybrid | Silence | +0 |
| Stock Gemma E4B IT hybrid | `is` | +1 |

## 4. sr_latn · boundary

Typed: `Dostavljač je zvao da kaže da ne može da pronađe ▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | Silence | +0 |
| Luchador E4B hybrid | `adresu.` | +2 |
| Stock Gemma E4B IT hybrid | `adresu.` | +2 |

## 5. sr_latn · boundary

Typed: `Dostavljač je zvao da kaže da ▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | `je` | +1 |
| Luchador E4B hybrid | Silence | +0 |
| Stock Gemma E4B IT hybrid | Silence | +0 |

## 6. sr_latn · midword

Typed: `U prilogu šaljem izmenjeni raspored kako biste mo▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | `gli da se upoznate` | +1 |
| Luchador E4B hybrid | `gli ga pregledati.` | +2 |
| Stock Gemma E4B IT hybrid | `gli ga pregledati.` | +2 |

## 7. sr_latn · midword

Typed: `Dostavljač je zvao da kaže da ne mo▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | `že da dođe jer` | +2 |
| Luchador E4B hybrid | `že isporučiti.` | +1 |
| Stock Gemma E4B IT hybrid | `že isporučiti.` | +1 |

## 8. sr_latn · midword

Typed: `Kada nestane veza sa mrežom, program treba da zad▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | `rži sve podatke koji` | +1 |
| Luchador E4B hybrid | `rma sve operacije dok` | -2 |
| Stock Gemma E4B IT hybrid | `rma (pause) izvrš` | -2 |

## 9. sr_latn · midword

Typed: `Dodaj napomenu da se ovo podešavanje odnosi sa▌`

| Model | Offered suffix | Opus utility |
|---|---|---:|
| Gemma E2B hybrid | `mo na Windows 1` | -1 |
| Luchador E4B hybrid | `mo do tego urządzenia.` | -2 |
| Stock Gemma E4B IT hybrid | `mo do tego urządzenia.` | -2 |
