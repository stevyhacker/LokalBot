**Fresh latency-ablation examples**

The fastest confirmed configuration produces exactly the current suggestion in every paired case. These examples show why changing the search constraints was less attractive. Selection: largest judged loss for exact-only in each language and width-two in Serbian; the sole budget-eight change. Every judged case is retained in the raw archive.

**Exact typed prefix only — en**

Typed: `The mechanic replaced the cracked belt before starting the eng`

Current (and fastest exact-output candidate): `ine.` — utility 2

Ablation: `in.` — utility -2

Claude: Produces misspelled 'engin'.

**Exact typed prefix only — sr_latn**

Typed: `Mehaničar je zamenio napukli kaiš pre nego što je ponovo pokr`

Current (and fastest exact-output candidate): `enuo motor.` — utility 2

Ablation: `čio.` — utility -2

Claude: 'pokrčio' is not a valid word.

**Two prefix paths — sr_latn**

Typed: `Izmenjeni raspored ostavlja kratku pauzu između popod`

Current (and fastest exact-output candidate): `nevnih i večernjih termina` — utility 2

Ablation: `ručja 1 i` — utility -2

Claude: "popodručja" is not a word, and the number is arbitrary.

**Eight search expansions — sr_latn**

Typed: `Potreban nam je ponovljiv primer pre istraž`

Current (and fastest exact-output candidate): `ivanja i istraživača.` — utility -1

Ablation: `ivanja.` — utility 2

Claude: 'istraživanja.' completes the sentence naturally.

One model opinion on synthetic text, not a user acceptance measurement. The budget-eight improvement is one checkpoint, not a demonstrated general quality gain.
