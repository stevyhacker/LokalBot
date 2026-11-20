# 0063. Windows and Linux: ai — autocomplete

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/accept.rs`

#### Accept key chunking and edit mirror CotypingAcceptanceChunker and ContinuationAcceptance
What one accept key press takes (`CotypingAcceptanceChunker`) and the
exact edit it makes (`CotypingContinuationAcceptance`).

#### Acceptance settings default to the macOS ones
`AcceptOptions`: The acceptance settings that shape a press (`Options`). The defaults are
the macOS ones.

#### Off by default as Cotypist: full stop or comma takes its own press
`AcceptOptions.auto_accept_trailing_punctuation`: Punctuation after a word goes with it in the same press. Off, as in
Cotypist: a full stop or comma takes its own press.

#### One accept press planned once for desktop accept key and practice editor
`AcceptancePlan`: One accept press, planned once for the desktop's accept key and the
practice editor alike.

#### Chunk consumed must be reported back in AutocompleteCommand::Accepted
`AcceptancePlan.chunk`: The part of the suggestion this press consumes; report it back in
`AutocompleteCommand::Accepted`.

#### Skip a space the field has; add space a new sentence needs
`AcceptancePlan.insertion`: What to type at the caret: the chunk without a space the field
already has, with the space a new sentence needs.

#### Graphemes after caret replaced when completing a word the caret is inside
`AcceptancePlan.forward_delete`: User-perceived characters after the caret the insertion replaces,
when it completes a word the caret is inside of.

#### Graphemes before caret replaced: the typed shortcode an emoji stands for
`AcceptancePlan.backward_delete`: User-perceived characters before the caret the insertion replaces:
the typed `:shortcode` an emoji stands for.

#### Mirrors ContinuationAcceptance.plan plus emoji replacement planner; None when nothing accepted
`plan`: `CotypingContinuationAcceptance.plan` plus the emoji replacement of
`CotypingReplacementAcceptancePlanner`. `None` when nothing is accepted.

#### Emoji replaces its typed shortcode whole or not at all
`plan`: An emoji replaces the shortcode typed before it, whole or not at all.

#### Spaceless scripts advance by UAX #29 word with CJK punctuation bound; macOS uses ICU
`next_word`: The first word-like chunk of `text`, keeping its leading whitespace.
Scripts without spaces advance one UAX #29 word at a time (macOS uses
ICU's dictionary words), with CJK punctuation bound to the word before it.

#### Phrase ends at sentence or clause boundary; ASCII commas stay inside
`next_phrase`: Up to and including the next sentence or clause boundary, or the whole
text when there is none. ASCII commas stay inside the phrase.

#### Do not retype a space the field has; add separating space for new sentence
`insertion_chunk`: The chunk as typed: a leading space the field already has is not typed
twice, and a new sentence gets its separating space.

#### With trailing-space option, model's own space after finished word goes with it
`chunk_consuming_trailing_space`: `acceptanceChunkConsumingTrailingSpace`: with the trailing-space option the
model's own space after a finished word goes with it.

#### Count words containing at least one letter or digit
`accepted_word_count`: Words with at least one letter or digit (`acceptedWordCount`).

#### Piece-by-piece acceptance must reproduce suggestion across accents, emoji, punctuation, spaceless scripts
`accepting_piece_by_piece_reproduces_the_suggestion`: Accepting piece by piece reproduces the suggestion exactly, for
accents, emoji, punctuation runs and scripts written without spaces.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/client.rs`

#### One streamed /completion request per suggestion reproduces macOS decode loop behaviours
The Autocomplete model on its llama-server (`LocalLlamaCotypingEngine`
and `LlamaCotypingRuntime`, over HTTP).

One `/completion` request per suggestion, with the raw prompt (no chat
template) and `cache_prompt`, so the server reuses what it read of the
previous prompt and only reads the newly typed tokens (macOS's
`IncrementalPrefill`). The response is streamed and read token by token,
with each token's probabilities (`n_probs`), to apply what the in-process
macOS decode loop applies:

- token healing: a grammar re-types the text cut from the prompt
  (`healing`), and only what follows is shown. When
  the grammar's token-by-token path through a word fragment ("to", then
  "mo", then "r…") is less likely than one token that spells the whole
  fragment ("tomorrow"), the request is restarted from that token: the
  case macOS's prefix search exists for;
- the first-word confidence gate and its one-word fallback;
- stop when the most likely next token ends the text, even if the
  sampler picked another;
- stop at a sentence end or a control token (`CotypingDecodeStopPolicy`),
  and once a line is complete unless multi-line suggestions are on. A
  reply that starts on a new line is kept: the normalizer joins it with a
  space, as the in-process runtime's output is.

Stopping drops the connection, which llama-server notices at its next
token. A request still reading its prompt finishes that first, so the
caller keeps one request in flight at a time.

#### Gate sums boundary mass over top probabilities; healing looks for whole-fragment token
`GATED_PROBABILITIES`: Probabilities asked for per token. The gate sums boundary mass over
these; healing a word fragment looks among them for a token that spells
the whole fragment.

#### Healed space adds one constrained token, fragment up to four
`HEALED_SPACE_TOKENS`: A space before the first word is one constrained token more; a word
fragment can take a few (`CotypingEngine.completionRequest`).

#### Inline suggestions must feel instant, matching completionSession
`REQUEST_TIMEOUT`: Inline suggestions must feel instant (`completionSession`).

#### Token budget ran out so the thought may continue
`Completion.hit_limit`: The token budget ran out (the thought may go on).

#### Milliseconds from request to first streamed token
`Timings.first_token_ms`: Milliseconds from the request to the first streamed token.

#### Prompt tokens the server read, not reused
`Timings.prompt_tokens`: Prompt tokens the server read for this request (not reused).

#### root_url is loopback http://127.0.0.1:port from Lease::root_url
`Completer::new`: `root_url` is `http://127.0.0.1:<port>` (`Lease::root_url`).

#### Prefill the server cache on focus so first keystroke adds only typed text
`Completer::prefill`: Reads `request`'s healed prompt into the server's cache without
generating, so the first keystroke in a newly focused field only adds
what was typed (`LocalLlamaCotypingEngine.prewarm(for:)`).

#### Cancellation polled between streamed tokens drops request and returns Cancelled
`Completer::complete`: One suggestion. `cancelled` is polled between streamed tokens; when it
returns true the request is dropped and [`Cancelled`] returned.

#### Continue from the whole-fragment token which server now reads as prompt
`Completer::complete`: Go on from the token that spells the whole fragment, which the
server now reads as part of the prompt.

#### Healed raw prompt with macOS sampler; one line unless multi-line suggestions on
`request_body`: The `/completion` body: the healed raw prompt, the macOS sampler, one
line unless multi-line suggestions are on.

#### timings_per_token gives counts with every token however early stream is left
`request_body`: The prompt and generation counts arrive with every token, so they
are known however early the stream is left.

#### Continue with healed prompt plus token id mixed, with no constraint
`cover_body`: The request that goes on after a whole-fragment token: the healed prompt
with that token appended (llama-server takes text and token ids mixed),
and no constraint left.

#### Special tokens carry no text; at end of reply they end it
`Candidate::is_end`: Special tokens carry no text; at the end of a reply they end it.

#### Streamed decode loop mirrors LlamaCotypingRuntime.generate using per-token reports
`Decoder`: The streamed decode loop of `LlamaCotypingRuntime.generate`, fed with
llama-server's per-token reports instead of logits.

#### Track grammar path probability against best whole-fragment token, as searchPrefixPath
`Decoder.path_logprob`: Healing a word fragment (`searchPrefixPath`): the log probability of
the grammar's path through it so far, whether its first token covered
only part of it, and the best first-step token that spells all of it.

#### Text of cover token past fragment is first visible text
`Decoder::start_from`: Starts after a whole-fragment token: its text past the fragment is
the first visible text.

#### Weigh text without probabilities as 0 to keep gate closed
`Decoder::feed_event`: Text without probabilities: weigh it as unknown (0), which
keeps the gate closed rather than showing it unweighed.

#### Path probability only falls, so a lower whole-fragment token wins and restarts
`Decoder::feed_token`: Each further token only lowers the path's probability: once it
is below a single whole-fragment token, that token wins.

#### Stop when most likely next token ends text, whatever sampler picked
`Decoder::feed_token`: The most likely next token ends the text: stop here, whatever the
sampler picked (`stopAtArgmaxEOG`).

