# Redesign Phase 4 — Settings absorbs Models + Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the redesign per spec §2.5 + §5 item 5: fold Models into Settings as a tab strip (General · Recording · Models · Privacy · Advanced), restyle onboarding to the three-pillar Capture/Ask/Type story, close the empty-state gaps, and produce the Show HN screenshot kit.

**Architecture:** `NavSection` loses `.models` (legacy `"models"` capture name maps to `.settings` and preselects the Models tab via a new `AppState.SettingsTab`). `SettingsView` becomes header (search + segmented tab strip) over content (the Form's sections distributed across tabs; `ModelsView` unchanged as the Models tab). Search with a non-empty query filters across ALL tabs (the existing `shows()` gating, tab-agnostic) plus a Models jump row.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 15+, XcodeGen, XCTest.

## Global Constraints

- **No subagents** — all work inline in this session (user directive).
- **No UI test runs** — user waiver; UI test *source* is still updated where selectors break, but gating is unit suite + build only.
- Unit tests: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test` (scheme "LokalBot"). Suite must stay green (641+ tests).
- `git checkout -- default.profraw` before EVERY commit; never commit it.
- No new source files except where listed; if any are added/removed, run `xcodegen generate`.
- Nothing leaves the Mac — pure UI change, no new network surface.
- Spec §2.5 verbatim: "One surface with a tab strip: **General · Recording · Models · Privacy · Advanced**. `ModelsView` becomes the Models tab unchanged; `SettingsView`'s existing sections distribute across the other tabs; the settings-search field filters across all tabs. No behavioral changes."
- Spec §3.3: onboarding "same flow, restyled with `HeroPanel`/`IconTile`; the three-pillar framing (Capture / Ask / Type) replaces the current pillar copy". Cotyping ghost rendering/insertion/event tap untouched (§4) — verified: the ghost `NSPanel` is cotyping's only floating chrome, so no cotyping change in this phase. Dictation HUD (`.hudCapsule`) and menu-bar `HeroPanel` were completed in Phase 0 — no change.
- Spec §3.4: `accessibilityReduceMotion` respected on all new animations; slate reserved for hero/HUD surfaces only (§7).
- Preserved accessibility ids: `settings.form`, `settings.search`, `models.transcription`, `models.summarization`, `models.cotyping`, `models.embeddings`, `sidebar.settings`. Removed: `sidebar.models`. New: `settings.tab`.
- Commit trailer: `Claude-Session: https://claude.ai/code/session_014XXdyc5pTVGh24L2MhTaSv`
- Finish: push `redesign-phase4`, PR targeting `redesign-phase3` (stacked).

---

### Task 1: SettingsTab model + NavSection remap

**Files:**
- Modify: `LokalBot/LokalBotApp.swift` (NavSection enum ~line 114, TypeTab ~line 135, published nav state ~line 184)
- Modify: `LokalBot/AppLifecycle.swift:158-183` (capture environment)
- Modify: `LokalBot/Views/Window/MainWindowView.swift:106-146` (navigation branch + sidebar)
- Modify: `LokalBot/Views/CommandPaletteView.swift:89-90` (nav.models row)
- Test: `LokalBotTests/Views/Window/NavSectionMappingTests.swift`

**Interfaces:**
- Consumes: existing `AppState.NavSection`, `AppState.TypeTab(captureName:)` pattern.
- Produces: `AppState.SettingsTab` (`enum SettingsTab: String, CaseIterable { case general, recording, models, privacy, advanced }`) with `init?(captureName:)` and `var displayName: String`; `@Published var settingsTab: SettingsTab = .general`; `func openSettings(tab: SettingsTab)`. Task 2 binds `app.settingsTab` in SettingsView.

- [ ] **Step 1: Update the mapping tests (failing first)**

In `LokalBotTests/Views/Window/NavSectionMappingTests.swift`, change the `"models"` expectation and add SettingsTab coverage:

```swift
    func testCaptureNamesMapToTheirSections() {
        XCTAssertEqual(AppState.NavSection(captureName: "capture"), .capture)
        XCTAssertEqual(AppState.NavSection(captureName: "type"), .type)
        XCTAssertEqual(AppState.NavSection(captureName: "ask"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "settings"), .settings)
    }

    /// Spec §2.5: Settings absorbs Models — the legacy "models" capture name
    /// lands on Settings, and the SettingsTab mapping preselects its tab.
    func testLegacyModelsNameMapsToSettings() {
        XCTAssertEqual(AppState.NavSection(captureName: "models"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "Models"), .settings)
    }

    func testSettingsTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.SettingsTab(captureName: "models"), .models)
        XCTAssertEqual(AppState.SettingsTab(captureName: "general"), .general)
        XCTAssertEqual(AppState.SettingsTab(captureName: "recording"), .recording)
        XCTAssertEqual(AppState.SettingsTab(captureName: "privacy"), .privacy)
        XCTAssertEqual(AppState.SettingsTab(captureName: "advanced"), .advanced)
        XCTAssertNil(AppState.SettingsTab(captureName: "settings"))
        XCTAssertNil(AppState.SettingsTab(captureName: "capture"))
    }
```

- [ ] **Step 2: Build tests to verify they fail** (`SettingsTab` undefined, `"models"` still maps to `.models`)

- [ ] **Step 3: Implement in `LokalBotApp.swift`**

NavSection becomes `case capture, type, ask, settings`; in `init?(captureName:)` replace the two lines `case "models": self = .models` / `case "settings": self = .settings` with `case "settings", "models": self = .settings`. After the `TypeTab` enum add:

```swift
    /// Which tab the Settings surface shows (spec §2.5 — Settings absorbs
    /// Models as a tab strip). Session-sticky like TypeTab.
    enum SettingsTab: String, CaseIterable {
        case general, recording, models, privacy, advanced

        var displayName: String { rawValue.capitalized }

        /// Legacy capture names select their tab; the pre-merge "models"
        /// section name lands on the Models tab.
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "general": self = .general
            case "recording": self = .recording
            case "models": self = .models
            case "privacy": self = .privacy
            case "advanced": self = .advanced
            default: return nil
            }
        }
    }
```

Next to `@Published var typeTab` add `@Published var settingsTab: SettingsTab = .general`, and next to `openType(_:)` add:

```swift
    /// Navigate to Settings with a specific tab preselected.
    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        navSection = .settings
    }
```

- [ ] **Step 4: Compile fixes at the three consumers**

`AppLifecycle.swift` inside `applyCaptureEnvironment`, after the TypeTab line:

```swift
            if let tab = AppState.SettingsTab(captureName: raw) { app.settingsTab = tab }
```

`CommandPaletteView.swift` nav.models row action becomes `{ app.openSettings(tab: .models) }` (title/icon/subtitle unchanged).

`MainWindowView.swift`: delete the `else if app.navSection == .models { … }` navigation branch and the sidebar `Label("Models"…)` entry (its `.tag` and `sidebar.models` id) — the Configure section keeps only Settings.

- [ ] **Step 5: Run the unit suite** — expected: all green including the updated mapping tests.

- [ ] **Step 6: Commit** — `git checkout -- default.profraw; git add -A LokalBot LokalBotTests; git commit` message: `Fold the Models destination into Settings navigation`

---

### Task 2: SettingsView tab strip, section distribution, cross-tab search

**Files:**
- Modify: `LokalBot/Views/Settings/SettingsView.swift` (whole body restructure)
- Modify: `LokalBot/Views/ModelSetup/ModelsView.swift` (stale copy only)
- Modify: `LokalBotUITests/MainWindowUITests.swift:77-93` (testModelsSectionRendersRoleCards selectors — source update only, not run)

**Interfaces:**
- Consumes: `app.settingsTab` + `AppState.SettingsTab` from Task 1; existing `shows(_:_:)` / `SettingsSearchRanker`.
- Produces: layout = `VStack { header (search field `settings.search` + segmented Picker `settings.tab`); content }`, whole surface keeps `settings.form` id. Query empty → selected tab's sections (Models tab = `ModelsView()` unchanged); query non-empty → Form with ALL matching sections regardless of tab + a "Models" jump section when models keywords match.

- [ ] **Step 1: Restructure `SettingsView.body`**

Replace the body with a header + tabbed content. The existing `Section("…") { … }` blocks move verbatim into small `@ViewBuilder` vars (`generalSection`, `permissionsSection`, `meetingsSection`, `processingSection`, `summarizationSection`, `dayTrackingSection`, `privacySection`, `storageSection`, `updatesSection`, `systemSection`, `agentCLISection`) — each keeps its `if shows(…)` wrapper exactly as today. Distribution:

- **General**: General, Permissions, Storage, Updates
- **Recording**: Meetings, Processing, Summarization, Day tracking
- **Models**: `ModelsView()`
- **Privacy**: Privacy
- **Advanced**: System, Agent CLI

```swift
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.settingsTab == .models && queryIsEmpty {
                ModelsView()
            } else {
                Form {
                    if queryIsEmpty {
                        sections(for: app.settingsTab)
                    } else {
                        searchResults
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 460)
        .accessibilityIdentifier("settings.form")
        .navigationTitle("Settings")
        .onAppear { … unchanged … }
        .onDisappear { … unchanged … }
    }

    private var queryIsEmpty: Bool {
        settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings…", text: $settingsQuery)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("settings.search")
                if !settingsQuery.isEmpty {
                    Button { settingsQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $app.settingsTab) {
                ForEach(AppState.SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings.tab")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func sections(for tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .general:
            generalSection; permissionsSection; storageSection; updatesSection
        case .recording:
            meetingsSection; processingSection; summarizationSection; dayTrackingSection
        case .models:
            EmptyView() // handled by the ModelsView branch in body
        case .privacy:
            privacySection
        case .advanced:
            systemSection; agentCLISection
        }
    }

    /// Spec §2.5: the search field filters across ALL tabs — a non-empty
    /// query shows every matching section regardless of the selected tab,
    /// plus a jump row into the Models tab when its keywords match.
    @ViewBuilder private var searchResults: some View {
        generalSection; permissionsSection; meetingsSection; processingSection
        summarizationSection; dayTrackingSection; privacySection; storageSection
        updatesSection; systemSection; agentCLISection
        if shows("Models", ["model", "models", "transcription", "summarization",
                            "cotyping", "embeddings", "llm", "whisper", "download",
                            "gguf", "hugging face", "ollama", "engine", "backend"]) {
            Section("Models") {
                Button("Open the Models tab…") {
                    settingsQuery = ""
                    app.settingsTab = .models
                }
                Text("Transcription, summarization, cotyping, and embedding models live in the Models tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
```

The old first Form `Section` holding the search field is removed (search lives in the header now). All existing section bodies are byte-identical moves.

- [ ] **Step 2: Copy fixes**

- Processing section caption: `"Choose transcription and summarization models in the Models section (sidebar → Engine → Models)."` → `"Choose transcription and summarization models in the Models tab."`
- `ModelsView` doc comment: `/// The "Models" section (sidebar → Engine → Models).` → `/// The Models tab of Settings (spec §2.5).`
- `ModelsView` embeddings card: `"Off — enable it in the Search section"` → `"Off — enable it in Ask"`, and caption `"…(sidebar → Search)."` → `"…(enabled from Ask)."`
- `ModelsView` drops `.navigationTitle("Models")` (it now lives inside Settings).

- [ ] **Step 3: Update the UI test source (not run)**

`MainWindowUITests.testModelsSectionRendersRoleCards`: `clickSidebar("sidebar.models")` → navigate via Settings:

```swift
        clickSidebar("sidebar.settings")
        let tabs = app.descendants(matching: .any)["settings.tab"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 8), "settings tab strip missing")
        let segment = tabs.buttons["Models"].exists
            ? tabs.buttons["Models"] : tabs.radioButtons["Models"]
        segment.click()
```

(assertions on `models.*` card ids unchanged).

- [ ] **Step 4: Build + run the unit suite** — expected: green.

- [ ] **Step 5: Commit** — message: `Restructure Settings into a five-tab surface absorbing Models`

---

### Task 3: Onboarding three-pillar restyle

**Files:**
- Modify: `LokalBot/Views/Onboarding/OnboardingView.swift` (welcomePage, flowPage, LokalBotHeroDemo)

**Interfaces:**
- Consumes: `HeroPanel`, `IconTile`, `Brand` tokens from Phase 0. No produced interfaces.

- [ ] **Step 1: Welcome page — pillar copy + chips**

Subtitle: `"Your local meeting memory, with recording, recap, search, and cotyping on this Mac."` → `"Capture your meetings and day, ask your local library anything, and type with on-device AI — nothing leaves this Mac."`

Chips row becomes the three pillars plus the invariant:

```swift
            HStack(spacing: 8) {
                OnboardingFeatureChip(systemImage: "lock.fill", label: "On-device")
                OnboardingFeatureChip(systemImage: "waveform.circle", label: "Capture")
                OnboardingFeatureChip(systemImage: "sparkle.magnifyingglass", label: "Ask")
                OnboardingFeatureChip(systemImage: "keyboard", label: "Type")
            }
```

- [ ] **Step 2: Flow page — three pillar cards**

Header: title `"Three pillars: Capture, Ask, Type"`, subtitle `"Everything LokalBot does hangs off three verbs — all local."`, systemImage stays `"waveform.badge.magnifyingglass"`. The three `TimelineCard`s become:

```swift
                TimelineCard(
                    number: "1",
                    systemImage: "waveform.circle",
                    tint: Brand.teal,
                    title: "Capture",
                    subtitle: "Meetings and your day, recorded, transcribed, and summarized locally."
                )
                TimelineCard(
                    number: "2",
                    systemImage: "sparkle.magnifyingglass",
                    tint: .indigo,
                    title: "Ask",
                    subtitle: "One search over everything you captured — press ↵ to ask the local assistant."
                )
                TimelineCard(
                    number: "3",
                    systemImage: "keyboard",
                    tint: .orange,
                    title: "Type",
                    subtitle: "Dictation and Cotyping inline autocomplete, anywhere you type."
                )
```

(`.onboardingReveal` indices unchanged.)

- [ ] **Step 3: Hero demo — pillar phases on a HeroPanel**

`LokalBotHeroDemo` phases become the pillars and the card chrome becomes the slate `HeroPanel` (spec §3.2 "onboarding cards"); inner text goes white-on-slate:

```swift
    private let phases = [
        ("Capture", "Google Meet · recording", "Mic + system audio, transcribed locally"),
        ("Ask", "What did we promise Alex?", "Searches your local meeting library"),
        ("Type", "Cotyping suggests as you type", "Inline autocomplete, on-device")
    ]
```

Icon mapping in the body: phase 0 `"waveform.circle"`/`Brand.teal`, phase 1 `"sparkle.magnifyingglass"`/`.indigo`, phase 2 `"keyboard"`/`.orange`. Replace the outer `.padding(16).onboardingCard(cornerRadius: 14)` with wrapping the VStack in `HeroPanel(radius: 14) { … }`; the inner phase box swaps `Color(nsColor: .textBackgroundColor).opacity(0.72)` for `Color.white.opacity(0.08)` and the two secondary texts use `.foregroundStyle(.white.opacity(0.65))` with the title `.foregroundStyle(.white)` so the demo reads on slate in both appearances. Traffic-light dots and the reduce-motion `task` behavior stay as-is.

- [ ] **Step 4: Build + spot-check** — build the LokalBot Dev scheme (`xcodebuild -project LokalBot.xcodeproj -scheme 'LokalBot Dev' -destination 'platform=macOS' build`); expected: succeeds.

- [ ] **Step 5: Run the unit suite** (onboarding has no unit coverage; suite guards regressions) — expected: green.

- [ ] **Step 6: Commit** — message: `Restyle onboarding around the Capture, Ask, Type pillars`

---

### Task 4: Empty-state polish

**Files:**
- Modify: `LokalBot/Views/Meetings/MeetingListView.swift` (empty overlay)

**Interfaces:** none produced.

- [ ] **Step 1: Meeting-list empty state**

The Library list renders blank when no meetings exist. Add after the recording overlay in `MeetingListView.body`:

```swift
        .overlay {
            if groupedMeetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "waveform.circle",
                    description: Text("LokalBot detects meeting apps and records automatically — or press Record in the menu bar."))
            }
        }
```

- [ ] **Step 2: Audit the remaining empty states (verification, no code expected)**

Confirm these render a proper empty state: Capture Day (`No activity recorded` ContentUnavailableView — CaptureView.swift:171), Capture inspector (CaptureDetailView.swift:26), Ask idle (`chat.empty` — AskView.swift:285), menu-bar recents (`No meetings yet` caption). Confirm slate appears only on HeroPanel/HUDCapsule surfaces (grep `Brand.slate` — expected: DesignSystem/Brand + HeroPanel usage only) and every `withAnimation`/`.animation` added this branch is guarded by or indifferent to `accessibilityReduceMotion` (this branch adds none).

- [ ] **Step 3: Run the unit suite** — expected: green.

- [ ] **Step 4: Commit** — message: `Add an empty state to the meeting library list`

---

### Task 5: Screenshot kit for Show HN + website

**Files:**
- Create: `Docs/guides/screenshot-kit.md` (docs only — no xcodegen needed)

**Interfaces:** consumes the UI-test-host env hooks (`LOKALBOT_INITIAL_SECTION`, `LOKALBOT_SELECT_FIRST`, `LOKALBOT_DISMISS_ONBOARDING` — AppLifecycle.swift:158-183).

- [ ] **Step 1: Write the shot list**

Document (a) the six shots: menu-bar dropdown while recording, Capture Day view, Capture Library + inspector, Ask with results + escalated answer, Type with Cotyping ghost text (composited or real), Settings Models tab; (b) per-shot setup: build the `LokalBot UI Test Host` target against a synthetic library (`LOKALBOT_STORAGE_ROOT` pointing at a seeded fixture) and launch with `LOKALBOT_INITIAL_SECTION` = `capture`/`ask`/`type`/`models` (the last now lands on Settings → Models tab), `LOKALBOT_SELECT_FIRST=1`, `LOKALBOT_DISMISS_ONBOARDING=1`; (c) both appearances (dark primary for the site's slate aesthetic, light for README), Retina 2×, window ~1280×800; (d) where they go: `Website/public/` hero + Show HN kit (`Docs/show-hn-kit.md`).

- [ ] **Step 2: Commit** — message: `Document the Show HN and website screenshot kit`

---

### Task 6: Finish the branch

- [ ] Full unit suite green; `git checkout -- default.profraw`.
- [ ] Whole-branch self-review vs `redesign-phase3` (`git diff redesign-phase3...HEAD --stat`): no stale `.models` NavSection producers (`grep -rn "navSection = .models\|NavSection.models"` → empty), preserved ids present, no `sidebar.models` left in app or test sources except intentionally-removed spots.
- [ ] Push `redesign-phase4`, open PR targeting `redesign-phase3` with the session URL trailer.
- [ ] Update `.superpowers/sdd/progress.md`.
