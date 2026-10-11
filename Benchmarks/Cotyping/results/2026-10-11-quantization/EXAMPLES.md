**Quantization examples — synthetic text, equal suggestion frequency**

These are the largest judged win and loss for each quantization in each language (ties use corpus order), deliberately showing both extremes. They are not a representative acceptance sample. The full 288-case output/rating map is `quality-examples.json` in the evidence archive. Text is copied exactly, including unfinished tails. Join each continuation directly to the typed prefix.

**Q4_K_M — en, selected loss (fresh-03-en-2)**

Typed: `The librarian renewed my membership and explained how to re`

- Current Q6: `new my books.` — utility +2. Renewing books is a natural library follow-up.
- Q4_K_M: `new my membership.` — utility -1. Awkwardly repeats 'renewed my membership' from the same sentence.

**Q4_K_M — en, selected win (fresh-02-en-0)**

Typed: `We should check the weather `

- Current Q6: *no suggestion* — utility +0. No suggestion.
- Q4_K_M: `forecast before we go` — utility +2. Natural, common phrase with good typing savings.

**Q4_K_M — sr_latn, selected loss (fresh-09-sr_latn-2)**

Typed: `Grupa za pešačenje će se okupiti pored fontane blizu glav`

- Current Q6: `nog ulaza u park,` — utility +2. 'glavnog ulaza u park' is natural and saves useful typing.
- Q4_K_M: `nog trga u 1` — utility -1. Good word completion, but the tail ends in a dangling, arbitrary number.

**Q4_K_M — sr_latn, selected win (fresh-14-sr_latn-1)**

Typed: `Molim te isključi produžni kabl pre nego što pome`

- Current Q6: `riš ili ukloniš bilo` — utility -1. The tail ends on a dangling 'bilo' and feels unfinished.
- Q4_K_M: `riš uređaj.` — utility +2. Natural, generic object for unplugging before moving it.

**IQ4_XS — en, selected loss (fresh-01-en-2)**

Typed: `Please fold the clean towels and put them on the bath`

- Current Q6: `room shelf.` — utility +2. Natural, sensible completion of 'bathroom shelf'.
- IQ4_XS: `room floor.` — utility -1. Putting clean folded towels on the floor is implausible.

**IQ4_XS — en, selected win (fresh-19-en-2)**

Typed: `We arranged the photographs in chronological order before making the fa`

- Current Q6: `ces of the people` — utility -1. 'making the faces of the people' doesn't make sense here.
- IQ4_XS: `mily tree.` — utility +2. 'family tree' is a coherent, natural completion.

**IQ4_XS — sr_latn, selected loss (fresh-44-sr_latn-1)**

Typed: `Pregled je otkrio nedoslednost između na`

- Current Q6: `voda u dokumentaciji i` — utility +2. Natural and fits the review context well.
- IQ4_XS: `voda o broju žrt` — utility -2. Ends on the cut-off token 'žrt'; 'victims' is an unsupported specific.

**IQ4_XS — sr_latn, selected win (fresh-07-sr_latn-1)**

Typed: `Potreban nam je vodootporan pokrivač za stolic`

- Current Q6: `u za wc školjku` — utility -1. A chair cover 'za wc školjku' is odd and too specific.
- IQ4_XS: `u za kupanje.` — utility +1. Plausible bath chair; somewhat specific, but reasonable.

**Q5_K_M — en, selected loss (fresh-03-en-2)**

Typed: `The librarian renewed my membership and explained how to re`

- Current Q6: `new my books.` — utility +2. Renewing books is a natural library follow-up.
- Q5_K_M: `new my membership.` — utility -1. Awkwardly repeats 'renewed my membership' from the same sentence.

**Q5_K_M — en, selected win (fresh-39-en-1)**

Typed: `We agreed to review the unanswered questi`

- Current Q6: `ons and the answers` — utility -1. Unanswered questions with 'the answers' contradicts itself.
- Q5_K_M: `ons from the previous` — utility +2. Natural, useful phrase: questions from the previous meeting.

**Q5_K_M — sr_latn, selected loss (fresh-32-sr_latn-2)**

Typed: `Možemo da odložimo konačnu odluku dok preostala merenja ne budu dos`

- Current Q6: `tupna.` — utility +2. Completes 'dostupna' naturally and ends the sentence.
- Q5_K_M: `tupna, ali je jasno` — utility +0. The clause 'ali je jasno' doesn't fit the logic of the sentence.

**Q5_K_M — sr_latn, selected win (fresh-29-sr_latn-1)**

Typed: `Otkrili smo duplirani unos tokom usk`

- Current Q6: `lađivanja sa EU, a` — utility -1. Word completion is good, but the EU is an unsupported specific and the tail dangles.
- Q5_K_M: `lađivanja podataka iz sistema` — utility +2. Natural, relevant completion: reconciling data from the system.

**Q8_0 — en, selected loss (fresh-24-en-1)**

Typed: `The draft needs a shorter introduction before we sh`

- Current Q6: `ow the reader what` — utility +1. 'show the reader' is plausible, but 'share' is more likely.
- Q8_0: `ould even start to` — utility -1. 'before we should' is unidiomatic, and 'even start' adds to the awkwardness.

**Q8_0 — en, selected win (fresh-19-en-2)**

Typed: `We arranged the photographs in chronological order before making the fa`

- Current Q6: `ces of the people` — utility -1. 'making the faces of the people' doesn't make sense here.
- Q8_0: `mily tree.` — utility +2. 'family tree' is a coherent, natural completion.

**Q8_0 — sr_latn, selected loss (fresh-32-sr_latn-2)**

Typed: `Možemo da odložimo konačnu odluku dok preostala merenja ne budu dos`

- Current Q6: `tupna.` — utility +2. Completes 'dostupna' naturally and ends the sentence.
- Q8_0: `tupna, ali je jasno` — utility +0. The clause 'ali je jasno' doesn't fit the logic of the sentence.

**Q8_0 — sr_latn, selected win (fresh-29-sr_latn-2)**

Typed: `Otkrili smo duplirani unos tokom usklađivanja evidencije iz pret`

- Current Q6: `hodnog perioda sa evid` — utility -1. Ends with unfinished token 'evid'.
- Q8_0: `hodnog perioda.` — utility +2. Natural complete ending.
