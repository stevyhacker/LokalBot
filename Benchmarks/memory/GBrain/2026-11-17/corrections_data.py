"""The corrections suite: authored synthetic facts and meetings, no personal data.

FACTS: an entity, the original statement, its correction, a question, and the
words that identify the current and the stale value in a retrieved block.
PAIRS: two short meetings a week apart; the later one changes a decision.
"""

FACTS = [
    ("Atlas launch", "The Atlas launch is on October 3.", "The Atlas launch moved to November 14.", "When is the Atlas launch?", "November 14", "October 3"),
    ("Maya Chen", "Maya Chen is my manager.", "Daniel Ortiz is my manager now; Maya moved to the platform team.", "Who is my manager?", "Daniel Ortiz", "Maya Chen is my manager"),
    ("billing project", "The billing project is called Ledger.", "The billing project was renamed to Tally.", "What is the billing project called?", "Tally", "called Ledger"),
    ("design review", "Design review happens on Tuesdays at 10.", "Design review moved to Thursdays at 15.", "When is design review?", "Thursdays", "Tuesdays"),
    ("Q4 budget", "The Q4 marketing budget is 40,000 EUR.", "The Q4 marketing budget was cut to 28,000 EUR.", "How big is the Q4 marketing budget?", "28,000", "40,000"),
    ("office", "Our team sits on floor 3 of the Belgrade office.", "Our team moved to floor 7 of the Belgrade office.", "Which floor does our team sit on?", "floor 7", "floor 3"),
    ("CI provider", "We run CI on Jenkins.", "We migrated CI from Jenkins to GitHub Actions.", "What do we run CI on?", "GitHub Actions", "We run CI on Jenkins"),
    ("Priya", "Priya owns the onboarding flow.", "Onboarding flow ownership passed from Priya to Marko.", "Who owns the onboarding flow?", "Marko", "Priya owns the onboarding flow"),
    ("standup", "Daily standup is at 9:30.", "Daily standup is now at 9:00 sharp.", "What time is standup?", "9:00", "9:30"),
    ("summary language", "Write meeting summaries in English.", "Write meeting summaries in Serbian from now on.", "Which language should meeting summaries be in?", "Serbian", "in English"),
    ("Helios contract", "The Helios contract renews in March.", "The Helios contract renewal was pushed to June.", "When does the Helios contract renew?", "pushed to June", "renews in March"),
    ("on-call", "I am on call the week of December 1.", "I swapped on-call with Ana; I'm on call the week of December 8 instead.", "Which week am I on call?", "December 8", "week of December 1."),
    ("database", "The analytics service uses MySQL.", "The analytics service was moved to Postgres.", "Which database does the analytics service use?", "Postgres", "uses MySQL"),
    ("Lena", "Lena is the design lead for the mobile app.", "Lena left; Tomas is the design lead for the mobile app.", "Who is the design lead for the mobile app?", "Tomas", "Lena is the design lead"),
    ("pricing", "The Pro plan costs 12 dollars a month.", "The Pro plan price went up to 15 dollars a month.", "How much does the Pro plan cost?", "15 dollars", "12 dollars"),
    ("offsite", "The team offsite is in Lisbon.", "The team offsite location changed to Porto.", "Where is the team offsite?", "Porto", "in Lisbon"),
    ("release train", "We ship releases every two weeks.", "We now ship releases every week.", "How often do we ship releases?", "every week", "every two weeks"),
    ("Orion API", "The Orion API rate limit is 100 requests per minute.", "The Orion API rate limit was raised to 250 requests per minute.", "What is the Orion API rate limit?", "250", "100 requests"),
    ("hiring", "We are hiring two backend engineers this quarter.", "Hiring is frozen; no backend engineers this quarter.", "How many backend engineers are we hiring this quarter?", "frozen", "two backend engineers"),
    ("coffee", "I take my coffee black.", "I switched to oat milk flat whites.", "How do I take my coffee?", "oat milk", "coffee black"),
    ("demo day", "Demo day is on the 20th.", "Demo day was moved up to the 17th.", "When is demo day?", "17th", "the 20th"),
    ("security review", "Ivan runs the security review.", "Jelena took over the security review from Ivan.", "Who runs the security review?", "Jelena", "Ivan runs the security review"),
    ("Nimbus", "Nimbus is hosted on AWS in eu-west-1.", "Nimbus was migrated to Hetzner in Falkenstein.", "Where is Nimbus hosted?", "Hetzner", "AWS"),
    ("report format", "Send weekly reports as PDF.", "Send weekly reports as a Notion page instead of PDF.", "What format should weekly reports be in?", "Notion page", "reports as PDF"),
    ("SLA", "The support SLA is 24 hours.", "The support SLA was tightened to 8 hours.", "What is the support SLA?", "8 hours", "24 hours"),
    ("Kiran", "Kiran prefers to be contacted on Slack.", "Kiran asked to be contacted by email, not Slack.", "How should I contact Kiran?", "email", "contacted on Slack"),
    ("feature flag", "The new checkout is behind the flag checkout_v2.", "The new checkout flag was renamed to checkout_next.", "What is the feature flag for the new checkout?", "checkout_next", "checkout_v2"),
    ("board meeting", "The board meeting is on January 15.", "The board meeting was rescheduled to January 29.", "When is the board meeting?", "January 29", "January 15"),
    ("vendor", "Our transcription vendor is Speechly.", "We replaced Speechly with an in-house model.", "Who is our transcription vendor?", "in-house model", "vendor is Speechly"),
    ("timezone", "I work from Belgrade time.", "I relocated and now work from Lisbon time.", "Which time zone do I work in?", "Lisbon time", "Belgrade time"),
    ("mobile release", "The iOS app ships version 3.2 next.", "Version 3.2 was skipped; the iOS app ships 4.0 next.", "Which version does the iOS app ship next?", "4.0", "ships version 3.2"),
    ("Sara", "Sara is the account manager for Globex.", "Globex's account manager is now Petar; Sara moved to Initech.", "Who is the account manager for Globex?", "Petar", "Sara is the account manager"),
    ("retro", "Sprint retro is a 60 minute meeting.", "Sprint retro was shortened to 30 minutes.", "How long is the sprint retro?", "30 minutes", "60 minute"),
    ("code review", "Pull requests need one approval.", "Pull requests now need two approvals.", "How many approvals do pull requests need?", "two approvals", "one approval"),
    ("Zephyr", "Zephyr's target customers are agencies.", "Zephyr pivoted to target in-house legal teams.", "Who are Zephyr's target customers?", "legal teams", "agencies"),
    ("laptop", "My work laptop is a ThinkPad X1.", "My work laptop is now a MacBook Pro.", "What is my work laptop?", "MacBook Pro", "ThinkPad"),
    ("bonus", "The referral bonus is 2,000 EUR.", "The referral bonus was raised to 3,500 EUR.", "How much is the referral bonus?", "3,500", "2,000"),
    ("roadmap owner", "Nikola owns the 2027 roadmap.", "The 2027 roadmap is now owned by Ivana.", "Who owns the 2027 roadmap?", "Ivana", "Nikola owns"),
    ("parking", "I park in garage B.", "I moved my parking spot to garage D.", "Which garage do I park in?", "garage D", "garage B"),
    ("Aurora deadline", "The Aurora RFP response is due November 30.", "The Aurora RFP deadline was extended to December 12.", "When is the Aurora RFP response due?", "December 12", "November 30"),
]

