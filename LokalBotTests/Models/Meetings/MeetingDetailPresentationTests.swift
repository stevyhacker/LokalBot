import XCTest
@testable import LokalBot

final class MeetingDetailPresentationTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, _ speaker: String, _ text: String,
                         user: Bool = false) -> Transcript.Segment {
        .init(start: start, end: end, speaker: speaker, text: text,
              attribution: .init(source: user ? .microphone : .system,
                                 identity: user ? .user : .unresolved,
                                 method: user ? .confirmation : .diarization))
    }

    private var transcript: Transcript {
        Transcript(segments: [
            segment(0, 30, "them 1", "The gateway is in staging."),
            segment(30, 40, "me", "Where does the load test stand?", user: true),
            segment(40, 100, "them 2", "Mobile needs three more weeks."),
            segment(100, 130, "them 1", "Then the beta date holds."),
            segment(130, 131, "them 2", "   "),
        ], engine: "fixture", speakerAliases: ["them 1": "Maya Chen"])
    }

    private var meeting: Meeting {
        Meeting(id: UUID(), title: "Synthetic planning", appName: "Meet",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: Date(timeIntervalSince1970: 1_780_001_800),
                relativePath: "meetings/synthetic")
    }

    private func references(_ actions: [MeetingOutcomes.ActionItem],
                            state: MeetingOutcomeState = MeetingOutcomeState()) -> [OutcomeActionReference] {
        let meeting = meeting
        let outcomes = MeetingOutcomes(actionItems: actions, decisions: [], openQuestions: [])
        return MeetingOutcomeProjection(meeting: meeting, outcomes: outcomes, state: state,
                                        followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
            .actionReferences
    }

    func testShortStampDropsLeadingZerosAndKeepsHours() {
        XCTAssertEqual(Transcript.shortStamp(0), "0:00")
        XCTAssertEqual(Transcript.shortStamp(12.9), "0:12")
        XCTAssertEqual(Transcript.shortStamp(72), "1:12")
        XCTAssertEqual(Transcript.shortStamp(2225), "37:05")
        XCTAssertEqual(Transcript.shortStamp(3729), "1:02:09")
        XCTAssertEqual(Transcript.shortStamp(-4), "0:00")
        XCTAssertEqual(Transcript.shortStamp(.nan), "0:00")
    }

    func testDateTextNamesTodayAndSpellsOutOlderDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let locale = Locale(identifier: "en_US")
        XCTAssertTrue(MeetingDetailPresentation.dateText(Date(), calendar: calendar, locale: locale)
            .hasPrefix("Today"))
        let old = MeetingDetailPresentation.dateText(
            Date(timeIntervalSince1970: 1_780_000_000), calendar: calendar, locale: locale)
        XCTAssertTrue(old.contains("2026"), old)
        XCTAssertFalse(old.hasPrefix("Today"))
    }

    func testSpeakersPutYouFirstThenOrderOfSpeakingAndFlagUnnamedCallVoices() {
        let transcript = transcript
        let speakers = MeetingDetailPresentation.speakers(
            in: transcript, presentation: MeetingSpeakerPresentation(transcript: transcript))
        XCTAssertEqual(speakers.map(\.id), ["me", "them 1", "them 2"])
        XCTAssertEqual(speakers.map(\.name), ["You", "Maya Chen", "Speaker 2"])
        XCTAssertEqual(speakers.map(\.isUser), [true, false, false])
        XCTAssertEqual(speakers.map(\.needsName), [false, false, true])
        XCTAssertEqual(speakers.first?.colorIndex, 0)
        XCTAssertEqual(MeetingDetailPresentation.unnamedSpeakerKeys(in: transcript), ["them 2"])
        XCTAssertTrue(MeetingDetailPresentation.speakers(
            in: nil, presentation: MeetingSpeakerPresentation(transcript: nil)).isEmpty)
    }

    func testSpeechTimeSumsEachSpeakersSegmentsAndRoundsToWholeMinutes() {
        var transcript = transcript
        transcript.segments.append(segment(200, 150, "them 2", "Backwards bounds are ignored."))
        let seconds = MeetingDetailPresentation.speechSeconds(in: transcript)
        XCTAssertEqual(seconds["them 1"], 60)
        XCTAssertEqual(seconds["me"], 10)
        XCTAssertEqual(seconds["them 2"], 61)
        XCTAssertEqual(MeetingDetailPresentation.speechMinutes(10), 1, "any speech reads as a minute")
        XCTAssertEqual(MeetingDetailPresentation.speechMinutes(61), 1)
        XCTAssertEqual(MeetingDetailPresentation.speechMinutes(12 * 60 + 20), 12)
        XCTAssertEqual(MeetingDetailPresentation.speechMinutes(7 * 60 + 40), 8)
    }

    func testCaptionFollowsThePlayheadAndSkipsBlankLines() {
        let index = MeetingDetailPresentation.PlayheadIndex(display: .init(transcript: transcript))
        XCTAssertFalse(index.isEmpty)
        XCTAssertEqual(index.caption(at: 0)?.segmentIndex, 0)
        XCTAssertEqual(index.caption(at: 29.9)?.speakerKey, "them 1")
        XCTAssertEqual(index.caption(at: 30)?.text, "Where does the load test stand?")
        XCTAssertEqual(index.caption(at: 35)?.speakerKey, "me")
        // The blank fifth segment is never shown, so the last spoken line stays.
        XCTAssertEqual(index.caption(at: 500)?.segmentIndex, 3)
        XCTAssertEqual(index.caption(at: -3)?.segmentIndex, 0, "before any speech the first line is shown")
        XCTAssertNil(MeetingDetailPresentation.PlayheadIndex().caption(at: 10))
    }

    func testCaptionUsesStartOrderWhenSegmentsAreStoredOutOfOrder() {
        let transcript = Transcript(segments: [
            segment(20, 30, "them", "Second in time."),
            segment(0, 10, "me", "First in time.", user: true),
        ], engine: "fixture")
        let index = MeetingDetailPresentation.PlayheadIndex(display: .init(transcript: transcript))
        XCTAssertEqual(index.caption(at: 5)?.segmentIndex, 1)
        XCTAssertEqual(index.caption(at: 25)?.segmentIndex, 0)
    }

    func testActionsSplitIntoYoursAndOthersKeepingTheirOrder() {
        let actions = references([
            .init(id: "a", text: "Run the synthetic load test", owner: "Maya Chen"),
            .init(id: "b", text: "Write the synthetic announcement", owner: "Me"),
            .init(id: "c", text: "Start the synthetic legal review"),
            .init(id: "d", text: "Book the synthetic pricing call", owner: "Me"),
        ])
        let groups = MeetingDetailPresentation.groups(actions)
        XCTAssertEqual(groups.forYou.map(\.action.id), ["b", "d"])
        XCTAssertEqual(groups.forOthers.map(\.action.id), ["a", "c"])
    }

    func testActionsPanelCountsEveryActionAndKeepsBothBands() {
        let panel = MeetingDetailPresentation.ActionsPanel(references([
            .init(id: "a", text: "Run the synthetic load test", owner: "Maya Chen"),
            .init(id: "b", text: "Write the synthetic announcement", owner: "Me"),
            .init(id: "c", text: "Start the synthetic legal review"),
        ]))
        XCTAssertEqual(panel.count, 3)
        XCTAssertTrue(panel.showsBands)
        XCTAssertEqual(panel.groups.forYou.map(\.action.id), ["b"])
        XCTAssertEqual(panel.groups.forOthers.map(\.action.id), ["a", "c"])
        XCTAssertNil(panel.forYouLine)
        XCTAssertNil(panel.forOthersLine)
    }

    func testActionsPanelSaysWhichSideHasNothing() {
        let allMine = MeetingDetailPresentation.ActionsPanel(references([
            .init(id: "a", text: "Write the synthetic announcement", owner: "Me"),
            .init(id: "b", text: "Book the synthetic pricing call", owner: "Me"),
        ]))
        XCTAssertEqual(allMine.count, 2)
        XCTAssertTrue(allMine.showsBands, "the For others band stays, with a line under it")
        XCTAssertNil(allMine.forYouLine)
        XCTAssertEqual(allMine.forOthersLine, .nothingForOthers)

        let noneMine = MeetingDetailPresentation.ActionsPanel(references([
            .init(id: "a", text: "Run the synthetic load test", owner: "Maya Chen"),
        ]))
        XCTAssertEqual(noneMine.forYouLine, .nothingForYou)
        XCTAssertNil(noneMine.forOthersLine)
    }

    func testActionsPanelWithoutActionsHasNoCountAndNoBands() {
        let panel = MeetingDetailPresentation.ActionsPanel([])
        XCTAssertNil(panel.count, "a meeting without actions shows no zero in the header")
        XCTAssertFalse(panel.showsBands)
        XCTAssertNil(panel.forYouLine)
        XCTAssertNil(panel.forOthersLine)
        XCTAssertFalse(panel.showsActionsLink(hasSavedOutcomes: true, isSample: false))
    }

    func testAlsoInActionsNeedsASavedActionOfYoursFromARealMeeting() {
        let mine = MeetingDetailPresentation.ActionsPanel(references([
            .init(id: "a", text: "Write the synthetic announcement", owner: "Me"),
        ]))
        XCTAssertTrue(mine.showsActionsLink(hasSavedOutcomes: true, isSample: false))
        XCTAssertFalse(mine.showsActionsLink(hasSavedOutcomes: false, isSample: false),
                       "notes still being written are not in the Actions list yet")
        XCTAssertFalse(mine.showsActionsLink(hasSavedOutcomes: true, isSample: true),
                       "the sample meeting's actions never reach the Actions list")
        let others = MeetingDetailPresentation.ActionsPanel(references([
            .init(id: "a", text: "Run the synthetic load test", owner: "Maya Chen"),
        ]))
        XCTAssertFalse(others.showsActionsLink(hasSavedOutcomes: true, isSample: false))
    }

    func testPinnedHeaderTakesTheScrollBarsInset() {
        // Overlay scroll bars: the scrolling column is as wide as the pane.
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 952, scrollContentWidth: 952), 0)
        // Scroll bars always shown: the column gives up the scroller's width.
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 952, scrollContentWidth: 937), 15)
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 952, scrollContentWidth: 936.4), 16)
        // Not yet measured, a rounding difference, or a layout in flight.
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 0, scrollContentWidth: 937), 0)
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 952, scrollContentWidth: 0), 0)
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 952, scrollContentWidth: 951.6), 0)
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 952, scrollContentWidth: 700), 0)
        XCTAssertEqual(MeetingDetailLayout.pinnedTrailingInset(paneWidth: 700, scrollContentWidth: 952), 0)
    }

    func testFindIsInTheTranscriptPanelUntilCommandFSearchesTheWholeMeeting() {
        XCTAssertEqual(MeetingDetailLayout.findPlacement(tab: .summary, pageSearchPresented: false), .hidden)
        XCTAssertEqual(MeetingDetailLayout.findPlacement(tab: .notes, pageSearchPresented: false), .hidden)
        XCTAssertEqual(MeetingDetailLayout.findPlacement(tab: .transcript, pageSearchPresented: false),
                       .transcriptPanel)
        // One field at a time: the pinned bar replaces the panel's field.
        for tab in MeetingWorkspaceTab.allCases {
            XCTAssertEqual(MeetingDetailLayout.findPlacement(tab: tab, pageSearchPresented: true), .pinnedBar)
        }
    }

    func testTextBoundWidthsGrowWithTheTextSize() {
        let standard = AppTextSize.standard.scale
        XCTAssertEqual(MeetingDetailLayout.proseWidth(textScale: standard), 860)
        XCTAssertEqual(MeetingDetailLayout.findFieldWidth(textScale: standard), 260)
        XCTAssertGreaterThan(MeetingDetailLayout.proseWidth(textScale: AppTextSize.largest.scale), 860)
        XCTAssertLessThan(MeetingDetailLayout.proseWidth(textScale: AppTextSize.small.scale), 860)
        XCTAssertGreaterThan(MeetingDetailLayout.findFieldWidth(textScale: AppTextSize.largest.scale), 260)
        // A scale of zero from an unset environment never collapses a width.
        XCTAssertGreaterThan(MeetingDetailLayout.proseWidth(textScale: 0), 0)
        // The column is wider than the prose it holds and than a row needs.
        XCTAssertGreaterThanOrEqual(MeetingDetailLayout.columnMaximumWidth, 1100)
        XCTAssertGreaterThan(MeetingDetailLayout.columnMaximumWidth, MeetingDetailLayout.proseWidth)
        XCTAssertLessThan(MeetingDetailLayout.findFieldMinimumWidth, MeetingDetailLayout.findFieldWidth)
    }

    func testTranscriptFooterNamesTheModelExceptForMergedOrEmptyTranscripts() {
        XCTAssertEqual(MeetingTranscriptEngineLine.text(for: transcript), "Transcribed with fixture")
        XCTAssertNil(MeetingTranscriptEngineLine.text(for: Transcript(segments: transcript.segments, engine: "merged")))
        XCTAssertNil(MeetingTranscriptEngineLine.text(for: Transcript(segments: transcript.segments, engine: "")))
        XCTAssertNil(MeetingTranscriptEngineLine.text(for: Transcript(segments: [], engine: "fixture")))
    }

    func testCorrectedOwnerMovesAnActionBetweenGroups() {
        var state = MeetingOutcomeState()
        state.actions["a"] = .init(ownerOverride: "Me", userEdited: true)
        let actions = references([.init(id: "a", text: "Run the synthetic load test", owner: "Maya Chen")],
                                 state: state)
        XCTAssertEqual(MeetingDetailPresentation.groups(actions).forYou.map(\.action.id), ["a"])
    }

    func testOwnerNeedsAttentionWhenMissingOrStillAnUnnamedVoice() {
        func needs(_ owner: String?, shown: String? = nil, mine: Bool = false) -> Bool {
            MeetingDetailPresentation.ownerNeedsAttention(owner: owner, displayOwner: shown ?? owner, isForUser: mine)
        }
        XCTAssertTrue(needs(nil))
        XCTAssertTrue(needs("  "))
        XCTAssertTrue(needs("Them 2", shown: "Speaker 2"))
        XCTAssertTrue(needs("Them", shown: "Other speaker"))
        XCTAssertTrue(needs("Unresolved speaker"))
        XCTAssertTrue(needs("Local speaker"))
        XCTAssertFalse(needs("Maya Chen"))
        XCTAssertFalse(needs("Me", shown: "You", mine: true))
        XCTAssertFalse(needs(nil, mine: true), "your own action never asks for an owner")
    }

    func testDueUrgencyMatchesTheActionsListRule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15)))
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
        }
        func urgency(_ date: Date?, _ status: OutcomeStatus = .open) -> MeetingDetailPresentation.DueUrgency {
            MeetingDetailPresentation.dueUrgency(resolved: date, status: status, now: now, calendar: calendar)
        }
        XCTAssertEqual(urgency(day(-1)), .overdue)
        XCTAssertEqual(urgency(day(0)), .soon)
        XCTAssertEqual(urgency(day(ActionAttentionOrder.dueSoonWindowDays)), .soon)
        XCTAssertEqual(urgency(day(ActionAttentionOrder.dueSoonWindowDays + 1)), .later)
        XCTAssertEqual(urgency(nil), .later)
        XCTAssertEqual(urgency(day(-1), .done), .later, "finished work is never overdue")
    }

    func testOwnerOptionsOfferYouThisMeetingsSpeakersInvitedPeopleAndNoOwner() {
        let transcript = transcript
        let speakers = MeetingDetailPresentation.speakers(
            in: transcript, presentation: MeetingSpeakerPresentation(transcript: transcript))
        let stored = MeetingDetailPresentation.storedSpeakerNames(in: transcript, speakers: speakers)
        XCTAssertEqual(stored, ["me": "Me", "them 1": "Maya Chen", "them 2": "Them 2"])
        let options = MeetingDetailPresentation.ownerOptions(
            owner: "Them 2", isForUser: false, speakers: speakers, storedNames: stored,
            invited: ["Daniel Ortiz", "maya chen", " ", "Daniel Ortiz"])
        XCTAssertEqual(options.map(\.title), ["You", "Maya Chen", "Speaker 2", "Daniel Ortiz", "No owner"])
        XCTAssertEqual(options.map(\.kind), [.you, .speaker, .speaker, .invited, .none])
        // An unnamed voice is saved under the transcript's own name for it.
        XCTAssertEqual(options.map(\.value), ["Me", "Maya Chen", "Them 2", "Daniel Ortiz", ""])
        XCTAssertEqual(options.filter(\.isSelected).map(\.title), ["Speaker 2"])
    }

    func testOwnerOptionsSelectExactlyOneChoice() {
        let transcript = transcript
        let speakers = MeetingDetailPresentation.speakers(
            in: transcript, presentation: MeetingSpeakerPresentation(transcript: transcript))
        func selected(_ owner: String?, mine: Bool = false) -> [String] {
            MeetingDetailPresentation.ownerOptions(
                owner: owner, isForUser: mine, speakers: speakers,
                storedNames: MeetingDetailPresentation.storedSpeakerNames(in: transcript, speakers: speakers),
                invited: ["Daniel Ortiz"]).filter(\.isSelected).map(\.title)
        }
        XCTAssertEqual(selected("Me", mine: true), ["You"])
        XCTAssertEqual(selected("MAYA CHEN"), ["Maya Chen"])
        XCTAssertEqual(selected("daniel ortiz"), ["Daniel Ortiz"])
        XCTAssertEqual(selected(nil), ["No owner"])
        XCTAssertEqual(selected("Someone not listed"), [], "a typed owner is none of the menu's choices")
    }

    /// Filmed by CI: after "Them" was named Ana Petrović, the action still
    /// said "Other speaker", yet Ana's menu item counted as already chosen,
    /// so choosing it did nothing.
    func testAnOwnerLeftAsAPlaceholderIsNotTheNamedSpeakerUntilChosen() throws {
        let transcript = Transcript(segments: [
            segment(0, 10, "me", "I'll draft the synthetic policy.", user: true),
            segment(10, 20, "them", "Please benchmark the synthetic failover."),
        ], engine: "fixture", speakerAliases: ["them": "Ana Petrović"])
        let speakers = MeetingDetailPresentation.speakers(
            in: transcript, presentation: MeetingSpeakerPresentation(transcript: transcript))
        let options = MeetingDetailPresentation.ownerOptions(
            owner: "Them", isForUser: false, speakers: speakers,
            storedNames: MeetingDetailPresentation.storedSpeakerNames(in: transcript, speakers: speakers),
            invited: ["Ana Petrović", "Marko Marković"])
        XCTAssertEqual(options.map(\.title), ["You", "Ana Petrović", "Marko Marković", "No owner"])
        XCTAssertEqual(options.filter(\.isSelected).map(\.title), [], "the page still shows Other speaker")
        let action = try XCTUnwrap(references([
            .init(id: "a", text: "Benchmark the synthetic failover", owner: "Them"),
        ]).first)
        let ana = try XCTUnwrap(options.first { $0.title == "Ana Petrović" })
        XCTAssertEqual(MeetingDetailPresentation.ownerCorrection(ana, for: action),
                       .init(text: nil, owner: "Ana Petrović", due: nil))
    }

    func testChoosingTheCurrentOwnerAgainChangesNothing() throws {
        let actions = references([
            .init(id: "a", text: "Run the synthetic load test", owner: "Maya Chen"),
            .init(id: "b", text: "Write the synthetic announcement", owner: "Me"),
            .init(id: "c", text: "Start the synthetic legal review"),
        ])
        func option(_ value: String, _ kind: MeetingDetailPresentation.OwnerOption.Kind)
            -> MeetingDetailPresentation.OwnerOption {
            .init(id: value, title: value, value: value, kind: kind, isSelected: false)
        }
        XCTAssertNil(MeetingDetailPresentation.ownerCorrection(option("maya chen", .speaker), for: actions[0]))
        XCTAssertNil(MeetingDetailPresentation.ownerCorrection(option("Me", .you), for: actions[1]))
        XCTAssertNil(MeetingDetailPresentation.ownerCorrection(option("", .none), for: actions[2]))
        XCTAssertNotNil(MeetingDetailPresentation.ownerCorrection(option("Me", .you), for: actions[0]))
        XCTAssertNotNil(MeetingDetailPresentation.ownerCorrection(option("", .none), for: actions[0]))
    }

    func testChangingOnlyTheOwnerKeepsCorrectedWordingAndDueDate() {
        var state = MeetingOutcomeState()
        state.actions["a"] = .init(dueOverride: "next Friday", textCorrection: "Run the full synthetic load test",
                                   userEdited: true)
        state.actions["b"] = .init(userEdited: true, dueWasCleared: true)
        let actions = references([
            .init(id: "a", text: "Run the synthetic load test", owner: "Maya Chen", due: "Friday"),
            .init(id: "b", text: "Book the synthetic pricing call", owner: "Maya Chen", due: "Monday"),
            .init(id: "c", text: "Start the synthetic legal review", owner: "Maya Chen", due: "Tuesday"),
        ], state: state)
        let you = MeetingDetailPresentation.OwnerOption(id: "you", title: "You", value: "Me", kind: .you,
                                                        isSelected: false)
        XCTAssertEqual(MeetingDetailPresentation.ownerCorrection(you, for: actions[0]),
                       .init(text: "Run the full synthetic load test", owner: "Me", due: "next Friday"))
        XCTAssertEqual(MeetingDetailPresentation.ownerCorrection(you, for: actions[1]),
                       .init(text: nil, owner: "Me", due: ""), "a cleared due date stays cleared")
        XCTAssertEqual(MeetingDetailPresentation.ownerCorrection(you, for: actions[2]),
                       .init(text: nil, owner: "Me", due: nil), "an extracted due date is left to the source")
    }

    func testRowSubtitleReadsTimeLengthThenApp() {
        XCTAssertEqual(MeetingDetailPresentation.rowSubtitle(time: "1:00 PM", duration: "50 min", source: "Zoom"),
                       "1:00 PM · 50 min · Zoom")
        XCTAssertEqual(MeetingDetailPresentation.rowSubtitle(time: "1:00 PM", duration: "50 min", source: nil),
                       "1:00 PM · 50 min")
        XCTAssertEqual(MeetingDetailPresentation.rowSubtitle(time: "in progress", duration: "3 min", source: ""),
                       "in progress · 3 min")
    }

    func testDateLineNamesTheAppAndWarnsOnlyForAMicOnlyRecording() {
        var meeting = meeting
        meeting.hasSystemTrack = false
        let micOnly = MeetingDetailMetadataItem.items(for: meeting)
        XCTAssertEqual(micOnly.map(\.field), [.date, .duration, .app, .audioSource])
        XCTAssertEqual(micOnly.last?.text, "Mic only")
        XCTAssertNotNil(micOnly.last?.warning)
        XCTAssertNil(micOnly.first?.warning)
        meeting.hasSystemTrack = true
        let full = MeetingDetailMetadataItem.items(for: meeting)
        XCTAssertEqual(full.map(\.field), [.date, .duration, .app])
        XCTAssertEqual(full.map(\.text).suffix(2), ["30 min", "Meet"])
    }
}