#### Token ending inside a character still counts toward first-word probability
`Decoder::emit`: A token that ends inside a character still counts toward the
first word's probability, as in the in-process runtime.

#### Normalizer keeps first line or paragraph; later text is never shown
`Decoder::emit`: The normalizer keeps the first line (or paragraph); what follows a
finished one is never shown.

#### If cut text was never retyped, suppress so nothing skips the fragment
`Decoder::result`: The cut text was never re-typed: nothing may skip the fragment.

#### Sum probability of new-word or end tokens over reported candidates
`boundary_mass`: The probability that a new word starts or the text ends, summed over the
reported candidates (`LlamaCotypingRuntime.boundaryMass`).

#### Tokens are byte fragments; unfinished character waits, malformed bytes reject reply
`Utf8Decoder`: `CotypingUTF8TokenDecoder`: tokens are byte fragments; an unfinished
character waits for the next token, and malformed bytes reject the reply.

#### Grammar forced path through fragment is far less likely than one whole token
`a_whole_fragment_token_beats_an_unlikely_path_through_the_fragment`: The grammar takes " to", the most likely token compatible with
" tomor", and must then force "mo": far less likely than " tomorrow".

#### Worked probabilities showing product fails gate but fallback boundary mass cuts to one word
`an_unsure_first_word_shows_nothing_and_a_fair_one_is_cut_to_one_word`: p(" Thursday") = 0.6 passes; p(" or") = 0.1 drops the product to
0.06, under 0.1. A word boundary after "Thursday" (0.5 + 0.4) keeps
the fallback at 0.54, so the suggestion is cut to that one word.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/clipboard.rs`

#### Clipboard snippet pinned in memory per field and state; never saved or logged
Clipboard context for the prompt (`CotypingClipboardContext.swift`), the
pure half: sanitizing, bounding, relevance and the already-in-the-field
guard. A snippet may be pinned in memory for one field and one clipboard
state to keep the prompt's start stable; it is never saved or logged.

#### Prompt clipboard snippet capped at 1,200 characters, as Cotabby
`MAX_SNIPPET_CHARACTERS`: The most the prompt ever gets (Cotabby's 1,200).

#### A copy older than five minutes no longer shows current work
`STALE_AFTER`: A copy older than this no longer says what the user is working on.

#### Keep only letters, digits, whitespace, @ and . since small models copy shell prompts and fences
`sanitize_text`: `CotypingPromptContextSanitizer.sanitize`: shell prompts, Markdown fences
and punctuation-heavy output are what small models copy back, so only
letters, digits, whitespace, `@` and `.` survive.

#### Exclude snippet already in typed text to avoid feeding back pasted content
`should_include`: False when the snippet is already in the text being typed: no point in
feeding back what was just pasted.

#### Keep lines sharing a word with prefix; unrelated long copies shrink to head sample
`distill`: Keeps the clipboard lines that share a word with the prefix. Short
snippets pass through; long unrelated copies shrink to a small head sample.

#### First observation is a baseline of unknown age; only later fresh related copies count
`RelevanceFilter`: The first observation is a baseline of unknown age, not a fresh copy.
Only later copies count, while fresh and related to what is being typed
(`CotypingClipboardRelevanceFilter`).

#### Pin only non-empty verdicts; nil verdict is re-evaluated as more is typed
`Memo`: One non-empty verdict pinned to a field and a clipboard state. A nil
verdict is not pinned: it is looked at again as more is typed.

#### None snapshot for unreadable or concealed clipboard; next copy starts new baseline
`Preface::resolve`: `CotypingClipboardPrefaceResolver.resolve`. `snapshot` is `None` when
the clipboard holds nothing readable, or something concealed: the next
copy after that starts a new baseline.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/confidence.rs`

#### Gate first-word probability at 0.1 with one-word hybrid fallback at 0.31
The confidence gate (`CotypingFirstWordConfidence`,
`CotypingConfidenceDecision`): stay quiet when the model is unsure of a
suggestion's first word, as Cotypist does.

