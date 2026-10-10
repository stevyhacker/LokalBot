Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

These are selected examples from the fresh confirmation set, including regressions and a remaining failure. They illustrate behavior; the full counts are in [the report](REPORT.md).

The caret is at the end of the typed text. Insertions below are exact, including spaces and punctuation. Claude scores range from −2 (disruptive) to +2 (useful); they are judgments, not human acceptance measurements.

**Correct verb form** · `fresh-sr_latn-04-10-3`

Typed: `Moj ujak čuva malu svesku sa imenima ptica koje je vid`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| E2B | Previous | `o u prirodi.` | -2 |
| E2B | Prefix search | `eo u prirodi.` | +2 |

E2B before: `Moj ujak čuva malu svesku sa imenima ptica koje je vido u prirodi.`

E2B after: `Moj ujak čuva malu svesku sa imenima ptica koje je video u prirodi.`

**Both models repair a broken noun** · `fresh-sr_latn-09-8-4`

Typed: `Obećao sam da ću pomoći rođaki da unese kuti`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| E2B | Previous | `čnu kućicu u` | -2 |
| E2B | Prefix search | `ju u kuću.` | +2 |
| Luchador | Previous | `lj.` | -2 |
| Luchador | Prefix search | `je u kamion.` | +1 |

E2B before: `Obećao sam da ću pomoći rođaki da unese kutičnu kućicu u`

E2B after: `Obećao sam da ću pomoći rođaki da unese kutiju u kuću.`

Luchador before: `Obećao sam da ću pomoći rođaki da unese kutilj.`

Luchador after: `Obećao sam da ću pomoći rođaki da unese kutije u kamion.`

**Correct grammatical case** · `fresh-sr_latn-12-11-3`

Typed: `Ostavio sam činiju sveže vode u hladu za mačku koja luta uli`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| Luchador | Previous | `ca.` | -2 |
| Luchador | Prefix search | `com.` | +2 |

Luchador before: `Ostavio sam činiju sveže vode u hladu za mačku koja luta ulica.`

Luchador after: `Ostavio sam činiju sveže vode u hladu za mačku koja luta ulicom.`

**Finish the typed word before continuing** · `fresh-sr_latn-11-6-6`

Typed: `Mali muzej ima zbirku mapa koje pokazu`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| E2B | Previous | ` kako je izgledao grad` | -2 |
| E2B | Prefix search | `ju kako je izgledao` | +2 |

E2B before: `Mali muzej ima zbirku mapa koje pokazu kako je izgledao grad`

E2B after: `Mali muzej ima zbirku mapa koje pokazuju kako je izgledao`

**English also improves** · `fresh-en-04-10-3`

Typed: `My uncle keeps a small notebook with the names of bir`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| E2B | Previous | `thed in the family.` | -2 |
| E2B | Prefix search | `ds he has seen` | +2 |

E2B before: `My uncle keeps a small notebook with the names of birthed in the family.`

E2B after: `My uncle keeps a small notebook with the names of birds he has seen`

**Serbian regression** · `fresh-sr_latn-26-11-6`

Typed: `Sažetak treba da navede glavnu odluku pre nego što nabroji preostala otvore`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| E2B | Previous | `na pitanja.` | +2 |
| E2B | Prefix search | `nija pitanja.` | -2 |

E2B before: `Sažetak treba da navede glavnu odluku pre nego što nabroji preostala otvorena pitanja.`

E2B after: `Sažetak treba da navede glavnu odluku pre nego što nabroji preostala otvorenija pitanja.`

**English regression** · `fresh-en-10-5-5`

Typed: `We need to buy a longe`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| Luchador | Previous | `r rope.` | +2 |
| Luchador | Prefix search | `t for a chicken.` | -2 |

Luchador before: `We need to buy a longer rope.`

Luchador after: `We need to buy a longet for a chicken.`

**Remaining failure** · `fresh-sr_latn-00-5-2`

Typed: `Pumpa za bicikl visi pored al`

| Model | Decoder | Exact insertion | Claude utility |
|---|---|---|---:|
| Luchador | Previous | `be.` | -2 |
| Luchador | Prefix search | `be.` | -2 |

Luchador before: `Pumpa za bicikl visi pored albe.`

Luchador after: `Pumpa za bicikl visi pored albe.`
