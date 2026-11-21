# Replay — November 21, 2026 at 8:46 PM
**Duration:** in progress · **App:** Benchmark · **Words:** 486 words · **Template:** Meeting · **Model:** inkling-2-mini · on this PC

## TL;DR

- **Them 1:** Odluka promenjena: nema verzije tri; odgovor ostaje unazad kompatibilan, ETA ostaje nepromenjen, delivery window dodajemo kao novo opciono polje, ostajemo na verziji dva, puštanje 11. novembra. — [00:02:07]
- **Them 1:** Danijele ažurira API specifikaciju i changelog do petka; javi Leni da je šema zamrznuta; Prija mejlom obavesti tri partnera. — [00:02:50]
- **Them 1:** Backfill za stare porudžbine ostaje otvoreno; Majo pita Priju da li partnerima to treba. — [00:03:30]

## Key points

- **Them 2:** Podrška želi da kupci vide delivery window (npr. između dva i četiri popodne) umesto jednog ETA vremena; tri najveća partnera su tražila isto. — [00:00:19]
- **Them 2:** 42 partnera pozivaju orders endpoint; 19 koristi generisane klijente koji pucaju kad nedostaje polje koje očekuju; uklanjanje ETA bi tih 19 srušilo onog dana kad pustimo izmenu. — [00:01:32]
- **Them 2:** Fernhill je trebalo četiri meseca da pređe na verziju dva. — [00:02:01]
- **Them 2:** Performanse u redu u oba slučaja: P95 latencija ostaje oko 180 milisekundi. — [00:01:08]
- **Them 2:** Tomas kaže da mobilni tim to može da ubaci u reliz 4.2, ali ne ranije. — [00:01:20]
- **Them 1:** Backfill znači ponovno pokretanje estimatora nad oko dva miliona otvorenih porudžbina; ne zna se da li se isplati. — [00:03:13]

## Decisions

- Them 1: Nema verzije tri; odgovor ostaje unazad kompatibilan: ETA ostaje tačno onakav kakav je, delivery window dodajemo kao novo opciono polje; ako ne znamo prozor, polje izostavljamo. — [00:02:07]
- Them 2: Opciono, izostavljeno kad je nepoznato, ETA bez promene, ostajemo na verziji dva; puštanje do 11. novembra umesto 18. — [00:02:20]

## Action items

### Me
None

### Others
- [ ] Them 2: Pusti izmenu do 11. novembra (umesto 18.) — due 11. novembra — [00:02:20]
- [ ] Them 1: Pita Priju da li partnerima treba backfill za stare porudžbine — [00:03:30]
- [ ] Them 2: Ažurira API specifikaciju i changelog do petka — due petka — [00:02:50]

### Owner unclear
- [ ] Lena doda contract testove (dva dana kad se šema zamrzne) — [00:01:28]
- [ ] Prija mejlom obavesti tri partnera koja su tražila delivery window — [00:02:50]
- [ ] Javi Leni da je šema zamrznuta — [00:02:46]

## Open questions

- **Them 2:** Da li radimo backfill delivery windowa za porudžbine napravljene pre izmene, ili samo za nove porudžbine — otvoreno; Majo pita Priju. — [00:03:03]
