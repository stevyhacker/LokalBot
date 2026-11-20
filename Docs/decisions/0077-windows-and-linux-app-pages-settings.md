# 0077. Windows and Linux: app — pages / settings

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/settings/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/advanced.rs`

#### Same command path that lokalbot-cli install-skill installs to
`cli_install_path`: Where `InstallCli` puts the command for coding agents: the path
`lokalbot-cli install-skill` installs to.

#### Uninstall removes only what the installer created
`SettingsPage::uninstall_cli`: Removes only what the installer created.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/calendar.rs`

#### Calendar links live in credential store and show only by host
Meetings → Calendar (`SettingsView.swift` "Calendar"): calendar-assisted
detection, the private links it reads (kept in the credential store and
shown only by host), Evolution on Linux, and how matches are used.

#### Saved links are read from the credential store when Settings opens
`CalendarState.links`: Saved links, read from the credential store when Settings opens.

#### Read saved links off the main thread, once
`CalendarState::load_links`: Reads the saved links off the main thread, once.

#### Meeting count matches Today; personal appointments are not meetings
`calendar_status_row`: Counted as Today lists them: personal appointments are not meetings.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/catalog.rs`

#### Settings catalog mirrors SettingDescriptor.swift
Searchable settings (`SettingDescriptor.swift`): title, category, extra
words to match, and the current value shown in results.

#### Device list has no own value; it follows the sharing switch
`details_or_off`: The device list has no value of its own: it follows the switch above it.

#### Page label differs from title, shown in results and searched; mirrors SettingDescriptor.label
`label`: Entries whose title, aliases or category contain every query word.
The setting's name on its page, where it differs from its title
(`SettingDescriptor.label`): results show it, and it is searched too.

#### Result opens the setting, or the off switch behind it
`focus_target`: The control a setting's search result opens: the setting itself, or the
switch it shows behind while that is off (`SettingDescriptor.focusTarget`).

#### Phones and tablets show other controls only while sharing is on
`focus_target`: Phones & tablets shows its other controls only while sharing is on.

#### Search still finds settings by a page's former names
`former_keys`: What a page was called before, so search still finds its settings by the
old name (`SettingsTab.formerNames`).

#### Updates check, download and install are searchable on this port
`features_missing_on_this_platform_are_not_offered`: Updates check, download and install here too.

#### Regression: searching auto-record used to miss
`punctuation_and_diacritics_fold_and_exact_titles_lead`: "auto-record" used to miss.

#### Reasoning level is its own row under Models Advanced
`a_setting_behind_a_switch_opens_the_switch`: The level is a row of its own under Models' Advanced now.

#### Old page names still find the settings they held
`settings_sit_on_the_page_that_holds_them_now`: Old page names still find what they held.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/coding_agents.rs`

#### Nothing read until the person chooses; agents' own files untouched
Day Memory → Coding agent sessions (`CodingAgentEvidenceSettings.swift`).
Nothing is read until the person has chosen, in setup or here. The saved
records can be deleted here. Notes are off until turned on after a notice.
The agents' own files stay untouched either way.

#### Row shows on only once the person has chosen
`reads_sessions`: The row reads what actually happens: on only once the person has chosen.

#### Flipping the row either way counts as the person's choice
`choose`: Flipping the row is the person's choice, whichever way they flip it.

#### Notes cover every project, so reading starts only on Turn On
`confirm_notes`: The notice before notes are read: they cover every project the agents
worked in, so reading starts only on Turn On.

#### Agent switches and excluded folders also apply to notes
`coding_agents_section`: The agent switches and the excluded folders apply to notes too.

#### Regression: setting saved true without ever being asked
`the_row_stays_off_until_the_person_chooses`: Saved as true without ever having been asked.

#### Turning off is a choice too, so it is not asked again
`the_row_stays_off_until_the_person_chooses`: Turning it off is a choice too, so it isn't asked again.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/day_memory.rs`

#### Only the first 500 characters of digest instructions are used
`DIGEST_PROMPT_LIMIT`: The first characters of the digest instructions that are used.

#### Mirrors ScreenContextCaptureMode.detail for this platform's accessibility and OCR
`mode_detail`: `ScreenContextCaptureMode.detail`, for this platform's accessibility and OCR.

#### Desktop limits are said in the page header beside their fix
`screen_status`: What this desktop doesn't allow (window pixels, the credential
store) is said in the page's header, beside its fix.

#### Recognition download is never started on its own
`screen_text_model_row`: Screen text recognition: what reads here, in which languages, and the
download that would help. Never started on its own.

#### Mirrors MemoryHealthSection.textSourceLabel
`text_source_label`: `MemoryHealthSection.textSourceLabel`.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/devices.rs`

#### Sharing starts a LAN and Tailscale listener; controls exist only while on
Settings → Phones & tablets (`CompanionSettingsView.swift`). Turning sharing
on starts a listener for paired devices on the local network and Tailscale;
everything below the switch only exists while it is on.

#### Six pixels per QR module with a four-module quiet border
`QR_SCALE`: Pixels per QR module, and the blank border a scanner needs around the code.

#### Port applies when editing ends so half-typed numbers never restart the listener
`DevicesState::subscribe`: The port applies when editing ends, so a half-typed number never
restarts the listener.

#### Port is clamped to listener range; non-numbers keep the current port
`parsed_port`: A number clamped to the range a listener may use, or the current port when
it isn't a number.

#### Release the QR code once sharing stops; it would be a dead picture
`devices_sections`: A code held after sharing stopped would be a dead picture.

#### Devices name their own platform; only known ones are translated
`platform_label`: A device names its own platform; only the known ones are translated.

#### LokalBot cannot see past a firewall, so it tells the user what to check
`firewall_note`: LokalBot can't see past a firewall, so it says what to check.

#### QR uses error level M, as on the Mac
`qr_modules`: One grid cell per module, for a code scanners read at error level M, as
on the Mac.

#### Black and white read the same in GPUI's BGRA
`qr_pixels`: Black and white read the same in GPUI's BGRA.

#### Show or clear the pairing question in Settings; called off the engine update
`pairing_prompt_changed`: Brings the Settings window up on Phones & tablets with the question a
scanning device is waiting on, or takes it away once the request is gone.
Called off the engine's update.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/dictation.rs`

#### Dictation settings mirror DictationView.swift; Try it is the header sheet
Settings › Dictation (`DictationView.swift`, `RecentDictationsViews.swift`):
under the shared header, the shortcut, what it writes and who writes it,
what shows while dictating, and a row that opens the recent dictations.
Trying it out is the header's "Try it…" sheet (`try_sheet`).

#### online means dictated text leaves this computer to be written
`Writer.online`: What is dictated leaves this computer to be written.

#### A Compose-only model is always one on this computer
`writer`: A model of its own for Compose is always one on this computer.

#### A running dictation keeps its starting settings; grants locked meanwhile
`is_working`: The dictation in progress keeps the settings it started with, so its grants
do not change under it.

#### Pasting limitation row appears only on this port
`dictation_main_sections`: What this desktop lets pasting do (port-only).

#### Remote Compose notice states everything sent with the dictated words
`dictation_main_sections`: What else travels with the dictated words, said in full.

#### Recent dictations let a lost clipboard result be copied again
`recent_dictations_section`: Recent dictations: earlier results with Copy, so one left on the
clipboard can be copied again after something else replaced it.

#### Try it pastes nothing into other apps and leaves the clipboard alone
`dictation_try`: "Try it…" (`DictationTrySheet`, `DictationView`): what still stands in
the way, then the button that starts and stops a recording, where it
stands, and the last result. Nothing is pasted into another app and
the clipboard is left alone.