The probability is the product of the emitted tokens' probabilities up to
and including the token in which the first word ends (softmax at
temperature 1, whatever the sampler's settings). macOS measured that a
minimum of 0.1 halves wrong suggestions for about 1.5 points of
keystrokes saved. Suggestions inside a word are not gated: their first
token is forced to re-type the fragment.

The app runs the "selective one-word hybrid": when the gate fails but the
probability that the first word is complete (the mass of every token that
starts a new word or ends the text) still clears 0.31, the suggestion is
cut to that one word instead of being dropped. llama-server reports the
top candidates of each step (`n_probs`), so that mass is summed over them
rather than the whole vocabulary; a long tail makes it a little stricter.

#### Like SelectedToken but token starting next word counts as 1
`BoundaryMode::WordOnly`: Like `SelectedToken`, but the token that starts the next word counts 1.

#### Boundary token counts as probability any word boundary follows
`BoundaryMode::BoundaryMass`: That token counts as the probability that any word boundary follows.

#### Product only falls, so generation can stop once below minimum
`FirstWordConfidence::accept`: Weighs the next emitted token. False once the first word is known to
fall below the minimum; the product only falls, so generation can stop.

#### Token starts a word boundary by first complete character; partial characters never do
`token_starts_boundary`: Whether a token's bytes start a new word: its first complete character is
not a letter, digit, joiner or mark. A token that is only part of a
character never does.

#### Sticky gate decision; fallback never revives failed gate nor changes passed one
`ConfidenceDecision`: One token stream with a sticky decision for the gate and, under the
hybrid, its one-word fallback. The fallback never revives a gate that
failed nor changes one that passed.

#### App gate: selected-token minimum with hybrid; inside a word nothing is weighed
`ConfidenceDecision::for_autocomplete`: The app's gate: the selected-token minimum with the one-word hybrid.
Inside a word there is nothing to weigh.

#### Selected-token gate does not weigh end of text
`ConfidenceDecision::accept`: The selected-token gate does not weigh the end of the text.

#### Hybrid cap keeps only first word of normalization and its suppression
`one_word_fallback`: The hybrid's cap: only the first word of a finished normalization, its
suppression kept.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/debounce.rs`

#### Model server keeps conservative backoff because dropped requests do not stop prompt reading
`CotypingDebouncePolicy`: how long to wait after a keystroke before
asking for a suggestion. A model server keeps the conservative backoff,
because dropping a request does not stop a prompt the server is reading.

#### Wait configured pause or half last latency if longer, minus time already waited
`milliseconds`: The configured pause, or half the last request's latency when that is
longer, minus what the caller already waited.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/emoji.rs`

#### Curated emoji catalog; colon opens query only at word boundary; open prefix needs two chars
Inline `:shortcode:` emoji (`CotypingEmoji`): a curated catalog instead
of gemoji. A `:` opens a query only at a word boundary, so `http://`,
`12:30` and `foo::bar` never trigger. Both `:roc` (open, prefix match,
two characters at least) and `:rocket:` (closed, exact) work.

#### Emoji ghost text matches macOS: glyph and its shortcode
`ghost`: The ghost text macOS shows for an emoji: the glyph and its shortcode.

#### Alias characters follow gemoji: +1, -1, e-mail
`is_name_char`: The alias characters gemoji allows (`+1`, `-1`, `e-mail`).

#### Catalog ordered most-common first so first prefix match wins
`best_match`: The catalog is ordered most-common first, so the first prefix match wins.

#### Synonyms map typed intents to canonical shortcode, exact match only
`SYNONYMS`: What people type for an intent → the canonical shortcode, exact only.

#### Catalog is ordered roughly by popularity
`CATALOG`: Ordered roughly by popularity.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/healing.rs`

#### Token healing via GBNF grammar on /completion instead of macOS in-process constraint
Token healing (`CotypingTokenHealing`) on llama-server.

A prompt that ends mid-word ("…I wanted to follo") tokenizes unnaturally
at its end, and a small model then treats the fragment as a finished
word. Healing cuts the prompt back to the last word boundary ("…I wanted
to") and makes the cut text (" follo") a decode constraint: generation
must first re-type those bytes through natural tokens (" follow"
overshooting the caret), then runs free. The suggestion is everything
after the constraint. A trailing space is healed the same way, so " is"
is one natural token instead of a lone space token.

macOS enforces the constraint inside its llama.cpp decode loop. Here it is
a GBNF grammar on the `/completion` request, `root ::= "<cut text>" any*`:
llama.cpp's grammar sampler accepts a token only while its bytes stay on
that path, so " follow" passes for " follo" and " up" does not. macOS also
searches four tokenizations of a fragment for the most probable path;
the grammar picks the best compatible token one step at a time.

#### Skip healing long fragments like URLs; too many constrained steps
`MAX_WORD_LENGTH`: Longest word fragment worth healing; longer runs (URLs, identifiers)
would spend many constrained steps on text the model should not assist.

#### None unless prompt ends in word fragment or spaces after word, short enough, with context left
`split`: `CotypingTokenHealing.split`: `None` when the prompt does not end in a
word fragment or spaces after a word, the fragment is too long, or
cutting it would leave no context.

#### Replay space after a finished word through natural tokens, then hide it
`split`: A finished word followed by a space must not be extended
(cat → cats): replay the space through natural tokens, then hide it.

#### Heal when caret is in or after a word, or after a space
`healed_generation`: The prompt and required prefix a request is sent with
(`LocalLlamaCotypingEngine.healedGeneration`): healing applies when the
caret is inside or right after a word, or after a space.

#### Escape every character as code point so no prefix breaks the string literal
`grammar`: The GBNF grammar that makes generation start with `required_prefix` and
lets anything follow. Every character is written as a code point escape,
so no prefix can break out of the string literal.

#### Match token bytes, not chars, because tokens can split UTF-8 characters
`match_piece`: `CotypingRequiredPrefixMatcher`: one token's bytes against the remaining
required prefix. Bytes, because tokens can split a UTF-8 character.

#### Extra bytes past the prefix are the first visible text
`PrefixMatch::Overshoots`: The token covers the rest of the prefix and goes on; the extra bytes
are the first visible text.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/learning.rs`

#### Learn only from identified Google Docs documents; 30-day retention; excludes saved-fact suggestions
Learning from accepted suggestions (`CotypingLearningStore`,
`CotypingLearningRanker`, `CotypingLearningScope`,
`CotypingAcceptedSuggestionBatch`).

An accepted suggestion becomes an example that later prompts in the same
document can show the model ("Previously accepted completion: …"). Only a
positively identified document learns: a Google Docs document in a
browser, by its address. Mail, chat, code editors, terminals and unknown
documents neither learn nor reuse examples, and neither do suggestions
that used saved facts or the text above the field. Examples are kept for
30 days; the engine seals them on disk in the Mac's format.

#### Learning file is AES-256-GCM sealed JSON as nonce, ciphertext, tag
`FILE_NAME`: `<root>/cotyping-learning.enc`: this JSON sealed with AES-256-GCM as
`nonce ‖ ciphertext ‖ tag`.

#### Scope key hashes browser and document address; None if unidentified
`Place::scope_key`: `CotypingLearningScope.key`: a hash of the browser and the document's
stable address, or `None` when the document is not identified.

#### Encoding matches Mac: seconds since 2001, uppercase UUIDs, empty optionals omitted
`Example`: One learned example (`CotypingLearningExample`). Keys and encoding match
the Mac: `createdAt` is seconds since 2001, UUIDs are uppercase, and empty
optionals are left out.

#### File JSON has no version wrapper
`Snapshot`: `CotypingLearningSnapshot`: the file's JSON, with no version wrapper.

#### Store holds examples in memory; engine loads and saves them
`LearningStore`: The examples in memory. The engine loads and saves them.

#### Loaded file examples go before anything learned while it opened
`LearningStore::merge_loaded`: Adds what the file held, before anything learned while it opened.

#### Returns true when store changed and should be saved
`LearningStore::record`: One finished suggestion's accepted text (`recordCompletedSuggestion`).
True when the store changed and should be saved.

#### Rank same-document examples by shared context words, best first
`LearningStore::examples`: `rankedExamples`: the same document's examples whose context shares
words with what is being written, best first.

#### Cleared on Forget learned text or autocomplete turning off
`LearningStore::clear`: "Forget learned text", or autocomplete turning off.

#### Returns true when expired examples went so file is saved
`LearningStore::prune`: True when expired examples went, so the file should be saved.

#### Learn false when learning off or suggestion used saved facts or nearby text
`AcceptedBatch::append`: `learn` is false when learning is off, and for suggestions that used
saved facts or nearby text.

#### Default JSONEncoder date is seconds since 2001 and nil optionals are omitted
`the_macs_encoding_reads_and_writes_back_the_same`: From `CotypingLearningExample`'s `Codable`: a default `JSONEncoder`
date is seconds since 2001-01-01, and a nil optional is left out.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/macros.rs`

#### Macro opens only at word boundary; ghost shows only when query computes
Inline `/macro` autocomplete (`CotypingMacro`).

A `/` opens a query only at a word boundary (the field's start or after
whitespace), so `http://`, `and/or` and file paths never fire, and the
ghost shows only when the query computes to a result: `/5+5` → `= 10`,
`/10km->mi` → `6.214 mi`, `/today` → `Jun 23, 2026`, `/100usd to eur` →
`€92.00`, `/d20` → a roll, `/uuid` → a UUID.

macOS formats dates and money with the user's locale through Foundation;
here they read as they do in en-US. `iso` and `24h` dates need no locale.

#### Preview and insertion differ for arithmetic
`MacroResult`: What to preview under the caret and what an accept inserts. They differ
for arithmetic (`= 10`, then `10`).

#### token_length counts user-perceived characters of the typed query
`MacroMatch.token_length`: User-perceived characters of the typed `/query`.

#### Token length reported whether or not the query evaluates
`trailing_token_length`: Length of the trailing `/query`, whether or not it evaluates.

#### Inner slash after non-space stays in query; newline or long run ends scan
`scan_token`: Walks back from the caret until a boundary `/`. An inner `/` preceded by
a non-space (`5/2`) stays in the query; a newline or an over-long run ends
the search.

#### Clock and random source injected so tests are deterministic
`Engine`: The clock and random source are injected so tests are deterministic.

#### Random takes inclusive bounds
`Engine.random`: A whole number from the first bound to the second, inclusive.

#### UUID uppercase to match Swift uuidString
`Engine::standard`: Swift's `UUID().uuidString` is uppercase.

#### Evaluation order: date, random, unit, currency, then arithmetic catch-all
`Engine::evaluate`: Date, random, unit, currency, then arithmetic as the catch-all.

#### Accepted relative date forms: +3d, -5d, +2w, +1mo, +1y
`Engine::relative_date`: `+3d`, `-5d`, `+2w`, `+1mo`, `+1y`.

#### next is strictly after today, this includes today, last strictly before
`Engine::weekday_date`: `next-<weekday>` (strictly after today), `this-<weekday>` (including
today), `last-<weekday>` (strictly before today).

#### Aliases and misspellings normalized; weekday written without separator accepted
`canonical_base`: Short forms and misspellings of the keywords, then a `next`/`this`/`last`
weekday written with a space or no separator as `next-fri`.

#### Conversion separators ->, arrow or ' to ' shared by unit and currency
`split_conversion`: `<value><from> <sep> <to>`, on `->`, `→` or ` to `. Shared by the unit and
currency families.

#### Case-insensitive ' to ' search is ASCII so byte offsets hold
`split_conversion`: Case-insensitive " to ": ASCII, so byte offsets hold.

#### Temperature stored as coefficient and constant to kelvin
`Quantity::Temperature`: Coefficient and constant to kelvin.

#### Coefficients copy Foundation Dimension so conversions print as on macOS
`unit`: Foundation's `Dimension` coefficients, so conversions print as on macOS.

#### Stone is 6.35029 kg; Foundation's table value is stones per kilogram
`unit`: Foundation's table has 0.157473 here, which is stones per kilogram;
a stone is 6.35029 kg.

#### Print near-whole values as whole numbers despite rounded temperature constants
`unit_format`: Foundation's rounded temperature constants leave `32f to c` a hair off
zero; a whole number should print as one.

#### Emulate C %g formatting because Rust has none
`format_g`: C's `%.<precision>g`: significant digits, trailing zeros removed, and an
exponent below 1e-4 or from 1e\<precision> up. Rust has no `%g`.

#### Bundled offline approximate rates per USD, never networked, as of 2026-06
`RATES_PER_USD`: Bundled, offline, approximate rates, units per US dollar. Never reaches
the network. As of 2026-06.

#### Mimic NumberFormatter currency style in en-US; no decimals for yen and won
`format_currency`: `NumberFormatter`'s `.currency` style in en-US: its symbols, its grouping,
and no decimals for yen and won.

#### Whole numbers print without point; others up to 10 significant digits
`format_number`: Whole numbers print without a point; others with up to 10 significant digits.

#### Hand-written parser so queries are never evaluated as code
`Arithmetic`: A hand-written parser: nothing in a query is ever evaluated as code.

#### Exponentiation is right associative
`Arithmetic::power`: Right associative.

#### Test clock fixed at Tuesday 23 June 2026, 15:04
`tests::engine`: Tuesday 23 June 2026, 15:04.

#### On a Tuesday, this is today and next/last are a week off
`dates_come_from_the_injected_clock`: Tuesday: this week's Tuesday is today, next and last are a week off.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/memory.rs`

#### Memory is retrieval policy; reading meetings is a separate off-by-default grant
Small, relevant facts from saved sources (`CotypingMemoryContext`,
`CotypingMemoryLookup`, `CotypingMemoryVocabulary`): a retrieval policy,
not a second model call or a stored profile.

Reading the meeting library is its own grant (macOS
`cotypingUseMeetingMemory`, off by default), separate from turning
Autocomplete on. A fact is used only when the draft, the window title or
the conversation above the field names its source, or when it shares
enough distinctive words with what the user wrote themselves. Everyday
wording never counts: "I'll get back to" is not about a note that happens
to say so too.

#### Only the writing tool's own grants permit reading saved facts
`Policy`: The writing tool's own grants; nothing else permits reading saved facts.

#### Screen-derived facts need their own separate grant
`Policy.screen_derived`: Facts derived from screen memory need that separate grant too.

#### Source stamp mirrors macOS FileStamp; None when source missing
`FileStamp`: Size, modification time and file number of a source, or `None` when it is
missing (`CotypingMemoryContextProvider.FileStamp`).

#### Edits, deletions or withdrawn grants end suggestions they shaped; paths and stamps only
`MemoryGuard`: What a lookup read, so it can be told later whether its facts still hold
(`CotypingMemoryContextProvider.Snapshot.isCurrent`). Editing or deleting
a source, or withdrawing a grant, ends the suggestions it shaped. Paths and
stamps only: no text.

#### Library root whose evidence must stay readable
`MemoryGuard.root`: The library, whose evidence must stay readable.

#### Stamp paths before reading so a later edit shows
`MemoryGuard::stamp`: Stamps `paths` now, before they are read, so a later edit shows.

#### Overnight-review statements are facts even when one is its own title
`Item.is_work_memory`: Overnight-review statements, facts even when one is its own title.

#### Lookup searches only the 600 characters of nearby text nearest the field
`MAX_VISIBLE_QUERY_CHARACTERS`: The part of the nearby text a lookup may search, nearest the field.

#### Words kept apart by origin; only the user's own words show topical match
`Query`: What the writing is about, kept apart by where each word came from. The
conversation above the field may name a saved topic, but only the user's
own words can show that a saved sentence is about the same thing.

#### all is own words plus distinctive visible-text words
`Query.all`: `own` plus distinctive words from the visible text.

#### Named words are capitals or digits that do not merely open a sentence
`Query.named`: Words written as a name: a capital or a digit that does not merely
open a sentence.

#### capitalized is named plus capitalized sentence openers
`Query.capitalized`: `named` plus capitalized sentence openers.

#### Index search terms ordered nearest the caret first
`Query.search`: Index search terms, nearest the caret first.

#### Window title's trailing app name is not a topic
`Query::new`: A window title usually ends with its app's name, which is no topic.

#### Every capitalized title word may be a name since titles are not prose
`Query::new`: Titles are not prose: every capitalized title word may be a name.

#### No query for code editors, terminals or text carrying a secret
`Query::for_field`: `CotypingMemoryContext.query(for:)`: nothing for code editors,
terminals, or text that carries a secret. `before` should already be
cut to [`finished_words`].

#### Folded words in reading order with repeats kept
`tokens`: Folded words in reading order, repeats included.

#### Distinctive word can show two texts share a topic
`is_distinctive`: A word that can show two texts share a topic.

#### Sentence- or line-opening capitals alone do not make a name
`capitalized_terms`: Distinctive words written with a capital or a digit, apart from those
that open a sentence or line, where the capital alone does not make a name.

#### Source named when half its title's distinctive words appear; one word of long title too little
`names`: A source is named when at least half of its title's distinctive words
are in the draft, title or conversation. One word of a long title is
too little to pull in everything filed under it.

#### Notes line adding no word to its title is a heading
`is_heading`: A notes line that adds no word to its source's title, such as a heading.

#### Fact needs named source, or two shared words (one a name) or three
`relevance`: Whether a saved fact has earned a place in the prompt: its source is
named, or it shares two distinctive words with the user's own draft or
title, one written as a name, or three when none is.

#### At most two recent relevant facts, newest version of a named topic only
`select`: The facts for a prompt: relevant, recent, at most two, the newest
version of a named topic only.

#### Recognized named topic excludes other projects' facts to avoid conflicting names or deadlines
`select`: When a named topic is recognized, another project's facts must not
add a second, conflicting name or deadline.

#### Older version of the same topic must not contradict the current one
`select`: An older version of the same topic must not contradict the current one.

#### Overnight items need grants of every source kind; unattributed or sourceless items left out
`work_memory_items`: Projects and goals from the overnight reviews (`memory/memory.json` in
a macOS library), each needing the grants of every kind of source behind
it (`CotypingMemoryContextProvider.memoryItems`). Items with unattributed
or no sources are left out.

#### A digest can mix meetings with activity history
`work_memory_items`: A digest can mix meetings with activity history.

#### Strip summary Markdown; drop headings, metadata and None
`fact_line`: A notes or summary line as a fact: the Markdown of `summary.md` (list
markers, checkboxes, bold names, transcript time links) removed, and
headings, metadata and "None" left out.

#### Drop the half-typed word so it neither starts a lookup nor changes facts mid-word
`finished_words`: The text before the caret without a word still being typed, so a
half-typed word neither starts a lookup nor changes the facts mid-word.

#### Generic writing words must not pull unrelated private facts into a draft
`GENERIC_TERMS`: Writing and meeting language that must not pull an unrelated private
fact into a draft because both say "project" or "today".

#### Everyday words mirror macOS list; first-name-like words excluded so people can be found
`EVERYDAY_TERMS`: `CotypingMemoryContext.everydayTerms`: everyday wording, calendar words
and app names, folded like the tokens. Words that double as first names
(Sam, Ali, Jan) are left out so a person can still be looked up.

#### Contraction stems appear from splitting on apostrophes
`EVERYDAY_TERMS`: Contraction stems left by splitting on the apostrophe.

#### Pronouns and counting words the search stop list leaves in
`EVERYDAY_TERMS`: Pronouns and counting words the search stop list leaves in.

#### An unfinished revocation stops all overnight memory
`a_lookup_stops_being_current_when_a_source_or_grant_changes`: An unfinished revocation stops all overnight memory.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/mod.rs`

#### Pipeline overview: macros and typo fixes win over model; server can stand in
Autocomplete (`LokalBot/Cotyping`): suggestions for the text field the
user is typing in, from the Autocomplete model on its own llama-server.

This crate holds the prediction pipeline, the same for every model in the
catalog: a request from the field ([`prompt`]), one streamed completion
with token healing and the confidence gate ([`client`]), cleanup into
ghost text ([`normalize`], [`seam`]), and the rules for accepting,
typing through and topping up a suggestion ([`accept`], [`session`]),
with saved facts, learned examples, the clipboard and the focused window's
text when allowed ([`memory`], [`learning`], [`clipboard`],
[`window_text`]). `/macros` and typo corrections ([`macros`], [`typo`]) win
over the model, and a chosen server can stand in for it ([`server`]). The
engine's worker schedules it; the desktop integration reads fields and
draws and inserts the suggestions.

#### One accept press takes next word or phrase with its spacing
`accept_chunk`: The part of `suggestion` one accept key press takes: the next word or
phrase, with the spacing that belongs to it (`CotypingAcceptanceChunker`).

#### Accept edit covers replaced text; None when replacement no longer matches live text
`plan_acceptance`: The edit one accept key press makes at the caret
(`CotypingContinuationAcceptance`, `CotypingReplacementAcceptancePlanner`):
the chunk it takes, the text to type for it, and what it replaces before
the caret (an emoji's `:shortcode`, a `/macro`, a misspelled word) or after
it (the rest of a word the caret is inside of). `None` when nothing would
be accepted, or a replacement no longer matches the live text.

#### Emoji ghost draws glyph plus shortcode as macOS does
`emoji_ghost`: What to draw for an emoji suggestion ("🚀 :rocket:"), as macOS does; `None`
when `suggestion` is not the emoji for the `:shortcode` before the caret.

#### Last strongly directional character before caret decides direction
`is_right_to_left`: Whether the text nearest the caret runs right to left, for placing the
ghost (`CotypingTextDirectionDetector`): the last strongly directional
character before the caret decides.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/normalize.rs`

#### Normalization is pure, backend-agnostic cleanup of raw model output
Raw model output to clean ghost text (`CotypingTextNormalizer`,
`CotypingPromptLeakGuard`, `CotypingControlTokens`,
`CotypingTrailingDuplicationFilter`, `CotypingInsertionSafety`): the
backend-agnostic cleanup that makes a small model's completion safe to
show and insert. Pure: the same output and request give the same result.

#### Non-word fragment followed by a new word is suppressed
`Suppression::WordCompletionMismatch`: A fragment that is not a word ("follo") followed by a new word.

#### Suppress when model was unsure of the first word
`Suppression::LowConfidence`: The model was unsure of the first word (`CotypingFirstWordConfidence`).

#### With token healing, output must retype cut text; only the rest is the suggestion
`normalize_healed`: `CotypingEngine.normalize(_:requiredPrefix:for:)`: with token healing the
output must first re-type the text cut from the prompt; only what follows
is the suggestion.

#### Pipeline step order follows Cotabby
`normalize_detailed`: The full pipeline, in Cotabby's order: control tokens, think blocks,
prompt and prefix echoes, scaffolding labels, line collapse, mid-word
rules, trailing duplication, echoed words, spacing, safety.

#### Line break after typed text dropped; one space replaces it later
`normalize_detailed`: The model put a line break between the typed text and its completion.
The break goes; one space takes its place further down.

#### Instruct models restart from hidden prompt head; compare to exact preface
`normalize_detailed`: Instruction-tuned models used as raw continuers sometimes restart from
the hidden prompt head; compare with the exact rendered preface.

#### Never retype the caret's fragment; never begin with whitespace inside a word
`normalize_detailed`: Mid-word: never re-type the fragment the caret sits in, and strictly
inside a word never begin with whitespace.

#### Suppress new word after non-word fragment to avoid broken text
`normalize_detailed`: Caret at the end of a fragment that is not a word: a new word after it
would leave broken text ("follo" + " up on that").

#### Apply spacing after echo stripping, which can expose a leading space
`normalize_detailed`: Spacing, after echo stripping (which can expose a leading space).

#### Restore a space when the line break is dropped so text is not glued
`normalize_detailed`: Without its line break the completion would be glued to the typed
text: two words run together, or a comma loses its space.

#### Try overlaps up to 15 words and keep the longest
`strip_echo_prefix`: Leading words that repeat the tail of the text before the caret. Every
overlap up to 15 words is tried; the longest wins.

#### Leak caught only when that label was in this request's preface
`RENDERER_MARKER_STEMS`: Renderer labels; a leak is caught only when that kind of line was really
in this request's preface.

#### Older prompt layouts can return via learned examples or model prior
`LEGACY_MARKER_STEMS`: Older prompt layouts a learned example or model prior can bring back.

#### Leak match ignores punctuation, case and diacritics against exact preface
`detects_prompt_leak`: `CotypingPromptLeakGuard.detectsLeak`: punctuation-, case- and
diacritic-insensitive matching against the exact preface the model saw.

#### Changed or omitted value of an active renderer label counts as a leak
`detects_prompt_leak`: A renderer label whose value the model changed or left out, when that
label is active in this preface.

#### Context-free scaffolding check used for learned examples
`looks_like_prompt_scaffolding`: `CotypingPromptLeakGuard.looksLikePromptScaffolding`: the context-free
check for learned examples.

#### Window lines may be continued; only their label stays protected
`protected_preface_lines`: Preface lines a suggestion must not repeat. The focused window's own
lines are left out: continuing with a name or phrase on screen is what
that context is for. Its label stays protected; the block ends at the
blank line the renderer puts after it.

#### Leave out \</s> because it also closes HTML s
`STOP_MARKERS`: End-of-turn markers; `</s>` is left out because it also closes HTML `<s>`.

#### Suppress completion that mostly retypes the text after the caret
`duplicates_trailing_text`: `CotypingTrailingDuplicationFilter`: the completion would mostly re-type
the text after the caret.

#### Reject control characters, replacement glyph and whitespace-only text
`is_safe_to_insert`: `CotypingInsertionSafety`: no control characters, no replacement glyph,
not only whitespace.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/prompt.rs`

#### Model is a pure text continuer; prefix is last with whitespace intact
The completion prompt (`CotypingPromptRenderer`) and the request built
around it (`CotypingRequestBuilder`).

The model is a pure text continuer, not an instruction follower, for
every model in the catalog: there is no chat template and no control
token besides the BOS llama-server adds. Persona, style and context go
into a short conditioning preface, and the text before the caret is the
last thing in the prompt, its whitespace intact.

#### Low temperature and fixed seed keep identical context reproducible
`Sampling`: `CotypingConfiguration.standard`: low temperature for stable inline
completions; the fixed seed keeps identical context reproducible.

#### Seed 0x00C0FFEE is Cotabby's coffee seed
`Sampling::default`: 0x00C0FFEE, Cotabby's "coffee" seed.

#### ceil(words x 1.3), min 5, doubled for multi-line, max 120
`max_response_tokens`: `AppSettings.cotypingMaxResponseTokens`: ceil(words × 1.3), at least 5,
doubled for multi-line, at most 120.

#### App and window-title conditioning is on by default on macOS
`Personalization.app_context`: Condition on the app and window title. On by default on macOS.

#### Normalizer enforces the word ceiling after the model
`Request.max_words`: The word ceiling the normalizer enforces after the model.

#### Caret strictly inside a word forces the suggestion to continue it
`Request.force_word_continuation`: The caret is strictly inside a word: the suggestion must continue it.

#### word_prefix is empty at a word boundary
`Request.word_prefix`: The word characters right before the caret ("" at a word boundary).

#### Valid-word check is true without a language dictionary, as on macOS
`Request.word_prefix_is_valid_word`: Whether `word_prefix` is a whole word ("the") rather than a fragment
("follo"). True without a dictionary for the text's language, as on
macOS.

#### Exact hidden preface kept so an echo of it is suppressed
`Request.conditioning_preface`: The exact hidden preface in `prompt`, so an echo of it is suppressed.

#### Leading space in answer dropped when prefix ends on whitespace
`Request::preceding_ends_with_whitespace`: The caret prefix ends on whitespace, so a leading space in the answer
is dropped.

#### Clipboard used only as a fresh copy related to what is typed
`Extras.clipboard`: A fresh copy related to what is being typed (`CotypingClipboardContext`).

#### Blank field may still build a request to prefill its prompt
`Extras.allows_blank_prefix`: Build a request for a blank field too, to prefill its prompt.

#### None when nothing before the caret to continue
`build_request`: `CotypingRequestBuilder.build`. `None` when there is nothing before the
caret to continue.

#### Whole-window text already covers the column above the field
`build_request`: The whole window includes everything the column above the field would add.

#### Cap preface at 900 characters so style notes never crowd the prompt
`MAX_PREFACE_CHARACTERS`: Upper bound on the preface so a long style note never crowds the prompt.

#### Window text first with its own budget: it changes least and server keeps cached start
`render`: Window text has its own budget and comes first: it changes least
while typing, and the server keeps what it read of an unchanged start.

#### Blank line separates preface from live text; no label to echo; prefix stays last
`render`: A blank line separates the preface from the live text, with no label
the model could echo. The prefix stays the final bytes.

#### At most three excerpts within 420 characters, nearest first; credential-like lines excluded
`nearby_text`: `CotypingVisibleContext`: at most three excerpts within 420 characters,
nearest the field first, kept in reading order and joined with " | ".
Lines that look like credentials or prompt instructions are left out.

#### Lines without a letter or digit add nothing
`nearby_text`: A line without a letter or digit (a rule, an emoji reaction) adds
nothing (`CotypingWindowText.cleaned`).

#### No secrets or injection phrasing; None when nothing safe remains
`sanitized_context`: `CotypingMemoryContext.sanitized`: no secrets, no prompt-injection
phrasing, whitespace collapsed. `None` when nothing safe is left.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/seam.rs`

#### Suppress junk punctuation runs and mid-word splices that misspell the word
`CotypingSeamGuard`: no suggestion beats a junk punctuation run or a
mid-word splice that misspells the word being typed.

#### Without a spell checker, is_known_word should accept everything, as macOS does
`verdict`: `is_known_word` answers for the joined word at the caret. Without a
spell checker for the text's language it should say yes to everything,
as macOS does where it has no dictionary.

#### Continuing an existing divider run is fine
`introduces_junk_punctuation_run`: Continuing a divider the text already has ("--" + "----") is fine.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/server.rs`

#### Typing goes to a server only after autocomplete origin approval; loopback exempt; no replays
Autocomplete on a server (`CotypingServerRoute.swift`): Think's Ollama or
OpenAI-compatible server, or another one the user names. The route is
built from settings for every request, so a change applies to the next
keystroke. Typing goes to a server only after its origin is approved for
autocomplete (`approved_remote_autocomplete_origins`); Think's approval
does not cover it. A loopback server needs no approval, since nothing
leaves the computer.

Raw text completion where the server offers it, chat continuation
otherwise. A failed request is never replayed: a newer keystroke supersedes
it anyway. There is no prefill: a server keeps its own cache.

#### A completion slower than 15 s is not worth showing
`DEADLINE`: A completion slower than this is no longer worth showing.

#### Extra token room for reasoning a model cannot turn off
`REASONING_ROOM_TOKENS`: Room for reasoning a model cannot turn off, on top of the phrase.

#### Self-run servers get llama.cpp sampling fields; hosted APIs may reject them
`Endpoint::is_self_hosted`: A server the user runs themselves, which takes llama.cpp's sampling
fields. Hosted APIs may reject unknown fields.

#### Automatic uses chat for OpenAI, Anthropic, OpenRouter; self-run servers offer raw completions
`Endpoint::starts_with_chat`: OpenAI and Anthropic offer no raw completions for current
models, and OpenRouter's raw route continues text as gibberish
on many hosts. Servers people run themselves offer them.

#### Keys read from credential store only when asked, None for presentation
`Keys`: The API keys a route may need, read from the credential store only when
asked. `None` for presentation and decisions about context.

#### Mirrors InferenceEndpointPolicy: reason a URL may not yet receive typing
`validate`: `InferenceEndpointPolicy.validate(allowsPrivateNetworkHTTP: true)`: the
reason `url` may not get typing yet, or `None`.

#### A server not set up yet counts as off this computer
`leaves_this_computer`: True unless the prompt stays on this computer. A server that is not set up
yet counts as off it.

#### Route fingerprint for caches covers everything affecting completions but the key
`fingerprint`: Everything about the route that changes what a completion can be, for
caches. The key is left out (`cotypingRouteFingerprint`).

#### Writing shows server failures; hold no server message since errors can quote the prompt
`Failure`: Why the last request to a server brought no suggestion. Writing shows it,
since typing elsewhere shows no error. Holds no server message: a request
error can quote the prompt.

#### Learned server behavior is kept until LokalBot quits
`ServerMemory`: What a server taught this run, kept until LokalBot quits.

#### Blocking; cancel checked between tokens and while waiting out rate limit
`complete`: One suggestion from `endpoint`. Blocking; `cancel` is checked between
streamed tokens and while waiting out a rate limit.

#### Share origin gate with Think so autocomplete does not pile onto busy server
`complete`: A slot on the origin's gate, shared with Think, so autocomplete can't pile
onto a server it's using for something else (`RemoteCotypingEngine`).

#### Detect server without raw route or model served only through chat
`rejects_text_completion`: A server without a raw completion route, or a model it serves through chat
only (`rejectsTextCompletion`).

#### Cut prompt to word boundary; suppress output not retyping the cut text
`raw`: Raw `/v1/completions`. The prompt goes cut back to the word boundary, and
only output that re-types the cut text counts: a server cannot be held to
that prefix, so other output is suppressed.

#### Whitespace cut needs no extra tokens; cut fragment needs a few more
`raw`: A space joins the first word's token; a cut fragment needs a few more.

#### Normalizer still collapses lines defensively despite stop sequence
`raw`: The normalizer still collapses defensively.

#### Autocomplete instruction as system message, thinking off, truncated reply keeps its text
`chat`: `ChatContinuationEngine`: the autocomplete instruction as the system
message and the rendered prompt as the user message, with thinking off. A
reply cut off at the budget keeps the text it has; an empty reply means the
model had nothing to add.

#### Anthropic chat served under /v1 whatever URL form was entered
`chat_reply`: Anthropic serves chat completions under /v1 whichever form of its URL
was entered.

#### Restore the space chat models drop after a whole word; leave other cases
`restoring_word_space`: Chat models often leave out the space before a new word: "at a" + "higher
level" would show as "ahigher level". After a whole word, a reply that
starts with a letter or digit starts a new word, so it gets the space
back. Inside a word, after a fragment the spell checker does not know, when
the reply restates the word at the caret, and in scripts written without
spaces, the reply is left as it is.

#### Spaced-script test excludes Han, kana, Hangul, Thai, Lao, Myanmar, Khmer
`is_spaced_word_character`: A letter or digit of a script that puts spaces between words: not Han,
kana, Hangul, Thai, Lao, Myanmar or Khmer.

#### Think's approval never authorizes autocomplete typing
`typing_goes_only_to_an_approved_server`: Think's approval never counts.

#### Private network may use plain HTTP once approved
`typing_goes_only_to_an_approved_server`: A private network may use plain HTTP, once approved.

#### Loopback needs no approval since nothing leaves the computer
`typing_goes_only_to_an_approved_server`: Loopback needs no approval: nothing leaves the computer.

#### Origin's two-second pause from Think also holds autocomplete back
`a_rate_limit_on_think_pauses_autocomplete_on_the_same_server`: The origin's two-second pause held autocomplete back too.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/session.rs`

#### preview is what to draw and differs from the inserted text
`SuggestionKind::Macro`: Replaces the `/query` before the caret with the result; `preview` is
what to draw (`= 10` for an insertion of `10`).

#### Any change to text after the caret ends the suggestion
`Session.after`: Text after the caret then; any change to it ends the suggestion.

#### consumed counts bytes of full_text accepted or typed through
`Session.consumed`: Bytes of `full_text` accepted or typed through.

#### Only suggestions cut by the length limit are topped up
`Session.open_ended`: The model's output was cut by the length limit, so there is more to
say; only such a suggestion is topped up.

#### Includes field showing accepted text with the space a new sentence needs
`Reconciled::Advanced`: The user typed the suggestion's next characters (or the field showed
accepted text with the space a new sentence needs).

