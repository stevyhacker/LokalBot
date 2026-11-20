# 0094. Windows and Linux: core — settings

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/settings.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/settings.rs`

#### Settings keys follow macOS blob; tolerant decoding defaults missing or unreadable keys
`settings.json` in the library root.

Keys follow the macOS `AppSettings` blob where the setting exists on both
platforms. Decoding is tolerant: a missing or unreadable key takes its
default, so older or newer files always load.

#### Interface language only, shared key with macOS appLanguage
`Settings.app_language`: Interface only; compatible with macOS's appLanguage preference.

#### Empty string means system default input
`Settings.microphone_device`: Empty means the system default input.

#### Values: match, language code, or custom:\<name>
`Settings.summary_language`: `match`, a language code, or `custom:<name>`.

#### Port installs saved enabled true unasked, so reading needs explicit confirmation
`Settings.coding_agent_evidence_confirmed`: The user chose to let coding-agent sessions into day memory. The Mac
asks during setup; installs here saved the enabled key as true without
ever asking, so reading also needs this (not a Mac key).

#### Private routing is default; following account policy is explicit opt-in
`Settings.open_router_data_policy`: OpenRouter's per-request provider policy for Think and Autocomplete.
Private routing stays the default; following the account's policy is
an explicit opt-in (`openRouterDataPolicy`).

#### Alias or full id; empty uses Claude Code's default
`Settings.claude_plan_model`: Model for the Claude plan: an alias Claude Code accepts ("sonnet") or a
full model id. Empty uses Claude Code's own default.

#### Slug agy accepts; empty uses Antigravity default
`Settings.antigravity_plan_model`: Model for the Antigravity plan: a slug `agy models` accepts. Empty uses
Antigravity CLI's own default.

#### Model id gemini accepts; empty uses auto
`Settings.gemini_plan_model`: Model for the Gemini plan: a model id `gemini` accepts. Empty uses
Gemini CLI's own default (`auto`).

#### Agent's own level; None follows Think
`Settings.agent_reasoning_level`: Agent Mode's own reasoning level, chosen in the Agent composer; `None`
follows Think (`agentReasoningLevel`).

#### CUDA is opt-in until native NVIDIA validation completes
`Settings.llama_backend`: llama.cpp build for the built-in runtime: `auto`, `cuda`, `vulkan` or `cpu`.
CUDA is opt-in while native NVIDIA validation is pending.

#### Host with subdomains or full URL, comma-separated
`Settings.cotyping_excluded_domains`: Sites where autocomplete never runs: a host (subdomains included) or a
full URL, comma-separated (`cotypingExcludedDomains`).

#### Uses text above the field; on by default as on macOS
`Settings.cotyping_use_visible_context`: Use the text shown just above the field, such as the conversation
being answered (`cotypingUseVisibleContext`, on as on macOS).

#### Separate grant, off by default as on macOS
`Settings.cotyping_use_meeting_memory`: Let suggestions use relevant facts from saved meetings. A grant of
its own, off by default, as on macOS.

#### Calendar feed links are secrets in the credential store, never settings
`Settings.calendar_detection_enabled`: Calendar (macOS `AppSettings` keys). Feed links are secrets and live in
the system credential store, never here.

#### Calendar reading is off by default because contents are sensitive
`Settings.calendar_detection_enabled`: Read the user's calendars to confirm meetings and title recordings.
Off by default: calendar contents are sensitive.

#### Auto-record browser calls only with active calendar event and meeting link
`Settings.require_calendar_for_browser`: Only auto-record a browser call backed by an active calendar event
with a meeting link.

#### Agenda read and saved with matched recordings; off by default
`Settings.use_calendar_agenda`: Read the invitation agenda (notes without joining details) and save
it with calendar-matched recordings. Off by default.

#### Calendar title and invitees are only secondary context for notes
`Settings.meeting_notes_use_calendar_context`: Meeting notes may use the calendar title and invited names as
secondary context.

#### Linux reads Evolution Data Server calendars locally, no network request
`Settings.calendar_evolution_enabled`: Linux: also read calendars from Evolution Data Server, which includes
GNOME Online Accounts. Local; makes no network request of its own.

#### User's addresses identify them and skip declined invitations
`Settings.calendar_my_email_addresses`: The user's own addresses, comma-separated, so feeds can tell the user
from other attendees and skip invitations the user declined.

#### Rewrites selection in any app; off by default
`Settings.selection_actions_enabled`: Rewrite what's selected in any app (`selectionActionsEnabled`). Off by default.

#### Mac's Ctrl+Shift+W chord closes tabs here
`Settings.selection_actions_shortcut`: Ctrl+Shift+W, the Mac's chord, closes tabs and windows on these platforms.

#### Mac's speaker model choice kept so shared library round-trips
`Settings.diarization_model`: The Mac's choice of speaker model; kept so a shared library round-trips.

#### Agent notes indexing is opt-in because notes are agents' words about projects
`Settings.coding_agent_notes_enabled`: Read the notes Claude Code and Codex keep for their own later sessions
into a searchable index. Off until the person turns it on: the notes are
the agents' words about any project they worked in. The per-agent
switches and folder exclusions apply here too.

#### Overnight review on by default as on macOS
`Settings.dreaming_enabled`: The overnight review (`dreamingEnabled`), on by default as on macOS.

#### File search off until user reads notice and picks folders
`Settings.file_search_enabled`: Search chosen folders. Off until the user reads the notice and picks them.

#### Days shared; 0 means all; Mac raw values 0,30,90,365
`Settings.companion_history`: Days of history shared; 0 is all of it (the Mac's raw values: 0, 30, 90, 365).

#### Mac ModelCatalog entries kept as written
`Settings.custom_built_in_models`: The Mac's `ModelCatalog.Entry` records, kept as written.

#### Tracks one-time GitHub request: answered, summary done, active days
`Settings.github_star_dismissed`: Today's one-time GitHub request (`GitHubStarPromptStore`): answered,
a summary has finished, and the days LokalBot was used.

#### One-time LFM2.5 to Gemma E2B move done, so later LFM choice is kept; port-only
`Settings.autocomplete_default_adopted`: The one-time move of an unused LFM2.5 Autocomplete default to Gemma 4
E2B has run (`lokalbot_ai::catalog::adopt_default_autocomplete`), so
a later choice of LFM2.5 is kept. Port-only.

#### Dragged pane widths stored here; Mac keeps them in split views
`Settings.pane_widths`: Pane widths you dragged, by pane (`LokalBot.people`). The Mac keeps
these in its split views instead.

#### Last Settings page reopens; empty is Overview; port-only key
`Settings.settings_page`: The Settings page shown last, so the window opens there again
(`lokalbotv4.settings.selectedPage`, which the Mac keeps in its
defaults). Empty opens Overview. Port-only.

#### Unmodeled keys preserved so Mac-written values survive saving
`Settings.other`: Keys this port doesn't model. A library moves between computers, so
saving here must not lose what the Mac wrote.

#### Default autocomplete model is Gemma 4 E2B Base as on macOS
`Settings::default`: Gemma 4 E2B Base, as on macOS (`ModelCatalog.recommendedCotypingID`).

#### Dictation screen context off on new installs, matching Mac
`Settings::default`: Off on a new install, as on the Mac. Its decode falls back to on
only for its own older installs, and nothing here has those.

#### Learning from dictation needs both switches above it
`Settings.learns_from_dictation`: Learn from my dictation needs both switches above it (`learnsFromDictation`).

#### Boundary day stored in other keys under Mac's name
`Settings.dreaming_first_eligible_day_key`: The first local day the overnight review may read in this enabled period
(`dreamingFirstEligibleDayKey`), kept with the keys this app has no field
for, under the Mac's name.

#### Each enabled period starts yesterday, never backfilling; off clears boundary
`Settings.normalize_dreaming_boundary`: `AppState.applyDreamingSetting`: each enabled period starts at yesterday, so
an opt-in never backfills older days; off clears the boundary. Returns
whether anything changed.

#### Wrong-typed field falls back alone; rest still loads
`Settings.load`: Loads settings, falling back to defaults for anything missing or unreadable.
A field with the wrong type falls back on its own; the rest still load.

#### Try every stored key so one bad value cannot reset all settings
`Settings.load_field_by_field`: Every stored key is tried, including ones the defaults leave out
when unset (`agentReasoningLevel`): an unreadable value there
would otherwise fail the final decode and reset every setting.
Keys this port doesn't model always decode, into `other`.

#### Comma-separated as the Mac stores them
`Settings.coding_agent_excluded_folder_list`: Folders whose coding-agent sessions are never read. Comma-separated, as
the Mac stores them.

#### Enabled key alone proves nothing; needs confirmation
`Settings.coding_agent_evidence_active`: The user chose to use coding-agent sessions. The enabled key alone proves
nothing here: installs saved it as true without asking, so sessions a Mac
recorded in this library wait for that choice as well.

#### Empty until chosen since enabled defaults true unasked
`Settings.enabled_coding_agents`: The agents whose sessions may be read now. Empty until the person has
chosen: `coding_agent_evidence_enabled` defaults to true and is saved
without being asked, so on its own it proves nothing.

#### Notes depend only on per-agent switches, not session reading
`Settings.coding_agent_note_agents`: The agents whose notes are read now; empty while Read coding agent notes
is off. Notes don't depend on reading sessions, only on the per-agent
switches.

#### Plan approvals are separate entries so API-server approval never covers plans
`SubscriptionPlan`: Think backends that run on the user's own ChatGPT, Claude, Antigravity, or
Gemini plan instead of an API key (`SubscriptionPlan.swift`). Requests count
toward that plan's usage limits.

Each plan has its own entry in `approved_remote_inference_origins`. The
entries are not URL origins, so approving an API server
(`https://api.openai.com` with a key) never approves plan usage, and the
reverse: the two run under different provider terms.

