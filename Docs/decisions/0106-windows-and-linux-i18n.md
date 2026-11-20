# 0106. Windows and Linux: i18n

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-i18n/src/lib.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-i18n/src/lib.rs`

#### Translation lookup is for interface copy only, never user content
Interface copy only. Never apply translation lookup to user content, model
prompts, serialized values, paths, or protocol identifiers.

#### Match AppLanguage.swift rules; explicit ar-EG is Egyptian, system ar-EG standard Arabic
`resolve`: Same matching rules as AppLanguage.swift, including script/region aliases.
Explicit `ar-EG` is Egyptian Arabic; a system `ar-EG` is standard Arabic.

#### Follow GNU locale precedence; C/POSIX forces English; Windows uses OS list
`unix_preferences`: GNU message locale precedence. C/POSIX explicitly selects English, even
when LANGUAGE contains another language. Windows uses the OS preference list.

#### Substitute fields once after translation; arguments never re-interpreted as templates
`format_in`: Replaces named/numbered fields once, after translation. Argument text is
never looked up or interpreted as another template (including braces).

#### GNU FIRST_WEEKDAY is one-based offset from WEEK reference date
`first_weekday_in`: GNU locale data defines FIRST_WEEKDAY as a one-based offset from the
reference date in WEEK (normally 1997-11-30, a Sunday).

#### Use locale date order and clock; never for storage, filenames or timecodes
`date_pattern`: Locale date/time order and 12/24-hour conventions, not a hard-coded US
layout. Storage timestamps, filenames and media timecodes never call this.

#### Keep English presentation; compact clocks must not gain seconds
`date_pattern_in`: Retain the existing English presentation, while using the regional
date order and clock convention for other locales. Compact UI clocks
must not acquire seconds just because %X includes them.

#### Content direction from first strong character, independent of interface; URLs can opt LTR
`content_is_rtl`: Content direction comes from its own first strong character, independently
of interface chrome. URLs/code/media controls can opt into LTR explicitly.

#### Prefix RLM because GPUI drops a leading number in RTL shaped lines
`directional`: A phrase drawn as one shaped line, starting with the right-to-left mark
when its own text reads right to left. GPUI drops a number that starts such
a line ("39م" shows as "م", "3ح 57م" as "ح 57م"); the mark keeps it. It is
for shaping only and invisible. Text that reads left to right, which is all
of it in a left-to-right interface, is returned as it is.

#### In RTL interface every phrase gets the mark, even bare counts
`interface_directional`: Like [`directional`], but by the interface rather than the text: in a
right-to-left interface every phrase gets the mark, a bare count too.
Text in a left-to-right interface is returned as it is.

#### Short date shows year only when not today's year; mirrors AskDateLabel.day
`short_date`: "Nov 10", with the year once it is not `today`'s year
(`AskDateLabel.day`). Both are local days.

#### Today/Yesterday/weekday labels then short date; mirrors ActionListWording.day
`day_label`: "Today", "Yesterday", "Fri, Nov 6" for the rest of the past week, then
[`short_date`] (`ActionListWording.day`). Both are local days.

#### Translate whole count phrases; never append English plural suffix
`count`: Complete count phrases are translated together; never append an English
plural suffix to a translated noun.

#### POSIX grouping: sizes from the right, last repeating until -1
`number_in`: POSIX grouping: group sizes from the right, the last one repeating,
until a size of -1 (or none) leaves the rest whole.

#### Fill Mac catalog fields; caller does the lookup so keys stay literals for catalog checks
`fill`: Fills a Mac catalog string's fields (`%lld`, `%@`, `%d`, or numbered
`%1$lld`, `%2$@`) with `values`, in order unless numbered. The lookup
itself is the caller's [`tr`], so the key stays a literal the catalog
checks can see.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
