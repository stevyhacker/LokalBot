"""Author-labeled synthetic fixture; run before model inference, never tune on results."""
import hashlib
import json
from pathlib import Path

ASK = '''What did we decide about Redis?|Šta smo odlučili o Redis sistemu?
Who owns the failover benchmark|Ko je zadužen za test oporavka
Summarize the design review|Sažmi pregled dizajna
When is the migration due|Kada je rok za migraciju
Why did we reject the hosted option|Zašto smo odbacili hostovanu opciju
How does the new fee calculation work|Kako radi novi obračun naknade
Which tasks are still open|Koji zadaci su još otvoreni
Did Ana agree to send the report|Da li je Ana pristala da pošalje izveštaj
Compare the two database proposals|Uporedi dva predloga baze podataka
List my commitments from yesterday|Navedi moje obaveze od juče
Explain the storage layout change|Objasni promenu rasporeda skladištenja
Tell me what changed since Monday|Reci mi šta se promenilo od ponedeljka
Remind me why we chose PostgreSQL|Podseti me zašto smo izabrali PostgreSQL
Draft a follow-up based on the meeting|Sastavi poruku na osnovu sastanka
What happened after the deployment failed|Šta se desilo posle neuspele objave
Were the audit findings resolved|Da li su nalazi revizije rešeni
Has Marko finished the integration|Da li je Marko završio integraciju
Can you recap the discussion about retention|Možeš li da prepričaš razgovor o čuvanju podataka
Should we keep the old API according to the call|Treba li da zadržimo stari API prema razgovoru
Where did we leave the pricing discussion|Dokle smo stigli sa razgovorom o cenama
I need a summary of today's standup|Treba mi sažetak današnjeg sastanka
Give me the reasons for delaying release|Daj mi razloge odlaganja izdanja
I'd like to know who approved the budget|Želim da znam ko je odobrio budžet
Help me understand the authentication decision|Pomozi mi da razumem odluku o autentifikaciji
Put together the outstanding follow-ups|Sastavi pregled preostalih obaveza
Break down the risks mentioned in the review|Razloži rizike pomenute u pregledu
Based on our last call, what should I do next|Na osnovu poslednjeg poziva šta treba sledeće da uradim
Please summarize the customer feedback|Molim te sažmi povratne informacije korisnika
Any unresolved questions from the security review?|Ima li nerešenih pitanja sa bezbednosnog pregleda?
What are the next steps for AlphaVault|Koji su sledeći koraci za AlphaVault
Summarize yesterday|Sažmi jučerašnji dan
Explain this decision|Objasni ovu odluku
Who promised to update the documentation?|Ko je obećao da ažurira dokumentaciju?
Is there evidence that we accepted the new deadline|Postoji li dokaz da smo prihvatili novi rok
What's blocking the mobile launch|Šta koči pokretanje mobilne aplikacije
How many action items did I accept|Koliko sam zadataka prihvatio
What did we decide about ERC-7540 compliance|Šta smo odlučili o usklađenosti sa ERC-7540
Why was PR-1234 postponed|Zašto je PR-1234 odložen
Remind me what Jelena said about the API limits|Podseti me šta je Jelena rekla o API ograničenjima
Turn the last meeting into a short status update|Pretvori poslednji sastanak u kratak izveštaj'''

SEARCH = '''Redis|Redis
redis cluster|redis klaster
failover benchmark|test oporavka
PR-1234|PR-1234
AlphaVault.sol|AlphaVault.sol
ERC-7540|ERC-7540
PostgreSQL migration notes|beleške o PostgreSQL migraciji
Ana budget review|Ana pregled budžeta
yesterday standup|jučerašnji sastanak
retention policy|politika čuvanja podataka
Q3 roadmap|Q3 plan razvoja
authentication design|dizajn autentifikacije
customer interview September|razgovor sa korisnikom septembar
fee accounting|obračun naknada
deployment incident|incident pri objavi
screen recording permissions|dozvole za snimanje ekrana
GitHub notification settings|GitHub podešavanja obaveštenja
meeting with Marko|sastanak sa Markom
invoice 2026-091|faktura 2026-091
release checklist|spisak provera za izdanje
"How we ship safely"|"Kako bezbedno objavljujemo softver"
"What good looks like"|"Kako izgleda dobar rezultat"
"Can we scale this"|"Možemo li ovo proširiti"
how-to guide|uputstvo za upotrebu
what|šta
why|zašto
redis?|redis?
API?|API?
whatever happened|šta god se desilo
will release notes|beleške o izdanju
is private mode enabled.txt|da li je privatni režim uključen.txt
summarize_meeting.py|sazmi_sastanak.py
WHERE user_id IS NULL|WHERE user_id IS NULL
who owns this repo.md|ko je vlasnik ovog projekta.md
canary deployment metrics|metrike postepene objave
draft follow-up template|nacrt šablona poruke
compare migration.sql|uporedi migration.sql
tell me more.mp3|reci mi više.mp3
2026-09-22 design review|2026-09-22 pregled dizajna
budget approval screenshot|snimak ekrana odobrenja budžeta'''

def cyrillic(text):
    # Keep literal technical identifiers; transliterate the surrounding Serbian.
    protected = ['Redis', 'PostgreSQL', 'PR-1234', 'AlphaVault', 'GitHub', 'API',
                 'SQL', 'Q3', 'ERC-7540', 'WHERE user_id IS NULL', 'migration.sql',
                 'sazmi_sastanak.py', '.sol', '.txt', '.md', '.mp3']
    for i, word in enumerate(protected):
        text = text.replace(word, f'\uFFF0{i}\uFFF1')
    for a, b in [('Dž','Џ'),('dž','џ'),('Lj','Љ'),('lj','љ'),('Nj','Њ'),('nj','њ')]:
        text = text.replace(a, b)
    latin = 'abcčćdđefghijklmnoprsštuvzž'
    cyr = 'абцчћдђефгхијклмнопрсштувзж'
    text = text.translate(str.maketrans(latin + latin.upper(), cyr + cyr.upper()))
    for i, word in enumerate(protected):
        text = text.replace(f'\uFFF0{i}\uFFF1', word)
    return text

rows = []
for label, block in [('ask', ASK), ('search', SEARCH)]:
    lines = block.splitlines()
    assert len(lines) == 40
    for i, line in enumerate(lines):
        en, sr = line.split('|')
        family = f'{label}-{i + 1:02d}'
        for lang, query in [('en', en), ('sr-Latn', sr), ('sr-Cyrl', cyrillic(sr))]:
            rows.append(dict(id=f'{family}-{lang}', family=family, language=lang,
                             query=query, expected=label, suite='main'))

regressions = {
    'ask': ['What did we decide about Redis?', 'what did we decide about redis',
            'Who owns the failover benchmark', 'summarize the design review', 'redis cluster mode?'],
    'search': ['failover', 'redis cluster', 'what', 'redis?', 'PR-1234', '  ', 'whatever happened'],
}
for label, queries in regressions.items():
    for i, query in enumerate(queries):
        rows.append(dict(id=f'regression-{label}-{i}', family=f'regression-{label}-{i}',
                         language='en', query=query, expected=label, suite='regression'))

path = Path(__file__).with_name('cases.jsonl')
content = ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows)
path.write_text(content)
print(json.dumps({'rows': len(rows), 'main': 240, 'sha256': hashlib.sha256(content.encode()).hexdigest()}))