#### An approved Think server receives the dictated text
`who_writes_the_text_says_where_it_runs`: A Think server that is approved receives what is dictated.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/exports.rs`

#### Backing out of first folder choice leaves the feature off, as on the Mac
`choose_folder`: Asks for a folder and saves it with `set`. Backing out of the first choice
leaves the feature off through `cancelled`, as on the Mac.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/files.rs`

#### Nothing read until Files is turned on after a notice and a folder chosen
Settings → Files (`FileSearchSettings.swift`). Nothing is read until the person
turns Files on after a notice and chooses a folder.

#### File sizes use decimal units for people
`bytes_label`: "12 MB": the way files are sized for people.

#### Folder count and estimate come from metadata; nothing is read before adding
`AddFolderSheet`: Before a folder is added: what it holds and how long its first read takes,
counted from metadata while the sheet is open. Nothing is read until the person
adds it, and adding doesn't wait for the count.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/general.rs`

#### Email is not ported, so Ask sources has no email row
`ask_sources_section`: What Ask can search, each row leading to the page that decides it
(`askSourcesSection`). Email isn't ported, so it has no row.

#### Mirrors macOS Settings General Updates
`updates_section`: Mirrors macOS Settings → General → Updates: the automatic-check
switch, the version with Check for Updates…, and the update on offer.

#### A package manager's copy has nothing to download here
`updates_section`: A package manager's copy has nothing to download here.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/header.rs`

#### Every Settings page opens with one shared header (SettingsPageHeader.swift)
How every Settings page opens (`SettingsPageHeader.swift`): the page's
icon, name and one-line description, "Try it…" where the feature has
something to try, the page's own control and its main switch where it has
them, and under them one status line for each thing to know, with the
button that fixes it. Overview has no header: it opens with what needs you.

A page fills in a [`HeaderSpec`] in `SettingsPage::header_spec`; the
window draws the header above the page's sections.

#### Opener selects a page and reveals a setting by catalog id
`Opener`: Opens a Settings page, revealing a setting on it when one is named (a
catalog id such as "settings.permissions"): what a status line's `Open`
does. Make one with [`opener`].

#### Accessory control draws before Try it and the switch
`HeaderSpec.accessory`: A page's own leading control, such as Models' "Download all". Drawn
before "Try it…" and the switch.

#### Summary overrides the category line, e.g. Dictation's shortcut
`HeaderSpec.summary`: The page's line under its name, when it is not the category's own
(Dictation names its shortcut).

#### Switch setting id lets search and links land on it
`HeaderSwitch.setting_id`: The setting it stands for, so search and links land on it, such as
"settings.cotypingEnabled". Highlighted while it is the found setting.

#### Header switch must do exactly what the old switch did, confirmations included
`HeaderSwitch.on_change`: Runs on every flip. It must do exactly what the page's own switch did
before, confirmations included: moving a control never skips one.

#### Status fixes run the same way everywhere, mirroring SettingsStatusActions.perform
`perform`: Runs a status line's fix, an Overview row's or a permission row's, the
same way everywhere (`SettingsStatusActions.perform`). `open` selects a
page and reveals a setting on it.

#### Download missing Transcribe and Think models in turn, Autocomplete's only while on
`start_downloads`: Downloads what Transcribe and Think are missing, one at a time, and
Autocomplete's model while Autocomplete is on
(`startCoreModelDownloads(includeAutocomplete:)`).

#### Cancel stops every in-flight model of the three roles
`cancel_downloads`: Stops the downloads "Download all" started: every model of the three
roles that is on its way (`cancelCoreModelDownloads`).

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/health.rs`

#### Tone says good, needs the person, deliberately idle, or neutral
`Tone`: How a value reads at a glance: running as intended, needing the person,
deliberately off or waiting, or a plain measurement.

#### Unexpected status strings ask for a look
`Tone::status`: Status strings outside both lists are unexpected, so they ask for a look.

#### Only live input is good; quiet is idle; stalls and missing tracks need a look
`Tone::audio`: Only live input is good; quiet states between meetings are idle; stalls,
recovery, degradation and a missing track need a look.

#### No permission prompts here, so list what this desktop cannot do
`missing_capabilities`: `missingPermissions`: Linux and Windows have no permission prompts, so this is
what this desktop can't do for the features that are on: seeing the window in
front, capturing it, reading text over the accessibility bus or UI Automation,
global shortcuts, and the credential store that keeps the screen image key,
as Privacy & permissions and setup read them.

#### Tone is a dot plus a word so meaning survives without color
`status`: A value in a tone: a dot and a word, the word keeping its meaning without
color. Only states that need the person are emphasized.

#### Read database values off-thread; page redraws on every engine event
`SettingsPage::refresh_health`: The page redraws on every engine event, several times a second
while recording, so what it shows from the database is read
here and not while drawing.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/meetings.rs`

