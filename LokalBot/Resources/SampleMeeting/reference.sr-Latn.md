# Primer: delivery window u Orders API-ju

Reference transcript of the LokalBot sample meeting: what each synthetic voice was asked to say, with the time each turn starts in the recording. The people and the company are fictional.

**[00:00] Maja:** Ovo je primer sastanka u LokalBotu. Glasovi su sintetički, a firma i ljudi u njemu su izmišljeni.

**[00:06] Maja:** Ćao, Danijele. Čuješ li me dobro?

**[00:09] Danijel:** Čujem te odlično, Majo. Izvini što kasnim minut, još mi se vrteo build.

**[00:13] Maja:** Nema problema. Hajde da rešimo delivery window za Orders API.

**[00:19] Danijel:** Može. Ukratko, kontekst: podrška želi da kupci vide delivery window, recimo između dva i četiri popodne, umesto jednog ETA vremena koje danas vraćamo.

**[00:31] Maja:** Tako je. A Prija iz partner success tima kaže da su tri naša najveća partnera tražila isto.

**[00:38] Maja:** Znači, plan od prošle nedelje: ETA polje menjamo novim delivery window objektom i to puštamo kao verziju tri API-ja.

**[00:48] Danijel:** To je bio plan. Prozor bi imao dva timestampa, početak i kraj, oba u UTC-u. Verziju tri mogu da spremim do osamnaestog novembra.

**[00:59] Maja:** Okej. Odluka za sada: verzija tri, delivery window zamenjuje ETA, a cilj je osamnaesti novembar.

**[01:08] Danijel:** Performanse su u redu u oba slučaja. Merio sam juče, i P95 latencija ostaje na oko sto osamdeset milisekundi.

**[01:16] Maja:** Dobro. A mobilna aplikacija?

**[01:20] Danijel:** Tomas kaže da mobilni tim to može da ubaci u reliz četiri tačka dva, ali ne ranije.

**[01:25] Maja:** To je u redu. A testiranje?

**[01:28] Danijel:** Lena će dodati contract testove. Treba joj dva dana kad se šema zamrzne.

**[01:32] Danijel:** Zapravo, pre nego što ovo zaključamo. Sinoć sam prošao kroz integracije partnera. Četrdeset dva partnera pozivaju orders endpoint, a devetnaest njih koristi generisane klijente koji pucaju kad nedostaje polje koje očekuju. Ako uklonimo ETA, tih devetnaest pada onog dana kad pustimo izmenu.

**[01:52] Maja:** Devetnaest od četrdeset dva. To je skoro polovina. A verzija tri znači da baš svaki partner mora da migrira.

**[02:01] Danijel:** Tačno. Samo je Fernhillu trebalo četiri meseca da pređe na verziju dva.

**[02:07] Maja:** Onda menjamo odluku. Nema verzije tri. Odgovor ostaje unazad kompatibilan: ETA ostaje tačno onakav kakav je, a delivery window dodajemo kao novo, opciono polje. Ako ne znamo prozor, to polje izostavljamo.

**[02:20] Danijel:** Opciono, izostavljeno kad je nepoznato, ETA bez promene, i ostajemo na verziji dva. To je i manje posla. Mogu to da pustim do jedanaestog novembra umesto do osamnaestog.

**[02:33] Maja:** Odlično. Znači, za beleške: ovo zamenjuje ono što smo rekli na početku. Odgovor ostaje unazad kompatibilan, delivery window je opciono polje, i puštamo jedanaestog novembra.

**[02:46] Danijel:** Da onda javim Leni da je šema zamrznuta?

**[02:50] Maja:** Da, javi joj. I Prija će mejlom obavestiti ta tri partnera koja su to tražila. Danijele, možeš li da ažuriraš API specifikaciju i changelog?

**[03:01] Danijel:** Da, završiću oba do petka.

**[03:03] Danijel:** Jednu stvar još nismo rešili: da li radimo backfill delivery windowa za porudžbine koje su napravljene pre izmene, ili samo za nove porudžbine?

**[03:13] Maja:** Hm. Backfill znači da ponovo pokrenemo estimator nad oko dva miliona otvorenih porudžbina. Iskreno, ne znam da li se to isplati.

**[03:25] Danijel:** Ne znam ni ja. Zavisi od toga da li partneri uopšte gledaju stare porudžbine.

**[03:30] Maja:** Hajde da to zasad ostavimo otvoreno. Pitaću Priju da li partnerima to treba za stare porudžbine.

**[03:36] Danijel:** Okej. Znači, backfill je i dalje otvoreno pitanje.

**[03:41] Maja:** Da. Hvala, Danijele. To je to za danas.