#### Fields over 1 KiB may arrive as sliding window of their end
`WINDOWED_TEXT_BYTES`: Fields longer than this may arrive as a sliding window of their end.

#### A window may slide up to 512 bytes between reads
`MAX_WINDOW_SHIFT`: How far a window may slide between two reads.

#### Reconciles whole-field snapshots rather than key presses
`reconcile`: `sessionReconciledByPublishedTyping`, for a reader that reports whole
field snapshots rather than key presses.

#### New sentence's separating space is added when typed in, not in the suggestion
`reconcile`: A new sentence got its separating space when it was typed in
(`insertion_chunk`); the suggestion itself did not have it.

#### Long field read as window may have slid by a few characters
`typed_since`: What was typed after `expected`, when `before` still starts with it. A
long field read as a window of its end may have slid by a few characters.

#### Do not show new suggestion repeating just-accepted chunk before field shows it
`is_stale_acceptance_echo`: `isStaleAcceptanceEcho`: a new suggestion that only repeats the chunk just
accepted, while the field has not shown it yet, is not shown.

#### Top up once two or fewer words are left
`EXTENSION_THRESHOLD_WORDS`: A suggestion is topped up once this many words, or fewer, are left.

#### A one-word limit never tops up
`extension_threshold`: Words left at which a top-up starts. A one-word limit never tops up.