DISTRACTORS = [
    f"{name} prefers {thing}." for name, thing in [
        ("Ana", "morning meetings"), ("Boris", "written updates"), ("Cara", "short agendas"), ("Dejan", "video off"),
        ("Ema", "async reviews"), ("Filip", "phone calls"), ("Goran", "detailed specs"), ("Hana", "whiteboard sessions"),
        ("Igor", "Friday demos"), ("Jana", "Kanban boards"), ("Kosta", "pair programming"), ("Lara", "dark mode"),
        ("Mila", "bullet points"), ("Nina", "Gantt charts"), ("Ognjen", "voice notes"), ("Pavle", "standing desks"),
    ]
] + [
    f"The {proj} project uses {tool}." for proj, tool in [
        ("Comet", "Rust"), ("Delta", "Kotlin"), ("Echo", "Elixir"), ("Falcon", "Go"), ("Garnet", "Swift"),
        ("Harbor", "Terraform"), ("Iris", "React Native"), ("Jade", "Django"), ("Krypton", "Flutter"), ("Lumen", "Svelte"),
        ("Magma", "Haskell"), ("Nova", "Scala"), ("Onyx", "Vue"), ("Pulse", "Rails"), ("Quartz", "Next.js"), ("Raven", "Spring"),
    ]
] + [
    f"{who}'s birthday is on {day}." for who, day in [
        ("Mom", "May 4"), ("Luka", "June 18"), ("Tea", "August 2"), ("Vuk", "September 9"), ("Zoe", "April 21"),
        ("Uros", "February 7"), ("Stefan", "July 30"), ("Ruza", "March 12"),
    ]
]

