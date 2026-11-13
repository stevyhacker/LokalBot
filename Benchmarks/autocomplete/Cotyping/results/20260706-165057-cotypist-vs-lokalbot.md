# Cotypist vs LokalBot — cotyping side-by-side

Prompts: 25 (from `prompts.tsv`). Insertion = TextEdit text delta after one Tab accept; ∅ = Tab landed with no suggestion; — = capture missing.

## LokalBot engine benchmark (`--cotyping-bench`)

- scenarios passed: 25/28 (safety 28/28)
- word completions extending the typed word: 12/13
- latency: avg 471 ms · p95 1798 ms

## Per-prompt insertions

| # | Kind | Prompt tail | Cotypist inserted | LokalBot inserted | WC ok (C/L) |
|---|------|-------------|-------------------|-------------------|-------------|
| 01-follow-up | next-word | `…ding this over. I wanted to follow` | — | — |  |
| 02-take-ownership | next-word | `…Sounds good, I can take` | — | — |  |
| 03-tradeoff | next-word | `…The main tradeoff is` | — | — |  |
| 04-quick-update | next-word | `…i team, just a quick update on the` | — | — |  |
| 05-scheduling | next-word | `…Could we move our call to` | — | — |  |
| 06-support-reply | next-word | `… reset your account and you should` | — | — |  |
| 07-question | next-word | `…send over the final version before` | — | — |  |
| 08-comma-clause | next-word | `…he numbers hold up through Friday,` | — | — |  |
| 09-sentence-start | next-word | `…he rollout went smoothly overall. ` | — | — |  |
| 10-wc-follo | word-completion | `…nding this over. I wanted to follo` | — | — | —/— |
| 11-wc-conversati | word-completion | `… — let us continue this conversati` | — | — | —/— |
| 12-wc-tomorro | word-completion | `…send over the final report tomorro` | — | — | —/— |
| 13-wc-recei | word-completion | `…e let me know as soon as you recei` | — | — | —/— |
| 14-wc-producti | word-completion | `…eryone, that was a really producti` | — | — | —/— |
| 15-wc-schedu | word-completion | `…Let me double-check my schedu` | — | — | —/— |
| 16-wc-importa | word-completion | `…hing — this part is really importa` | — | — | —/— |
| 17-wc-weeke | word-completion | `…Sounds great, have a lovely weeke` | — | — | —/— |
| 18-wc-aro | word-completion | `… budget for Q3 lands somewhere aro` | — | — | —/— |
| 19-wc-unterstuet | word-completion | `…s, vielen Dank für deine Unterstüt` | — | — | —/— |
| 20-wc-revie | word-completion | `…wider team, could you please revie` | — | — | —/— |
| 21-vf-the | valid-fragment | `…I think we should discuss the` | — | — |  |
| 22-vf-can | valid-fragment | `…Absolutely, we can` | — | — |  |
| 23-vf-don | valid-fragment | `…am sure we will figure it out, don` | — | — |  |
| 24-typo-recieve | typo | `…Please make sure you recieve` | — | — |  |
| 25-typo-teh | typo | `…Quick reminder about teh` | — | — |  |

## Totals

- **cotypist**: suggestions on 0/0 prompts; word completions 0/0
- **lokalbot**: suggestions on 0/0 prompts; word completions 0/0