#### Top-up asks one word fewer so ghost never exceeds limit plus one
`top_up_word_limit`: Words asked for in one top-up: one fewer than a fresh suggestion, so the
ghost never grows past the limit plus one.

#### One word short counts as length-limited since token budget can run out
`is_open_ended`: Whether output stopped at the length limit rather than at the end of a
thought. One word short still counts: the token budget can run out
before the last word is whole.

#### Top-up continues from the original before-text plus whole suggestion
`continuation_prefix`: The text a top-up continues from: what stood before the caret when the
suggestion was made, then the whole suggestion.

#### Addition starts a new word, never changes on-screen words or repeats them
`addition`: The part of `output` that may be appended to `suggestion`. Words already
on screen must not change, so the addition starts a new word (or adds
punctuation) and does not repeat what the suggestion just said.

#### Re-show still-valid tails without a model call after focus bounce or backspace
`AnchorCache`: Recently shown suggestions, so common edits re-show a still-valid tail
without a model call: focus bounce, backspace, typing through after the
session was cleared.

#### Restore the deepest still-valid tail for current text
`AnchorCache::restoration`: The deepest still-valid tail for the text now before the caret.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/stop.rs`

#### Stop at the same visible boundary as the macOS in-process decode
`CotypingDecodeStopPolicy`: where a streamed completion stops early, at
the same visible boundary the in-process macOS runtime stops its decode.

#### Control token stops at once; sentence end only after two tokens
`verdict`: A chat control token stops at once; a sentence end once two tokens are in.

#### Sentence end rules: bang, question, CJK terminator, real period, trailing closers
`ends_sentence`: `CotypingSentenceBoundary.endsSentence`: `!`, `?`, a CJK terminator, or a
period that ends a sentence, optionally followed by closing quotes or
brackets and whitespace.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/surface.rs`