PAIRS = [
    # (topic, older meeting line, newer meeting line, question, current, stale)
    ("vendor for the data warehouse", "We agreed to go with Snowflake for the data warehouse; Marko will sign the order form.",
     "Change of plan on the data warehouse: Snowflake was too expensive, we're going with ClickHouse Cloud instead.",
     "Which vendor did we pick for the data warehouse?", "ClickHouse", "go with Snowflake"),
    ("launch date for the Atlas mobile app", "Atlas mobile app launch is locked for October 3, marketing is booked.",
     "The Atlas mobile app launch slips to November 14 because App Store review flagged the payments screen.",
     "When does the Atlas mobile app launch?", "November 14", "October 3"),
    ("owner of the billing migration", "Priya will own the billing migration end to end.",
     "Priya is out on leave, so Stefan now owns the billing migration.",
     "Who owns the billing migration?", "Stefan", "Priya will own"),
    ("price of the Pro plan", "We settled the Pro plan at 12 dollars per seat per month.",
     "After the pricing test we raised the Pro plan to 15 dollars per seat per month.",
     "What is the price of the Pro plan?", "15 dollars", "12 dollars"),
    ("location of the company offsite", "The company offsite will be in Lisbon in May.",
     "Lisbon fell through; the company offsite moves to Porto, same week in May.",
     "Where is the company offsite?", "Porto", "be in Lisbon"),
    ("hosting for Nimbus", "Nimbus stays on AWS in eu-west-1 for now.",
     "We decided to migrate Nimbus off AWS to Hetzner in Falkenstein to cut costs.",
     "Where will Nimbus be hosted?", "Hetzner", "stays on AWS"),
    ("support SLA", "The support SLA for enterprise customers remains 24 hours.",
     "Legal approved the tighter terms: the enterprise support SLA becomes 8 hours.",
     "What is the enterprise support SLA?", "8 hours", "24 hours"),
    ("database for analytics", "Analytics keeps running on MySQL this quarter.",
     "The analytics service moves from MySQL to Postgres starting next sprint.",
     "Which database will the analytics service run on?", "Postgres", "keeps running on MySQL"),
    ("hiring plan for backend", "We will hire two backend engineers this quarter.",
     "Finance froze headcount, so the backend hiring for this quarter is cancelled.",
     "Are we hiring backend engineers this quarter?", "froze", "will hire two"),
    ("code review policy", "Pull requests need one approval before merge.",
     "After the incident we require two approvals on every pull request.",
     "How many approvals does a pull request need?", "two approvals", "need one approval"),
    ("release cadence", "We ship the web app every two weeks.",
     "Starting this month the web app ships every week.",
     "How often does the web app ship?", "every week", "every two weeks"),
    ("security review owner", "Ivan runs the quarterly security review.",
     "Jelena takes over the quarterly security review from Ivan.",
     "Who runs the quarterly security review?", "Jelena", "Ivan runs"),
    ("board meeting date", "The board meeting is set for January 15.",
     "The board meeting is rescheduled to January 29 because two directors are travelling.",
     "When is the board meeting?", "January 29", "January 15"),
    ("Helios renewal", "The Helios contract renewal is due in March.",
     "Helios asked to push the renewal to June and we agreed.",
     "When is the Helios contract renewal?", "June", "due in March"),
    ("referral bonus", "The referral bonus stays at 2,000 EUR.",
     "HR raised the referral bonus to 3,500 EUR for senior roles.",
     "How much is the referral bonus?", "3,500", "2,000"),
    ("checkout feature flag", "The new checkout ships behind the checkout_v2 flag.",
     "We renamed the checkout_v2 flag to checkout_next to match the other flags.",
     "What is the feature flag for the new checkout?", "checkout_next", "behind the checkout_v2"),
    ("Aurora RFP deadline", "The Aurora RFP response is due November 30.",
     "Aurora extended the RFP deadline to December 12.",
     "When is the Aurora RFP response due?", "December 12", "due November 30"),
    ("design lead for mobile", "Lena leads design for the mobile app.",
     "Lena is leaving at the end of the month; Tomas becomes design lead for mobile.",
     "Who is the design lead for the mobile app?", "Tomas", "Lena leads"),
    ("transcription vendor", "We keep Speechly as the transcription vendor.",
     "We are dropping Speechly and moving transcription to our in-house model.",
     "What do we use for transcription?", "in-house", "keep Speechly"),
    ("retro length", "Sprint retro stays at 60 minutes.",
     "We cut sprint retro to 30 minutes, with the rest as async notes.",
     "How long is sprint retro?", "30 minutes", "60 minutes"),
]

FILLER = [
    "Thanks everyone for joining.", "Let's go through the agenda quickly.", "Any blockers from last week?",
    "I'll share my screen.", "Can you see the slides?", "Good, moving on.", "Let's take the rest offline.",
    "I'll send the notes after the call.", "Anything else before we wrap up?", "Okay, thanks all.",
]


def check():
    """Every marker must identify only its own statement."""
    texts = DISTRACTORS + [t for f in FACTS for t in (f[1], f[2])]
    problems = []
    for entity, original, correction, _, current, stale in FACTS:
        for marker, home in ((current, correction), (stale, original)):
            where = [t for t in texts if marker in t]
            if where != [home]:
                problems.append((entity, marker, where))
    for topic, older, newer, _, current, stale in PAIRS:
        if current not in newer or current in older or stale not in older or stale in newer:
            problems.append((topic, current, stale))
    return problems


if __name__ == "__main__":
    print(check() or "markers ok")
