import AppKit
import Common

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        let notifApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if notifApp?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let notifPid = notifApp?.processIdentifier
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if let notifPid, let app = MacApp.allAppsMap[notifPid] {
                if notifName == NSWorkspace.didUnhideApplicationNotification.rawValue {
                    if app.consumeSuppressedUnhideNotification() {
                        return
                    }
                    app.markExternallyUnhiddenOrActivated()
                    if app.rawAppBundleId == "com.google.Chrome" {
                        MacApp.lastExternalChromeActivationTime = .now
                        await app.checkForNewlyOpenedExternalChromeTab()
                        Task.startUnstructured { @MainActor in
                            for delayMs in [100, 250] {
                                try? await Task.sleep(for: .milliseconds(delayMs))
                                await app.checkForNewlyOpenedExternalChromeTab()
                            }
                        }
                    }
                } else if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                    onAppActivatedInWorkspace(notifPid)
                    if (app.isSuppressingSelfFocusNotifications || !app.isHiddenByAeroSpace) && globalFocus.windowOrNil?.app.pid == app.pid {
                        cancelActiveRefreshTask()
                        return
                    }
                    if let hideTime = MacApp.lastAeroSpaceActiveAppHideTime,
                       hideTime.duration(to: .now) < .milliseconds(400),
                       app.isEligibleForAeroSpaceAutoHide()
                    {
                        app.scheduleHideByAeroSpaceIfEligible()
                        return
                    }
                    app.markExternallyUnhiddenOrActivated()
                    if app.rawAppBundleId == "com.google.Chrome" {
                        MacApp.lastExternalChromeActivationTime = .now
                        await app.checkForNewlyOpenedExternalChromeTab()
                        Task.startUnstructured { @MainActor in
                            for delayMs in [100, 250] {
                                try? await Task.sleep(for: .milliseconds(delayMs))
                                await app.checkForNewlyOpenedExternalChromeTab()
                            }
                        }
                    }
                }
            }
            if !MacWindow.savedWindowWorkspaces.isEmpty {
                for app in MacApp.allAppsMap.values {
                    app.needsWindowRefresh = true
                }
            }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        let hiddenPid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        Task.startUnstructured { @MainActor in
            if let hiddenPid, let app = MacApp.allAppsMap[hiddenPid], app.consumeSuppressedHideNotification() {
                return
            }
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.isUserHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.isUserHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values where app.isUserHidden {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task.startUnstructured { @MainActor in
                if !TrayMenuModel.shared.isEnabled { return }
                gcMonitors()
                for app in MacApp.allAppsMap.values {
                    app.needsWindowRefresh = true
                }
                for window in MacWindow.allWindows where window.isHiddenInCorner {
                    window.needsCornerRehide = true
                }
                scheduleCancellableCompleteRefreshSession(.globalObserver("didChangeScreenParameters"))
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task.startUnstructured { @MainActor in
                if !TrayMenuModel.shared.isEnabled { return }
                for app in MacApp.allAppsMap.values {
                    app.needsWindowRefresh = true
                }
                scheduleCancellableCompleteRefreshSession(.globalObserver("com.apple.screenIsUnlocked"))
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task.startUnstructured { @MainActor in
                let wasNonChrome = globalFocus.windowOrNil?.app.rawAppBundleId != "com.google.Chrome" ||
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.google.Chrome"
                if wasNonChrome {
                    MacApp.lastNonChromeLeftMouseUpTime = .now
                }
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.visibleRect.contains(mouseLocation) && clickedMonitor.visibleWorkspace != globalFocus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.visibleWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