#### Mirrors LanguageCode.summaryPresets with display names
`SUMMARY_LANGUAGES`: `LanguageCode.summaryPresets` with their display names.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/mod.rs`

#### Settings window layout mirrors SettingsView and SettingsSidebar in the Mac app
Settings (`SettingsView.swift`, `SettingsSidebar.swift`), in its own
window (`windows::settings`). On the left: search, the LokalBot row that
opens Overview with what needs you, then every page in its group, each
marked "Off", "Paused" or with a count where something needs fixing
(`status`). On the right: back, forward and the page's name in the
window's bar, then the page: Overview's status page, or one shared header
(`header`) above the page's sections. Search reaches every page.

#### Page order matches SettingsTab.allCases
`CATEGORIES`: Every page, in the order the window lists them: the LokalBot row
(Overview), the pages above the first heading, each heading's pages, then
Diagnostics (`SettingsTab.allCases`).

#### Icons are the Lucide glyphs closest to the Mac's symbols
`category_icon`: The page's glyph, the Lucide closest to the Mac's symbol.

#### Section ids are the rows it holds, used for search jumps
`Section.ids`: One grouped section of a category; `ids` are the rows it holds, for search jumps.

#### A header-only section draws without a panel
`Section.header`: Drawn in place of the title (a disclosure, a way back). A section
with a header and no rows is the header alone, with no panel.

#### None means read the marker file
`SettingsPage.files_access`: The Files grant as last set here; `None` reads the marker.

#### Dragging only previews; nothing changes until release and review
`SettingsPage.retention_draft`: Where the retention slider is while it is being dragged. Nothing changes
until it is let go and any review is applied.

#### Ask and dictation shortcuts avoid selection chord and system or other-app keys
`other_shortcut_problem`: What the Ask and dictation shortcuts share: not selection actions' chord,
and nothing the system or other apps hold (Ctrl+Shift+W closes tabs here).

#### Closing the window mid-recording must resume paused global shortcuts
`SettingsPage::new`: A window closed while a shortcut field records never hears the
field stop, and the global shortcuts would stay paused.

#### Global shortcuts unregister while a field records, then return
`SettingsPage::new`: Unregisters the global shortcuts while the field
records, and puts them back when it stops.

#### Global shortcuts unregister while a field records, then return
`SettingsPage::new`: Unregisters the global shortcuts while the field
records, and puts them back when it stops.

#### Global shortcuts unregister while a field records, then return
`SettingsPage::new`: Unregisters the global shortcuts while the field
records, and puts them back when it stops.

#### Dragging retention previews only; shortening goes through review
`SettingsPage::new`: Dragging only previews: shortening has to go through the review.

#### Page opened from CLI or tray reveals the setting after window opens
`SettingsPage::new`: Opened from the CLI or tray with its window closed.

#### A drag in progress keeps its slider position
`SettingsPage::on_data_changed`: A drag in progress keeps its place.

#### A row's subpage closes when another page is selected
`SettingsPage::select_category`: A row's page belongs to the Settings page that opened it.

#### A setting behind a switch opens that switch instead
`SettingsPage::jump_to`: Opens a setting from search: its category, scrolled to and highlighted. A
setting that shows only behind a switch opens that switch instead.

#### Open the try-out sheet after the update; page may still be opening
`SettingsPage::jump_to`: After this update: the page may still be opening its window.

#### Row subpage opens for its settings; page settings close it (revealFocusedSetting)
`SettingsPage::jump_to`: A setting a row's page holds opens that page; one on the page
itself closes it (`revealFocusedSetting`).

#### Header switch sets the setting with no confirmation, as before
`SettingsPage::header_spec`: The switch does what the page's own switch did: it sets the
setting, with no confirmation, as before.

#### Row subpages and Models pages replace the shared header with their own
`SettingsPage::replaces_header`: What opens in place of the shared header: a row's page starts with
its way back (`SettingsSubpageBar`), and Models' own pages draw
theirs. `None` keeps the header.

#### Free space measured off main thread at most every 30 seconds
`SettingsPage::refresh_free_space`: The free space where the models go, for the header's download line
("They need 3.7 GB, and this PC has 79 GB free"), measured off the main
thread at most every 30 seconds.

#### Library size and free space measured off-thread at most every 30 seconds
`SettingsPage::refresh_library_size`: The library's size without its models, and the free space where the
models are, measured off the main thread at most every 30 seconds.

#### Permissions read as setup reads them so the two agree
`SettingsPage::status`: Read the way setup reads it (`crate::access`), so the two agree.

#### Search field takes its own clicks; the strip around it moves the window
`SettingsPage::render_categories`: The field takes its own clicks; the strip
around it moves the window.

#### Top bar is the window title bar: moves the window and holds its buttons
`SettingsPage::render_top_bar`: Back and forward through the pages visited, then the page's name
(`SettingsView.topBar`). It is the window's title bar: it moves the
window and holds its buttons.

#### Arrows take their own clicks; the rest of the bar moves the window
`SettingsPage::render_top_bar`: The arrows take their own clicks; the rest of the
bar moves the window.

#### Occlude so presses do not reach the bar and start a window move
`SettingsPage::render_top_bar`: The bar under them must not see their presses:
it would start moving the window.

#### Re-read computer access periodically; it can change while Settings is open
`SettingsPage::render`: What this computer allows can change while Settings is open (an
extension installed, a service started): read it again now and then.

#### First-drawn page has no layout, so scroll again next frame
`SettingsPage::render`: A page drawn for the first time has no layout to scroll in yet.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_browse.rs`

#### Adding a model edits customBuiltInModels only; search always uses huggingface.co
Add a model from Hugging Face (`ModelImportSheet`). Adding only edits
`customBuiltInModels`; the model then appears in Think's and Autocomplete's
choices, and downloads when chosen. Search goes to huggingface.co whichever
download source is chosen.

#### Each search bumps generation so a newer search wins
`BrowseState.generation`: Bumped by each search, so a newer one wins.

#### Both apps read the record; added model must parse as a catalog entry
`an_added_file_becomes_a_usable_model`: Both apps read the record: what's added here parses as a catalog entry.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_checks.rs`

#### Checks send only sample content, never meeting, screen or clipboard data
`disclosure`: What the checks send where. Text only ever names sample content.

#### Checks use saved values, so unsaved edits disable Check connection
`connection_check_row`: "Check connection", its status and what a failure means, below the
connection form. Checks use the saved values, so unsaved edits disable it.

#### A server on this computer keeps the sample here
`the_disclosure_names_where_samples_go`: A server on this computer keeps the sample here.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_options.rs`

#### Models option rows port ModelSupportingSettings and remoteTranscriptionSetup
The options behind Models' rows (`ModelSupportingSettings.swift`,
`ModelPickerSheet.remoteTranscriptionSetup`): Read aloud's voice, speed and
sample, the transcription language and vocabulary, the transcription server
and where downloads come from.

#### Speed label matches Mac's %.2g× two significant digits
`speed_label`: `speechSpeed` shown like the Mac's `%.2g×`, two significant digits: 1×,
1.2×, 0.95×, 0.5×.

#### Approval checkbox draft applies to origin in server_origin
`OptionsState.server_consent`: The approval checkbox's draft, for the origin in `server_origin`.

#### Ask credential store when form first shows; locked store may prompt
`OptionsState.server_key_saved`: Asked of the credential store when the form first shows, since a locked
store may prompt.

#### Slider rounds to 0.05 steps as the Mac stores them
`OptionsState.subscribe`: Slider steps as the Mac stores them: 1.05, not 1.0499999.

#### Mirrors ModelDownloadSourcePicker, used in Settings and onboarding
`download_source_row`: "Download models from" (`ModelDownloadSourcePicker`), in Settings and onboarding.

#### Approval belongs to one origin; reload saved choice on URL change
`SettingsPage.server_draft_changed`: The URL changed: an approval belongs to one origin, so show the saved
choice for a newly entered server rather than carrying the toggle over.

#### Approval list replaced whole so unchecking revokes the origin
`SettingsPage.use_transcription_server`: Saves the typed key and the approval, then switches once the server is
allowed to receive audio. The approval list is replaced as a whole, so
unchecking revokes the origin.

#### Mirrors ModelTranscriptionOptionsSheet on the Mac
`SettingsPage.transcription_options_page`: Language & vocabulary (`ModelTranscriptionOptionsSheet`).

#### Read saved-key state off main thread; locked store prompts
`SettingsPage.load_server_key_state`: The server form (`remoteTranscriptionSetup`).
Reads whether the transcription server has a key saved, off the main
thread: a locked credential store answers only after its prompt.

#### Key saved or forgotten meanwhile is the newer answer
`SettingsPage.load_server_key_state`: A key saved or forgotten meanwhile is the newer answer.

#### Mirrors remoteTranscriptionAccess: audio destination and per-origin approval
`SettingsPage.server_access`: Where the audio goes and its per-origin approval (`remoteTranscriptionAccess`).

#### Sample text is spoken by an English voice in every language
`read aloud sample`: Spoken by an English voice in every interface language.

#### Mirrors ModelDownloadsView.speechRow; shown only once there is something
`SettingsPage.read_aloud_storage_row`: Read aloud's model in Model Storage, once there is something to show
(`ModelDownloadsView.speechRow`).

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_overview.rs`

#### Where Mac model-page features and port-only parts live on this page
Settings › Models' first page (`ModelStackOverviewView`,
`ModelsPagePresentation`): what each of the three models does, which one
it is, where it runs, what it weighs and whether it is ready, under the
Model set; then rows that open the downloaded models, the online services
and the other models; then Advanced, folded. The header carries "Download
all" (`header::start_downloads`).

Port-only parts and where they went: the llama.cpp backend (Automatic,
Vulkan, CUDA, CPU) and its runtime download sit under Advanced; download
mirrors are Advanced's "Download models from"; Ollama, OpenAI-compatible
servers and the ChatGPT and Claude plan sign-ins are Online services;
Hugging Face models are under Think's "Change…"; the transcription server
and language are under Transcribe's "Change…"; screen text recognition
files and the runtime's libraries are listed in Downloaded models.

#### Search and links landing on these settings open Advanced
`ADVANCED_SETTINGS`: The settings that are rows under Advanced: search and links that land on
one open it (`ModelStackOverviewView.advancedSettings`).

