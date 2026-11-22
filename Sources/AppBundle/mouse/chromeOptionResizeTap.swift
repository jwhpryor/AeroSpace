import AppKit
import ApplicationServices
import Common
import PrivateApi

struct ChromeResizeEdges: Equatable, Sendable {
    let left: Bool
    let right: Bool
    let top: Bool
    let bottom: Bool

    var any: Bool { left || right || top || bottom }
}

func detectChromeResizeEdges(point: CGPoint, frame: CGRect, edgeMargin: CGFloat = 8.0, outerHalo: CGFloat = 6.0) -> ChromeResizeEdges {
    let withinY = point.y >= frame.minY - outerHalo && point.y <= frame.maxY + outerHalo
    let withinX = point.x >= frame.minX - outerHalo && point.x <= frame.maxX + outerHalo
    let left = withinY && abs(point.x - frame.minX) <= edgeMargin
    let right = withinY && abs(point.x - frame.maxX) <= edgeMargin
    let top = withinX && abs(point.y - frame.minY) <= edgeMargin
    let bottom = withinX && abs(point.y - frame.maxY) <= edgeMargin
    return ChromeResizeEdges(left: left, right: right, top: top, bottom: bottom)
}

func computeSymmetricChromeResizeFrame(
    startFrame: CGRect,
    startMouse: CGPoint,
    currentMouse: CGPoint,
    edges: ChromeResizeEdges,
    screenBounds: CGRect,
    minWidth: CGFloat = 500.0,
    minHeight: CGFloat = 300.0,
) -> CGRect {
    var newX = startFrame.minX
    var newW = startFrame.width
    var newY = startFrame.minY
    var newH = startFrame.height

    if edges.left || edges.right {
        let dx = currentMouse.x - startMouse.x
        let signedDx = edges.right ? dx : -dx
        let desiredLeft = startFrame.minX - signedDx
        let desiredRight = startFrame.maxX + signedDx
        let clampedLeft = max(screenBounds.minX, desiredLeft)
        let clampedRight = min(screenBounds.maxX, desiredRight)
        if clampedRight - clampedLeft < minWidth {
            let centerX = startFrame.midX
            let half = minWidth / 2.0
            newX = max(screenBounds.minX, min(screenBounds.maxX - minWidth, centerX - half))
            newW = minWidth
        } else {
            newX = clampedLeft
            newW = clampedRight - clampedLeft
        }
    }

    if edges.top || edges.bottom {
        let dy = currentMouse.y - startMouse.y
        let signedDy = edges.bottom ? dy : -dy
        let minTop = max(screenBounds.minY, 25.0)
        let desiredTop = startFrame.minY - signedDy
        let desiredBottom = startFrame.maxY + signedDy
        let clampedTop = max(minTop, desiredTop)
        let clampedBottom = min(screenBounds.maxY, desiredBottom)
        if clampedBottom - clampedTop < minHeight {
            let centerY = startFrame.midY
            let half = minHeight / 2.0
            newY = max(minTop, min(screenBounds.maxY - minHeight, centerY - half))
            newH = minHeight
        } else {
            newY = clampedTop
            newH = clampedBottom - clampedTop
        }
    }

    return CGRect(x: newX.rounded(), y: newY.rounded(), width: newW.rounded(), height: newH.rounded())
}

/// Intercepts Option-drag resizing on Google Chrome window edges and applies symmetric
/// AXPosition + AXSize updates directly, bypassing Chromium's buggy macOS Option-drag loop.
@MainActor
final class ChromeOptionResizeTap {
    static let shared = ChromeOptionResizeTap()

    private struct ActiveSession {
        let axWindow: AXUIElement
        let windowId: UInt32
        let pid: pid_t
        let startMouse: CGPoint
        let startFrame: CGRect
        var lastAppliedFrame: CGRect
        let screenBounds: CGRect
        let edges: ChromeResizeEdges
    }

    private var eventTap: CFMachPort? = nil
    private var runLoopSource: CFRunLoopSource? = nil
    private var activeSession: ActiveSession? = nil

    private let axQueue = DispatchQueue(label: "aerospace.chromeOptionResize", qos: .userInteractive)
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pendingTarget: (axWindow: AXUIElement, targetFrame: CGRect, prevFrame: CGRect)? = nil
    nonisolated(unsafe) private var isDraining = false

    private init() {}

    func start() {
        if isUnitTest || serverArgs.isReadOnly || eventTap != nil { return }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            let flags = event.flags
            let location = event.location
            let shouldConsume = MainActor.assumeIsolated {
                ChromeOptionResizeTap.shared.handleEvent(type: type, flags: flags, location: location)
            }
            return shouldConsume ? nil : unsafe Unmanaged.passUnretained(event)
        }

