import XCTest
@testable import LokalBot

final class DayDigestPresentationTests: XCTestCase {
    func testParsesHumanSummaryAndGroupsForensicLogByHour() {
        let markdown = """
            ## Day summary

            ### At a glance
            - Shipped a clearer digest presentation.
            - Verified the release build.

            ### Focus blocks
            - **09:00–10:15 · Digest redesign** — User implemented the parser [screen:11].
            - **13:05–14:20 · Verification** — Ran focused tests [screen:22] [screen:23].

            ### Other activity
            - **16:00–16:05 · Invoice payment** — Paid one invoice [screen:24].

            ### Decisions and next steps
            - Reinstall the signed app.

            ## Meetings

            ### 12:00 — Product sync
            - Outcome: use progressive disclosure.

            ## Time allocation

            | App | Tracked time |
            | --- | ---: |
            | Xcode | 1h 30m |
            | Safari | 25m |

            ## Full activity log

            - **09:00–09:45** — **Xcode** — DayDigestView.swift
              - [screen:11], 09:20: Structured the digest.
            - **09:45–10:15** — **Xcode** — Tests
            - **13:05** — **Screen context** — Safari — Documentation
              - [screen:22]: Read the API reference.
              - [screen:23]: Compared behavior.
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("clearer digest"))
        XCTAssertEqual(presentation.focusBlocks.count, 2)
        XCTAssertEqual(presentation.focusBlocks.map(\.sourceIDs), [[11], [22, 23]])
        XCTAssertEqual(presentation.focusBlocks.map(\.timeRange), ["09:00–10:15", "13:05–14:20"])
        XCTAssertEqual(presentation.focusBlocks.map(\.title), ["Digest redesign", "Verification"])
        XCTAssertEqual(presentation.focusBlocks.first?.summaryMarkdown,
                       "Implemented the parser.")
        XCTAssertFalse(presentation.focusBlocks.first?.summaryMarkdown.contains("screen:") == true)
        XCTAssertEqual(presentation.otherActivityBlocks.count, 1)
        XCTAssertEqual(presentation.otherActivityBlocks.first?.timeRange, "16:00–16:05")
        XCTAssertEqual(presentation.otherActivityBlocks.first?.title, "Invoice payment")
        XCTAssertEqual(presentation.otherActivityBlocks.first?.sourceIDs, [24])
        XCTAssertEqual(presentation.followUps.map(\.summaryMarkdown), ["Reinstall the signed app."])
        XCTAssertTrue(presentation.meetingsMarkdown?.contains("Product sync") == true)
        XCTAssertEqual(presentation.timeAllocations.map(\.app), ["Xcode", "Safari"])
        XCTAssertEqual(presentation.timeAllocations.map(\.seconds), [5_400, 1_500])
        XCTAssertEqual(presentation.activityGroups.map(\.hour), ["09", "13"])
        XCTAssertEqual(presentation.activityGroups.map { $0.entries.count }, [2, 1])
        XCTAssertEqual(presentation.activityCount, 3)
        XCTAssertEqual(presentation.evidenceCount, 3)
    }

    func testLegacyHeadingsRemainReadableAndExtraSummaryMovesBehindDisclosure() {
        let bullets = (1...10).map { "- Legacy focus \($0)" }.joined(separator: "\n")
        let markdown = """
            ## Day summary

            ### Overview
            A concise legacy overview.

            ### Work completed and in progress
            \(bullets)

            ### Decisions, follow-ups, and blockers
            None found in the evidence.

            ## Meetings

            _None._

            ## Time allocation

            _No tracked app time._

            ## Chronological work log

            - **17:04–17:30** — **Xcode** — Legacy journal
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(presentation.atAGlanceMarkdown, "A concise legacy overview.")
        XCTAssertEqual(presentation.focusBlocks.count, 10)
        assertNoFollowUps(presentation)
        XCTAssertNil(presentation.meetingsMarkdown)
        XCTAssertTrue(presentation.timeAllocations.isEmpty)
        XCTAssertEqual(presentation.activityGroups.first?.label, "17:00–17:59")
    }

