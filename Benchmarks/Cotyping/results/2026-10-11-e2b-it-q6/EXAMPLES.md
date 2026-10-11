**Exact matched-frequency suggestions — awaiting Claude ratings**

These are literal outputs, not rewritten demonstrations. `▏` marks the cursor; append the shown continuation directly. `—` means silence. Selection is the first three differing boundary and first three differing midword checkpoints per language in frozen corpus order, not a ranking by quality. All 288 paired cases are in `judge/cases.json` in the evidence archive.

**English**

| Typed prefix | Current Q6 | Unsloth IT Q6 | Bartowski IT Q6 |
|---|---|---|---|
| `Please leave the spare umbrella ▏` | `in the car.` | — | — |
| `Could you move the afternoon ▏` | `session to 1:30` | `meeting to 3:00` | `meeting to 3:00` |
| `We need a quieter place ▏` | `to live.` | — | — |
| `We should label the smaller boxes before mov▏` | `ing them to the` | `ing them.` | `ing them.` |
| `We should label the smaller boxes before moving them into the stor▏` | `age unit.` | `age area.` | `age area.` |
| `The printer started working again after we repl▏` | `aced the ink cartridges.` | `aced the cartridge.` | `aced the cartridge.` |

**Serbian Latin**

| Typed prefix | Current Q6 | Unsloth IT Q6 | Bartowski IT Q6 |
|---|---|---|---|
| `Štampač je ponovo proradio nakon ▏` | `što sam ga isključio` | — | — |
| `Možeš li da pomeriš popodnevni ▏` | — | `čas?` | — |
| `Potreban nam je mirniji prostor ▏` | `za` | — | — |
| `Molim te ostavi rezervni kišobran pored ul▏` | `aza u zgradu.` | `itsa.` | `itsa.` |
| `Molim te ostavi rezervni kišobran pored ulaza kako bi ga naš pos▏` | `jetitelj mogao koristiti.` | `iłek.` | `ługa našla.` |
| `Trebalo bi da obeležimo manje kutije pre nego što ih pre▏` | `bacimo u kutiju za` | `bacimo.` | `bacimo.` |

The authored first-word reference is deliberately absent here, as it was from the judge packets. Several different continuations may be useful. No Claude ratings or quality winner are claimed while judging is blocked.