        guard let tap = unsafe CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil,
        ) else {
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
    }

    /// Returns `true` if the event should be consumed, `false` to pass it through.
    private func handleEvent(type: CGEventType, flags: CGEventFlags, location: CGPoint) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        if !TrayMenuModel.shared.isEnabled {
            activeSession = nil
            return false
        }

        switch type {
            case .leftMouseDown:
                // Only intercept Option+drag without Cmd/Ctrl
                guard flags.contains(.maskAlternate),
                      !flags.contains(.maskCommand),
                      !flags.contains(.maskControl)
                else {
                    return false
                }
                guard let session = beginSessionIfChromeEdge(at: location) else {
                    return false
                }
                activeSession = session
                return true

            case .leftMouseDragged:
                guard var session = activeSession else {
                    return false
                }
                let newFrame = computeSymmetricChromeResizeFrame(
                    startFrame: session.startFrame,
                    startMouse: session.startMouse,
                    currentMouse: location,
                    edges: session.edges,
                    screenBounds: session.screenBounds,
                )
                if newFrame != session.lastAppliedFrame {
                    let prevFrame = session.lastAppliedFrame
                    session.lastAppliedFrame = newFrame
                    activeSession = session
                    enqueueFrameApply(axWindow: session.axWindow, targetFrame: newFrame, prevFrame: prevFrame)
                }
                return true

            case .leftMouseUp:
                guard let session = activeSession else {
                    return false
                }
                let finalFrame = computeSymmetricChromeResizeFrame(
                    startFrame: session.startFrame,
                    startMouse: session.startMouse,
                    currentMouse: location,
                    edges: session.edges,
                    screenBounds: session.screenBounds,
                )
                activeSession = nil
                enqueueFrameApply(axWindow: session.axWindow, targetFrame: finalFrame, prevFrame: session.lastAppliedFrame)
                if let win = Window.get(byNativeId: session.windowId, pid: session.pid) as? MacWindow {
                    win.lastFloatingSize = finalFrame.size
                }
                return true

            default:
                return false
        }
    }

    private func beginSessionIfChromeEdge(at pt: CGPoint) -> ActiveSession? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let outerHalo: CGFloat = 6.0
        for info in windowList {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { continue }
            var cgBounds = CGRect.zero
            guard unsafe CGRectMakeWithDictionaryRepresentation(boundsDict, &cgBounds) else { continue }
            if cgBounds.width < 100 || cgBounds.height < 100 { continue }

            // Hit-test topmost normal-layer window (with small outer resize halo)
            guard cgBounds.insetBy(dx: -outerHalo, dy: -outerHalo).contains(pt) else { continue }

            guard let pid = (info[kCGWindowOwnerPID as String] as? pid_t) ?? (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
                  let windowId = (info[kCGWindowNumber as String] as? UInt32) ?? (info[kCGWindowNumber as String] as? Int).map(UInt32.init)
            else {
                return nil
            }

            // Only intercept Google Chrome windows; let all other apps pass through untouched
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.google.Chrome" else {
                return nil
            }

            let edges = detectChromeResizeEdges(point: pt, frame: cgBounds, edgeMargin: 8.0, outerHalo: outerHalo)
            guard edges.any else { return nil }

            guard let axWindow = findAxWindow(pid: pid, windowId: windowId) else { return nil }
            let axFrame = readAxFrame(axWindow) ?? cgBounds
            let screenBounds = displayBounds(containing: CGPoint(x: axFrame.midX, y: axFrame.midY))

            return ActiveSession(
                axWindow: axWindow,
                windowId: windowId,
                pid: pid,
                startMouse: pt,
                startFrame: axFrame,
                lastAppliedFrame: axFrame,
                screenBounds: screenBounds,
                edges: edges,
            )
        }
        return nil
    }

    private func findAxWindow(pid: pid_t, windowId: UInt32) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else { return nil }
        for w in axWindows {
            var wid: CGWindowID = 0
            if unsafe _AXUIElementGetWindow(w, &wid) == .success && wid == windowId {
                return w
            }
        }
        return nil
    }

    private func readAxFrame(_ axWindow: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
              unsafe AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef
        else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard unsafe AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
              unsafe AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
        else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private func displayBounds(containing point: CGPoint) -> CGRect {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        if unsafe CGGetActiveDisplayList(16, &displays, &displayCount) == .success && displayCount > 0 {
            for i in 0 ..< Int(displayCount) {
                let bounds = CGDisplayBounds(displays[i])
                if bounds.contains(point) {
                    return bounds
                }
            }
            return CGDisplayBounds(displays[0])
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    nonisolated private func enqueueFrameApply(axWindow: AXUIElement, targetFrame: CGRect, prevFrame: CGRect) {
        pendingLock.lock()
        unsafe pendingTarget = (axWindow, targetFrame, prevFrame)
        let shouldStart = unsafe !isDraining
        if shouldStart {
            unsafe isDraining = true
        }
        pendingLock.unlock()

        if shouldStart {
            axQueue.async { [weak self] in
                self?.drainPendingFrames()
            }
        }
    }

    nonisolated private func drainPendingFrames() {
        while true {
            pendingLock.lock()
            let next = unsafe pendingTarget
            unsafe pendingTarget = nil
            if next == nil {
                unsafe isDraining = false
                pendingLock.unlock()
                return
            }
            pendingLock.unlock()

            if let (axWindow, targetFrame, prevFrame) = next {
                applyAxFrame(axWindow, targetFrame: targetFrame, prevFrame: prevFrame)
            }
        }
    }

    nonisolated private func applyAxFrame(_ axWindow: AXUIElement, targetFrame: CGRect, prevFrame: CGRect) {
        var pt = targetFrame.origin
        var sz = targetFrame.size
        guard let posVal = unsafe AXValueCreate(.cgPoint, &pt),
              let sizeVal = unsafe AXValueCreate(.cgSize, &sz)
        else { return }
        let isExpanding = targetFrame.width > prevFrame.width || targetFrame.height > prevFrame.height
        if isExpanding {
            _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
            _ = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        } else {
            _ = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
            _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        }
    }
}
