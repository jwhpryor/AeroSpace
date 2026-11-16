import AppKit
import Common

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since #macos14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private var windowsCount = 0
    var lastFocusedNativeWindowOpaqueId: OpaqueWindowId? = nil
    @MainActor var isHiddenByAeroSpace: Bool = false
    @MainActor var isUserHidden: Bool {
        if !isUnitTest && !config.automaticallyUnhideMacosHiddenApps {
            return false
        }
        return nsApp.isHidden && !isHiddenByAeroSpace
    }
    @MainActor private var hideTaskGeneration: UInt64 = 0
    @MainActor private var isAutoHideTaskPending: Bool = false
    @MainActor private var suppressNextHideNotification: Bool = false
    @MainActor private var suppressNextUnhideNotification: Bool = false
    @MainActor private var preventAutoHideUntil: ContinuousClock.Instant? = nil
    @MainActor static var lastAeroSpaceActiveAppHideTime: ContinuousClock.Instant? = nil
    @MainActor private var inFlightFocusJobsCount: Int = 0
    @MainActor private var inFlightBackgroundMainJobsCount: Int = 0
    @MainActor private var lastNativeFocusTime: ContinuousClock.Instant? = nil
    @MainActor private var lastBackgroundMainSyncTime: ContinuousClock.Instant? = nil
    @MainActor private var lastPromotedStandardChromeWindowId: OpaqueWindowId? = nil
    @MainActor private var lastBackgroundMainWindowId: OpaqueWindowId? = nil
    @MainActor private var backgroundMainWindowJob: RunLoopJob? = nil
    @MainActor private(set) var isDetachingTabToNewWindow: Bool = false
    @MainActor private var cachedAliveWindowIds: [OpaqueWindowId: WindowLifeStatus] = [:]
    @MainActor private var hasCompletedInitialWindowRefresh: Bool = false
    @MainActor var needsWindowRefresh: Bool = false
    @MainActor private var cachedTitles: [UInt32: String] = [:]
    @MainActor private var cachedTabCounts: [UInt32: Int] = [:]
    @MainActor private var preChangeTitles: [UInt32: String] = [:]
    @MainActor private var preChangeTabCounts: [UInt32: Int] = [:]
    @MainActor private var lastOffWorkspaceTitleChangeTime: [UInt32: ContinuousClock.Instant] = [:]
    @MainActor private var lastOffWorkspaceFocusTime: [UInt32: ContinuousClock.Instant] = [:]
    @MainActor private var lastTitleChangedChromeWindowId: UInt32? = nil
    @MainActor private var lastFocusedOffWorkspaceChromeWindowId: UInt32? = nil
    @MainActor private var lastNewWindowCreatedTime: ContinuousClock.Instant? = nil
    @MainActor private var lastWindowDestroyedTime: ContinuousClock.Instant? = nil
    @MainActor private var isCheckingChromeTabMenu: Bool = false
    @MainActor private var pendingChromeTabMenuCheck: Bool = false
    @MainActor private var pendingChromeHintWindowId: UInt32? = nil
    @MainActor static var lastNonChromeLeftMouseUpTime: ContinuousClock.Instant? = nil
    @MainActor static var lastExternalChromeActivationTime: ContinuousClock.Instant? = nil
    private var thread: Thread?
    private var setFrameJobs: [OpaqueWindowId: RunLoopJob] = [:]
    // Never pruned: while the screen is locked, AX reports windows as gone, and closedWindowsCache matches
    // the windows re-detected after unlock by their OpaqueWindowId
    // todo: start prunning after we get rid of closedWindowsCache
    private var windowIdMapping = BiDictionary<OpaqueWindowId, UInt32>()
    @MainActor private static var focusJob: RunLoopJob? = nil

    /*conforms*/ var name: String? { nsApp.localizedName }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    private init(
        _ nsApp: NSRunningApplication,
        _ axApp: AXUIElement,
        _ axSubscriptions: [AxSubscription],
        _ thread: Thread,
    ) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap { KnownBundleId.init(rawValue: $0) }
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    @MainActor @discardableResult static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        if let existing = allAppsMap[pid] { return existing }
        try checkCancellation()
        if let wip = wipPids[pid] {
            try await wip.await(.cancellable)
            return allAppsMap[pid]
        }
        let wip = AwaitableOneTimeBroadcastLatch()
        wipPids[pid] = wip

        let thread = Thread {
            $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.5)
                AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
                let handlers: HandlerToNotifKeyMapping = unsafe [
                    (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]),
                ]
                let job = RunLoopJob(.cancellable)
                let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(nsApp, axApp, job, handlers)) ?? []
                let isGood = !subscriptions.isEmpty
                let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil

                let appAxSubscriptionsThreadGuarded = app?.appAxSubscriptions
                let windowsThreadGuarded = app?.windows
                let axAppThreadGuarded = app?.axApp

                Task.startUnstructured { @MainActor in
                    if let app, isStartup && nsApp.isHidden {
                        app.isHiddenByAeroSpace = true
                    }
                    allAppsMap[pid] = app
                    wipPids[pid] = nil
                    await wip.signalToAll()
                }
                if isGood {
                    CFRunLoopRun()

                    // Destroy AX objects in reverse order of their creation
                    appAxSubscriptionsThreadGuarded?.destroy()
                    windowsThreadGuarded?.destroy()
                    axAppThreadGuarded?.destroy()
                }
            }
        }
        thread.name = "AxAppThread \(nsApp.idForDebug)"
        thread.start()

        try await wip.await(.cancellable)
        return allAppsMap[pid]
    }

    func nativeWindowId(of windowId: OpaqueWindowId) -> UInt32? { windowIdMapping.forward[windowId] }

    func opaqueWindowId(of nativeWindowId: UInt32) -> OpaqueWindowId? { windowIdMapping.backward[nativeWindowId] }

    @MainActor private func getOrRegisterOpaqueWindowId(_ nativeWindowId: UInt32) -> OpaqueWindowId {
        if let existing = windowIdMapping.backward[nativeWindowId] { return existing }
        let candidate = OpaqueWindowId(UInt64(nativeWindowId))
        let windowId = windowIdMapping.forward[candidate] == nil ? candidate : OpaqueWindowId.nextUniqId()
        windowIdMapping.put(windowId, nativeWindowId)
        return windowId
    }

    func closeAndUnregisterAxWindow(_ windowId: OpaqueWindowId) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return }
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(closeButton.cast, kAXPressAction as CFString) == .success {
                windows.threadGuarded.removeValue(forKey: nativeWindowId)
            }
        }
    }

    func getAxSize(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> CGSize? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        let (nativeWindowId, isNewAxWindow) = try await thread?.runInLoop(cm) { [nsApp, axApp, windows] job -> (UInt32?, Bool) in
            guard let focused = axApp.threadGuarded.get(Ax.focusedWindowAttr) else { return (nil, false) }
            let existed = windows.threadGuarded[focused.windowId] != nil
            guard let win = try windows.threadGuarded.getOrRegisterAxWindow(windowId: focused.windowId, focused.ax.cast, nsApp, job) else {
                return (nil, false)
            }
            return (win.windowId, !existed)
        } ?? (nil, false)
        guard let nativeWindowId else { return nil }
        let opaqueId = getOrRegisterOpaqueWindowId(nativeWindowId)
        if isNewAxWindow || cachedAliveWindowIds[opaqueId] != .alive || MacWindow.allWindowsMap[opaqueId] == nil {
            cachedAliveWindowIds[opaqueId] = .alive
            lifeStatusesOfLastRefresh[nativeWindowId] = .alive
            needsWindowRefresh = true
        }
        return try await MacWindow.getOrRegister(windowId: opaqueId, macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: OpaqueWindowId) {
        if serverArgs.isReadOnly { return }
        unhideIfHiddenByAeroSpace(forceIfHidden: true)
        MacApp.focusJob?.cancel()
        if rawAppBundleId == "com.google.Chrome" {
            backgroundMainWindowJob?.cancel()
            lastBackgroundMainWindowId = windowId
            if hasStandardChromeTitle(windowId) {
                lastPromotedStandardChromeWindowId = windowId
            }
        }
        recordAeroSpaceNativeFocus(windowId, app: self)
        inFlightFocusJobsCount += 1
        lastNativeFocusTime = .now
        let pid = self.pid
        MacApp.focusJob = withWindowAsync(windowId, .cancellable, onComplete: {
            Task.startUnstructured { @MainActor in
                if let app = MacApp.allAppsMap[pid] {
                    app.inFlightFocusJobsCount = max(0, app.inFlightFocusJobsCount - 1)
                    app.lastNativeFocusTime = .now
                    if app.inFlightFocusJobsCount == 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                        onAppActivatedInWorkspace(pid)
                    }
                }
            }
        }) { [nsApp] window, _ in
            // Raise firstly to make sure that by the time we activate the app, the window would be already on top
            window.set(Ax.isMainAttr, true)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if #available(macOS 14, *) {
                nsApp.activate()
            } else {
                // Deprecated since #macos14
                nsApp.activate(options: .activateIgnoringOtherApps)
            }
        }
        if rawAppBundleId != "com.google.Chrome" {
            MacApp.syncAllChromeVisibleStandardMainWindows()
        }
    }

    @MainActor
    func hasStandardChromeTitle(_ windowId: OpaqueWindowId) -> Bool {
        guard rawAppBundleId == "com.google.Chrome",
              let nativeWindowId = windowIdMapping.forward[windowId]
        else { return false }
        return cachedTitles[nativeWindowId]?.contains("- Google Chrome") == true
    }

    @MainActor
    func visibleWorkspaceStandardChromeWindowId() -> OpaqueWindowId? {
        guard rawAppBundleId == "com.google.Chrome" else { return nil }
        guard let firstChromeWin = globalFocus.workspace.allLeafWindowsRecursiveMru.first(where: {
            ($0 as? MacWindow)?.macApp.pid == self.pid
        }) else { return nil }
        return hasStandardChromeTitle(firstChromeWin.windowId) ? firstChromeWin.windowId : nil
    }

    @MainActor
    func noteChromeWindowNativelyFocused(_ windowId: OpaqueWindowId) {
        guard rawAppBundleId == "com.google.Chrome" else { return }
        lastBackgroundMainWindowId = windowId
        if hasStandardChromeTitle(windowId) {
            lastPromotedStandardChromeWindowId = windowId
        }
    }

    @MainActor
    func raiseWindowWithoutActivating(_ windowId: OpaqueWindowId) {
        if isUnitTest || serverArgs.isReadOnly { return }
        inFlightBackgroundMainJobsCount += 1
        lastBackgroundMainSyncTime = .now
        let pid = self.pid
        _ = withWindowAsync(windowId, .cancellable, onComplete: {
            Task.startUnstructured { @MainActor in
                if let app = MacApp.allAppsMap[pid] {
                    app.inFlightBackgroundMainJobsCount = max(0, app.inFlightBackgroundMainJobsCount - 1)
                    app.lastBackgroundMainSyncTime = .now
                }
            }
        }) { window, _ in
            window.set(Ax.isMainAttr, true)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    @MainActor
    static func onGlobalLeftMouseUp() {
        lastNonChromeLeftMouseUpTime = .now
        if isUnitTest || serverArgs.isReadOnly { return }
        for app in allAppsMap.values where app.rawAppBundleId == "com.google.Chrome" {
            if let focusedWin = globalFocus.windowOrNil as? MacWindow,
               focusedWin.macApp.pid == app.pid,
               app.hasStandardChromeTitle(focusedWin.windowId),
               let nativeId = app.nativeWindowId(of: focusedWin.windowId)
            {
                Task.startUnstructured { @MainActor [weak app] in
                    try? await Task.sleep(for: .milliseconds(200))
                    await app?.refreshSingleChromeWindowTabCount(nativeId)
                }
            } else {
                Task.startUnstructured { @MainActor [weak app] in
                    for delayMs in [100, 300, 700] {
                        try? await Task.sleep(for: .milliseconds(delayMs))
                        await app?.checkForNewlyOpenedExternalChromeTab()
                        if delayMs == 300 {
                            await app?.checkForTabCountIncreaseInTopChromeWindows()
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func refreshSingleChromeWindowTabCount(_ nativeWindowId: UInt32) async {
        guard rawAppBundleId == "com.google.Chrome",
              !isUnitTest,
              !serverArgs.isReadOnly,
              let thread
        else { return }
        if let (count, title) = try? await thread.runInLoop(.cancellable, { [windows] _ -> (Int, String)? in
            guard let axWin = windows.threadGuarded[nativeWindowId]?.ax,
                  let title = axWin.get(Ax.titleAttr),
                  title.contains("- Google Chrome"),
                  let snap = readChromeWindowTabsSnapshot(axWin)
            else { return nil }
            return (snap.tabs.count, title)
        }) {
            cachedTabCounts[nativeWindowId] = count
            cachedTitles[nativeWindowId] = title
        }
    }

    @MainActor
    static func syncAllChromeVisibleStandardMainWindows(force: Bool = false) {
        if isUnitTest || serverArgs.isReadOnly { return }
        for app in allAppsMap.values where app.rawAppBundleId == "com.google.Chrome" {
            app.syncVisibleWorkspaceStandardChromeMainWindow(force: force)
        }
    }

    @MainActor
    func syncVisibleWorkspaceStandardChromeMainWindow(force: Bool = false) {
        guard rawAppBundleId == "com.google.Chrome",
              !isUnitTest,
              !serverArgs.isReadOnly,
              !isDetachingTabToNewWindow
        else { return }
        guard let stdWinId = visibleWorkspaceStandardChromeWindowId(),
              let stdNativeId = windowIdMapping.forward[stdWinId]
        else { return }

        let focusedWin = globalFocus.windowOrNil as? MacWindow
        if let focusedWin, focusedWin.macApp.pid == self.pid {
            if hasStandardChromeTitle(focusedWin.windowId) {
                lastPromotedStandardChromeWindowId = focusedWin.windowId
                lastBackgroundMainWindowId = focusedWin.windowId
            }
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid {
            return
        }

        guard force || lastBackgroundMainWindowId != stdWinId || lastPromotedStandardChromeWindowId != stdWinId,
              let thread
        else { return }
        lastPromotedStandardChromeWindowId = stdWinId
        lastBackgroundMainWindowId = stdWinId
        lastFocusedNativeWindowOpaqueId = stdWinId
        inFlightBackgroundMainJobsCount += 1
        lastBackgroundMainSyncTime = .now
        let pid = self.pid
        backgroundMainWindowJob?.cancel()
        backgroundMainWindowJob = thread.runInLoopAsync(job: RunLoopJob(.cancellable), autoCheckCancelled: false) { [windows] job in
            defer {
                _ = Thread.current.runInLoopAsync(job: RunLoopJob(.nonCancellable), autoCheckCancelled: false) { _ in
                    Task.startUnstructured { @MainActor in
                        if let app = MacApp.allAppsMap[pid] {
                            app.inFlightBackgroundMainJobsCount = max(0, app.inFlightBackgroundMainJobsCount - 1)
                            app.lastBackgroundMainSyncTime = .now
                        }
                    }
                }
            }
            if job.isCancelled { return }
            windows.threadGuarded[stdNativeId]?.ax.set(Ax.isMainAttr, true)
        }
    }

    @MainActor
    func onNewWindowCreated() {
        lastNewWindowCreatedTime = .now
        if rawAppBundleId == "com.google.Chrome" {
            lastOffWorkspaceTitleChangeTime.removeAll()
            lastOffWorkspaceFocusTime.removeAll()
            preChangeTitles.removeAll()
            preChangeTabCounts.removeAll()
            lastTitleChangedChromeWindowId = nil
            lastFocusedOffWorkspaceChromeWindowId = nil
        }
    }

    @MainActor
    func onWindowDestroyed(isPopup: Bool = false) {
        if !isPopup {
            lastWindowDestroyedTime = .now
            if rawAppBundleId == "com.google.Chrome" {
                lastOffWorkspaceTitleChangeTime.removeAll()
                lastOffWorkspaceFocusTime.removeAll()
                preChangeTitles.removeAll()
                preChangeTabCounts.removeAll()
                lastTitleChangedChromeWindowId = nil
                lastFocusedOffWorkspaceChromeWindowId = nil
            }
        } else if !isUnitTest,
                  let lastNew = lastNewWindowCreatedTime,
                  lastNew.duration(to: .now) < .seconds(2.0),
                  let focusedWin = globalFocus.windowOrNil,
                  focusedWin.app.pid == self.pid
        {
            focusedWin.nativeFocus()
        }
        enforceOffWorkspaceWindowsParkedInCorner()
    }

    @MainActor
    func onChromeWindowFocusedOrMainChanged(_ nativeWindowId: UInt32?, _ currentTitle: String?) async {
        let hasRecentDestroyedWin = lastWindowDestroyedTime.map { $0.duration(to: .now) < .seconds(1.2) } ?? false
        guard rawAppBundleId == "com.google.Chrome",
              !isUnitTest,
              !serverArgs.isReadOnly,
              !isDetachingTabToNewWindow,
              !hasRecentDestroyedWin
        else { return }
        if let nativeWindowId {
            let opaqueId = opaqueWindowId(of: nativeWindowId)
            let win = opaqueId.flatMap { MacWindow.allWindowsMap[$0] }
            guard let win, !(win.parent is MacosPopupWindowsContainer) else {
                needsWindowRefresh = true
                onNewWindowCreated()
                return
            }
            let isOffWorkspace = win.nodeWorkspace == nil || win.nodeWorkspace?.isVisible == false
            if isOffWorkspace {
                lastBackgroundMainWindowId = nil
                lastPromotedStandardChromeWindowId = nil
                lastOffWorkspaceFocusTime[nativeWindowId] = .now
                lastFocusedOffWorkspaceChromeWindowId = nativeWindowId
                if let currentTitle, !currentTitle.isEmpty {
                    _ = onChromeWindowTitleChanged(nativeWindowId, currentTitle)
                }
                await checkForNewlyOpenedExternalChromeTab(hintWindowId: nativeWindowId)
                Task.startUnstructured { @MainActor [weak self] in
                    for delayMs in [80, 200, 500, 1000] {
                        try? await Task.sleep(for: .milliseconds(delayMs))
                        await self?.checkForNewlyOpenedExternalChromeTab(hintWindowId: nativeWindowId)
                    }
                }
                return
            } else {
                lastBackgroundMainWindowId = win.windowId
                if hasStandardChromeTitle(win.windowId) {
                    lastPromotedStandardChromeWindowId = win.windowId
                }
            }
        }
        await checkForNewlyOpenedExternalChromeTab(hintWindowId: nativeWindowId)
    }

    @MainActor
    fileprivate func onChromeWindowTitleChanged(_ nativeWindowId: UInt32, _ newTitle: String) -> Bool {
        let oldTitle = cachedTitles[nativeWindowId] ?? preChangeTitles[nativeWindowId]
        cachedTitles[nativeWindowId] = newTitle
        guard !isDetachingTabToNewWindow,
              let oldTitle,
              !oldTitle.isEmpty,
              !newTitle.isEmpty,
              oldTitle != newTitle || preChangeTitles[nativeWindowId] != nil
        else { return false }

        let effectiveOldTitle = (oldTitle != newTitle) ? oldTitle : (preChangeTitles[nativeWindowId] ?? oldTitle)
        let strippedOld = stripChromeTitleSuffix(effectiveOldTitle)
        let strippedNew = stripChromeTitleSuffix(newTitle)
        guard strippedOld != strippedNew else { return false }

        let hasRecentNewWin = lastNewWindowCreatedTime.map { $0.duration(to: .now) < .seconds(1.2) } ?? false
        if hasRecentNewWin {
            preChangeTitles.removeValue(forKey: nativeWindowId)
            preChangeTabCounts.removeValue(forKey: nativeWindowId)
            lastOffWorkspaceTitleChangeTime.removeValue(forKey: nativeWindowId)
            return false
        }

        let opaqueId = opaqueWindowId(of: nativeWindowId)
        let win = opaqueId.flatMap { MacWindow.allWindowsMap[$0] }
        let isCandidateUnfocusedWindow =
            win != nil &&
            !(win?.parent is MacosPopupWindowsContainer) &&
            win?.windowId != globalFocus.windowOrNil?.windowId
        guard isCandidateUnfocusedWindow else {
            preChangeTitles.removeValue(forKey: nativeWindowId)
            preChangeTabCounts.removeValue(forKey: nativeWindowId)
            lastOffWorkspaceTitleChangeTime.removeValue(forKey: nativeWindowId)
            if newTitle.contains("- Google Chrome") {
                syncVisibleWorkspaceStandardChromeMainWindow()
            }
            return false
        }

        let hadRecentChange = lastOffWorkspaceTitleChangeTime[nativeWindowId].map { $0.duration(to: .now) < .seconds(6.0) } ?? false
        if !hadRecentChange || preChangeTitles[nativeWindowId] == nil {
            preChangeTitles[nativeWindowId] = effectiveOldTitle
            if let count = cachedTabCounts[nativeWindowId] {
                preChangeTabCounts[nativeWindowId] = count
            }
        }
        lastOffWorkspaceTitleChangeTime[nativeWindowId] = .now
        lastTitleChangedChromeWindowId = nativeWindowId
        return true
    }

    @MainActor
    func checkForNewlyOpenedExternalChromeTab(hintWindowId: UInt32? = nil) async {
        guard rawAppBundleId == "com.google.Chrome",
              !isUnitTest,
              !serverArgs.isReadOnly,
              !isDetachingTabToNewWindow,
              let thread
        else { return }
        if isCheckingChromeTabMenu {
            pendingChromeTabMenuCheck = true
            if let hintWindowId {
                pendingChromeHintWindowId = hintWindowId
            }
            return
        }
        isCheckingChromeTabMenu = true
        defer { isCheckingChromeTabMenu = false }

        var currentHintWindowId = hintWindowId
        while true {
            pendingChromeTabMenuCheck = false
            pendingChromeHintWindowId = nil
            await performChromeTabMenuCheckOnce(hintWindowId: currentHintWindowId, thread: thread)
            if pendingChromeTabMenuCheck && !isDetachingTabToNewWindow {
                currentHintWindowId = pendingChromeHintWindowId
                continue
            }
            break
        }
    }

    @MainActor
    private func clearPendingTabChangeTracking(for winId: UInt32) {
        preChangeTitles.removeValue(forKey: winId)
        preChangeTabCounts.removeValue(forKey: winId)
        lastOffWorkspaceTitleChangeTime.removeValue(forKey: winId)
        lastOffWorkspaceFocusTime.removeValue(forKey: winId)
        if lastTitleChangedChromeWindowId == winId {
            lastTitleChangedChromeWindowId = nil
        }
        if lastFocusedOffWorkspaceChromeWindowId == winId {
            lastFocusedOffWorkspaceChromeWindowId = nil
        }
    }

    @MainActor
    private func performChromeTabMenuCheckOnce(hintWindowId: UInt32?, thread: Thread) async {
        let hasRecentNewWin = lastNewWindowCreatedTime.map { $0.duration(to: .now) < .seconds(1.2) } ?? false
        let hasRecentDestroyedWin = lastWindowDestroyedTime.map { $0.duration(to: .now) < .seconds(1.2) } ?? false
        if hasRecentNewWin || hasRecentDestroyedWin || isDetachingTabToNewWindow {
            return
        }

        let candidateWinId: UInt32? = if let hintWindowId,
            (lastOffWorkspaceTitleChangeTime[hintWindowId].map { $0.duration(to: .now) < .seconds(6.0) } ?? false) ||
            (lastOffWorkspaceFocusTime[hintWindowId].map { $0.duration(to: .now) < .seconds(6.0) } ?? false)
        {
            hintWindowId
        } else if let recentId = lastTitleChangedChromeWindowId,
            let t = lastOffWorkspaceTitleChangeTime[recentId],
            t.duration(to: .now) < .seconds(6.0)
        {
            recentId
        } else if let focusedId = lastFocusedOffWorkspaceChromeWindowId,
            let t = lastOffWorkspaceFocusTime[focusedId],
            t.duration(to: .now) < .seconds(6.0)
        {
            focusedId
        } else {
            nil
        }
        guard let winId = candidateWinId else { return }

        let targetOpaqueId = opaqueWindowId(of: winId)
        guard let targetWin = targetOpaqueId.flatMap({ MacWindow.allWindowsMap[$0] }),
              !(targetWin.parent is MacosPopupWindowsContainer),
              targetWin.windowId != globalFocus.windowOrNil?.windowId
        else {
            clearPendingTabChangeTracking(for: winId)
            return
        }
        let isOffWorkspace = targetWin.nodeWorkspace == nil || targetWin.nodeWorkspace?.isVisible == false
        if !isOffWorkspace {
            let hasRecentInteraction =
                (MacApp.lastNonChromeLeftMouseUpTime.map { $0.duration(to: .now) < .seconds(5.0) } ?? false) ||
                (MacApp.lastExternalChromeActivationTime.map { $0.duration(to: .now) < .seconds(5.0) } ?? false) ||
                (lastOffWorkspaceFocusTime[winId].map { $0.duration(to: .now) < .seconds(5.0) } ?? false)
            if !hasRecentInteraction {
                clearPendingTabChangeTracking(for: winId)
                return
            }
        }

        let initialPreTitle = preChangeTitles[winId] ?? cachedTitles[winId]
        guard let preTitle = initialPreTitle, !preTitle.isEmpty else { return }

        // Passively inspect the target window's own AXTabGroup -> AXRadioButton elements
        // without mutating kAXMainAttribute or stealing focus.
        guard let (snap, currentWinTitle) = try? await thread.runInLoop(.cancellable, { [axApp, windows] _ -> (ChromeWindowTabsSnapshot, String)? in
            let appEl = axApp.threadGuarded
            if let currentWins = appEl.get(Ax.windowsAttr),
               currentWins.contains(where: { windows.threadGuarded[$0.windowId] == nil })
            {
                return nil
            }
            guard let axWin = windows.threadGuarded[winId]?.ax,
                  let winTitle = axWin.get(Ax.titleAttr),
                  winTitle.contains("- Google Chrome"),
                  let snap = readChromeWindowTabsSnapshot(axWin)
            else { return nil }
            return (snap, winTitle)
        }) else { return }

        cachedTitles[winId] = currentWinTitle
        let preTabCount = preChangeTabCounts[winId]
        cachedTabCounts[winId] = snap.tabs.count

        let selectedTitle = snap.selectedTabTitle ?? ""
        let preTitleInUnselectedTab = snap.tabs.enumerated().contains { idx, tabTitle in
            idx != snap.selectedIndex && !tabTitle.isEmpty && chromeWindowTitle(preTitle, matchesTabMenuTitle: tabTitle)
        }
        let checkedTabDiffersFromPreTitle = selectedTitle.isEmpty || !chromeWindowTitle(preTitle, matchesTabMenuTitle: selectedTitle)
        let tabCountIncreased = preTabCount.map { snap.tabs.count > $0 } ?? false
        let hasRecentUserSignal =
            (MacApp.lastNonChromeLeftMouseUpTime.map { $0.duration(to: .now) < .seconds(4.0) } ?? false) ||
            (MacApp.lastExternalChromeActivationTime.map { $0.duration(to: .now) < .seconds(4.0) } ?? false) ||
            (lastOffWorkspaceFocusTime[winId].map { $0.duration(to: .now) < .seconds(4.0) } ?? false)

        let strippedCur = stripChromeTitleSuffix(currentWinTitle)
        let isTransientLoading =
            selectedTitle.isEmpty ||
            selectedTitle == "Untitled" || selectedTitle == "Loading…" || selectedTitle == "about:blank" ||
            strippedCur.isEmpty ||
            strippedCur == "Untitled" || strippedCur == "Loading…" || strippedCur == "about:blank"

        let isMultiTabExternalOpen =
            snap.tabs.count >= 2 &&
            preTitleInUnselectedTab &&
            (checkedTabDiffersFromPreTitle || (tabCountIncreased && hasRecentUserSignal))

        let isSingleNewTabNavigated =
            snap.tabs.count == 1 &&
            stripChromeTitleSuffix(preTitle) == "New Tab" &&
            !selectedTitle.isEmpty &&
            selectedTitle != "New Tab"

        guard isMultiTabExternalOpen || isSingleNewTabNavigated else {
            if !isTransientLoading && stripChromeTitleSuffix(currentWinTitle) != stripChromeTitleSuffix(preTitle) {
                clearPendingTabChangeTracking(for: winId)
            }
            return
        }

        clearPendingTabChangeTracking(for: winId)

        if isOffWorkspace {
            if isMultiTabExternalOpen {
                cachedTabCounts[winId] = max(1, snap.tabs.count - 1)
                await detachActiveChromeTabToNewWindow(fromWindowId: winId)
            } else if let token: RunSessionGuard = .isServerEnabled {
                let targetWorkspace = globalFocus.workspace
                _ = try? await runLightSession(.globalObserver("ChromeExternalLinkTab"), token) {
                    if targetWin.nodeWorkspace != targetWorkspace {
                        let targetParent: NonLeafTreeNodeObject = targetWin.isFloating
                            ? targetWorkspace.floatingWindowsContainer
                            : targetWorkspace.rootTilingContainer
                        _ = targetWin.bind(to: targetParent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                    }
                    targetWin.unhideFromCorner()
                    _ = targetWin.focusWindow()
                    targetWin.nativeFocus()
                }
            }
        } else if let token: RunSessionGuard = .isServerEnabled {
            _ = try? await runLightSession(.globalObserver("ChromeVisibleWorkspaceLinkTab"), token) {
                targetWin.unhideFromCorner()
                _ = targetWin.focusWindow()
                targetWin.nativeFocus()
            }
        }
    }

    @MainActor
    func checkForTabCountIncreaseInTopChromeWindows() async {
        guard rawAppBundleId == "com.google.Chrome",
              !isUnitTest,
              !serverArgs.isReadOnly,
              !isDetachingTabToNewWindow,
              let thread
        else { return }
        let hasRecentNewWin = lastNewWindowCreatedTime.map { $0.duration(to: .now) < .seconds(1.2) } ?? false
        let hasRecentDestroyedWin = lastWindowDestroyedTime.map { $0.duration(to: .now) < .seconds(1.2) } ?? false
        if hasRecentNewWin || hasRecentDestroyedWin { return }

        let focusedNativeId: UInt32? = (globalFocus.windowOrNil as? MacWindow).flatMap {
            $0.macApp.pid == self.pid ? nativeWindowId(of: $0.windowId) : nil
        }
        let knownCounts = cachedTabCounts

        guard let updates = try? await thread.runInLoop(.cancellable, { [axApp, windows] _ -> [(UInt32, Int, String)] in
            let appEl = axApp.threadGuarded
            guard let axWins = appEl.get(Ax.windowsAttr) else { return [] }
            if axWins.contains(where: { windows.threadGuarded[$0.windowId] == nil }) {
                return []
            }
            var out: [(UInt32, Int, String)] = []
            var checkedStd = 0
            for entry in axWins {
                guard let axWin = windows.threadGuarded[entry.windowId]?.ax,
                      let title = axWin.get(Ax.titleAttr),
                      title.contains("- Google Chrome")
                else { continue }
                if let snap = readChromeWindowTabsSnapshot(axWin) {
                    out.append((entry.windowId, snap.tabs.count, title))
                }
                checkedStd += 1
                if checkedStd >= 5 { break }
            }
            return out
        }) else { return }

        var matchedWinId: UInt32? = nil
        for (wid, count, title) in updates {
            cachedTitles[wid] = title
            let prevCount = knownCounts[wid]
            cachedTabCounts[wid] = count
            if matchedWinId == nil,
               wid != focusedNativeId,
               let prevCount,
               count > prevCount,
               count >= 2
            {
                matchedWinId = wid
            }
        }

        guard let winId = matchedWinId,
              let opaqueId = opaqueWindowId(of: winId),
              let targetWin = MacWindow.allWindowsMap[opaqueId],
              !(targetWin.parent is MacosPopupWindowsContainer),
              targetWin.windowId != globalFocus.windowOrNil?.windowId
        else { return }

        clearPendingTabChangeTracking(for: winId)
        let isOffWorkspace = targetWin.nodeWorkspace == nil || targetWin.nodeWorkspace?.isVisible == false
        if isOffWorkspace {
            cachedTabCounts[winId] = max(1, (cachedTabCounts[winId] ?? 2) - 1)
            await detachActiveChromeTabToNewWindow(fromWindowId: winId)
        } else if let token: RunSessionGuard = .isServerEnabled {
            _ = try? await runLightSession(.globalObserver("ChromeVisibleWorkspaceLinkTab"), token) {
                targetWin.unhideFromCorner()
                _ = targetWin.focusWindow()
                targetWin.nativeFocus()
            }
        }
    }

    @MainActor
    private func detachActiveChromeTabToNewWindow(fromWindowId: UInt32?) async {
        guard !isDetachingTabToNewWindow, let thread else { return }
        isDetachingTabToNewWindow = true
        defer { isDetachingTabToNewWindow = false }
        onNewWindowCreated()

        let targetWorkspace = globalFocus.workspace
        let fromWin = fromWindowId.flatMap { opaqueWindowId(of: $0) }.flatMap { MacWindow.allWindowsMap[$0] }
        preventAutoHideUntil = ContinuousClock.now.advanced(by: .seconds(2))
        unhideIfHiddenByAeroSpace(forceIfHidden: true)

        let result = try? await thread.runInLoop(.cancellable) { [axApp, windows] _ -> (UInt32?, String?, String?) in
            let appEl = axApp.threadGuarded
            let oldWindowIds = Set(appEl.get(Ax.windowsAttr)?.map(\.windowId) ?? [])
            if let fromWindowId, let axWin = windows.threadGuarded[fromWindowId]?.ax {
                axWin.set(Ax.isMainAttr, true)
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                Thread.sleep(forTimeInterval: 0.025)
            }
            var didPress = false
            for _ in 0 ..< 15 {
                if let moveItem = findMoveTabToNewWindowMenuItem(appEl),
                   moveItem.get(Ax.enabledAttr) == true
                {
                    _ = AXUIElementPerformAction(moveItem, kAXPressAction as CFString)
                    didPress = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.015)
            }
            var newWindowId: UInt32? = nil
            var newWinTitle: String? = nil
            if didPress {
                for _ in 0 ..< 15 {
                    Thread.sleep(forTimeInterval: 0.02)
                    if let currentWins = appEl.get(Ax.windowsAttr),
                       let created = currentWins.first(where: { !oldWindowIds.contains($0.windowId) })
                    {
                        newWindowId = created.windowId
                        newWinTitle = created.ax.get(Ax.titleAttr)
                        break
                    }
                }
            }
            let updatedFromTitle = fromWindowId.flatMap { windows.threadGuarded[$0]?.ax.get(Ax.titleAttr) }
            return (newWindowId, updatedFromTitle, newWinTitle)
        }

        if let fromWindowId, let updatedFromTitle = result?.1, !updatedFromTitle.isEmpty {
            cachedTitles[fromWindowId] = updatedFromTitle
        }
        if let newNativeId = result?.0, let newWinTitle = result?.2, !newWinTitle.isEmpty {
            cachedTitles[newNativeId] = newWinTitle
        }
        onNewWindowCreated()
        cancelActiveRefreshTask()
        needsWindowRefresh = true
        await runHeavyCompleteRefreshSession(.ax(kAXWindowCreatedNotification), assumeCancellable: false)
        if let newNativeWindowId = result?.0,
           let newOpaqueId = opaqueWindowId(of: newNativeWindowId),
           let newWin = MacWindow.allWindowsMap[newOpaqueId],
           let token: RunSessionGuard = .isServerEnabled
        {
            _ = try? await runLightSession(.ax(kAXWindowCreatedNotification), token) {
                if newWin.nodeWorkspace != targetWorkspace {
                    let targetParent: NonLeafTreeNodeObject = newWin.isFloating
                        ? targetWorkspace.floatingWindowsContainer
                        : targetWorkspace.rootTilingContainer
                    _ = newWin.bind(to: targetParent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                }
                newWin.restoreDetachedWindowPosition(from: fromWin)
                _ = newWin.focusWindow()
                newWin.nativeFocus()
            }
        }
    }

    @MainActor
    var hasInFlightFocusJobs: Bool {
        inFlightFocusJobsCount > 0
    }

    @MainActor
    var isSuppressingSelfFocusNotifications: Bool {
        if inFlightFocusJobsCount > 0 || inFlightBackgroundMainJobsCount > 0 { return true }
        if let lastNativeFocusTime, lastNativeFocusTime.duration(to: .now) < .milliseconds(500) {
            return true
        }
        if let lastBackgroundMainSyncTime,
           lastBackgroundMainSyncTime.duration(to: .now) < .milliseconds(150),
           MacApp.lastExternalChromeActivationTime.map({ $0 < lastBackgroundMainSyncTime }) ?? true
        {
            return true
        }
        return false
    }

    @MainActor
    func unhideIfHiddenByAeroSpace(forceIfHidden: Bool = false) {
        hideTaskGeneration &+= 1
        isAutoHideTaskPending = false
        let shouldUnhide = isHiddenByAeroSpace || (forceIfHidden && !isUnitTest && !config.automaticallyUnhideMacosHiddenApps && nsApp.isHidden)
        guard shouldUnhide else { return }
        isHiddenByAeroSpace = false
        if !isUnitTest && !serverArgs.isReadOnly && nsApp.isHidden {
            suppressNextUnhideNotification = true
            for workspace in Workspace.all where !workspace.isVisible {
                for window in workspace.allLeafWindowsRecursive where window.app.pid == self.pid {
                    (window as? MacWindow)?.needsCornerRehide = true
                }
            }
            nsApp.unhide()
            _ = thread?.runInLoopAsync(job: RunLoopJob(.cancellable), autoCheckCancelled: false) { [axApp] _ in
                _ = AXUIElementSetAttributeValue(axApp.threadGuarded, kAXHiddenAttribute as CFString, kCFBooleanFalse)
            }
            enforceOffWorkspaceWindowsParkedInCorner()
        }
    }

    @MainActor
    func enforceOffWorkspaceWindowsParkedInCorner() {
        guard !isUnitTest && !serverArgs.isReadOnly else { return }
        Task.startUnstructured { @MainActor [weak self] in
            for delayMs in [0, 40, 140] {
                if delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
                guard let self, !self.nsApp.isHidden else { return }
                for workspace in Workspace.all where !workspace.isVisible {
                    for window in workspace.allLeafWindowsRecursive where window.app.pid == self.pid {
                        let macWin = window as! MacWindow
                        if macWin.needsCornerRehide || !macWin.isCurrentlyInHideCorner() {
                            macWin.needsCornerRehide = true
                            try? await macWin.hideInCorner(.bottomRightCorner)
                        }
                    }
                }
                if self.rawAppBundleId == "com.google.Chrome" {
                    self.syncVisibleWorkspaceStandardChromeMainWindow()
                }
            }
        }
    }

    @MainActor
    func consumeSuppressedHideNotification() -> Bool {
        if suppressNextHideNotification {
            suppressNextHideNotification = false
            return true
        }
        return isHiddenByAeroSpace
    }

    @MainActor
    func consumeSuppressedUnhideNotification() -> Bool {
        if suppressNextUnhideNotification {
            suppressNextUnhideNotification = false
            return true
        }
        return false
    }

    @MainActor
    func markExternallyUnhiddenOrActivated() {
        needsWindowRefresh = true
        enforceOffWorkspaceWindowsParkedInCorner()
        guard isHiddenByAeroSpace else { return }
        hideTaskGeneration &+= 1
        isAutoHideTaskPending = false
        isHiddenByAeroSpace = false
        preventAutoHideUntil = ContinuousClock.now.advanced(by: .seconds(1))
    }

    @MainActor
    func scheduleHideByAeroSpaceIfEligible(delayMs: Int? = nil) {
        // Never use NSRunningApplication.hide() to auto-hide off-workspace apps:
        // macOS WindowServer caches hidden window frames and ignores/defers AX position
        // updates while an app is hidden, causing stale off-workspace windows to flash
        // across the screen whenever the app is unhidden or spawns a new window.
        // Instead, off-workspace windows remain parked in the 1px hide corner behind
        // HideCornerOccluder.
    }

    @MainActor
    func isEligibleForAeroSpaceAutoHide() -> Bool {
        if needsWindowRefresh || isDetachingTabToNewWindow { return false }
        if globalFocus.windowOrNil?.app.pid == pid || stickyClosedAppPidOnCurrentWorkspace == pid || (globalFocus.windowOrNil == nil && nsApp.isActive) { return false }
        for node in macosPopupWindowsContainer.children {
            if (node as? Window)?.app.pid == pid { return false }
        }
        var hasInvisibleWorkspaceWindows = false
        for workspace in Workspace.all {
            for window in workspace.allLeafWindowsRecursive where window.app.pid == pid {
                if workspace.isVisible {
                    return false
                }
                hasInvisibleWorkspaceWindows = true
            }
            if workspace.macOsNativeFullscreenWindowsContainer.children.contains(where: { ($0 as? Window)?.app.pid == pid }) {
                if workspace.isVisible {
                    return false
                }
                hasInvisibleWorkspaceWindows = true
            }
            if workspace.macOsNativeHiddenAppsWindowsContainer.children.contains(where: { ($0 as? Window)?.app.pid == pid }) {
                return false
            }
        }
        return hasInvisibleWorkspaceWindows
    }

    func waitForPendingAxJobs() async {
        if isUnitTest || serverArgs.isReadOnly { return }
        _ = try? await thread?.runInLoop(.cancellable) { _ in () }
    }

    func setAxFrame(_ windowId: OpaqueWindowId, _ topLeft: Point?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable, onComplete: {
            Task.startUnstructured { @MainActor in
                if let win = MacWindow.allWindowsMap[windowId] {
                    win.inFlightSetFrameCount = max(0, win.inFlightSetFrameCount - 1)
                    win.lastSetFrameTime = .now
                }
            }
        }) { [axApp] window, job in
            if size != nil {
                try disableAnimations(app: axApp.threadGuarded, job) {
                    try setFrame(window, topLeft, size, job)
                }
            } else {
                try setFrame(window, topLeft, nil, job)
            }
        }
    }

    func setAxFrameForTermination(_ windowId: OpaqueWindowId, _ topLeft: Point?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        let job = withWindowAsync(windowId, .nonCancellable) { [axApp] window, job in
            try? disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
            semaphore.signal()
        }
        switch job.isCancelled {
            case true: return
            case false: semaphore.wait()
        }
    }

    func getAxWindowsCount(_ cm: CancellationMode) async throws -> Int? {
        try await thread?.runInLoop(cm) { [axApp] job in
            axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Rect? {
        try await withWindow(windowId, cm) { window, job in
            try AppBundle::getAxRect(window: window, job: job)
        }
    }

    func getAxRectForTermination(_ windowId: OpaqueWindowId) -> Rect? {
        let future = CompletableFuture<Rect?>()
        let job = withWindowAsync(windowId, .nonCancellable) { window, job in
            future.complete(try AppBundle::getAxRect(window: window, job: job))
        }
        return switch job.isCancelled {
            case true: nil
            case false: future.blockingGet()
        }
    }

    func isWindowHeuristic(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        try await withWindow(windowId, cm) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: OpaqueWindowId, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: OpaqueWindowId, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> [String: Json] {
        try await withWindow(windowId, cm) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await thread?.runInLoop(cm) { [axApp] job in
            dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    @MainActor
    func updateCachedTitle(_ nativeWindowId: UInt32, _ title: String) {
        if rawAppBundleId == "com.google.Chrome",
           let old = cachedTitles[nativeWindowId],
           !old.isEmpty,
           old != title,
           stripChromeTitleSuffix(old) != stripChromeTitleSuffix(title),
           preChangeTitles[nativeWindowId] == nil
        {
            preChangeTitles[nativeWindowId] = old
        }
        cachedTitles[nativeWindowId] = title
        if rawAppBundleId == "com.google.Chrome", title.contains("- Google Chrome") {
            syncVisibleWorkspaceStandardChromeMainWindow()
        }
    }

    @MainActor
    func getAxTitle(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> String? {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return nil }
        if !isUnitTest, let cached = cachedTitles[nativeWindowId], (!cached.isEmpty || nsApp.isHidden) {
            if !nsApp.isHidden {
                _ = withWindowAsync(windowId, .cancellable) { [pid] window, _ in
                    guard let title = window.get(Ax.titleAttr) else { return }
                    Task.startUnstructured { @MainActor in
                        MacApp.allAppsMap[pid]?.updateCachedTitle(nativeWindowId, title)
                    }
                }
            }
            return cached
        }
        let title = try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
        if let title {
            updateCachedTitle(nativeWindowId, title)
        }
        return title
    }

    func isMacosNativeFullscreen(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    func getMacosWindowNativeState(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> MacosWindowNativeState? {
        try await withWindow(windowId, cm) { window, job in
            if window.get(Ax.isFullscreenAttr) == true { return .nativeFullscreen }
            try job.checkCancellation()
            if window.get(Ax.minimizedAttr) == true { return .nativeMinimized }
            return .normal
        }
    }

    @MainActor func getWindowLevel(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> MacOsWindowLevel? {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return nil }
        return try await AppBundle::getWindowLevel(forNativeId: nativeWindowId, cm)
    }

    @MainActor static func refreshAllAndGetAliveWindowIds(
        frontmostAppBundleId: String?,
    ) async throws -> [MacApp: [OpaqueWindowId: WindowLifeStatus]] {
        for app in MacApp.allAppsMap.values { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(
            of: (MainActorRef<MacApp>, [OpaqueWindowId: WindowLifeStatus]).self,
            returning: [MacApp: [OpaqueWindowId: WindowLifeStatus]].self,
        ) { group in
            @MainActor func refreshTheApp(_ app: MacApp) {
                group.addTask { @Sendable @MainActor in
                    return (MainActorRef.init(app), try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if nsApp.activationPolicy == .regular, let app = try await MacApp.getOrRegister(nsApp) {
                    refreshTheApp(app)
                }
            }
            for app in MacApp.allAppsMap.values {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular {
                    refreshTheApp(app)
                }
            }
            var result: [MacApp: [OpaqueWindowId: WindowLifeStatus]] = [:]
            for try await (macAppRef, windowIds) in group {
                result[macAppRef.value] = windowIds
            }
            return result
        }
    }

    @MainActor private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [OpaqueWindowId: WindowLifeStatus] {
        if nsApp.isTerminated {
            await destroy()
            return [:]
        }
        let hasUnregisteredCachedWindow = cachedAliveWindowIds.contains { id, status in
            status == .alive && MacWindow.allWindowsMap[id] == nil
        }
        if !isUnitTest && hasCompletedInitialWindowRefresh && !needsWindowRefresh && !hasUnregisteredCachedWindow {
            switch refreshSessionEvent {
                case .startup:
                    break
                case .globalObserverLeftMouseUp where nsApp.bundleIdentifier == frontmostAppBundleId:
                    break
                default:
                    return cachedAliveWindowIds
            }
        }
        guard let thread else { return [:] }
        let existingTitleIds = Set(cachedTitles.keys)
        let isChromeApp = rawAppBundleId == "com.google.Chrome"
        let (rawAliveOrInvisible, newTitles, newTabCounts, skippedDueToMouseDown) = try await thread
            .runInLoop(.cancellable) { [nsApp, windows, axApp, bgTabsScheduledForPrune] (job) -> ([UInt32: WindowLifeStatus], [UInt32: String], [UInt32: Int], Bool) in
                var aliveOrInvisible: [UInt32: AxWindow] = windows.threadGuarded.filter { !bgTabsScheduledForPrune.contains($0.key) }
                var aliveWindowIds: Set<UInt32> = []
                var newTitles: [UInt32: String] = [:]
                var newTabCounts: [UInt32: Int] = [:]
                var skippedMouseDown = false
                // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
                // Second and third lines of defence are technically needed only to avoid potential flickering
                if frontmostAppBundleId != lockScreenAppBundleId {
                    aliveOrInvisible = try aliveOrInvisible.filter {
                        try job.checkCancellation()
                        return $0.value.ax.containingNativeWindowId() != nil
                    }
                }

                for (id, window) in axApp.threadGuarded.get(Ax.windowsAttr) ?? [] {
                    try job.checkCancellation()
                    if aliveOrInvisible[id] == nil && isLeftMouseButtonDown {
                        skippedMouseDown = true
                    }
                    if let axWin = try aliveOrInvisible.getOrRegisterAxWindow(windowId: id, window, nsApp, job),
                       !existingTitleIds.contains(id)
                    {
                        let title = axWin.ax.get(Ax.titleAttr) ?? ""
                        newTitles[id] = title
                        if isChromeApp && title.contains("- Google Chrome"),
                           let snap = readChromeWindowTabsSnapshot(axWin.ax)
                        {
                            newTabCounts[id] = snap.tabs.count
                        }
                    }
                    if aliveOrInvisible[id] != nil {
                        aliveWindowIds.insert(id)
                    }
                }

                windows.threadGuarded = aliveOrInvisible
                let statuses: [UInt32: WindowLifeStatus] = aliveOrInvisible.keys.associate(with: { it in
                    aliveWindowIds.contains(it) ? .alive : .invisible
                })
                return (statuses, newTitles, newTabCounts, skippedMouseDown)
            }
        var aliveOrInvisible = rawAliveOrInvisible
        bgTabsScheduledForPrune = []
        let wasInitialRefreshCompleted = hasCompletedInitialWindowRefresh
        hasCompletedInitialWindowRefresh = true
        needsWindowRefresh = skippedDueToMouseDown
        if skippedDueToMouseDown {
            Task.startUnstructured { @MainActor [weak self] in
                for delayMs in [120, 350] {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard let self, self.needsWindowRefresh else { return }
                    if !isLeftMouseButtonDown {
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                        return
                    }
                }
            }
        }
        windowsCount = aliveOrInvisible.count
        if wasInitialRefreshCompleted && !newTitles.isEmpty {
            onNewWindowCreated()
        }
        for (nativeId, title) in newTitles {
            cachedTitles[nativeId] = title
        }
        for (nativeId, count) in newTabCounts {
            cachedTabCounts[nativeId] = count
        }
        for nativeId in cachedTitles.keys where aliveOrInvisible[nativeId] == nil {
            cachedTitles.removeValue(forKey: nativeId)
            cachedTabCounts.removeValue(forKey: nativeId)
            preChangeTitles.removeValue(forKey: nativeId)
            preChangeTabCounts.removeValue(forKey: nativeId)
            lastOffWorkspaceTitleChangeTime.removeValue(forKey: nativeId)
            lastOffWorkspaceFocusTime.removeValue(forKey: nativeId)
        }

        nonidempotentNativeTabSwapHeuristic(&aliveOrInvisible)

        var aliveOrInvisibleMap: [OpaqueWindowId: WindowLifeStatus] = [:]
        for (id, lifeStatus) in aliveOrInvisible {
            aliveOrInvisibleMap[getOrRegisterOpaqueWindowId(id)] = lifeStatus
        }
        cachedAliveWindowIds = aliveOrInvisibleMap
        for windowId in setFrameJobs.keys {
            if !aliveOrInvisibleMap.keys.contains(windowId) {
                setFrameJobs.removeValue(forKey: windowId)?.cancel()
            }
        }
        return aliveOrInvisibleMap
    }

    private var bgTabsScheduledForPrune: Set<UInt32> = []
    private var lifeStatusesOfLastRefresh: [UInt32: WindowLifeStatus] = [:]
    @MainActor private func nonidempotentNativeTabSwapHeuristic(_ aliveOrInvisible: inout [UInt32: WindowLifeStatus]) {
        let noLongerAlive = lifeStatusesOfLastRefresh.filter { (id, lifeStatus) in lifeStatus == .alive && aliveOrInvisible[id] != .alive }
        let becameAlive = aliveOrInvisible.filter { (id, lifeStatus) in lifeStatus == .alive && lifeStatusesOfLastRefresh[id] != .alive }
        lifeStatusesOfLastRefresh = aliveOrInvisible
        guard !isUnitTest ? rawAppBundleId != "com.google.Chrome" : true else { return }
        if let backgroundTabId = noLongerAlive.singleOrNil()?.key,
           let frontmostTabId = becameAlive.singleOrNil()?.key
        {
            let tabGroupWindowId = getOrRegisterOpaqueWindowId(backgroundTabId)
            if MacWindow.allWindowsMap[tabGroupWindowId]?.parent is MacosPopupWindowsContainer {
                return
            }
            windowIdMapping.put(tabGroupWindowId, frontmostTabId)
            aliveOrInvisible[backgroundTabId] = nil
            bgTabsScheduledForPrune.insert(backgroundTabId)
        }
    }

    private func destroy() async {
        _ = await Task.startUnstructured { @MainActor [pid] in _ = MacApp.allAppsMap.removeValue(forKey: pid) }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { job in CFRunLoopStop(CFRunLoopGetCurrent()) }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T>(
        _ windowId: OpaqueWindowId,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return nil }
        return try await thread?.runInLoop(cm) { [windows] job in
            guard let window = windows.threadGuarded[nativeWindowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(
        _ windowId: OpaqueWindowId,
        _ cm: CancellationMode,
        onComplete: (@Sendable () -> ())? = nil,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> (),
    ) -> RunLoopJob {
        guard let nativeWindowId = windowIdMapping.forward[windowId], let thread else {
            onComplete?()
            return .cancelled
        }
        return thread.runInLoopAsync(job: RunLoopJob(cm), autoCheckCancelled: false) { [windows] job in
            defer {
                if let onComplete {
                    _ = Thread.current.runInLoopAsync(job: RunLoopJob(.nonCancellable), autoCheckCancelled: false) { _ in
                        onComplete()
                    }
                }
            }
            if job.isCancelled { return }
            guard let window = windows.threadGuarded[nativeWindowId] else { return }
            try? body(window.ax, job)
        }
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
            (titleChangedObs, [kAXTitleChangedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

private struct ChromeWindowTabsSnapshot: Sendable {
    let tabs: [String]
    let selectedIndex: Int?
    var selectedTabTitle: String? {
        guard let selectedIndex, tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }
}

private func findChromeTabGroup(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 9 { return nil }
    var roleRef: CFTypeRef?
    guard unsafe AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
          let role = roleRef as? String
    else { return nil }
    if role == "AXTabGroup" { return el }
    if role != "AXWindow" && role != "AXGroup" { return nil }
    var childrenRef: CFTypeRef?
    guard unsafe AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement]
    else { return nil }
    for child in children {
        if let found = findChromeTabGroup(child, depth: depth + 1) {
            return found
        }
    }
    return nil
}

private func readChromeWindowTabsSnapshot(_ axWin: AXUIElement) -> ChromeWindowTabsSnapshot? {
    guard let tabGroup = findChromeTabGroup(axWin) else { return nil }
    var childrenRef: CFTypeRef?
    guard unsafe AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement]
    else { return nil }
    var tabs: [String] = []
    var selectedIndex: Int? = nil
    for child in children {
        var roleRef: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
              (roleRef as? String) == "AXRadioButton"
        else { continue }
        let rawTitle = child.get(Ax.titleAttr) ?? ""
        var valRef: CFTypeRef?
        if unsafe AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valRef) == .success {
            if let num = valRef as? NSNumber, num.intValue != 0 {
                selectedIndex = tabs.count
            } else if let b = valRef as? Bool, b {
                selectedIndex = tabs.count
            }
        }
        tabs.append(stripChromeTitleSuffix(rawTitle))
    }
    guard !tabs.isEmpty else { return nil }
    return ChromeWindowTabsSnapshot(tabs: tabs, selectedIndex: selectedIndex)
}

private func findChromeTabSubmenuItems(_ axApp: AXUIElement) -> [AXUIElement]? {
    var menuBarRef: CFTypeRef?
    guard unsafe AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
          let menuBarRef
    else { return nil }
    let menuBar = menuBarRef as! AXUIElement
    var childrenRef: CFTypeRef?
    guard unsafe AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let topItems = childrenRef as? [AXUIElement]
    else { return nil }
    for item in topItems where item.get(Ax.titleAttr) == "Tab" {
        var subRef: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subRef) == .success,
              let subMenu = (subRef as? [AXUIElement])?.first
        else { return nil }
        var subItemsRef: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &subItemsRef) == .success,
              let subItems = subItemsRef as? [AXUIElement]
        else { return nil }
        return subItems
    }
    return nil
}

private func findMoveTabToNewWindowMenuItem(_ axApp: AXUIElement) -> AXUIElement? {
    guard let subItems = findChromeTabSubmenuItems(axApp) else { return nil }
    return subItems.first(where: { $0.get(Ax.titleAttr) == "Move Tab to New Window" })
}

private func stripChromeTitleSuffix(_ windowTitle: String) -> String {
    var s = windowTitle
    if let range = s.range(of: " - Google Chrome", options: .backwards) {
        s = String(s[..<range.lowerBound])
    }
    for marker in [
        " - Part of ",
        " - Pinned",
        " - High memory usage - ",
        " - Memory usage - ",
        " - Inactive",
        " - Audio playing",
        " - Audio muted",
    ] {
        if let range = s.range(of: marker, options: .backwards) {
            s = String(s[..<range.lowerBound])
        }
    }
    return s
}

private func chromeWindowTitle(_ windowTitle: String, matchesTabMenuTitle tabTitle: String) -> Bool {
    let stripped = stripChromeTitleSuffix(windowTitle)
    let strippedTab = stripChromeTitleSuffix(tabTitle)
    guard !stripped.isEmpty, !strippedTab.isEmpty else { return false }
    if stripped == strippedTab || stripped.hasPrefix(strippedTab) || windowTitle.hasPrefix(strippedTab) { return true }
    let parts = strippedTab.components(separatedBy: "…").filter { !$0.isEmpty }
    guard let first = parts.first, stripped.hasPrefix(first) else { return false }
    var searchStart = stripped.index(stripped.startIndex, offsetBy: first.count)
    for part in parts.dropFirst() {
        guard let range = stripped[searchStart...].range(of: part) else { return false }
        searchStart = range.upperBound
    }
    return true
}

private func titleChangedObs(_: AXObserver, ax: AXUIElement, _: CFString, _: UnsafeMutableRawPointer?) {
    guard let pid = axTaskLocalAppThreadToken?.pid,
          let windowId = ax.containingNativeWindowId(),
          let title = ax.get(Ax.titleAttr)
    else { return }
    Task.startUnstructured { @MainActor in
        guard let app = MacApp.allAppsMap[pid] else { return }
        if app.rawAppBundleId == "com.google.Chrome" {
            if app.onChromeWindowTitleChanged(windowId, title) {
                await app.checkForNewlyOpenedExternalChromeTab(hintWindowId: windowId)
                Task.startUnstructured { @MainActor in
                    for delayMs in [80, 200, 500, 1000] {
                        try? await Task.sleep(for: .milliseconds(delayMs))
                        await app.checkForNewlyOpenedExternalChromeTab(hintWindowId: windowId)
                    }
                }
            }
        } else {
            app.updateCachedTitle(windowId, title)
        }
    }
}

extension [UInt32: AxWindow] {
    @discardableResult fileprivate mutating func getOrRegisterAxWindow(
        windowId id: UInt32,
        _ axWindow: AXUIElement,
        _ nsApp: NSRunningApplication,
        _ job: RunLoopJob,
    ) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
    try job.checkCancellation()
    guard let size = window.get(Ax.sizeAttr) else { return nil }
    return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
}

private func setFrame(_ window: AXUIElement, _ topLeft: Point?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}

final class MainActorRef<T>: Sendable {
    @MainActor var value: T
    @MainActor public init(_ value: T) { self.value = value }
}
