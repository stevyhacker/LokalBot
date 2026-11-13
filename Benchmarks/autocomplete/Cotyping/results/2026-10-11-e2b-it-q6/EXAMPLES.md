**Literal suggestions with blinded Claude Opus 5.5 ratings**

`▏` marks the cursor; append the continuation directly. `—` means silence. Parentheses show Claude’s utility: +2 strongly useful, +1 useful, 0 neutral, −1 weak, −2 disruptive. These are model opinions, not human acceptance scores.

The first twelve examples are unchanged from the pending report: the first three differing boundary and first three differing midword checkpoints per language in frozen corpus order. They were selected before Claude returned ratings.

**English: preselected examples**

| Typed prefix | Current Q6 | Unsloth IT Q6 | Bartowski IT Q6 |
|---|---|---|---|
| `Please leave the spare umbrella ▏` | `in the car.` **(+1)** | — **(+0)** | — **(+0)** |
| `Could you move the afternoon ▏` | `session to 1:30` **(+1)** | `meeting to 3:00` **(+1)** | `meeting to 3:00` **(+1)** |
| `We need a quieter place ▏` | `to live.` **(+1)** | — **(+0)** | — **(+0)** |
| `We should label the smaller boxes before mov▏` | `ing them to the` **(+1)** | `ing them.` **(+2)** | `ing them.` **(+2)** |
| `We should label the smaller boxes before moving them into the stor▏` | `age unit.` **(+2)** | `age area.` **(+2)** | `age area.` **(+2)** |
| `The printer started working again after we repl▏` | `aced the ink cartridges.` **(+2)** | `aced the cartridge.` **(+2)** | `aced the cartridge.` **(+2)** |

**Serbian Latin: preselected examples**

| Typed prefix | Current Q6 | Unsloth IT Q6 | Bartowski IT Q6 |
|---|---|---|---|
| `Štampač je ponovo proradio nakon ▏` | `što sam ga isključio` **(+2)** | — **(+0)** | — **(+0)** |
| `Možeš li da pomeriš popodnevni ▏` | — **(+0)** | `čas?` **(+1)** | — **(+0)** |
| `Potreban nam je mirniji prostor ▏` | `za` **(+1)** | — **(+0)** | — **(+0)** |
| `Molim te ostavi rezervni kišobran pored ul▏` | `aza u zgradu.` **(+2)** | `itsa.` **(-2)** | `itsa.` **(-2)** |
| `Molim te ostavi rezervni kišobran pored ulaza kako bi ga naš pos▏` | `jetitelj mogao koristiti.` **(+1)** | `iłek.` **(-2)** | `ługa našla.` **(-2)** |
| `Trebalo bi da obeležimo manje kutije pre nego što ih pre▏` | `bacimo u kutiju za` **(+1)** | `bacimo.` **(+2)** | `bacimo.` **(+2)** |

**Additional judged improvements and regressions**

For each language, the table adds the first two cases in corpus order where an IT candidate scores above current Q6, then the first two where one scores below it, excluding examples above. This selection uses the completed ratings and is illustrative; the full sample determines the aggregate result.

| Typed prefix | Current Q6 | Unsloth IT Q6 | Bartowski IT Q6 |
|---|---|---|---|
| `Could you move the afternoon appointment because the ma▏` | `n who is supposed` **(+0)** | `in meeting is running` **(+1)** | `in meeting is running` **(+1)** |
| `We need a quieter place for the interview beca▏` | `use we have a` **(+1)** | `use of the noise` **(+2)** | `use of the noise` **(+2)** |
| `The package should arrive on Friday and the cou▏` | `rier will call me` **(+2)** | `rier service is reliable.` **(+1)** | `rier service is reliable.` **(+1)** |
| `I have added a short explanation ▏` | `of the meaning of` **(+1)** | — **(+0)** | — **(+0)** |
| `Štampač je ponovo proradio nakon što smo zame▏` | `nili matičnu ploč` **(-1)** | `nili glavni motor.` **(+1)** | `nili glavni motor.` **(+1)** |
| `Možeš li da pomeriš popodnevni termin jer ekipi za održavanje treba pri▏` | `lika da se pripreme` **(-1)** | `premiti prostor?` **(+2)** | `premiti prostor?` **(+2)** |
| `Trebalo bi da obeležimo manje kutije pre nego što ih prenesemo u osta▏` | `tak kuće.` **(+1)** | `tak.` **(-1)** | `tak.` **(-1)** |
| `Možeš li da pomeriš popodnevni termin jer ek▏` | `ipa iz Beograda je` **(+1)** | `splodirao?` **(-2)** | `splodirao?` **(-2)** |

The authored future was absent from every Claude packet. All [288 exact cases and ratings](quality-examples.json) are available for inspection. Different plausible continuations may be useful; [the report](REPORT.md) includes uncertainty and reversed-order consistency checks.