    func testKeepsEveryFocusBlockForTheWorkSummary() {
        let bullets = (1...9).map { "- Focus session \($0)" }.joined(separator: "\n")
        let markdown = """
            ## Day summary

            ### Tasks
            \(bullets)
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(presentation.focusBlocks.count, 9)
    }

    func testTopLevelLegacyBriefHeadingsPopulateHighlightsAndTasks() {
        let markdown = """
            ## Today at a glance

            Redis stays the caching layer while the failover benchmark runs.

            ## Next

            - Draft the eviction-policy document.
            - Run the failover benchmark.
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("Redis stays"))
        XCTAssertEqual(presentation.focusBlocks.count, 2)
        XCTAssertEqual(presentation.focusBlocks.first?.summaryMarkdown,
                       "Draft the eviction-policy document.")
    }

    func testOverviewShowsOnlyTheFirstThreeGeneratedHighlights() {
        let markdown = """
            ## Day summary

            ### At a glance
            - First outcome.
            - Second outcome.
            - Third outcome.
            - Fourth lower-priority detail.
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("First outcome"))
        XCTAssertTrue(presentation.atAGlanceMarkdown.contains("Third outcome"))
        XCTAssertFalse(presentation.atAGlanceMarkdown.contains("Fourth"))
    }

    func testSuppressesLegacyOverviewAndFollowUpAlreadyShownInTask() {
        let markdown = """
            ## Day summary

            ### At a glance
            - Release pipeline: Completed. Updated signing and verified the release build.

            ### Tasks
            - **Release pipeline** — Completed. Updated signing and verified the release build. Next: Publish the verified build.

            ### Decisions and next steps
            - Next — Release pipeline: Publish the verified build.
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertTrue(presentation.atAGlanceMarkdown.isEmpty)
        XCTAssertEqual(presentation.focusBlocks.count, 1)
        XCTAssertEqual(presentation.focusBlocks.first?.status, .completed)
        XCTAssertNil(presentation.focusBlocks.first?.nextStep)
        assertNoFollowUps(presentation)
    }

    func testTaskStatusAndNextStepsMoveOntoTheirTasks() {
        let markdown = """
            ## Day summary

            ### Tasks
            - **Publish LokalBot 0.9.5 release** — Completed. Prepared the release notes. Pull requests: stevyhacker/LokalBot#167
            - **Fix overlay positioning: caret-aware placement (PR #169)** — In progress. Identified the root cause and pushed a fix.
            - **Generate Matilda voiceover** — Blocked. Waiting for more audio credits.
            - **Read the API reference** — Looked at the documentation.

            ### Decisions and next steps
            - Decision: Keep a single cloud environment until onboarding starts.
            - **Blocker:** ElevenLabs API credit exhaustion stops the export.
            - Next — Fix overlay positioning: caret-aware placement (PR #169): Enable accessibility text metrics in Chrome.
            - Next — Generate Matilda voiceover: Purchase additional ElevenLabs credits.
            - Next — Estimate the article budget: Run the prepared upgrade scripts.
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(presentation.focusBlocks.map(\.status),
                       [.completed, .inProgress, .blocked, nil])
        XCTAssertEqual(presentation.focusBlocks.first?.summaryMarkdown,
                       "Prepared the release notes. Pull requests: stevyhacker/LokalBot#167")
        XCTAssertEqual(presentation.focusBlocks.map(\.nextStep), [
            nil,
            "Enable accessibility text metrics in Chrome.",
            "Purchase additional ElevenLabs credits.",
            nil,
        ])
        XCTAssertEqual(presentation.decisions,
                       ["Keep a single cloud environment until onboarding starts."])
        XCTAssertEqual(presentation.blockers,
                       ["ElevenLabs API credit exhaustion stops the export."])
        XCTAssertEqual(presentation.followUps.map(\.title), ["Estimate the article budget"])
        XCTAssertEqual(presentation.followUps.map(\.nextStep), ["Run the prepared upgrade scripts."])
        XCTAssertEqual(presentation.followUps.map(\.id), [4])
        XCTAssertEqual(presentation.taskGroups.map(\.kind),
                       [.blocked, .inProgress, .other, .completed])
        XCTAssertEqual(presentation.taskGroups.map { $0.blocks.map(\.id) },
                       [[2], [1], [3], [0]])
    }

    func testTaskFirstDigestCollapsesEveryTitledTaskIncludingUnknownStatus() {
        let taskFirst = DayDigestPresentation(markdown: """
            ## Day summary

            ### Tasks
            - **Publish the release** — Completed. Pushed the release branch after signing passed.
            - **Read the API reference** — Looked through the streaming section of the documentation.
            - **Plan the week** — In progress.
            """)
        XCTAssertEqual(taskFirst.focusBlocks.map(\.status), [.completed, nil, .inProgress])
        XCTAssertEqual(taskFirst.focusBlocks.map { taskFirst.collapsesDetails(of: $0) },
                       [true, true, false])

        let legacy = DayDigestPresentation(markdown: """
            ## Day summary

            ### Focus blocks
            - **09:00–10:30 · Fixture implementation** — User updated the Timeline UI.
            - Reviewed the release checklist.
            """)
        XCTAssertEqual(legacy.focusBlocks.map { legacy.collapsesDetails(of: $0) },
                       [false, false])
    }

    /// Timeline gives full rows to open tasks with a next step and to blocked
    /// tasks; the rest of a group, and all of Done, become one-line rows.
    func testTimelineRowsKeepNextStepsAndBlockersInFull() {
        let presentation = DayDigestPresentation(markdown: """
            ## Day summary

            ### Tasks
            - **Publish the release** — Completed. Pushed the release branch.
            - **Fix overlay positioning (PR #169)** — In progress. Pushed a fix.
            - **Review open PRs** — In progress. Read three diffs.
            - **Generate voiceover** — Blocked. Waiting for audio credits.

            ### Decisions and next steps
            - Next — Fix overlay positioning (PR #169): Enable text metrics in Chrome.
            """)
        func ids(_ kind: DayDigestPresentation.TaskGroup.Kind)
            -> (full: [Int], brief: [Int]) {
            guard let group = presentation.taskGroups.first(where: { $0.kind == kind }) else {
                return ([], [])
            }
            let rows = presentation.timelineRows(of: group)
            return (rows.full.map(\.id), rows.brief.map(\.id))
        }
        XCTAssertTrue(presentation.isTaskFirst)
        XCTAssertEqual(ids(.inProgress).full, [1])
        XCTAssertEqual(ids(.inProgress).brief, [2])
        XCTAssertEqual(ids(.blocked).full, [3])
        XCTAssertEqual(ids(.completed).full, [])
        XCTAssertEqual(ids(.completed).brief, [0])

        let legacy = DayDigestPresentation(markdown: """
            ## Day summary

            ### Focus blocks
            - **09:00–10:30 · Fixture implementation** — User updated the Timeline UI.
            """)
        XCTAssertFalse(legacy.isTaskFirst)
        let rows = legacy.timelineRows(of: legacy.taskGroups[0])
        XCTAssertEqual(rows.full.map(\.id), [0], "older journals keep every summary visible")
        XCTAssertTrue(rows.brief.isEmpty)
    }

    func testTitleTagSplitsOnlyATrailingParenthetical() {
        func split(_ title: String) -> [String?] {
            let parts = DayDigestPresentation.titleAndTag(title)
            return [parts.title, parts.tag]
        }
        XCTAssertEqual(split("Review all open PRs (LokalBot)"), ["Review all open PRs", "LokalBot"])
        XCTAssertEqual(split("alpha: Base/Monad staging deployment (PR #487)"),
                       ["alpha: Base/Monad staging deployment", "PR #487"])
        XCTAssertEqual(split("Protocol fee extraction code review (fork 2) (alpha)"),
                       ["Protocol fee extraction code review (fork 2)", "alpha"])
        XCTAssertEqual(split("Fix layout (overlay (caret))"), ["Fix layout", "overlay (caret)"])
        XCTAssertEqual(split("Machine maintenance, Mojo PR #230"), ["Machine maintenance, Mojo PR #230", nil])
        XCTAssertEqual(split("(LokalBot)"), ["(LokalBot)", nil], "a title is never only its tag")
        XCTAssertEqual(split("Ship it (and then (a long aside that keeps going))"),
                       ["Ship it (and then (a long aside that keeps going))", nil],
                       "a long parenthetical is part of the sentence, not a tag")
        XCTAssertEqual(split("Unbalanced)"), ["Unbalanced)", nil])
    }

    private func assertNoFollowUps(
        _ presentation: DayDigestPresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(presentation.decisions.isEmpty, file: file, line: line)
        XCTAssertTrue(presentation.blockers.isEmpty, file: file, line: line)
        XCTAssertTrue(presentation.followUps.isEmpty, file: file, line: line)
    }

    func testSimilarityRejectsLightRephrasingWithoutHidingDistinctFacts() {
        XCTAssertTrue(DayDigestTextSimilarity.isSimilar(
            "Publish verified build.",
            "Publish the verified build."))
        XCTAssertFalse(DayDigestTextSimilarity.isSimilar(
            "Publish the verified build.",
            "Gatekeeper verification passed."))
    }

    func testTaskSummaryWithoutRenderedOverflowDoesNotOfferExpansionControl() {
        XCTAssertFalse(DayDigestTaskSummaryExpansion.hasRenderedOverflow(
            fullHeight: 48,
            collapsedHeight: 48))
    }

    func testTaskSummaryIgnoresSubpointMeasurementNoise() {
        XCTAssertFalse(DayDigestTaskSummaryExpansion.hasRenderedOverflow(
            fullHeight: 48.75,
            collapsedHeight: 48))
    }

    func testTaskSummaryWaitsForValidLayoutMeasurements() {
        XCTAssertFalse(DayDigestTaskSummaryExpansion.hasRenderedOverflow(
            fullHeight: 0,
            collapsedHeight: 48))
        XCTAssertFalse(DayDigestTaskSummaryExpansion.hasRenderedOverflow(
            fullHeight: 64,
            collapsedHeight: 0))
    }

    func testTaskSummaryWithRenderedOverflowOffersExpansionControl() {
        XCTAssertTrue(DayDigestTaskSummaryExpansion.hasRenderedOverflow(
            fullHeight: 64,
            collapsedHeight: 48))
    }

    func testEmbeddedModesDoNotRepeatHostOwnedSections() {
        XCTAssertFalse(DayDigestView.Mode.timeline.showsTimeAllocation)
        XCTAssertFalse(DayDigestView.Mode.timeline.showsMeetings)
        XCTAssertFalse(DayDigestView.Mode.timeline.showsFullActivityLog)
        XCTAssertFalse(DayDigestView.Mode.timeline.showsOtherActivity)
        XCTAssertFalse(DayDigestView.Mode.timeline.arrangesSessionsInGrid)

        // Today embeds the same sections as Timeline, laid out as a card grid.
        XCTAssertFalse(DayDigestView.Mode.today.showsTimeAllocation)
        XCTAssertFalse(DayDigestView.Mode.today.showsMeetings)
        XCTAssertFalse(DayDigestView.Mode.today.showsFullActivityLog)
        XCTAssertFalse(DayDigestView.Mode.today.showsOtherActivity)
        XCTAssertTrue(DayDigestView.Mode.today.arrangesSessionsInGrid)

        XCTAssertTrue(DayDigestView.Mode.standalone.showsTimeAllocation)
        XCTAssertTrue(DayDigestView.Mode.standalone.showsMeetings)
        XCTAssertTrue(DayDigestView.Mode.standalone.showsFullActivityLog)
        XCTAssertTrue(DayDigestView.Mode.standalone.showsOtherActivity)
    }

    func testLegacyUnheadedOverviewAndUnicodeHyphenDecisionSentinel() {
        let markdown = """
            ## Day summary

            The day began with a substantive implementation session.

            ### Work completed and in progress
            - Implemented the structured digest.

            ### Decisions, follow‑ups, and blockers
            None found in the evidence.

            ## Chronological work log
            - **09:00–10:00** — **Xcode** — Implementation
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(
            presentation.atAGlanceMarkdown,
            "The day began with a substantive implementation session.")
        assertNoFollowUps(presentation)
        XCTAssertEqual(presentation.focusBlocks.count, 1)
    }

    func testOldStandaloneWhatIWorkedOnTableStillParses() {
        let markdown = """
            Date: Wednesday

            ## What I worked on
            - Development and collaboration
            - Analytics and monitoring

            ## Meetings
            None

            ## Time allocation
            | App | Primary use |
            | --- | --- |
            | Google Chrome | Research and monitoring |
            | LokalBot | Local recall |
            """

        let presentation = DayDigestPresentation(markdown: markdown)

        XCTAssertEqual(presentation.focusBlocks.count, 2)
        XCTAssertNil(presentation.meetingsMarkdown)
        XCTAssertEqual(presentation.timeAllocations.map(\.app), ["Google Chrome", "LokalBot"])
        XCTAssertEqual(presentation.timeAllocations.map(\.detail),
                       ["Research and monitoring", "Local recall"])
    }

    func testGenerationPromptEnforcesConciseProgressiveStructure() {
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("task-first"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("block_indices"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("Recorded time may only break ties"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("Omit activity that identifies no concrete item"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("instead of omitting them"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("different apps"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("exactly one owner"))
        XCTAssertTrue(PromptTemplates.dayDigestFallbackSystem.contains("low-signal"))
        XCTAssertTrue(PromptTemplates.dayDigestFallbackSystem.contains("block_indices"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("substantive work"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("weak metadata"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("substantive: false"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("still fill"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("work_done"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("source_ids"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("Do not infer completion"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("non-overlapping"))
    }
}