#### Window title is strongest cue; omitted for editors and terminals; ids differ from macOS
"What am I writing in?" (`CotypingSurfaceContext`): the window title
carries the email subject, document name, chat channel or page title, the
strongest situational cue a small model gets. Left out for code editors
and terminals, where app metadata pulls the model toward code.

macOS classifies by bundle identifier; here the desktop reports an
executable or desktop id ("firefox", "code.exe", "org.gnome.Evolution").

#### Integrated xterm.js surface is a terminal whatever app hosts it
`SurfaceClass::of_field`: `classify(bundleID:isIntegratedTerminal:)`: an xterm.js surface in an
editor or a browser is a terminal, whatever app it is in.

#### Mac raw value is the key in statistics and learned examples
`SurfaceClass::raw_name`: The Mac's raw value, used as a key in statistics and learned examples.

#### App id normalization: strip path and extension, keep dotted desktop ids
`normalized_app_id`: "Code.exe" → "code", "/usr/bin/firefox" → "firefox",
"org.mozilla.firefox.desktop" → "org.mozilla.firefox".

#### Linux and Windows window titles end with browser or app names
`TITLE_SUFFIXES`: Browser and app names Linux and Windows window titles end with
("Inbox - Gmail - Mozilla Firefox"), besides the app's own name.

