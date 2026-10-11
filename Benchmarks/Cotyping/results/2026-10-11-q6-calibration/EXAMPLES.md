**Exact suggestions at equal frequency — Q6 calibration**

These eight illustrative cases include four where Claude preferred bilingual calibration and four where it preferred current Q6. They do not estimate the overall win rate: bilingual wins 8 and loses 14 of all 288 checkpoints, with 266 utility ties. All cases and scores are in [quality-examples.json](quality-examples.json).

The cursor is shown as `▌`. Suggestions are JSON-quoted to preserve leading spaces and exact text. Append the string to the typed prefix; midword fragments are intentional. Utility is Claude’s −2..2 opinion relative to silence, not an observed acceptance rate. No reference future was supplied to Claude.

**English: bilingual preferred — fresh-17-en-2**

Typed: `The import finishes successfully but empty rows remain visible at the bott▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `"om of the page."` | +1 |
| Published static Q6 | `"om of the page."` | +1 |
| English-calibrated Q6 | `"om of the table."` | +2 |
| EN/SR Latin calibrated Q6 | `"om of the table."` | +2 |

Claude on current: Completes 'bottom' correctly; 'page' is plausible, though 'table' fits rows better.
Claude on bilingual: Completes 'bottom' naturally; 'table' fits empty rows well.

**English: useful new offer — fresh-07-en-0**

Typed: `Please keep the receipt until ▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `(no suggestion)` | +0 |
| Published static Q6 | `(no suggestion)` | +0 |
| English-calibrated Q6 | `(no suggestion)` | +0 |
| EN/SR Latin calibrated Q6 | `"you"` | +1 |

Claude on current: No suggestion.
Claude on bilingual: A plausible short next word.

**Serbian Latin: cleaner ending — fresh-06-sr_latn-2**

Typed: `Potreban nam je mirniji prostor za razgovor jer radovi na obližnjem gradilištu postaj▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `"u sve glasniji, a"` | +1 |
| Published static Q6 | `"u sve glasniji, a"` | +1 |
| English-calibrated Q6 | `"u sve glasniji."` | +2 |
| EN/SR Latin calibrated Q6 | `"u sve glasniji."` | +2 |

Claude on current: Correct, natural completion, but the trailing 'a' adds some speculation.
Claude on bilingual: Natural, complete ending that fits the context well.

**Serbian Latin: plausible new offer — fresh-09-sr_latn-0**

Typed: `Dodao sam kratko objašnjenje ispod ▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `(no suggestion)` | +0 |
| Published static Q6 | `(no suggestion)` | +0 |
| English-calibrated Q6 | `(no suggestion)` | +0 |
| EN/SR Latin calibrated Q6 | `"slike."` | +1 |

Claude on current: No suggestion.
Claude on bilingual: 'ispod slike' is a plausible, ordinary completion.

**English: invented tail — fresh-27-en-1**

Typed: `Please put the clean towels on the upper shel▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `"f."` | +1 |
| Published static Q6 | `"f of the dryer."` | -1 |
| English-calibrated Q6 | `"f of the laundry"` | +0 |
| EN/SR Latin calibrated Q6 | `"f of the dryer."` | -1 |

Claude on current: A clean completion of 'shelf', though it saves only one letter.
Claude on bilingual: Dryers rarely have shelves, so 'of the dryer' is an arbitrary, unlikely detail.

**English: weaker ending — fresh-05-en-1**

Typed: `The package should arrive on Friday and the cou▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `"rier will call me"` | +2 |
| Published static Q6 | `"rier will call to"` | +1 |
| English-calibrated Q6 | `"rier will call to"` | +1 |
| EN/SR Latin calibrated Q6 | `"rier will call to"` | +1 |

Claude on current: Natural completion of 'courier' with a plausible next clause.
Claude on bilingual: Completes 'courier' well; ends on 'to', which is an acceptable unfinished phrase.

**Serbian Latin: arbitrary number — fresh-21-sr_latn-1**

Typed: `Pregled bi trebalo automatski da se osv▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `"ježi kada se otvori"` | +2 |
| Published static Q6 | `"ježi nakon 10"` | -1 |
| English-calibrated Q6 | `"ježi nakon 10"` | -1 |
| EN/SR Latin calibrated Q6 | `"ježi nakon 10"` | -1 |

Claude on current: Completes 'osvežava' (refreshes) naturally with a sensible condition.
Claude on bilingual: The number 10 is arbitrary, and the unit is missing.

**Serbian Latin: unclear reference — fresh-40-sr_latn-1**

Typed: `Uputstva bi bilo lakše pratiti kada bi se sv▌`

| Variant | Exact continuation | Claude utility |
|---|---|---:|
| Current Q6 | `"e informacije nalazile na"` | +2 |
| Published static Q6 | `"e informacije nalazile na"` | +2 |
| English-calibrated Q6 | `"e informacije o njima"` | +0 |
| EN/SR Latin calibrated Q6 | `"e informacije o njima"` | +0 |

Claude on current: Natural 'sve informacije nalazile na' leading to 'jednom mestu'.
Claude on bilingual: 'Sve' fine, but 'informacije o njima' awkward, unclear referent.

In the “osv” example Claude misnames the actual completed word in its explanation: the output is “osvježi”, not “osvežava”. The original score and explanation are preserved; this is one reason to treat the judge as fallible and inspect the strings yourself.

[Full report](REPORT.md) · [All seven variants and language breakdowns](TABLES.md)