#### Mirrors ModelRoleRow.Place on the Mac
`Place`: Where a role's model runs (`ModelRoleRow.Place`).

#### Online means a server or plan receives what the model reads
`Place::Online`: A server or plan that receives what the model reads.

#### NotSetUp is a chosen server or plan not yet usable
`Place::NotSetUp`: A server or plan that is chosen and not usable yet.

#### Mirrors ModelRoleRow.Chip on the Mac
`Chip`: The state beside a role's model (`ModelRoleRow.Chip`).

#### None while the download has not reported progress
`Chip::Downloading`: `None` while the download has not said how far it is.

#### Mirrors ModelRoleRow on the Mac
`RoleRow`: One row under "What each model does" (`ModelRoleRow`).

#### Size shown only while the model runs here and downloads
`RoleRow.bytes`: What the model weighs, while it runs here and downloads.

#### Autocomplete model missing while Autocomplete off is not a warning
`RoleRow.needed`: False for Autocomplete's model while Autocomplete is off: nothing
waits for it, so its missing download is not a warning.

#### Problem text uses the downloader's or check's own words
`RoleRow.problem`: Why a download stopped or a check failed, in the downloader's or the
check's own words.

#### Unset choice shows as Online; the chip says the rest
`RoleRow.place_text`: "On this PC · 2.7 GB" or "Online · example.com". A choice that is not
set up yet is an online one; its chip says the rest.

#### Server on loopback address counts as this computer; nothing leaves
`place`: Where a role's model runs. A server on this computer's own address counts
as this computer: nothing leaves it.

#### Sizes match the header's download line, including runtime and speech files
`role_bytes`: What the role's model weighs when it downloads to this computer, from
the sizes the header's download line uses: Transcribe with the files that
find speech, Think with the runtime that runs it.

#### Mirrors ModelsPagePresentation.init
`role_rows`: The three rows, from the status the header uses, the downloads and the
last checks (`ModelsPagePresentation.init`).

#### Mirrors ModelStackPreset.matching
`model_set`: The preset the choices match, if any (`ModelStackPreset.matching`).

#### Set size is None when Autocomplete runs on a server
`preset_bytes`: What a set's three models weigh together with it applied. `None` when
one of them does not download here: Autocomplete on a server
(`ModelsPagePresentation.bytes(of:)`).

#### Compact layout below 960 px, matching Mac ViewThatFits
`SettingsPage.models_overview`: Below this the row stacks its model under its name (`ViewThatFits`).

#### Choosing a set opens a review before anything is applied
`SettingsPage.model_set_row`: The set the three models belong to, as a menu. Choosing one opens its
review, which lists the changes and the download before anything is
applied (`modelSetRow`).

#### Chip tooltip shows when the model last answered its check
`SettingsPage.chip`: The chip, with when the model last answered its check as its tooltip.

#### Each server is set up where it is chosen
`SettingsPage.review_connection`: Each server is set up where it is chosen: Think's on Online services,
Transcribe's on its server page, Autocomplete's on its own page.

#### Advanced stays folded until opened or search lands in it
`SettingsPage.models_advanced`: Advanced, folded until opened or until search lands on one of its
settings.

#### Folding clears the highlight that kept Advanced open
`SettingsPage.models_advanced`: Folding drops the highlight that kept it open.

#### llama.cpp runtime row is port-only
`SettingsPage.llama_row`: The llama.cpp runtime that runs Think, Autocomplete and search here:
its backend and its download (port-only).

#### Runtime downloaded but GPU setup check failed shows Not ready
`SettingsPage.llama_row`: Downloaded, but the setup GPU check failed: no download is left.

#### Check again repeats GPU check and repairs libraries without full download
`SettingsPage.llama_row`: Setup repeats the GPU check and repairs
missing libraries without a full download.

#### Mirrors ModelStorageRow on the Mac
`SettingsPage.storage_row`: Where the model files are and what is loaded now (`ModelStorageRow`).

#### Models in use can't be removed; port never deletes a model in use
`SettingsPage.downloaded_models_page`: Downloaded models (`ModelDownloadsView`): every model file here with
what it is for and its size, the downloads under way, the runtime's
libraries and Read aloud's voice. A model the settings don't use can be
removed; one in use stays (the port never deletes a model in use).

#### Mirrors ModelOtherModelsView on the Mac
`SettingsPage.other_models_page`: Other models (`ModelOtherModelsView`): Dictation's Compose, Read aloud
and search by meaning, each where it is set.

#### Compose uses Think unless a built-in model is chosen for it
`SettingsPage.other_models_page`: Compose writes with Think unless a built-in model is chosen for it.

#### Mirrors SettingsDrillRow and moreRow on the Mac
`drill_row`: A row that opens another page: its name, an optional line under it, an
optional value and a chevron (`SettingsDrillRow`, `moreRow`).

#### Row takes the pointer; chevron button gives Tab and Return access
`opener_button`: The chevron at a row's end, as a button: the row takes the pointer, and
this is where Tab and Return reach it.

#### Stop propagation so the row beneath doesn't run the action again
`opener_button`: The row under it would run it again.

#### Blocked server shows blocked chip whatever the engine reports
`a_server_is_online_once_approved_and_not_set_up_before`: Blocked: the chip says so, whatever the engine reports.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_setup.rs`

#### Replacement is prepared first; settings change only once ready
Safe model switching (`ModelSetupController`, `ModelSelectionPatch`): the
replacement is prepared first and the settings change only once it is ready,
so the current models stay active until then.

#### Patch is narrow: never overwrites privacy choices, credentials or concurrent edits
`ModelPatch`: A deliberately narrow patch: applying or undoing a switch never overwrites
privacy choices, credentials or unrelated edits made during a download.

#### Speech detection and speaker separation run locally even with a server
`ModelPatch.needs`: Speech detection and speaker separation run here even with a server.

#### Recheck approval at the end; it can be revoked during downloads
`ModelPatch.blocked_reason`: Why the target can't be used now: a transcription server or Think server
that isn't approved. Checked again at the end, because an approval can be
revoked while the replacement's downloads run.

#### Refuse activation if custom models or server changed during preparation
`ModelPatch.preparation_context_matches`: Ids alone don't identify a custom model's files or a server. Activation
is refused if either changed while the replacement was preparing.

#### Pending switch title is read by lokalbot-cli models status
`ModelSetup.pending_title`: The switch under way, for `lokalbot-cli models status`.

#### Clear earlier attempt's download failures before retrying
`ModelSetup.apply`: An earlier attempt's failure says nothing about this one.

#### Cancelling keeps selection; running downloads continue
`ModelSetup.cancel`: Keeps the current selection. Downloads already running continue.

#### Undo reruns preparation because old files may have been removed
`ModelSetup.undo`: Goes through the same preparation: the old files may have been removed
since the switch.

#### Mirrors ModelSetupFeedback strip on the Mac
`SettingsPage.model_setup_feedback`: The strip above the roles while a switch runs, failed or just finished
(`ModelSetupFeedback`).

#### A Think approval doesn't authorize sending audio
`unapproved_servers_are_refused`: A Think approval doesn't send audio.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/models.rs`

#### Port of ModelsView and ModelConnectionsView; catalog sources for names and sizes
Models (`ModelsView.swift`, `ModelConnectionsView.swift`): the model
catalog helpers, the pages Models opens, the "Change…" menus and Online
services (the servers and plan sign-ins Think can use, and what is
approved to receive data). The first page is `model_overview`.