#### CLI plans route through user's own signed-in CLI to its provider
`SubscriptionPlan.destination_host`: Where Think content goes. CLI-backed plans travel through the user's
own signed-in CLI installation to its provider.

#### Approval entry string identical to the Mac's
`SubscriptionPlan.consent_key`: The approval entry, the same string the Mac stores.

#### Request-level preference; account, key, workspace filters apply after
`OpenRouterDataPolicy`: OpenRouter's request-level provider preference (`OpenRouterDataPolicy`).
Account, API-key, workspace and guardrail filters apply after it.

#### Stored as Mac virtual key codes, so values must match
`CotypingAcceptKey`: Takes the next word. The Mac stores its virtual key codes, so these do too.

#### Test that missing dictation screen context setting stays off
`dictation_reads_no_window_until_the_person_chooses_it`: A settings file that doesn't mention it stays off too.

#### Test that a Mac library's saved choice is kept either way
`dictation_reads_no_window_until_the_person_chooses_it`: A Mac library's saved choice is kept either way.

#### Regression: unset agentReasoningLevel skipped per-field check, resetting all settings
`one_unreadable_value_does_not_reset_the_other_settings`: `agentReasoningLevel` is left out of the saved defaults when unset,
so it used to skip the per-field check: a level this build can't
read failed the whole decode and every setting came back default.

#### Test that API-server approval never covers a plan
`plan_approval_is_its_own_entry`: An API-server approval for the same company never covers a plan.

#### Interface language change must not alter notes language, shortcuts or consent choices
`interface_language_survives_an_existing_library_upgrade`: The same preference key is used by the macOS app. Changing the
interface must not change the language of generated meeting notes,
shortcuts or any capture/consent choice.

#### Field-by-field load path must also keep unmodeled keys
`saving_keeps_keys_this_port_does_not_model`: One typed value that doesn't parse sends loading down the
field-by-field path, which has to keep them as well.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