#### None for editors, terminals and generic apps with nothing useful
`compose`: `CotypingSurfaceComposer.compose`: nil for code editors, terminals, and
generic apps with nothing useful to say.

#### Integrated terminal has no surface to describe
`compose_field`: [`compose`] for a field: an integrated terminal has no surface to describe.

#### Interface descriptions pull small models toward talking about buttons instead of continuing
`preface_lines`: Conditions on the writing topic. Descriptions of the interface ("text
being typed", "the window is titled") pull small models toward talking
about buttons and fields instead of continuing the passage.

#### Strip app suffix, control characters and quotes; cap length
`sanitized_title`: Strips the app-name suffix titles carry ("Inbox - Gmail - Mozilla
Firefox", "Notes — Pages"), drops control characters and quotes, and caps
the length.

#### Titles can end in two app-name segments
`sanitized_title`: "Notes - Visual Studio Code - Insiders" style titles end in two segments.

#### Edge writes its name with a zero-width space, dropped first
`titles_lose_app_suffixes_control_characters_and_quotes`: Edge writes its name with a zero-width space, which is dropped first.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/text.rs`

#### Swift Character properties map to char; combining marks join preceding word
Character classes the autocomplete rules share. Swift's `Character`
properties map onto `char` here; a combining mark counts as part of the
word it follows, as it would inside one Swift `Character`.

#### Mirrors Swift Character.isLetter or isNumber
`is_word_char`: `Character.isLetter || Character.isNumber`.

#### Mirrors Swift Character.isLetter
`is_letter`: `Character.isLetter`.

#### Mirrors Swift Character.isNewline
`is_newline`: `Character.isNewline`.

#### Matches Swift controlCharacters: Cc plus leaked format characters (Cf)
`is_control`: Swift's `CharacterSet.controlCharacters`: Cc plus the format characters
(Cf) a model or a host can leak into text.

#### Visible non-word characters, mirroring Swift isPunctuation or isSymbol
`is_punctuation_or_symbol`: `Character.isPunctuation || Character.isSymbol`: anything visible that is
not part of a word.

#### Spaceless scripts list mirrors cotypingBeginsSpacelessScriptWord
`begins_spaceless_word`: `cotypingBeginsSpacelessScriptWord`: scripts written without spaces
between words (CJK, kana, Hangul, Thai, Lao, Khmer, Myanmar).

#### CJK comma marks mirror cotypingIsPhraseClauseBoundary
`is_phrase_clause_boundary`: `cotypingIsPhraseClauseBoundary`: the CJK comma marks.

#### Periods after these abbreviations do not end a sentence
`ABBREVIATIONS`: Periods after these do not end a sentence.

#### These suffixes make name.suffix a domain or file, not two sentences
`DOMAIN_OR_FILE_SUFFIXES`: Suffixes that make `name.suffix` a domain or a file name, not two sentences.

#### A period after a digit, lone letter or abbreviation is not terminal
`is_terminal_period`: Whether the period at byte `period` ends a sentence: not after a digit
(`1.5`), a lone letter (`U.S.`) or an abbreviation (`e.g.`, `Dr.`).

#### Case and diacritic folding mirrors Swift folding options
`fold`: Lowercase without diacritics, for comparisons (`folding(options:
[.caseInsensitive, .diacriticInsensitive])`).

#### Count user-perceived characters, as one Backspace or Delete removes them
`grapheme_count`: User-perceived characters, as one Backspace or Delete removes them.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/typo.rs`

#### Pure typo rules mirror Swift; only non-words flagged, real-word errors out of scope
Typo and autocorrect rules (`CotypingTypo.swift`,
`CotypingSpellChecker.swift`, `CotypingSpellLanguageGate.swift`), pure:
the words and verdicts come from a [`SpellSource`] the desktop provides.
Only non-words are flagged; real-word errors (their/there) are out of scope.

#### Spell calls must be fast; a loading dictionary answers not-a-typo
`SpellSource`: What a platform's spell checker answers. Calls must be quick: they run on
the autocomplete worker, and a dictionary still loading answers "not a
typo" and "no dictionary" rather than wait.

#### Languages formatted en_US or en-US; empty when spell checking unavailable
`SpellSource.languages`: The languages with a dictionary, as `en_US` or `en-US`. Empty when
spell checking is not available here.

#### True when a longer dictionary word starts with the given word
`SpellSource.is_completable_prefix`: A longer dictionary word starts with `word`.

#### Word length counted in user-perceived characters; one Delete removes one
`Word`: The trailing word at the caret and its length in user-perceived
characters: one Delete press removes one.

#### No word when caret is on whitespace or token is not natural language
`extract`: The trailing word, or `None` when the caret is on whitespace or the token
is not plausibly natural language.

#### Tolerate exactly one trailing space so a finished word stays actionable
`extract_trailing_word`: Tolerates exactly one trailing space, so a just-finished word stays
actionable after pressing Space.

#### Skip code, URLs, numbers, acronyms; a miss is fine, a false positive is not
`is_plausible_natural_word`: Skips code, URLs, numbers and all-caps acronyms. Conservative: a miss is
fine, a false positive on code is not.

#### No actionable typo: generate a normal continuation
`TypoDecision::Proceed`: No actionable typo: generate a normal continuation.

#### Misspelled with no correction: hide the continuation
`TypoDecision::Suppress`: Misspelled, no correction: hide the continuation.

#### Misspelled with a fix offered as a one-key replacement
`TypoDecision::Offer`: Misspelled, with a fix to offer as a one-key replacement.

#### Live prefix of a real word mid-word is not a typo; completed words are
`resolve`: `CotypingTypoGate.resolve`. A word still being typed that is a live prefix
of a real word ("follo") is not a typo: the model must complete it. Only a
fragment no word starts with is a typo mid-word; once finished with a
space, being completable no longer matters.

#### Correction edit is recomputed from live text at accept time
`CorrectionPlan`: The edit that replaces a verified trailing typo, recomputed from the live
text at accept time (`CotypingCorrectionPlan`).

#### Language recognition looks at the last 200 characters before the caret
`CONTEXT_WINDOW_CHARACTERS`: The caret-preceding window language recognition looks at.

#### Below 0.5 confidence the recognizer guesses, so spell checking stays on
`MINIMUM_CONFIDENCE`: Below this the recognizer is guessing, so spell checking stays on.

#### One token is never enough evidence to turn spell checks off
`MINIMUM_WORD_COUNT`: One token is never enough evidence to turn spell checks off.

#### Spell verdicts stand down for confident text in a language without dictionary; whatlang confidence own scale
`spell_verdicts_apply`: Whether spell verdicts mean anything for the text at the caret
(`CotypingSpellLanguageGate`): text confidently in a language with no
dictionary would otherwise be flagged word by word. `whatlang` stands in
for `NLLanguageRecognizer`; its confidence is its own scale.

#### Language recognized once per keystroke because several lookups hit same text
`Speller`: A [`SpellSource`] with the per-keystroke rules of `CotypingSpellChecker`
around it. One keystroke asks several times about the same text, so the
language is recognized once.

#### Unknown coverage must not turn every fragment into a spelling error
`Speller.word_prefix_is_valid_word`: Unknown coverage must not turn every fragment into a spelling error.

#### Seam guard accepts known words or text where verdicts do not apply
`Speller.is_known_word`: For the seam guard: a known word, or verdicts that do not apply.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/window.rs`

#### Prefix window and mid-word rules mirror CotypingPrefixWindow and CotypingMidWord
How much of the text before the caret a request reads
(`CotypingPrefixWindow`), and the word the caret sits in
(`CotypingMidWord`).

#### No generation on whitespace or numbers-only text; a word brings it back
`should_generate`: Generate only when there is something besides whitespace before the caret,
and not while it is numbers without a single letter: a verification code,
a phone number or an amount has no prose to continue. A word brings
suggestions back.

#### Digits without letters (codes, phones, amounts) have no prose to continue
`is_numbers_only`: Digits with no letters, such as `482 913`, `+382 67 123 456` or `12.50`
(`CotypingPrefixWindow.isNumbersOnly`).

#### Window starts at stable boundary so the server keeps its prompt cache
`truncated_prefix`: The latest text, bounded by characters and words, without rewriting
paragraph breaks, list indentation or the whitespace at the caret.

A window cut from longer text starts at a sentence or line boundary near
its front: the server keeps what it has read of an unchanged prompt
start, and a window that moved by one character per keystroke would make
it read the whole window again every time.

#### Full stop after a letter ends a sentence; numbered list markers do not
`stable_start`: A full stop after a letter ends a sentence; "1. " numbers a list.

#### Force continuation only strictly inside a word; word ends keep normal prediction
`should_force_continuation`: True only when the caret is strictly inside a word, with a letter or
digit on both sides. At a word end, ordinary next-word prediction (which
wants a leading space) is left alone, as in Cotabby.

#### Forced mid-word accept replaces only strong overlap, in user-perceived characters
`accepted_trailing_overlap`: How many characters to the right of the caret a forced mid-word accept
replaces. Only an overlap that completes the accepted word fragment or
the word fragment on the right counts, so a weak shared first letter
("operate" against "ord") is left alone. Counted in user-perceived
characters.

#### Test guards window start staying fixed while typing on a long draft
`a_long_drafts_window_start_stays_put_while_typing`: Typing on at the end of a long draft keeps the window's start in place.

### `LinuxWindows/crates/lokalbot-ai/src/autocomplete/window_text.rs`

#### Window text read from pixels in background, adopted after typing pause, never logged
Text read from the focused window's pixels for the "Use the focused window
as context" grant (`CotypingWindowText`, `CotypingWindowTextCapture`), the
pure half: which recognized lines enter the prompt, in what order, and
when a newer read replaces the one in use. The engine does the reading,
never on a keystroke: the first request in a field goes without it, later
ones use the result, reread in the background every few seconds. New text
waits for a pause in typing, because it starts the prompt and changing it
makes the model read the whole prompt again. The text is held for the
focused field only and never logged.

#### 2,000 characters is about 500-700 prompt tokens, a typical pane whole
`MAXIMUM_CHARACTERS`: About 500–700 prompt tokens: a typical chat or mail pane whole.

#### Lines this close to the field are its border, label or placeholder
`FIELD_MARGIN`: Lines this close to the field are its border, label or placeholder.

#### Message bubbles sit slightly inside or outside the field edges
`COLUMN_SLACK`: Message bubbles sit a little inside or outside the field's edges.

#### Text scrolled out of view may stay in use for 60 seconds
`MAXIMUM_HELD_AGE`: How long text that scrolled out of view may stay in use.

#### Short new text such as timestamps must not replace text in use
`MINIMUM_ADDED_CHARACTERS`: Shorter new text (a timestamp, a typing indicator) does not replace the
text in use, which would make the model read it all again.

#### New reread text is used once typing has stopped this long
`TYPING_PAUSE`: New text from a reread is used once typing has stopped this long.

#### Frames are screen pixels with top-left origin
`Frame`: A rectangle in screen pixels, top-left origin.

#### Drop credential lines instead of teaching the model to complete redaction markers
`cleaned`: Drops credential-bearing lines rather than teaching the model to complete
a redaction marker, and lines with no letters or digits.

#### The draft is never prompt context, so its lines are not kept
`outside_field`: The draft is never prompt context, so its lines are not kept for reuse.

#### Prompt lines: column above field nearest first, rest placed before them
`excerpts`: The lines a prompt gets, in reading order. The draft never enters: it is
already the text before the caret. Lines in the field's column above it
come first, nearest first, so a long conversation keeps its newest
messages; the rest of the window fills what is left and is placed before
them, so the conversation ends right where the draft begins.

#### Window text keeps line breaks because conversations read line by line
`Snapshot.text`: Window text keeps its line breaks: a conversation reads line by line.

#### Unchanged rereads change nothing; scrolled-away lines stay; new text replaces at once
`should_replace`: Whether a newer read replaces the text in use. Rereading an unchanged
window changes nothing, and lines that only scrolled away stay for a
while; new text replaces it at once.

#### Field height and position excluded from key; another title means different text
`key`: Identifies one field's window between reads. Field height and position are
left out because a reply box grows as you type; another title is another
document, tab or conversation, whose text is not reused.

#### Fingerprint ignores the field being typed in so equal prints reuse OCR lines
`fingerprint`: What recognition would read from a window image apart from the field being
typed in, whose draft and blinking caret a prompt never uses. Equal
fingerprints reuse the last lines instead of recognizing the window again.
`rgba` is `image_width` × `image_height` pixels showing `window`.

#### Area-averaged downscale so a changed word still changes pixels
`fingerprint`: Area-averaged, a changed word still changes pixels.

#### Newer read with new text is held until typing pauses
`Entry.pending`: A newer read with new text, held until typing pauses.

#### Changed text in use means the prompt start must be re-read
`Finished::Changed`: The text in use changed: the prompt's start must be read again.

#### New text waits for a pause in typing
`Finished::Held`: New text waits for a pause in typing.

#### Mirrors CotypingWindowTextCapture state without its thread or clock
`Capture`: The state of `CotypingWindowTextCapture`, without its thread or clock.

#### finish must receive the ticket's generation back
`Ticket`: A read to start. `finish` must get its `generation` back.

#### Refresh interval counted from read start so failures are not retried per keystroke
`Capture.snapshot`: The text for `key`, or `None` until the first read finishes, and a
ticket when a read should start: none is running and the last one is
old. Counted from the start, so a read that fails is not retried on
every keystroke.

#### A read older than the last forgetting cannot restore the text
`Capture.finish`: A read came back. `snapshot` is `None` when it failed or was refused.
A read older than the text's last forgetting cannot put it back.

#### Held text is usable when nothing is typed meanwhile
`Capture.adoption_due`: When held text can be used, if nothing is typed meanwhile.

#### A read already running cannot put forgotten text back
`Capture.remove_all`: Forgets the text in use. A read already running cannot put it back.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