Names and sizes come from the catalogs: `lokalbot_ai::catalog` for text
models, `lokalbot_speech::models` for speech, `lokalbot_ai::runtime` for
the llama.cpp binaries.

#### Must equal lokalbot_engine RUNTIME_ID
`RUNTIME_ID`: The engine's id for the llama.cpp binaries (`lokalbot_engine` `RUNTIME_ID`).

#### In-use set includes engine meeting, dictation, search, screen text needs
`models_in_use`: Model ids the current settings use on this PC: the engine's meeting,
dictation, search and screen text requirements, and Autocomplete's model
while autocomplete is on.

#### Read aloud voice has its own row and no setting turns it off
`unused_models`: Read aloud's voice has its own row, and no setting turns it off.

#### Presets leave Autocomplete's lighter CPU-suited model unchanged
`Preset.models`: Transcribe and Think model ids (`lokalbot_ai::catalog::PRESETS`).
Autocomplete keeps its own model here: its lighter default suits
suggestions on a CPU, and a preset should not swap it unasked.

#### Mirrors ModelStackOverviewView
`ModelsPage::Active`: What each model does, More and Advanced (`ModelStackOverviewView`).

#### Mirrors ModelRemoteOverview and ModelConnectionsView
`ModelsPage::Connections`: Online services: what is approved, then the connections
(`ModelRemoteOverview`, `ModelConnectionsView`).

#### Mirrors ModelDownloadsView
`ModelsPage::Downloaded`: The models on this computer (`ModelDownloadsView`).

#### Mirrors ModelOtherModelsView
`ModelsPage::Other`: Dictation's Compose, Read aloud and search by meaning
(`ModelOtherModelsView`).

#### Mirrors ModelSpeechSettingsSheet
`ModelsPage::ReadAloud`: Voice, speed and the sample (`ModelSpeechSettingsSheet`).

#### Mirrors ModelTranscriptionOptionsSheet
`ModelsPage::TranscriptionOptions`: `ModelTranscriptionOptionsSheet`.

#### Mirrors ModelPickerSheet.remoteTranscriptionSetup
`ModelsPage::TranscriptionServer`: `ModelPickerSheet.remoteTranscriptionSetup`.

#### Mirrors ModelChecksSheet
`ModelsPage::Checks`: `ModelChecksSheet`.

#### Mirrors ModelImportSheet
`ModelsPage::Browse`: `ModelImportSheet`.

#### Mirrors Mac key settings.models.advancedOpen
`ModelsState.advanced_open`: Advanced, under More, is open (`settings.models.advancedOpen`).

#### Follow external connection changes unless the user is editing
`ModelsState.sync`: Follows connection settings changed elsewhere, unless the user is editing.

#### Ask Think server about reasoning levels once per model
`SettingsPage.look_up_reasoning`: Asks the Think server what the selected model accepts, once per model; the
picker shows the answer when it comes (`ModelStackOverviewView`).

#### Change menu prepares model before switch; Autocomplete servers on own page
`SettingsPage.change_button`: "Change…" beside a role (`ModelPickerSheet`): the models to choose
from, then what sets the role up beyond its model. A model is
prepared before the switch, so the current one stays until then
(`ModelSetup`). Autocomplete's servers are set up on its own page.

#### Show only accepted reasoning levels; unsupported stored level shows its mapping
`SettingsPage.reasoning_control`: How long Think reasons (`ModelStackOverviewView.reasoningRow`): only
the levels the selected model accepts; a stored level it lacks shows
as the one it maps to (`ReasoningSupport`).

#### Mirrors budgetRow on the Mac
`SettingsPage.budget_control`: Think processing budget as a menu (`budgetRow`).

#### A plan is used only once its own consent is on
`SettingsPage.connections`: A plan is used only once its own consent is on.

#### Approvals list only revokes; nothing is approved or chosen here
`SettingsPage.approvals_section`: What is approved to receive data, each with Revoke… and what it
covers (`ModelRemoteOverview`). Nothing is approved or chosen here.

#### Listing queries saved server, which must already be approved
`SettingsPage.ollama_model_list`: "List server models" and the picker it fills (`refreshOllama`). It asks the
saved server, which must already be allowed to receive context.

#### Discard Ollama list answer if the server changed meanwhile
`SettingsPage.ollama_model_list`: The server changed meanwhile: this answer is about another one.

#### Catalog setting ids let search and links land on a role
`role_setting`: The catalog setting a role's row stands for, so search and links land on it.

#### Mirrors ModelSettingsPresentation.assistantName
`think_name`: Think's model as people know it: a built-in model, a server's model or the
server, or a plan (`ModelSettingsPresentation.assistantName`).

#### Recheck in-use at confirm time; settings may change while dialog open
`confirm_remove`: Settings may have changed while the dialog was open.

#### Mirrors SubscriptionPlan.approvalDisplayName on the Mac
`origin_display_name`: An approved Think origin as people know it: a plan by its name and
host, a server by its origin (`SubscriptionPlan.approvalDisplayName`).

#### Mirrors ModelConnectionsView notice of what approval covers
`remote_processing_notice`: What approving a Think server covers (`ModelConnectionsView`).

#### Mirrors ModelOverviewSections notice under approved origin
`approved_origin_notice`: Under an approved origin in Overview (`ModelOverviewSections`).

#### Revoking audio leaves a Think approval for same server intact
`revoke_audio_origin`: Audio stops going there. A Think approval for the same server stays apart.

#### Think approval must name what actually leaves, including screen text
`the_think_approval_names_what_is_sent`: The Think approval names what actually leaves: digests send screen text.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/overnight_review.rs`

#### Mirrors SettingsView.dreamingSection for overnight review
Settings → Daily review → Overnight review (`SettingsView.dreamingSection`):
the switch and hour, Review now, the projects and goals it keeps, Clear work
memory, and what the review uses.

#### Reviews restart from today so cleared week isn't re-reviewed into memory
`SettingsPage.clear_work_memory`: Reviews start again from today, so the week before the clear isn't
reviewed straight back into memory.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/overview.rs`

#### Overview is a status page; nothing here turns features on
Settings → Overview, opened from the LokalBot row at the top of the list
(`SettingsOverview.swift`). A status page: what needs you, each with its
own fix, then where your data is, the keyboard shortcuts and the version.
Features are turned on and off on their own pages, beside what explains
them and asks for consent, so nothing here turns anything on.

#### Shortcuts open their page; Quick Recall in-app Ctrl+K has none
`shortcut_rows`: The keyboard shortcuts Overview lists: each opens the page that sets it,
and one that is off says so. Quick Recall inside LokalBot (Ctrl+K) has
no page.

#### Fix button runs actions the same way as a header's
`SettingsPage.fix_button`: The button of a row's fix, run the same way as a header's.

#### Learned items await review but block nothing
`SettingsPage.learned_row`: What LokalBot learned waits for a look, but stops nothing from working.

