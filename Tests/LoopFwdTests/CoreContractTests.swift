import AppKit
import XCTest
@testable import LoopFwd

final class CoreContractTests: XCTestCase {
    func testNodeProcessSelectionPreservesIndependentChildSessions() {
        for kind in [AgentKind.qwen, .gemini] {
            func selected(_ launchers: Set<Int32>) -> [Int32] {
                [(Int32(10), Int32(1)), (Int32(20), Int32(10))].compactMap { pid, parent in
                    ProcessNaming.retainsAgentProcess(
                        pid: pid, kind: kind, parentPID: parent, parentKind: parent == 10 ? kind : nil,
                        launchers: launchers) ? pid : nil
                }
            }
            XCTAssertEqual(selected([]), [10, 20], "Same brand is not a relaunch proof")
            XCTAssertEqual(selected([10]), [20], "Only the proven launcher should disappear")
        }
    }

    func testProcessEnvironmentPreservesEmptyArgumentsAndFiltersKeys() throws {
        let key = "QWEN_CODE_NO_RELAUNCH"
        for argv in [["node", "cli.js"], ["node", "cli.js", ""], ["node", "", "cli.js", ""]] {
            var argc = Int32(argv.count)
            var bytes = withUnsafeBytes(of: &argc) { Array($0) }
            bytes += Array("/opt/node\0\0\0".utf8)
            for arg in argv { bytes += Array(arg.utf8) + [0] }
            bytes += Array("\(key)=true\0UNRELATED=must-not-return\0\0".utf8)
            XCTAssertEqual(AgentScanner.environmentValues(in: bytes, keys: [key]), [key: "true"])
            XCTAssertEqual(AgentScanner.environmentValues(in: bytes, keys: ["missing"]), [:])
            XCTAssertNil(AgentScanner.environmentValues(in: Array(bytes.dropLast(2)), keys: [key]))
        }
        XCTAssertNil(AgentScanner.environmentValues(in: [], keys: [key]))
        XCTAssertNil(AgentScanner.environmentValues(in: [255, 255, 255, 255, 0], keys: [key]))
    }

    func testOfficialNodeEntrypointsAndRelaunchIdentity() {
        let qwen = "/fixture/node_modules/@qwen-code/qwen-code/"
        let gemini = "/fixture/node_modules/@google/gemini-cli/bundle/gemini.js"
        for path in [qwen + "cli-entry.js", qwen + "cli.js", gemini] {
            let kind: AgentKind = path == gemini ? .gemini : .qwen
            for flags in ["", "--expose-gc ", "--max-old-space-size=8192 --expose-gc "] {
                XCTAssertEqual(AgentScanner.detect(args: "node \(flags)\(path) --screen-reader", tty: "ttys001"), kind)
            }
            for prefix in [
                "node other.js ", "node --eval ", "node --require ", "node --eval=", "node --require=",
                "node --import=", "echo node ",
            ] {
                XCTAssertNil(AgentScanner.detect(args: prefix + path, tty: "ttys001"))
            }
            XCTAssertNil(AgentScanner.detect(args: "node \(path).bak", tty: "ttys001"))
        }
        XCTAssertNil(AgentScanner.detect(args: "node /project/cli.js", tty: "ttys001"))
        XCTAssertTrue(
            ProcessNaming.isNodeAgentRelaunch(
                parentPID: 11, parentCommand: "node \(qwen)cli-entry.js",
                childCommand: "node --expose-gc \(qwen)cli.js",
                parentEnvironment: [:], childEnvironment: ["QWEN_CODE_LAUNCHER_PID": "11"]))
        XCTAssertFalse(
            ProcessNaming.isNodeAgentRelaunch(
                parentPID: 11, parentCommand: "node \(qwen)cli-entry.js",
                childCommand: "node --expose-gc \(qwen)cli.js",
                parentEnvironment: [:], childEnvironment: ["QWEN_CODE_LAUNCHER_PID": "12"]))
        for (path, key) in [(qwen + "cli.js", "QWEN_CODE_NO_RELAUNCH"), (gemini, "GEMINI_CLI_NO_RELAUNCH")] {
            XCTAssertTrue(
                ProcessNaming.isNodeAgentRelaunch(
                    parentPID: 11, parentCommand: "node \(path)", childCommand: "node --expose-gc \(path)",
                    parentEnvironment: [:], childEnvironment: [key: "true"]))
            XCTAssertFalse(
                ProcessNaming.isNodeAgentRelaunch(
                    parentPID: 11, parentCommand: "node \(path)", childCommand: "node --expose-gc \(path)",
                    parentEnvironment: [key: "true"], childEnvironment: [key: "true"]))
            XCTAssertFalse(
                ProcessNaming.isNodeAgentRelaunch(
                    parentPID: 11, parentCommand: "node \(path)", childCommand: "node --expose-gc /other\(path)",
                    parentEnvironment: [:], childEnvironment: [key: "true"]))
        }
    }

    func testDiagnosticsDistinguishesPartialEmptyFailedAndIncompatibleReads() {
        let expected = [
            "success": "Data source ready",
            "empty": "Data source ready · no sessions",
            "partial": "Partial data · scan incomplete",
            "incompatible": "Data source version incompatible",
            "failed": "Data temporarily unavailable",
            "unknown": "Data temporarily unavailable",
        ]
        for (outcome, key) in expected {
            XCTAssertEqual(DiagnosticsPane.sourceHealthKey(for: outcome), key)
        }
        XCTAssertEqual(
            L10n.string("Partial data · scan incomplete", language: "zh-Hans"), "部分数据可用 · 扫描未完整完成")
        XCTAssertEqual(
            L10n.string("Last complete read: %@", language: "zh-Hans"), "上次完整读取：%@")
    }

