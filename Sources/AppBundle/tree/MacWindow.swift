import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?
    private var lastRestoredProportionalPositionInsideWorkspaceRect: CGPoint?
    private var hiddenInCorner: OptimalHideCorner?
    @MainActor var needsCornerRehide: Bool = false
    var inFlightSetFrameCount: Int = 0
    var lastSetFrameTime: ContinuousClock.Instant = .now - .seconds(10)
    private(set) var lastCommandedTopLeft: CGPoint? = nil
    private(set) var lastCommandedSize: CGSize? = nil

    @MainActor
    var isSuppressingMoveResizeNotifications: Bool {
        inFlightSetFrameCount > 0 || ContinuousClock.now - lastSetFrameTime < .milliseconds(1500) || matchesLastCommandedFrame()
    }

    @MainActor
    func isPointInHideCorner(_ topLeftCorner: CGPoint) -> Bool {
        guard let nodeMonitorInfo else { return false }
        return (topLeftCorner.x >= nodeMonitorInfo.visibleRect.maxX - 2 || topLeftCorner.x <= nodeMonitorInfo.visibleRect.minX + 2) &&
            topLeftCorner.y >= nodeMonitorInfo.visibleRect.maxY - 64
    }

    @MainActor
    func isPointInAnyKnownHideCorner(_ topLeftCorner: CGPoint) -> Bool {
        if isPointInHideCorner(topLeftCorner) { return true }
        // Also recognize windows still parked at a previous monitor's bottom-right corner
        if topLeftCorner.x >= 1725 && topLeftCorner.y >= 1050 { return true }
        return false
    }

    @MainActor
    func isCurrentlyInHideCorner() -> Bool {
        guard !isUnitTest else { return false }
        if let rect = getCgWindowRect(for: self) {
            return isPointInHideCorner(rect.topLeftCorner)
        }
        return false
    }

    @MainActor
    func matchesLastCommandedFrame() -> Bool {
        if isUnitTest { return false }
        if isHiddenInCorner {
            return isCurrentlyInHideCorner()
        }
        guard lastCommandedTopLeft != nil || lastCommandedSize != nil else { return false }
        guard let rect = getCgWindowRect(for: self) else { return false }
        if let expectedPos = lastCommandedTopLeft {
            if abs(rect.topLeftX - expectedPos.x) > 4 || abs(rect.topLeftY - expectedPos.y) > 4 {
                return false
            }
        }
        if let expectedSize = lastCommandedSize {
            if abs(rect.width - expectedSize.width) > 4 || abs(rect.height - expectedSize.height) > 4 {
                return false
            }
        }
        return true
    }

    @MainActor private init(
        _ id: OpaqueWindowId,
        _ actor: MacApp,
        lastFloatingSize: CGSize?,
        parent: NonLeafTreeNodeObject,
        adaptiveWeight: CGFloat,
        index: Int,
    ) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [OpaqueWindowId: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }
    private static let savedPositionsUrl = URL(filePath: "/tmp/aerospace_corner_positions.json")
    @MainActor private static var savedCornerPositions: [String: [Double]] = {
        guard let data = try? Data(contentsOf: savedPositionsUrl),
              let dict = try? JSONDecoder().decode([String: [Double]].self, from: data)
        else { return [:] }
        return dict
    }()

    @MainActor
    private static func savedCornerKey(_ window: MacWindow) -> String {
        window.macApp.nativeWindowId(of: window.windowId).map(String.init) ?? window.windowId.description
    }

    @MainActor
    private static func recordSavedCornerPosition(_ window: MacWindow, _ prop: CGPoint) {
        let key = savedCornerKey(window)
        let val = [Double(prop.x), Double(prop.y)]
        if savedCornerPositions[key] == val { return }
        savedCornerPositions[key] = val
        let snapshot = savedCornerPositions
        Task.detached {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: savedPositionsUrl, options: .atomic)
            }
        }
    }

    @MainActor
    private static func loadSavedCornerPosition(_ window: MacWindow) -> CGPoint? {
        guard let arr = savedCornerPositions[savedCornerKey(window)], arr.count == 2 else { return nil }
        return CGPoint(x: arr[0], y: arr[1])
    }

    private static let savedWindowsBackupUrl = URL(filePath: "/tmp/aerospace_windows_backup.txt")
    @MainActor static var savedWindowWorkspaces: [String: String] = {
        guard let text = try? String(contentsOf: savedWindowsBackupUrl, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1)
            if parts.count == 2 {
                let wid = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let ws = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if !wid.isEmpty && !ws.isEmpty {
                    map[wid] = ws
                }
            }
        }
        return map
    }()

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: OpaqueWindowId, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        let savedWsKey = macApp.nativeWindowId(of: windowId).map(String.init) ?? windowId.description
        let savedWorkspaceName = isUnitTest ? nil : savedWindowWorkspaces.removeValue(forKey: savedWsKey)
        let targetWorkspace: Workspace
        if let savedWorkspaceName, !savedWorkspaceName.isEmpty {
            targetWorkspace = Workspace.get(byName: savedWorkspaceName)
        } else if isStartup {
            targetWorkspace = (rect?.center.monitorApproximation ?? mainMonitorInfo).visibleWorkspace
        } else {
            targetWorkspace = globalFocus.workspace
        }
        let data = try await unbindAndGetBindingDataForNewWindow(
            windowId,
            macApp,
            targetWorkspace,
            window: nil,
            .cancellable,
        )

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window

        try await debugWindowsIfRecording(window, .cancellable)
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            await runOnWindowDetected(ifConventional: window)
            if !isUnitTest,
               !isStartup,
               savedWorkspaceName == nil,
               window.nodeWorkspace?.isVisible == true
            {
                window.unhideFromCorner(centerIfSpawnedInCorner: true)
                _ = window.focusWindow()
                window.nativeFocus()
            } else if !isUnitTest,
                      savedWorkspaceName != nil,
                      window.nodeWorkspace?.isVisible == true
            {
                window.unhideFromCorner()
            }
        }
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    @MainActor func getWindowLevel(_ cm: CancellationMode) async throws -> MacOsWindowLevel? {
        try await macApp.getWindowLevel(windowId, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let parent = unbindFromParent().parent
        macApp.onWindowDestroyed(isPopup: parent is MacosPopupWindowsContainer)
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = globalFocus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    if isUnitTest {
                        let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                        _ = setFocus(to: deadWindowFocus)
                        if focus.windowOrNil?.app.pid != app.pid {
                            deadWindowFocus.windowOrNil?.nativeFocus()
                        }
                    } else if let sameAppWindow = deadWindowWorkspace.allLeafWindowsRecursiveMru.first(where: { $0.app.pid == app.pid }) {
                        _ = sameAppWindow.focusWindow()
                        sameAppWindow.nativeFocus()
                    } else if let nextWindow = deadWindowWorkspace.allLeafWindowsRecursiveMru.first {
                        _ = nextWindow.focusWindow()
                        nextWindow.nativeFocus()
                    } else if focus.windowOrNil == nil || focus.windowOrNil?.app.pid == app.pid {
                        stickyClosedAppPidOnCurrentWorkspace = app.pid
                        _ = setFocus(to: LiveFocus(windowOrNil: nil, workspace: deadWindowWorkspace))
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .monitor, // Monitor is invalid parent for windows
                     .workspacesContainer, // WorkspacesContainer is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    @MainActor override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }
    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }

    @MainActor override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitorInfo else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            let windowRect: Rect? = if isUnitTest {
                try await getAxRect(.cancellable)
            } else if let cgRect = getCgWindowRect(for: self) {
                cgRect
            } else {
                try await getAxRect(.cancellable)
            }
            guard let windowRect else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                let proportional = CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                let isStillClampedInCorner = !isUnitTest && isPointInAnyKnownHideCorner(topLeftCorner)
                if isStillClampedInCorner, let fallback = lastRestoredProportionalPositionInsideWorkspaceRect ?? MacWindow.loadSavedCornerPosition(self) {
                    prevUnhiddenProportionalPositionInsideWorkspaceRect = fallback
                    lastRestoredProportionalPositionInsideWorkspaceRect = fallback
                } else {
                    prevUnhiddenProportionalPositionInsideWorkspaceRect = proportional
                    lastRestoredProportionalPositionInsideWorkspaceRect = proportional
                    if !isStillClampedInCorner {
                        MacWindow.recordSavedCornerPosition(self, proportional)
                    }
                }
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        } else if hiddenInCorner == corner {
            if !isUnitTest && !needsCornerRehide && isCurrentlyInHideCorner() && refreshSessionEvent?.isStartup != true {
                return
            }
            lastCommandedTopLeft = nil
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                let s: CGSize? = if isUnitTest {
                    try await getAxSize(.cancellable)
                } else if let lastFloatingSize {
                    lastFloatingSize
                } else if let lastCommandedSize {
                    lastCommandedSize
                } else if let cgRect = getCgWindowRect(for: self) {
                    cgRect.size
                } else {
                    CGSize(width: nodeMonitorInfo.visibleRect.width * 0.5, height: nodeMonitorInfo.visibleRect.height * 0.5)
                }
                guard let s else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitorInfo.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitorInfo.visibleRect.bottomRightCorner - onePixelOffset
        }
        if needsCornerRehide || refreshSessionEvent?.isStartup == true {
            lastCommandedTopLeft = nil
        }
        hiddenInCorner = corner
        needsCornerRehide = false
        setAxFrame(p, nil)
    }

    @MainActor
    func restoreDetachedWindowPosition(from sourceWindow: MacWindow?) {
        let fallback = sourceWindow?.prevUnhiddenProportionalPositionInsideWorkspaceRect
            ?? sourceWindow?.lastRestoredProportionalPositionInsideWorkspaceRect
            ?? sourceWindow.flatMap { MacWindow.loadSavedCornerPosition($0) }
            ?? prevUnhiddenProportionalPositionInsideWorkspaceRect
            ?? lastRestoredProportionalPositionInsideWorkspaceRect
            ?? MacWindow.loadSavedCornerPosition(self)
            ?? MacWindow.allWindows.first(where: { $0.app.pid == app.pid && $0.windowId != windowId })
            .flatMap { $0.lastRestoredProportionalPositionInsideWorkspaceRect ?? $0.prevUnhiddenProportionalPositionInsideWorkspaceRect ?? MacWindow.loadSavedCornerPosition($0) }
            ?? CGPoint(x: 0.0, y: 0.03)
        prevUnhiddenProportionalPositionInsideWorkspaceRect = fallback
        if let sourceSize = sourceWindow?.lastFloatingSize {
            lastFloatingSize = sourceSize
        }
        unhideFromCorner()
    }

    @MainActor
    func unhideFromCorner(centerIfSpawnedInCorner: Bool = false) {
        self.hiddenInCorner = nil
        if prevUnhiddenProportionalPositionInsideWorkspaceRect == nil,
           !isUnitTest,
           let rect = getCgWindowRect(for: self),
           isPointInAnyKnownHideCorner(rect.topLeftCorner)
        {
            let fallback: CGPoint
            if centerIfSpawnedInCorner {
                if let saved = lastRestoredProportionalPositionInsideWorkspaceRect ?? MacWindow.loadSavedCornerPosition(self) {
                    fallback = saved
                } else {
                    let workspaceRect = nodeWorkspace?.workspaceMonitorInfo.visibleRect ?? mainMonitorInfo.visibleRect
                    let monitorRect = nodeWorkspace?.workspaceMonitorInfo.rect ?? mainMonitorInfo.rect
                    let windowWidth = lastFloatingSize?.width ?? rect.width
                    let windowHeight = lastFloatingSize?.height ?? rect.height
                    let cx = max(workspaceRect.minX, workspaceRect.minX + (workspaceRect.width - windowWidth) * 0.5)
                    let cy = max(workspaceRect.minY, workspaceRect.minY + (workspaceRect.height - windowHeight) * 0.5)
                    fallback = CGPoint(
                        x: (cx - monitorRect.topLeftX) / monitorRect.width,
                        y: (cy - monitorRect.topLeftY) / monitorRect.height,
                    )
                }
            } else {
                fallback = lastRestoredProportionalPositionInsideWorkspaceRect
                    ?? MacWindow.loadSavedCornerPosition(self)
                    ?? MacWindow.allWindows.first(where: { $0.app.pid == app.pid && $0.windowId != windowId })
                    .flatMap { $0.lastRestoredProportionalPositionInsideWorkspaceRect ?? $0.prevUnhiddenProportionalPositionInsideWorkspaceRect ?? MacWindow.loadSavedCornerPosition($0) }
                    ?? CGPoint(x: 0.1, y: 0.05)
            }
            prevUnhiddenProportionalPositionInsideWorkspaceRect = fallback
        }
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else {
            if centerIfSpawnedInCorner,
               !isUnitTest,
               let nodeWorkspace,
               let parent,
               case .floatingWindow = getChildParentRelation(child: self, parent: parent)
            {
                let workspaceRect = nodeWorkspace.workspaceMonitorInfo.visibleRect
                let windowWidth = lastFloatingSize?.width ?? (workspaceRect.width * 0.7)
                let windowHeight = lastFloatingSize?.height ?? (workspaceRect.height * 0.8)
                if let rect = getCgWindowRect(for: self),
                   rect.topLeftX > workspaceRect.maxX - 80 || rect.topLeftY > workspaceRect.maxY - 80
                {
                    let newX = max(workspaceRect.minX, workspaceRect.minX + (workspaceRect.width - windowWidth) * 0.5)
                    let newY = max(workspaceRect.minY, workspaceRect.minY + (workspaceRect.height - windowHeight) * 0.5)
                    setAxFrame(CGPoint(x: newX, y: newY), nil)
                }
            }
            return
        }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow, .macosNativeHiddenAppWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitorInfo.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            case .macosNativeFullscreenWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.lastRestoredProportionalPositionInsideWorkspaceRect = prevUnhiddenProportionalPositionInsideWorkspaceRect
        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        if !isUnitTest {
            let sameTopLeft = topLeft == nil || topLeft == lastCommandedTopLeft
            let sameSize = size == nil || size == lastCommandedSize
            if sameTopLeft && sameSize && (topLeft != nil || size != nil),
               let rect = getCgWindowRect(for: self),
               topLeft.map({ abs(rect.topLeftX - $0.x) <= 4 && abs(rect.topLeftY - $0.y) <= 4 }) ?? true,
               size.map({ abs(rect.width - $0.width) <= 4 && abs(rect.height - $0.height) <= 4 }) ?? true
            {
                return
            }
        }
        if let topLeft { lastCommandedTopLeft = topLeft }
        if let size { lastCommandedSize = size }
        lastSetFrameTime = .now
        inFlightSetFrameCount += 1
        macApp.setAxFrame(windowId, topLeft, size)
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        let data = forceTile
            ? unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace, window: self, cm)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewWindow(_ windowId: OpaqueWindowId, _ macApp: MacApp, _ workspace: Workspace, window: Window?, _ cm: CancellationMode) async throws -> BindingData {
    let windowLevel = try await macApp.getWindowLevel(windowId, cm)
    switch try await macApp.getAxUiElementWindowType(windowId, windowLevel, cm) {
        case .popup:
            return BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog:
            return BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window:
            if hasUnconditionalFloatingOnWindowDetected() {
                window?.unbindFromParent()
                return BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
            return unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
    }
}

@MainActor
private func hasUnconditionalFloatingOnWindowDetected() -> Bool {
    for callback in config.onWindowDetected {
        switch callback.matcher {
            case .command(let cmd):
                if case .empty = cmd {} else { continue }
            case .legacy(let m):
                if m.appId != nil || m.appNameRegexSubstring != nil || m.windowTitleRegexSubstring != nil || m.workspace != nil || m.duringAeroSpaceStartup != nil {
                    continue
                }
        }
        if case .cmd(let c) = callback.rawRun,
           let layoutCmd = c as? LayoutCommand,
           layoutCmd.args.toggleBetween.val == [.floating]
        {
            return true
        }
    }
    return false
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    if let (tilingParent, index) = workspace.mostRecentWindowRecursive?.nearestAliveTilingParent() {
        return BindingData(parent: tilingParent, adaptiveWeight: WEIGHT_AUTO, index: index + 1)
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

@MainActor
func runOnWindowDetected(ifConventional window: Window) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            let layout = global_layoutForNextDetectedWindow
            global_layoutForNextDetectedWindow = nil
            defer {
                if let layout {
                    await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                        .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
                }
            }
            if let layout {
                await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                    .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
            }
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        case .macosPopupWindowsContainer, nil:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matches(window) {
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        switch self.matcher {
            case .legacy(let matcher):
                if let startupMatcher = matcher.duringAeroSpaceStartup, startupMatcher != isStartup {
                    return false
                }
                if let regex = matcher.windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
                    return false
                }
                if let appId = matcher.appId, appId != window.app.rawAppBundleId {
                    return false
                }
                if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
                    return false
                }
                if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
                    return false
                }
                return true
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}