#### Overview shows contents; Privacy page shows folder path
`SettingsPage.library_row`: Where the library is and how much it holds, with a way to open it.
Overview says what is in it; Privacy & permissions names the folder
(`SettingsLibraryRow`).

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/personal_context.rs`

#### About you page: nothing reads saved file until page opens
Settings → About you (`PersonalContextSettings`): learned items waiting
for review, what LokalBot keeps about the person grouped by kind, the learning
switches, and whether agents can read the shared items. Every item can be
edited or forgotten here. Nothing reads the saved file until this page opens.

#### Show five suggestions before Show more so kept items stay in view
`COLLAPSED_SUGGESTION_LIMIT`: Suggestions shown before "Show N more", so kept items stay in view.

#### Grant marker is also read for Privacy & Data
`PersonalState.access_on`: The grant's marker, also read for Privacy & Data.

#### Reload personal store when a newly available key can open it
`load`: A key that has only just become available opens what was unreadable.

#### Mirrors PersonalContextSettings.agentSummary
`agent_summary`: `PersonalContextSettings.agentSummary`.

#### Personal context grant is separate; agents also need per-item sharing
`SettingsPage.personal_access_row`: The Personal context grant, separate from meeting and screen access. Agents
also need each item marked Share with Agents.

#### Forgetting everything also deletes unread dictation learning log
`SettingsPage.personal_context_sections`: Dictation not yet read goes too.

#### Mirrors PersonalClaimEditor; dialog stays open with reason on save failure
`ClaimEditor`: Add or edit one claim (`PersonalClaimEditor`). The dialog stays open with the
reason when it can't be saved.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/plans.rs`

#### Plan sign-in, approval and model are separate; sign-in alone never sends context
Think on a ChatGPT, Claude, Antigravity, or Gemini plan
(`SubscriptionPlanSetupView.swift`): the account, the model and the plan's
own consent, shown under Settings → Models → Connections. Signing in,
approval and the model are separate steps: a sign-in alone never lets
context leave this PC.

Also the OpenRouter provider data policy and the Anthropic API note shown
with the OpenAI-compatible connection (`ModelConnectionsView.swift`).

#### Claude Code aliases follow the newest model of each family
`CLAUDE_CHOICES`: Claude Code's aliases, which follow the newest model of each family.

#### Keep saved model visible when list drops it, not silently change
`SettingsPage.chatgpt_model_picker`: A saved model the list no longer offers stays visible instead of
silently changing.

#### Mirrors SubscriptionPlanConsentSection notice of what approval covers
`plan_consent_notice`: What approving a plan covers (`SubscriptionPlanConsentSection`).

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/privacy.rs`

#### Privacy page; retention, exclusions and agent access moved to other pages
Privacy & permissions (what LokalBot may use on this computer and what
leaves it), and the sections that moved out of the old Privacy & Data:
screen retention and capture exclusions (now on Screen & activity) and
external agent access (now on AI agents).

#### Mirrors AgentKindAccessSection shown on page of what it reads
`AgentKind`: One kind of agent access, shown again on the page of what it reads
(`AgentKindAccessSection`).

#### Same switch as on Privacy & Data, shown where read
`SettingsPage.agent_kind_section`: The same switch as on Privacy & Data, on the page it reads from.

#### Mirrors FilesAccessManager; Files grant keeps its folder list
`SettingsPage.set_files_access`: The Files grant, with the folder list it keeps (`FilesAccessManager`).

#### Agent notes grant is a marker; notes found only while reading is on
`SettingsPage.set_agent_notes_access`: The Agent notes grant: only a marker. Agents find notes only while Read
coding agent notes is on, because turning that off deletes the copy.

#### Privacy page is the one place for use and leaving; PRIVACY.md is contract
`SettingsPage.privacy_sections`: Privacy & permissions (`SettingsPrivacySections`): the one place
that shows what LokalBot may use on this computer and what leaves it.
Each permission says which features use it and where it stands; each
server that receives something is listed with the control that
revokes it; sharing with agents and with phones is summed up and opens
its own page, where its consent lives. PRIVACY.md is the contract for
every sentence here.

#### Mirrors retentionSection, now on Screen & activity
`SettingsPage.retention_section`: Screen memory retention (`retentionSection`), on Screen & activity.

#### Turning off keep-forever deletes text so it goes through review
`SettingsPage.retention_section`: Turning this off deletes text, so it goes through the review.

#### Mirrors agentAccessSection, moved to AI agents with same switches
`SettingsPage.agent_access_section`: What external agents may read or change (`agentAccessSection`), on
AI agents. The switches are the same as before the move.

#### Show items row only once a grant exists for them
`SettingsPage.agent_access_section`: The way to the items, once there's a grant for them to go through.

#### Agents search only folders chosen under Files
`SettingsPage.agent_access_section`: Agents can search only the folders chosen under Files.

#### Agents find notes only while coding agent notes are being read
`SettingsPage.agent_access_section`: Agents find notes only while they are being read.

#### Mirrors exclusionsSection, now on Screen & activity
`SettingsPage.exclusions_section`: Capture exclusions (`exclusionsSection`), on Screen & activity.

#### Mirrors permissionRow; names features using a permission, says when unused
`SettingsPage.permissions_section`: Every permission this desktop has, with its real state and its fix
(`SettingsPrivacySections.permissionRow`). Features that are on and
use one name it; one that nothing uses now says so.

#### Agent and phone sharing is agreed to on its own page
`SettingsPage.leaves_section`: Sharing with agents and phones is agreed to on its own page.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/remembered_people.rs`

#### Mirrors SpeakerVoiceProfileManager for encrypted voice profiles
"Remembered people" (`SpeakerVoiceProfileManager`): rename or forget the
encrypted voice profiles naming a speaker creates.

#### A failed deletion must not read as done
`RememberedPeople delete error`: A deletion that didn't happen must not read as done.

#### Split borrow: each row reads only its person
`RememberedPeople.render`: Split borrow: rendering a row reads only this person.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/resource_monitor.rs`

#### Resource monitor refreshes every 2 seconds while showing
Resource Monitor in Settings → Diagnostics (`ResourceMonitorSection`): a live
readout of LokalBot and its helpers, updated every 2 seconds while it shows.

#### Memory uses binary units (1024-based)
`memory`: 1.0 GB or 512 MB, in the binary units memory is counted in.

#### Mirrors memorySummary line under Model Storage
`memory_summary`: The line under Model Storage (`memorySummary`).

#### Polling stops itself once Advanced is no longer showing
`SettingsPage.start_resource_polling`: Starts the readout; it stops itself once Advanced is no longer showing.

#### Mirrors systemSection: five newest generations or none
`SettingsPage.resource_monitor_section`: `SettingsView.systemSection`: the five newest, or that there are none.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/retention_review.rs`

#### Reduced retention opens review first; policy unchanged until applied
The reviewed cleanup behind retention (`RetentionSettingsControls.swift`):
shortening how long screen context lasts, or stopping keeping screen text
forever, opens this review first. The policy stays unchanged until it is
applied, and what it lists is exactly what goes.

#### Only changes that delete data need review
`needs_review`: A change that deletes something needs a review; one that keeps more doesn't.

#### Slider only previews; reset returns to policy in force
`SettingsPage.reset_retention_draft`: Back to the policy in force: the slider only ever previewed a change.

#### Policy is set only once its cleanup has run
`SettingsPage.apply_retention_review`: The policy is set only once its cleanup has run.

#### Only Cancel and Apply close review so Cancel resets slider
`retention review dialog`: Only Cancel and Apply end the review: Cancel puts the slider
back, which Esc, the X and a click outside would skip.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/routines.rs`

#### Routines are fixed local renderers writing Markdown to chosen folder
Day Memory → Routines (`SettingsView.routinesSection`): fixed local renderers
that write Markdown into a folder the person chooses.

#### Weekday numbers follow the Mac: 1 is Sunday
`weekday_name`: The Mac's weekday numbers: 1 is Sunday.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/status.rs`

#### Settings status derives from real state only, mirroring SettingsStatus.swift
What the Settings window says about the state of each feature
(`SettingsStatus.swift`): the "Off" and "Paused" marks and count badges in
its list, what needs the person on Overview, each permission's row on
Privacy & permissions, and the status lines under every page's header.
Derived from real state and nothing else, so each of those places says
the same thing. Kept apart from drawing so it can be tested.