    @MainActor
    func testHoverTrackingAreaSurvivesAnimatedBoundsAndReattachment() {
        let view = AppKitHoverTracker.TrackingView(onChange: { _ in })
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 860))
        parent.addSubview(view)
        view.updateTrackingAreas()
        guard let original = view.trackingAreas.first else {
            return XCTFail("Expected a native tracking area")
        }
        XCTAssertTrue(original.options.contains(.inVisibleRect))
        XCTAssertTrue(original.options.contains(.activeAlways))
        for width in stride(from: 365.0, through: 530.0, by: 5) {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 195)
            view.updateTrackingAreas()
            XCTAssertEqual(view.trackingAreas.count, 1)
            XCTAssertTrue(view.trackingAreas.first === original)
        }
        view.removeFromSuperview()
        parent.addSubview(view)
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.first === original)
    }

    func testLayoutTraceIsBoundedAndSnapshotsDoNotChange() {
        let trace = IslandTraceBuffer(capacity: 2)
        trace.append("first")
        let original = trace.snapshot()
        trace.append("second")
        trace.append(String(repeating: "x", count: 1000))
        XCTAssertEqual(original, ["first"])
        XCTAssertEqual(trace.snapshot().count, 2)
        XCTAssertEqual(trace.snapshot().first, "second")
        XCTAssertEqual(trace.snapshot().last?.count, 256)
    }

    func testKeyboardDismissalCannotRestoreAnExcludedOrHiddenPanel() {
        for visible in [false, true] {
            for onActiveSpace in [false, true] {
                for alpha in [0.0, 0.49, 0.5, 1.0] {
                    XCTAssertEqual(
                        NotchSpacePolicy.shouldRestoreAfterKeyboardDismissal(
                            isVisible: visible, isOnActiveSpace: onActiveSpace, alpha: alpha),
                        visible && onActiveSpace && alpha >= 0.5)
                }
            }
        }
    }

    func testFullscreenSpacePolicySeparatesDesktopAndFullscreenEligibility() {
        for currentSpaceOnly in [false, true] {
            let hidden = NotchSpacePolicy.collectionBehavior(hideInFullscreen: true, currentSpaceOnly: currentSpaceOnly)
            let visible = NotchSpacePolicy.collectionBehavior(
                hideInFullscreen: false, currentSpaceOnly: currentSpaceOnly)
            XCTAssertTrue(hidden.contains(.fullScreenPrimary))
            XCTAssertFalse(hidden.contains(.fullScreenAuxiliary))
            XCTAssertTrue(visible.contains(.fullScreenAuxiliary))
            XCTAssertFalse(visible.contains(.fullScreenPrimary))
            for behavior in [hidden, visible] {
                XCTAssertEqual(behavior.contains(.moveToActiveSpace), currentSpaceOnly)
                XCTAssertEqual(behavior.contains(.canJoinAllSpaces), !currentSpaceOnly)
                XCTAssertEqual(behavior.contains(.stationary), !currentSpaceOnly)
                XCTAssertFalse(behavior.contains(.fullScreenNone))
            }
        }
    }

    func testTaskSummaryPrioritizesActivePlanAndRemovesGoalPrefix() {
        var session = makeSession()
        session.lastPrompt = "Old conversation opener"
        session.lastMessage = "A generic progress message"
        session.todos = [
            Todo(content: "/Goal Complete the release prototype", status: "in_progress"),
            Todo(content: "Later work", status: "pending"),
        ]
        XCTAssertEqual(session.currentTaskSummary, "Complete the release prototype")
    }

    func testTaskAndCurrentStepDoNotOverwriteEachOther() {
        var session = makeSession(status: .working)
        session.lastPrompt = "Improve lifecycle notifications"
        session.lastMessage = "I changed several files"
        session.activity = "Running tests"

        XCTAssertEqual(session.currentTaskSummary, "Improve lifecycle notifications")
        XCTAssertEqual(session.currentStepSummary, L10n.format("Running %@", "tests"))
    }

    func testActiveTodoBecomesStepWhileUserGoalRemainsTheTask() {
        let presentation = TaskPresentationResolver.resolve(
            project: "LoopFwd",
            previousTask: nil,
            lastPrompt: "Make active work easier to monitor",
            todos: [Todo(content: "Run the release build", status: "in_progress")],
            activity: nil,
            isActive: true
        )

        XCTAssertEqual(presentation.task, "Make active work easier to monitor")
        XCTAssertEqual(presentation.step, "Run the release build")
    }

    func testProcessOnlyStateDoesNotClaimIdle() {
        var session = makeSession()
        session.status = .idle
        session.observation = .processOnly("Process table", reason: "Reader unavailable")
        XCTAssertEqual(session.statusLabel, "Process detected")
    }

    func testStableIdentityIsIndependentFromProcessID() {
        var first = makeSession(id: "codex:thread-1", processID: 100)
        let second = makeSession(id: "codex:thread-1", processID: 200)
        first.processID = 200
        XCTAssertEqual(first.id, second.id)
    }

    func testLifecycleReducerDeduplicatesStableSessionIdentity() {
        let reducer = AgentLifecycleReducer()
        let now = Date(timeIntervalSince1970: 9_000)
        var first = makeSession(id: "codex:same", processID: 100, status: .working)
        first.observation = .rich("Fixture", updatedAt: now)
        var newer = first
        newer.processID = 200
        newer.activity = "Running tests"

        let reduced = reducer.reduce(
            [first, newer], suppressEvents: true, now: now
        )
        XCTAssertEqual(reduced.sessions.count, 1)
        XCTAssertEqual(reduced.sessions.first?.processID, 200)
        XCTAssertEqual(reduced.sessions.first?.activity, "Running tests")
    }

    func testReturnTargetFailsClosed() {
        let target = ReturnTarget.unavailable(reason: "Window could not be resolved")
        XCTAssertNil(target.label)
        XCTAssertEqual(target.unavailableReason, "Window could not be resolved")
    }

    func testCompletionAppearsBrieflyThenLeavesTheActiveList() {
        let center = NotificationCenter()
        var current = Date(timeIntervalSince1970: 10_000)
        var scheduled: [() -> Void] = []
        let presentations = OutcomePresentation(
            notificationCenter: center,
            now: { current },
            schedule: { _, action in scheduled.append(action) }
        )
        var completed = makeSession(status: .completed)
        completed.observation = .rich(
            "Fixture", updatedAt: Date(timeIntervalSinceNow: -10)
        )

        XCTAssertTrue(presentations.visible([completed]).isEmpty)
        center.post(name: .agentCompleted, object: completed.id)
        XCTAssertEqual(presentations.visible([completed]).map(\.id), [completed.id])

        current = current.addingTimeInterval(OutcomePresentation.completionDuration + 0.1)
        scheduled.forEach { $0() }
        XCTAssertTrue(presentations.visible([completed]).isEmpty)

        var working = completed
        working.status = .working
        XCTAssertEqual(presentations.visible([working]).map(\.id), [working.id])
    }

    func testOpeningCompletionDismissesOnlyThatTransientResult() {
        let center = NotificationCenter()
        let presentations = OutcomePresentation(
            notificationCenter: center,
            schedule: { _, _ in }
        )
        let first = makeSession(id: "codex:first", status: .completed)
        let second = makeSession(id: "codex:second", status: .completed)

        center.post(name: .agentCompleted, object: first.id)
        center.post(name: .agentCompleted, object: second.id)
        presentations.dismiss(first)

        XCTAssertEqual(presentations.visible([first, second]).map(\.id), [second.id])
    }

    func testExplicitStopAppearsBrieflyWithoutBecomingHistory() {
        let center = NotificationCenter()
        var current = Date(timeIntervalSince1970: 11_000)
        var scheduled: [() -> Void] = []
        let presentations = OutcomePresentation(
            notificationCenter: center,
            now: { current },
            schedule: { _, action in scheduled.append(action) }
        )
        let stopped = makeSession(status: .stopped)

        XCTAssertTrue(presentations.visible([stopped]).isEmpty)
        center.post(name: .agentStopped, object: stopped.id)
        XCTAssertEqual(presentations.visible([stopped]).map(\.id), [stopped.id])

        current = current.addingTimeInterval(OutcomePresentation.stoppedDuration + 0.1)
        scheduled.forEach { $0() }
        XCTAssertTrue(presentations.visible([stopped]).isEmpty)
    }

    func testViewingFailureDismissesItUntilANewFailureEvent() {
        let center = NotificationCenter()
        let presentations = OutcomePresentation(
            notificationCenter: center,
            schedule: { _, _ in }
        )
        let failed = makeSession(status: .failed)

        XCTAssertEqual(presentations.visible([failed]).map(\.id), [failed.id])
        presentations.dismiss(failed)
        XCTAssertTrue(presentations.visible([failed]).isEmpty)

        center.post(name: .agentFailed, object: failed.id)
        XCTAssertEqual(presentations.visible([failed]).map(\.id), [failed.id])
    }

    func testLifecycleLabelsDoNotConflateCompletionWithAttention() {
        XCTAssertEqual(AgentStatus.stalled.label, "Possibly stalled")
        XCTAssertEqual(AgentStatus.completed.label, "Completed")
        XCTAssertEqual(AgentStatus.needsAttention.label, "Needs attention")
        XCTAssertEqual(AgentStatus.failed.label, "Failed")
        XCTAssertEqual(AgentStatus.stopped.label, "Stopped")
    }

    func testLifecycleReducerEmitsOneProviderConfirmedCompletion() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 10_000)
        var working = makeSession(status: .working)
        working.observation = .rich("Fixture", updatedAt: start)

        XCTAssertTrue(
            reducer.reduce([working], suppressEvents: true, now: start).events.isEmpty
        )

        var completed = working
        completed.status = .completed
        completed.observation.updatedAt = start.addingTimeInterval(5)
        let transition = reducer.reduce(
            [completed], suppressEvents: false, now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(transition.events.map(\.kind), [.completed])

        let unchanged = reducer.reduce(
            [completed], suppressEvents: false, now: start.addingTimeInterval(6)
        )
        XCTAssertTrue(unchanged.events.isEmpty)
    }

    func testProcessHeuristicNeverInventsCompletion() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 20_000)
        var working = makeSession(status: .working)
        working.observation = .processOnly("Process table")
        _ = reducer.reduce([working], suppressEvents: true, now: start)

        var idle = working
        idle.status = .idle
        let transition = reducer.reduce(
            [idle], suppressEvents: false, now: start.addingTimeInterval(8)
        )
        XCTAssertTrue(transition.events.isEmpty)
        XCTAssertEqual(transition.sessions.first?.status, .idle)
    }

    func testReaderFailureKeepsLastPhaseInsteadOfClaimingIdle() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 30_000)
        var working = makeSession(status: .working)
        working.observation = .rich("Fixture", updatedAt: start)
        _ = reducer.reduce([working], suppressEvents: true, now: start)

        var stale = working
        stale.status = .idle
        stale.observation = .init(
            mode: .stale,
            updatedAt: start,
            source: "Fixture",
            reason: "Reader unavailable"
        )
        let degraded = reducer.reduce(
            [stale], suppressEvents: false, now: start.addingTimeInterval(10)
        )
        XCTAssertEqual(degraded.sessions.first?.status, .working)
        XCTAssertEqual(degraded.sessions.first?.statusLabel, "Data stale")
        XCTAssertTrue(degraded.events.isEmpty)
    }

    func testLifecycleReducerMarksAndRecoversPossiblyStalled() {
        let start = Date(timeIntervalSince1970: 40_000)
        let reducer = AgentLifecycleReducer(stalledAfter: 180)
        var working = makeSession(status: .working)
        working.activity = "Editing files"
        working.observation = .rich("Fixture", updatedAt: start)
        _ = reducer.reduce([working], suppressEvents: true, now: start)

        let stalled = reducer.reduce(
            [working], suppressEvents: false, now: start.addingTimeInterval(181)
        )
        XCTAssertEqual(stalled.sessions.first?.status, .stalled)
        XCTAssertEqual(stalled.events.map(\.kind), [.stalled])

        working.activity = "Running tests"
        working.observation.updatedAt = start.addingTimeInterval(182)
        let resumed = reducer.reduce(
            [working], suppressEvents: false, now: start.addingTimeInterval(182)
        )
        XCTAssertEqual(resumed.sessions.first?.status, .working)
        XCTAssertEqual(resumed.events.map(\.kind), [.resumed])
    }

    func testAttentionRequiresMoreThanProcessHeuristics() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 50_000)
        var idle = makeSession(kind: .opencode, status: .idle)
        idle.observation = .processOnly("Process table")
        _ = reducer.reduce([idle], suppressEvents: true, now: start)

        var attention = idle
        attention.status = .needsAttention
        attention.lastMessage = "Approve this action"
        let transition = reducer.reduce(
            [attention], suppressEvents: false, now: start.addingTimeInterval(1)
        )
        XCTAssertTrue(transition.events.isEmpty)
        XCTAssertEqual(transition.sessions.first?.status, .idle)
    }

    func testExperimentalReaderCannotInventNeedsAttention() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 50_500)
        var session = makeSession(kind: .grok, status: .needsAttention)
        session.observation = .rich("Experimental local store", updatedAt: start)

        let reduction = reducer.reduce([session], suppressEvents: false, now: start)

        XCTAssertEqual(reduction.sessions.first?.status, .idle)
        XCTAssertTrue(reduction.events.isEmpty)
    }

    func testOpenCodeDesktopPendingToolIsWorkNotUserAttention() {
        XCTAssertEqual(
            OpenCodeDesktopSessions.status(
                toolStatus: "pending",
                hasAssistantError: false,
                age: 1,
                userCreated: 2,
                assistantCreated: 1,
                assistantCompleted: false,
                hasAssistant: true,
                hasUser: true
            ),
            .working
        )
    }

    func testActivePresentationHidesIdleInventoryRegardlessOfObservationHealth() {
        var idle = makeSession(id: "codex:idle", status: .idle)
        idle.observation = .processOnly("Process table")
        var stale = makeSession(id: "codex:stale", status: .idle)
        stale.observation = .init(
            mode: .stale,
            updatedAt: Date(),
            source: "Fixture",
            reason: "Reader unavailable"
        )
        let visible = SessionPresentationPolicy.visible([idle, stale])
        XCTAssertTrue(visible.isEmpty)
    }

    func testActivePresentationKeepsStaleWorkVisible() {
        var staleWorking = makeSession(id: "codex:working-stale", status: .working)
        staleWorking.observation = .init(
            mode: .stale,
            updatedAt: Date(),
            source: "Fixture",
            reason: "Reader unavailable"
        )

        XCTAssertEqual(
            SessionPresentationPolicy.visible([staleWorking]).map(\.id),
            [staleWorking.id]
        )
    }

    func testPresentationPriorityIsActionBeforeBackgroundWork() {
        let sessions = [
            makeSession(id: "completed", status: .completed),
            makeSession(id: "working", status: .working),
            makeSession(id: "stalled", status: .stalled),
            makeSession(id: "failed", status: .failed),
            makeSession(id: "attention", status: .needsAttention),
        ]
        XCTAssertEqual(
            SessionPresentationPolicy.visible(sessions).map(\.id),
            ["attention", "failed", "stalled", "working", "completed"]
        )
    }

    func testEveryActiveSessionRemainsAccessibleBeyondTheCompactLimit() {
        let sessions = (0..<8).map { makeSession(id: "session-\($0)", status: .working) }

        XCTAssertEqual(
            SessionAccessPolicy.displayed(
                sessions, maximum: 6, showAll: false, switcherActive: false
            ).count,
            6
        )
        XCTAssertEqual(
            SessionAccessPolicy.displayed(
                sessions, maximum: 6, showAll: true, switcherActive: false
            ).map(\.id),
            sessions.map(\.id)
        )
        XCTAssertEqual(
            SessionAccessPolicy.displayed(
                sessions, maximum: 6, showAll: false, switcherActive: true
            ).map(\.id),
            sessions.map(\.id)
        )
    }

    func testCardTypographySupportsUpToTwoHundredPercentWithoutGrowingTheIslandWidth() {
        XCTAssertEqual(AccessibilityTypography.cardFontSize(base: 11, scaledReference: 11), 11)
        XCTAssertEqual(AccessibilityTypography.cardFontSize(base: 11, scaledReference: 16.5), 16.5)
        XCTAssertEqual(AccessibilityTypography.cardFontSize(base: 11, scaledReference: 33), 22)
    }

    func testNotificationTypesHaveIndependentPreferences() {
        XCTAssertEqual(
            AgentNotificationPolicy.preferenceKey(for: .completed), Pref.notifyOnComplete
        )
        XCTAssertEqual(
            AgentNotificationPolicy.preferenceKey(for: .needsAttention), Pref.notifyOnAttention
        )
        XCTAssertEqual(
            AgentNotificationPolicy.preferenceKey(for: .failed), Pref.notifyOnFailure
        )
        XCTAssertEqual(
            AgentNotificationPolicy.preferenceKey(for: .stalled), Pref.notifyOnStalled
        )
        XCTAssertNil(AgentNotificationPolicy.preferenceKey(for: .stopped))
    }

    func testTypedDefaultsMatchTheFirstRunProductPolicy() {
        XCTAssertFalse(Pref.Default.autoRevealOnComplete)
        XCTAssertTrue(Pref.Default.notifyOnAttention)
        XCTAssertTrue(Pref.Default.notifyOnFailure)
        XCTAssertTrue(Pref.Default.notifyOnComplete)
        XCTAssertFalse(Pref.Default.notifyOnStalled)
        XCTAssertFalse(Pref.Default.notifyOnStart)
        XCTAssertFalse(Pref.Default.claudeControlsEnabled)
        XCTAssertEqual(Pref.Default.maxVisibleSessions, 6)
    }

    func testDistinctAttentionRequestsReceiveDistinctEventRevisions() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 60_000)
        var idle = makeSession(kind: .opencode, status: .idle)
        idle.observation = .rich(
            "Fixture", updatedAt: start, authority: .officialLive
        )
        _ = reducer.reduce([idle], suppressEvents: true, now: start)

        var first = idle
        first.status = .needsAttention
        first.lastMessage = "Approve command A"
        first.attentionKind = .approval
        first.observation.updatedAt = start.addingTimeInterval(1)
        let firstEvent = reducer.reduce(
            [first], suppressEvents: false, now: start.addingTimeInterval(1)
        ).events.first

        var second = first
        second.lastMessage = "Approve command B"
        second.observation.updatedAt = start.addingTimeInterval(2)
        let secondEvent = reducer.reduce(
            [second], suppressEvents: false, now: start.addingTimeInterval(2)
        ).events.first

        XCTAssertEqual(firstEvent?.kind, .needsAttention)
        XCTAssertEqual(secondEvent?.kind, .needsAttention)
        XCTAssertNotEqual(firstEvent?.deduplicationKey, secondEvent?.deduplicationKey)
    }

    func testIntegrationProfilesSeparateSurfaceControlFromExperimentalObservation() {
        let codex = IntegrationProfiles.profile(for: .codexManaged, kind: .codex)
        XCTAssertEqual(codex.supportTier, SupportRegistry.tier(.codexManaged))
        XCTAssertEqual(codex.phaseAuthority, .officialLive)
        XCTAssertTrue(codex.capabilities.contains(.stop))
        XCTAssertEqual(codex.controlPolicy, .managedProvider)
        XCTAssertEqual(codex.degradationPolicy, .stale)
        XCTAssertLessThanOrEqual(codex.readerBudget, 1)
        XCTAssertTrue(codex.capabilities.diagnosticLabels.contains("exact-return"))

        let deepSeek = IntegrationProfiles.profile(for: .deepSeekWeb, kind: .deepseek)
        XCTAssertEqual(deepSeek.phaseAuthority, .versionedObserver)
        XCTAssertFalse(deepSeek.capabilities.contains(.reply))
        XCTAssertFalse(deepSeek.capabilities.contains(.exactReturn))
        XCTAssertEqual(deepSeek.degradationPolicy, .incompatible)
        XCTAssertTrue(deepSeek.supportedVersions.contains("0.1.2-alpha.5"))

        let gemini = IntegrationProfiles.profile(for: .experimentalLocal, kind: .gemini)
        XCTAssertEqual(gemini.supportTier, .experimental)
        XCTAssertFalse(gemini.capabilities.contains(.approve))
        XCTAssertEqual(gemini.degradationPolicy, .processOnly)
    }

    func testReaderDeadlineReturnsBeforeASlowProvider() async {
        let startedAt = Date()
        let result = await ReaderDeadline.run(seconds: 0.01) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return 42
        }

        if case .timedOut = result {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.15)
        } else {
            XCTFail("Slow Reader should have timed out")
        }
    }

    func testReturnCapabilitiesDistinguishProviderActivationFromExactJump() {
        let generic = ReturnTarget.application(
            bundleIdentifier: "ai.opencode.desktop",
            name: "OpenCode"
        )
        XCTAssertEqual(generic.capability, .providerOnly(label: "OpenCode"))

        let exact = CodexDeepLink.returnTarget(threadID: "thread-123")
        XCTAssertEqual(exact.capability, .exact(label: "Codex"))

        XCTAssertEqual(
            ReturnTarget.unavailable(reason: "Session vanished").capability,
            .unavailable(reason: "Session vanished")
        )

        let exactTerminal = ReturnTarget.terminal(
            app: "Terminal", tty: "ttys001", processID: 100
        )
        XCTAssertEqual(exactTerminal.capability, .exact(label: "Terminal"))

        let appOnlyTerminal = ReturnTarget.terminal(
            app: "Warp", tty: "ttys001", processID: 100
        )
        XCTAssertEqual(appOnlyTerminal.capability, .providerOnly(label: "Warp"))
    }

    func testGenericFollowUpDoesNotReplaceTrackedTask() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 65_000)
        var initial = makeSession(status: .working)
        initial.lastPrompt = "Improve task lifecycle accuracy"
        initial.observation.updatedAt = start
        let first = reducer.reduce([initial], suppressEvents: true, now: start)
        XCTAssertEqual(first.sessions.first?.taskAnchor, "Improve task lifecycle accuracy")

        var continued = initial
        continued.lastPrompt = "继续"
        continued.observation.updatedAt = start.addingTimeInterval(1)
        let second = reducer.reduce(
            [continued], suppressEvents: false, now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(second.sessions.first?.taskAnchor, "Improve task lifecycle accuracy")
    }

    func testTemporarilyMissingSessionIsRetainedDuringReconciliationGrace() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 66_000)
        var working = makeSession(status: .working)
        working.observation.updatedAt = start
        _ = reducer.reduce([working], suppressEvents: true, now: start)

        let transient = reducer.reduce([], suppressEvents: false, now: start.addingTimeInterval(5))
        XCTAssertEqual(transient.sessions.first?.id, working.id)
        XCTAssertEqual(transient.sessions.first?.observation.mode, .stale)
        XCTAssertTrue(transient.events.isEmpty)

        let expired = reducer.reduce([], suppressEvents: false, now: start.addingTimeInterval(26))
        XCTAssertTrue(expired.sessions.isEmpty)
        XCTAssertTrue(expired.events.isEmpty)
    }

    func testExactVisibilityRequiresTheSameSelectedTTY() {
        XCTAssertTrue(
            ExactTargetVisibilityPolicy.shouldSuppress(
                appMatches: true,
                capability: .exact(label: "Terminal"),
                selectedTTY: "/dev/ttys001",
                targetTTY: "ttys001"
            )
        )
        XCTAssertFalse(
            ExactTargetVisibilityPolicy.shouldSuppress(
                appMatches: true,
                capability: .exact(label: "Terminal"),
                selectedTTY: "ttys002",
                targetTTY: "ttys001"
            )
        )
        XCTAssertFalse(
            ExactTargetVisibilityPolicy.shouldSuppress(
                appMatches: true,
                capability: .providerOnly(label: "Codex"),
                selectedTTY: "ttys001",
                targetTTY: "ttys001"
            )
        )
    }

    func testNotificationIdentifierIsStablePerSession() {
        let first = AgentNotificationRouter.notificationIdentifier(sessionID: "codex:thread-1")
        let replacement = AgentNotificationRouter.notificationIdentifier(sessionID: "codex:thread-1")
        let other = AgentNotificationRouter.notificationIdentifier(sessionID: "codex:thread-2")

        XCTAssertEqual(first, replacement)
        XCTAssertNotEqual(first, other)
    }

    func testNotificationBodyUsesBoundedSemanticText() {
        var session = makeSession(status: .failed)
        session.lastMessage = String(repeating: "failure detail ", count: 20)
        let event = AgentLifecycleEvent(kind: .failed, session: session, occurredAt: Date())

        XCTAssertLessThanOrEqual(AgentNotificationPolicy.body(for: event).count, 96)
    }

    func testOpenCodeMultiQuestionRequiresAnsweringInProvider() {
        let request: [String: Any] = [
            "id": "question-1",
            "sessionID": "session-1",
            "questions": [
                ["question": "Choose A", "options": [["label": "A"]]],
                ["question": "Choose B", "options": [["label": "B"]]],
            ],
        ]
        let projection = OpenCodeSessions.questionProjection(
            request: request, sessionID: "session-1"
        )

        XCTAssertEqual(projection?.requestID, "question-1")
        XCTAssertFalse(projection?.isSupported ?? true)
    }

    func testAdapterCapabilityPreventsUnsupportedCompletionClaim() {
        let reducer = AgentLifecycleReducer()
        let start = Date(timeIntervalSince1970: 70_000)
        var working = makeSession(kind: .gemini, status: .working)
        working.observation = .rich("Gemini fixture", updatedAt: start)
        _ = reducer.reduce([working], suppressEvents: true, now: start)

        var completed = working
        completed.status = .completed
        completed.observation.updatedAt = start.addingTimeInterval(1)
        let transition = reducer.reduce(
            [completed], suppressEvents: false, now: start.addingTimeInterval(1)
        )
        XCTAssertTrue(transition.events.isEmpty)
    }

    func testCodexTaskDeepLinkTargetsOneExactThread() {
        let threadID = "01a05ae6-6c67-71d2-8426-24a922f2fc26"
        XCTAssertEqual(
            CodexDeepLink.threadURL(threadID: threadID)?.absoluteString,
            "codex://threads/\(threadID)"
        )
        XCTAssertEqual(CodexDeepLink.returnTarget(threadID: threadID).label, "Codex")
    }

    func testCodexTaskDeepLinkRejectsPathInjection() {
        XCTAssertNil(CodexDeepLink.threadURL(threadID: "task/../other"))
        XCTAssertNil(CodexDeepLink.threadURL(threadID: ""))
        XCTAssertNil(CodexDeepLink.returnTarget(threadID: "bad/task").label)
    }

    func testOnlyKnownTerminalHostsCanBeActivated() {
        XCTAssertTrue(ProcessNaming.isSupportedTerminalHost("Terminal"))
        XCTAssertTrue(ProcessNaming.isSupportedTerminalHost("VS Code"))
        XCTAssertFalse(ProcessNaming.isSupportedTerminalHost("Finder"))
        XCTAssertFalse(ProcessNaming.isSupportedTerminalHost("\" to quit"))
    }

    func testAppleScriptDynamicTextStaysInArgv() {
        let hostile = "hello \" & do shell script \"touch /tmp/nope\" & \""
        let arguments = TerminalBridge.appleScriptProcessArguments(
            source: "on run argv\nreturn item 1 of argv\nend run",
            arguments: [hostile]
        )

        XCTAssertEqual(arguments.count, 3)
        XCTAssertEqual(arguments[2], hostile)
        XCTAssertFalse(arguments[1].contains(hostile))
    }

    func testNotchAndExternalDisplayMetrics() {
        let notch = NotchMetrics.calculate(
            frameWidth: 1512, safeTop: 32, leftWidth: 684, rightWidth: 684
        )
        XCTAssertTrue(notch.hasNotch)
        XCTAssertEqual(notch.width, 144)
        XCTAssertEqual(notch.height, 32)

        let external = NotchMetrics.calculate(
            frameWidth: 2560, safeTop: 0, leftWidth: nil, rightWidth: nil
        )
        XCTAssertFalse(external.hasNotch)
        XCTAssertEqual(external.width, 148)
    }

    func testCollapsedIslandKeepsOriginalCleanAndDetailedWidths() {
        let notch = NotchMetrics(width: 144, height: 32, hasNotch: true)

        XCTAssertEqual(
            NotchPointerGeometry.collapsedWidth(notch: notch, pillStyle: "clean"),
            324
        )
        XCTAssertEqual(
            NotchPointerGeometry.collapsedWidth(notch: notch, pillStyle: "detailed"),
            584
        )
        XCTAssertEqual(NotchPointerGeometry.collapsedHeight(notch: notch), 33)
    }

    func testCollapsedPointerZonesMatchRenderedWingsAndNotch() {
        let panel = CGRect(x: 296, y: 42, width: 920, height: 860)
        let notch = NotchMetrics(width: 144, height: 32, hasNotch: true)
        let surface = NotchPointerGeometry.surfaceRect(
            panelFrame: panel,
            notch: notch,
            pillStyle: "clean"
        )

        XCTAssertEqual(surface, CGRect(x: 594, y: 869, width: 324, height: 33))
        XCTAssertEqual(
            NotchPointerGeometry.zone(
                at: CGPoint(x: 600, y: 885),
                panelFrame: panel,
                notch: notch,
                pillStyle: "clean"
            ),
            .leftWing
        )
        XCTAssertEqual(
            NotchPointerGeometry.zone(
                at: CGPoint(x: 756, y: 885),
                panelFrame: panel,
                notch: notch,
                pillStyle: "clean"
            ),
            .center
        )
        XCTAssertEqual(
            NotchPointerGeometry.zone(
                at: CGPoint(x: 912, y: 885),
                panelFrame: panel,
                notch: notch,
                pillStyle: "clean"
            ),
            .rightWing
        )
        XCTAssertEqual(
            NotchPointerGeometry.zone(
                at: CGPoint(x: 919, y: 885),
                panelFrame: panel,
                notch: notch,
                pillStyle: "clean"
            ),
            .outside
        )
    }

    func testCollapsedPointerPolicyOnlyClaimsCenterTarget() {
        XCTAssertTrue(
            NotchPointerPolicy.capturesMouseEvents(
                zone: .center,
                expanded: false,
                hidden: false
            )
        )
        for zone in [
            NotchPointerZone.outside,
            .leftWing,
            .rightWing,
        ] {
            XCTAssertFalse(
                NotchPointerPolicy.capturesMouseEvents(
                    zone: zone,
                    expanded: false,
                    hidden: false
                )
            )
        }
        XCTAssertTrue(
            NotchPointerPolicy.capturesMouseEvents(
                zone: .outside,
                expanded: true,
                hidden: false
            )
        )
        XCTAssertFalse(
            NotchPointerPolicy.capturesMouseEvents(
                zone: .center,
                expanded: true,
                hidden: true
            )
        )
    }

    func testExternalDisplayRetainsInvisibleCenterHotArea() {
        let panel = CGRect(x: 820, y: 220, width: 920, height: 860)
        let external = NotchMetrics(width: 148, height: 32, hasNotch: false)
        let surface = NotchPointerGeometry.surfaceRect(
            panelFrame: panel,
            notch: external,
            pillStyle: "detailed"
        )

        XCTAssertEqual(surface.size, CGSize(width: 240, height: 10))
        XCTAssertEqual(
            NotchPointerGeometry.zone(
                at: CGPoint(x: panel.midX, y: panel.maxY - 5),
                panelFrame: panel,
                notch: external,
                pillStyle: "detailed"
            ),
            .center
        )
    }

    func testArchivedAutoCollapseCasesRemainCovered() {
        XCTAssertTrue(
            IslandCollapsePolicy.shouldCollapse(
                autoCollapse: true, autoRevealActive: false,
                switcherActive: false, mouseInside: false
            ))
        XCTAssertFalse(
            IslandCollapsePolicy.shouldCollapse(
                autoCollapse: true, autoRevealActive: true,
                switcherActive: false, mouseInside: false
            ))
        XCTAssertFalse(
            IslandCollapsePolicy.shouldCollapse(
                autoCollapse: true, autoRevealActive: false,
                switcherActive: true, mouseInside: false
            ))
    }

    func testManagedProjectionReplacesDuplicateObservedSession() {
        let observed = makeSession(id: "codex:shared")
        var managed = makeSession(id: "codex:shared", processID: nil)
        managed.codexManagedControl = CodexManagedControl(threadID: "shared")

        let sessions = SessionList.merged(
            observed: [observed, observed],
            managed: [managed]
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.codexManagedControl?.threadID, "shared")
    }

    func testScanRequestsCollapseToOneFollowUp() {
        let coalescer = ScanRequestCoalescer()

        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.request())
        XCTAssertFalse(coalescer.request())
        XCTAssertTrue(coalescer.finish())

        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.finish())
    }

    func testProcessCacheDropsExitedAndRecycledPIDs() {
        let retained = ProcessCachePolicy.retained(
            cached: [100: "codex", 200: "claude", 300: "opencode"],
            live: [100: "codex", 200: "different-command", 400: "gemini"]
        )

        XCTAssertEqual(retained, [100: "codex"])
    }

    func testStaleSessionsLeaveActiveListAfterGracePeriod() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(
            SessionVisibility.keepsStaleObservation(
                updatedAt: now.addingTimeInterval(-5),
                providerIsRunning: false,
                now: now
            ))
        XCTAssertFalse(
            SessionVisibility.keepsStaleObservation(
                updatedAt: now.addingTimeInterval(-SessionVisibility.staleGracePeriod - 1),
                providerIsRunning: false,
                now: now
            ))
        XCTAssertTrue(
            SessionVisibility.keepsStaleObservation(
                updatedAt: now.addingTimeInterval(-3_600),
                providerIsRunning: true,
                now: now
            ))
    }

    func testDiagnosticsRemoveLocalPathsAndCredentialShapes() {
        let value = "Failed at \(NSHomeDirectory())/Private Project/file.swift with sk-secret123456"
        let sanitized = DiagnosticsSanitizer.sanitize(value)

        XCTAssertFalse(sanitized.contains(NSHomeDirectory()))
        XCTAssertFalse(sanitized.contains("sk-secret123456"))
        XCTAssertTrue(sanitized.contains("<home>"))
        XCTAssertTrue(sanitized.contains("<redacted-secret>"))
    }

    func testClaudeHookInstallAndRemoveAreBackedUpAndRecoverable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopfwd-hook-\(UUID().uuidString)", isDirectory: true)
        let settings = root.appendingPathComponent("claude/settings.json")
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data("{\"model\":\"claude-test\"}".utf8)
        try original.write(to: settings)

        ApprovalCenter.settingsPathOverride = settings.path
        ApprovalCenter.supportDirectoryOverride = support.path
        defer {
            ApprovalCenter.settingsPathOverride = nil
            ApprovalCenter.supportDirectoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        if case .failure(let error) = ApprovalCenter.installHook() {
            XCTFail("Hook install failed: \(error)")
        }
        XCTAssertTrue(ApprovalCenter.hookInstalled)
        XCTAssertFalse(ApprovalCenter.hookNeedsUpdate)
        let backups = try FileManager.default.contentsOfDirectory(
            at: ApprovalCenter.hookBackupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("settings.json")), original)
        let hookMode =
            try FileManager.default.attributesOfItem(
                atPath: ApprovalCenter.hookScriptPath
            )[.posixPermissions] as? NSNumber
        XCTAssertEqual(hookMode?.intValue, 0o700)

        if case .failure(let error) = ApprovalCenter.uninstallHook() {
            XCTFail("Hook removal failed: \(error)")
        }
        XCTAssertFalse(ApprovalCenter.hookInstalled)
        let final = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        )
        XCTAssertEqual(final["model"] as? String, "claude-test")
        // Another selected Claude profile can still reference the shared observer.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ApprovalCenter.hookScriptPath))
    }

    func testClaudeHookRefusesInvalidSettingsWithoutPartialInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopfwd-hook-invalid-\(UUID().uuidString)", isDirectory: true)
        let settings = root.appendingPathComponent("claude/settings.json")
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let invalid = Data("not-json".utf8)
        try invalid.write(to: settings)

        ApprovalCenter.settingsPathOverride = settings.path
        ApprovalCenter.supportDirectoryOverride = support.path
        defer {
            ApprovalCenter.settingsPathOverride = nil
            ApprovalCenter.supportDirectoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        guard case .failure = ApprovalCenter.installHook() else {
            return XCTFail("Invalid settings must fail closed")
        }
        XCTAssertEqual(try Data(contentsOf: settings), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ApprovalCenter.hookScriptPath))
    }

    func testDeepSeekInstallFailureBacksUpAndRunsOfficialRollback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopfwd-dsh-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("profiles/web", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let package = profile.appendingPathComponent("package.json")
        let original = Data("{\"dependencies\":{\"existing\":\"1.0.0\"}}".utf8)
        try original.write(to: package)
        let archive = root.appendingPathComponent("observer.tgz")
        try Data("fixture observer archive".utf8).write(to: archive)

        DeepSeekHarnessIntegration.dshRootOverride = root.path
        defer {
            DeepSeekHarnessIntegration.dshRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        var calls: [[String]] = []
        XCTAssertThrowsError(
            try DeepSeekHarnessIntegration.installObserver(
                executable: "/tmp/dsh",
                archivePath: archive.path,
                packageName: "@loopfwd/dsh-observer"
            ) { _, arguments in
                calls.append(arguments)
                if arguments == ["--version"] { return (true, "0.1.2-alpha.5") }
                return arguments.contains("add")
                    ? (false, "fixture add failure")
                    : (true, "removed")
            }
        )
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0], ["--version"])
        XCTAssertTrue(calls[1].contains("add"))
        XCTAssertTrue(calls[2].contains("remove"))

        let backupRoot = root.appendingPathComponent("backups/loopfwd")
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("package.json")), original)
    }

    func testBrandPlacementsUseDedicatedOpticalSizes() {
        XCTAssertEqual(LoopFwdMarkView.Placement.menuBar.size, CGSize(width: 14, height: 13))
        XCTAssertEqual(LoopFwdMarkView.Placement.collapsedIsland.size, CGSize(width: 17, height: 15))
        XCTAssertEqual(LoopFwdMarkView.Placement.islandHeader.size, CGSize(width: 20, height: 18))
        XCTAssertEqual(LoopFwdMarkView.Placement.about.size, CGSize(width: 63, height: 56))
    }

    private func makeSession(
        id: String = "codex:thread-1",
        processID: Int32? = 100,
        kind: AgentKind = .codex,
        status: AgentStatus = .completed
    ) -> AgentSession {
        var session = AgentSession(
            id: id,
            processID: processID,
            kind: kind,
            cpu: 0,
            elapsed: "<1m",
            cwd: "/tmp/example/project",
            status: status,
            terminalApp: "Terminal",
            tty: "ttys001",
            bypassPermissions: false,
            returnTarget: .terminal(app: "Terminal", tty: "ttys001", processID: processID),
            observation: .rich("Fixture")
        )
        switch kind {
        case .claude:
            session.surfaceID = .claudeCLI
        case .codex:
            session.surfaceID = .codexCLI
        case .opencode:
            session.surfaceID = .openCodeTUI
            session.observation.authority = .officialLive
        case .deepseek:
            session.surfaceID = .deepSeekWeb
            session.observation.authority = .versionedObserver
        default:
            session.surfaceID = .experimentalLocal
        }
        return session
    }
}