Linux and Windows have no permission prompts like macOS. A permission here
is what this desktop allows LokalBot ([`crate::control::permissions`]):
its real state, which features that are on use it, and the one fix that
exists, if any (Windows' microphone switch, the calendar links).

#### Need tone means the person must act: amber with warning sign
`Tone::Need`: Something the person has to do: amber, with a warning sign.

#### Ok tone means working, shown as a green dot
`Tone::Ok`: Working: a green dot.

#### Quiet tone means off or already waiting: gray
`Tone::Quiet`: Off, or waiting on something that is already under way: gray.

#### Online tone marks data leaving this computer: amber with globe
`Tone::Online`: Something leaves this computer: amber, with a globe.

#### Progress carries an optional 0-1 fraction when known
`Tone::Progress`: Under way, with how far along it is when that is known (0–1).

#### Status button, Overview row and Privacy row share one fix behaviour
`StatusAction`: What a status line's button, an Overview row and a Privacy & permissions
row do, so each fix works the same way everywhere.

#### Permission fix goes to system switch, calendar links or Privacy row
`StatusAction::Permission`: Where a permission is decided (`permissions::request`): the system's
own switch where it has one, the calendar links, or its row on
Privacy & permissions.

#### Status line mirrors SettingsStatusLine: state plus the one fixing control
`StatusLine`: One line under a Settings page's header: whether the feature works, and
when it does not, the one control that fixes it (`SettingsStatusLine`).

#### Button title is a catalog key overriding the action default
`StatusLine.action_title`: The button's title (a catalog key), when it is not the action's own.

#### Button title is returned already translated
`StatusLine::button_title`: The button's title, already translated.

#### Buttons fix something; links only navigate
`StatusLine::is_link`: Buttons fix something; links only take you somewhere.

#### Permission names match what `permissions request` accepts
`Permission.name`: `microphone`, `accessibility`, …, as `permissions request` takes them.

#### Checked is false where state is unreadable before use, like setup
`Permission.checked`: False where nothing can be read before the feature is used, the way
setup leaves it unclaimed too (`crate::access`).

#### Needed-by lists enabled features, already translated
`Permission.needed_by`: The features that are on and use it, already translated.

#### Access mirrors SettingsStatus.Access
`Access`: Where a permission stands (`SettingsStatus.Access`).

#### Missing means an enabled feature uses it and desktop denies it
`Access::Missing`: A feature that is on uses it, and this desktop does not allow it.

#### NotNeeded means denied but no enabled feature uses it
`Access::NotNeeded`: Not allowed, and nothing that is on uses it.

#### Unchecked means state cannot be read before use, as microphone
`Access::Unchecked`: Nothing can be read before it is used (the microphone).

#### Downloading carries a 0-1 fraction when known
`ModelState::Downloading`: On its way, with how far along when that is known (0–1).

#### Attention covers unusable servers and failed downloads
`ModelState::Attention`: A server that can't be used yet, or a download that failed.

#### Size is set only when a download is needed and size known
`ModelInfo.bytes`: What its download weighs, when one is needed and its size is known.

#### Servers have nothing to download
`ModelInfo.downloads`: False for a server: nothing downloads.

#### Runtime ships with Think; other roles share it, so not sized
`models`: The runtime comes with Think; another role shares it.

#### Agent read kinds count is bounded by AGENT_READ_KINDS
`StatusInput.agent_kinds`: The kinds of data external agents may read, of [`AGENT_READ_KINDS`].

#### Failed-check line opens the page that runs checks, as on Mac
`MODEL_CHECKS_FOCUS`: The setting a failed check's line opens: the page that runs the checks
(`SettingsStatus.modelChecksFocus`).

#### Five agent read kinds must match AgentReadAccess.Kind on Mac
`AGENT_READ_KINDS`: `AgentReadAccess.Kind`: meetings, screen memory, personal context, files
and agent notes.

#### RowState mirrors SettingsStatus.RowState
`RowState`: A list row's mark (`SettingsStatus.RowState`).

#### Paused means on but blocked by missing permission or model
`RowState::Paused`: On, but blocked by a missing permission or model.

#### A need is fixed and badge-counted on its page
`Need::page`: The page where it is fixed, which carries the count badge.

#### Missing means needed by something enabled and not allowed
`SettingsStatus::missing_permissions`: Needed by something that is on, and not allowed.

#### Dictation try blockers ignore whether the shortcut is on
`SettingsStatus::dictation_try_blockers`: What stops trying dictation in its sheet: the microphone and the
Transcribe model, said as the page's own lines say them, whether or
not the shortcut is on (`DictationTrySheet.blockers`).

#### Autocomplete model required only while Autocomplete is on
`SettingsStatus::required_models`: Transcribe and Think always; Autocomplete's model only while
Autocomplete is on.

#### Fraction defined only when every size and progress is known
`SettingsStatus::download_fraction`: 0–1 across the models that are downloading, when every size and
progress is known.

#### Download-all size is None when nothing missing or size unknown
`SettingsStatus::bytes_to_download`: What every model that still has to arrive weighs together, for the
header's "Download all" button. `None` when nothing is missing or a
size is unknown.

#### Status lines are ordered most pressing first
`SettingsStatus::lines`: The status lines under a page's header, most pressing first.

#### Header button downloads all; first line keeps button during Cancel
`SettingsStatus::model_lines`: The header's own button downloads them all. While it shows
Cancel for a running download, the first line keeps the button.

#### Stored size uses catalog sizes announced with the download
`SettingsStatus::stored_bytes`: What the models that are here weigh, from the catalog sizes the
download was announced with.

#### Skip unavailable reason when Accessibility row already says it
`SettingsStatus::autocomplete_lines`: Accessibility's row already says it when that is the reason.

#### Meetings names each missing model; first line's button downloads all
`SettingsStatus::meeting_lines`: Which ones, each by name; the first line's button downloads them all.

#### One not-downloaded sentence per model, never joined, matching Mac
`SettingsStatus::missing_each`: "X isn’t downloaded yet." for each model: the Mac's sentence names one
model, so several are never joined into one "isn’t".

#### Think host line covers Compose dictation; other servers named separately
`think_host`: The server Think sends to, while its connection is allowed: what Compose
dictation sends there too. The transcription and autocomplete servers are
named on their own lines.

#### Library size walk runs off the main thread; libraries are huge
`library_bytes`: What the library holds without the downloaded models
(`SettingsLibrarySize`): a long-used library has many thousands of files,
so call it off the main thread.

#### Visiting the already-shown page changes no history
`PageHistory::visit`: A page chosen from the list, a search result or a link. Choosing the
page already shown changes nothing.

#### Denied permission unused by enabled features is not a need
`tests: missing permission needs`: Not allowed, but nothing that is on uses it.

#### Two missing models never share one 'isn't downloaded' sentence
`several_missing_models_are_never_one_isnt`: The Mac's "%@ isn’t downloaded yet." names one model; two never share
one "isn’t", even before the free space is known.

#### A failed check is a line but never a badged need
`a_failed_check_is_a_line_that_opens_the_checks`: A check is no need of its own: nothing is badged for it.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/subpage.rs`

#### Subpages open in place of the page, starting with a back bar
The pages a row of Autocomplete or Dictation opens in place of the page
(`SettingsSubpage`, `SettingsSubpageBar`): the writing profile, the apps
and sites to skip, the usage numbers and the recent dictations. A page
opened this way starts with the way back instead of the header.

#### Server setup subpage is the port's counterpart of the Mac model picker sheet
`Subpage::AutocompleteServer`: Where autocomplete runs: on this computer or on a server, with the
server's setup and approval. On the Mac this is the model picker's
sheet; the port sets servers up here.

#### Subpages list their settings so search and links open them
`Subpage::setting_ids`: The settings edited on this page, so search and links open it and
land on them.

#### Dictation profile subpage is found via the row that opens it
`Subpage::setting_ids`: The row that opens it: search lands on the page itself.

#### Back chevron flips direction for right-to-left languages
`bar`: Back points the way the interface reads.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/try_sheet.rs`

#### Try-out opens as a sheet and turns nothing on
"Try it…" on Autocomplete and Dictation (`AutocompleteTrySheet`,
`DictationTrySheet`): the try-out opens over its page as a sheet, so the
page leads with its settings. Opening one turns nothing on; Done closes it.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/writing.rs`

#### Practice editor uses the same engine path as fields in other apps
Settings › Autocomplete (the port's "Writing" category,
`AutocompleteSettingsPage.swift`, `AutocompleteExperienceView.swift`):
under the shared header, the settings in groups, then rows that open the
writing profile, the apps and sites to skip and the usage numbers. The
practice editor is the header's "Try it…" sheet (`try_sheet`). The
writing profile is also what Compose dictation writes as.

The practice editor goes through the same engine path as a field in
another app: its text is sent as a field context, the suggestion is drawn
after its caret, the accept keys take the next word or phrase or the rest,
and Esc dismisses.

#### Primary accept key wins when both keys are the same
`accept_hint`: The primary key wins when both are bound to the same key.

#### Memory inventory is cached for 30 seconds before recount
`INVENTORY_LIFETIME`: How long a saved-memory count stays good before Settings reads it again.

#### Inventory counts saved items without reading text into the UI
`Inventory`: What is saved and readable, counted without reading any text into the UI
(`CotypingContextAvailability.Inventory`).

#### Context state explains why an enabled grant cannot take effect
`ContextState`: What an optional context source can contribute right now, shown under its
switch, so a grant that is on but cannot take effect says why.

#### Facts mixing meetings and screen need both grants
`screen_memory_state`: A fact built from meetings and screen activity needs both grants.

#### Practice keys follow live-field rules; primary key wins ties
`SettingsPage::practice_key`: A key in the practice editor, by the same rules as a live field: the
primary key wins when both are the same. True when it took the key.

#### Server failure shown only for the server it belongs to
`autocomplete_notices`: Why the selected server's last request brought no suggestion,
shown only for the server it belongs to.

#### Explain input-method meaning on this desktop before enabling autocomplete
`autocomplete_notices`: Where autocomplete reaches other apps as an input method, say what
that means on this desktop, before it is turned on too.

#### Total limits go in header; partial limits shown here while on
`autocomplete_notices`: Where autocomplete can't follow the user into other apps the
header says so; a partial limit is said here while it is on.

#### Second accept-the-rest key exists only in the port
`autocomplete_main_sections`: Port-only: a second key takes the whole suggestion.

#### Add-space-after-accept setting exists only in the port
`autocomplete_main_sections`: Port-only.

#### Servers receive enabled context; only local runs promise nothing kept
`autocomplete_main_sections`: A server receives what is turned on here; only this computer can
promise that nothing it reads is kept.

#### Profile fields are shared by Autocomplete and Compose; notes are port-only
`writing_profile_fields`: The writing profile's fields, which Autocomplete and Dictation's
Compose share (`WritingProfileFields`): both pages show them, bound to
the same settings. Notes for autocomplete is the port's own field.

#### Try-out uses the engine path of other apps and enables nothing
`autocomplete_try`: "Try it…" (`AutocompleteTrySheet`): the practice editor, over the page.
It goes through the same engine path as a field in another app, with
the page's settings; nothing is turned on by opening it.

#### Tab with no ghost follows focus order instead of indenting
`autocomplete_try editor`: Without a ghost to accept, this short editor follows the
window's focus order instead of inserting indentation.

#### Arrow keys drop the suggestion even at text edges, like live monitor
`autocomplete_try editor`: Like the live monitor, an arrow drops the suggestion even
when the caret has nowhere further to go.

#### Esc dismisses a suggestion, otherwise closes the sheet
`autocomplete_try editor`: Esc takes a suggestion away; with none showing it closes the sheet.

#### Try-out text goes to a server as typing in other apps does
`autocomplete_try_explanation`: What typing in the try-out sends, for the sheet's line under its
title. A server receives it as it receives typing in other apps.

#### Inventory counted periodically because facts are read from a file
`SettingsPage::context_inventory`: Counted once in a while, not per redraw: facts come from a file.

#### Window text download is never started automatically
`SettingsPage::window_text_row`: The window text grant's state, with the download it needs: never
started on its own.

#### Ghost placed from last-drawn caret: inline at line end, else below
`SettingsPage::practice_ghost`: The practice suggestion after the editor's caret: inline at the end
of a line, else under the caret's line, as in other apps. Placed in
the editor from the caret it drew last, so scrolling clips it.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/writing_rehearsal.rs`

#### Explain empty suggestions so a working model does not look broken
What the practice editor's last request drew on, and why it brought no
suggestion (`CotypingContextStatus.rehearsal`,
`AutocompleteExperienceView.explanation`): a working model that suggested
nothing shouldn't look like a broken one.

#### Source statuses use Settings order; used is None before a suggestion is asked
`statuses`: The three optional sources, in the order Settings lists them. `used` is `None`
until the practice editor has asked for a suggestion.

#### Practice editor reads its own sample, so both states are stated
`statuses`: The practice editor still reads its own sample, so it says both.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/writing_server.rs`

#### Typing goes to a server only after its origin is approved for autocomplete
Settings → Autocomplete → Where autocomplete runs (`AutocompleteServerSetup`,
the Mac's autocomplete model picker):
on this computer, on Think's server with the same or another model, or on
any OpenAI-compatible server, hosted or on the user's own network. It edits
a draft that Use model applies. Typing goes to a server only after its
origin is approved for autocomplete; Think's approval does not cover it.

#### Server settings are a draft applied only by Use model
`ServerDraft`: Where autocomplete runs, as being edited. Applied with Use model, so Cancel
changes nothing.

#### Key-saved state is unknown until the credential store answers
`ServerDraft.key_saved`: `None` until the credential store has answered.

#### API key is not stored in the applied settings
`applied`: The settings a draft would make. The key is not part of them.

#### Loopback servers need no approval; nothing leaves the computer
`approval_origin`: The origin an approval belongs to. `None` on this computer, where nothing
leaves it and nothing needs approving.

#### Approvals are per origin; new URL shows its own saved choice
`ServerDraft::subscribe`: An approval belongs to one origin: a newly
entered server shows its own saved choice.

#### Credential store is read off the main thread
`SettingsPage::load_key_state`: Reads whether "Another server" has a key saved, off the main thread.

### `LinuxWindows/crates/lokalbot-app/src/pages/settings/writing_stats.rs`

#### Usage statistics are estimates from field reads, not keystrokes
Settings → Autocomplete → Usage: Statistics (`AutocompleteStatisticsView.swift`) and
Usage and timing (`AutocompleteExperienceView.usage`): how much autocomplete
wrote, what it was shown and what was kept. These are worked out from reads
of the field rather than from keys, so they are estimates, and the footer
says so. Bars are drawn with plain elements.

#### Empty periods keep columns so the time axis stays even
`chart`: One column per day or month; empty periods keep the time axis even.

#### A day with nothing shown has no rate, drawn as zero
`chart`: A day with nothing shown has no rate, not a rate of zero.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
