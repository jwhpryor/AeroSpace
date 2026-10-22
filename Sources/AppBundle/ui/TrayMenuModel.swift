import AppKit
import Common

public final class TrayMenuModel: ObservableObject {
    @MainActor public static let shared = TrayMenuModel()

    private init() {}

    @Published var trayText: String = ""
    @Published var trayItems: [TrayItem] = []
    /// Is "layouting" enabled
    @Published var isEnabled: Bool = true
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()
    @Published var sponsorshipMessage: String = sponsorshipPrompts.randomElement().orDie()
    @Published var lastReloadConfigContainedWarnings: Bool = false
    @Published var axPermissionStatus: AxPermissionStatus = .waitingWithPrompt
    @MainActor fileprivate var lastFileColors: [String: String] = [:]
    @MainActor private var workspaceColorsDirWatchers: [String: WorkspaceColorsFsWatcher] = [:]
    @MainActor private var workspaceColorsFileWatchers: [String: WorkspaceColorsFsWatcher] = [:]

    @MainActor
    func syncWorkspaceColorsWatchers() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let defaultColorsDir = home.appending(path: ".aerospace_config/workspace_colors")
        try? fm.createDirectory(at: defaultColorsDir, withIntermediateDirectories: true)

        let dirs = experimentalUISettings.workspaceColorsDirectories
        var activeDirPaths: Set<String> = []
        var activeFilePaths: Set<String> = []

        for dirUrl in dirs {
            guard (try? dirUrl.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            activeDirPaths.insert(dirUrl.path)
            if workspaceColorsDirWatchers[dirUrl.path] == nil {
                workspaceColorsDirWatchers[dirUrl.path] = WorkspaceColorsFsWatcher(path: dirUrl.path) {
                    TrayMenuModel.shared.onWorkspaceColorsFsEvent()
                }
            }
            if let entries = try? fm.contentsOfDirectory(at: dirUrl, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for fileUrl in entries where (try? fileUrl.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    activeFilePaths.insert(fileUrl.path)
                    if workspaceColorsFileWatchers[fileUrl.path] == nil {
                        workspaceColorsFileWatchers[fileUrl.path] = WorkspaceColorsFsWatcher(path: fileUrl.path) {
                            TrayMenuModel.shared.onWorkspaceColorsFsEvent()
                        }
                    }
                }
            }
        }

        for path in Array(workspaceColorsDirWatchers.keys) where !activeDirPaths.contains(path) || workspaceColorsDirWatchers[path]?.isValid != true {
            workspaceColorsDirWatchers.removeValue(forKey: path)
        }
        for path in Array(workspaceColorsFileWatchers.keys) where !activeFilePaths.contains(path) || workspaceColorsFileWatchers[path]?.isValid != true {
            workspaceColorsFileWatchers.removeValue(forKey: path)
        }
    }

    @MainActor
    private func onWorkspaceColorsFsEvent() {
        syncWorkspaceColorsWatchers()
        let currentFileColors = experimentalUISettings.loadFileWorkspaceColors()
        if currentFileColors != lastFileColors {
            updateTrayText()
        }
    }
}

private final class WorkspaceColorsFsWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32
    private(set) var isValid: Bool = true

    init?(path: String, onChange: @escaping @MainActor () -> Void) {
        fd = unsafe open(path, O_EVTONLY)
        if fd < 0 { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .main,
        )
        source.setEventHandler { [weak self] in
            if let self {
                let flags = self.source.data
                if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                    self.isValid = false
                }
            }
            MainActor.checkIsolated { onChange() }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}

enum AxPermissionStatus: Equatable {
    case granted
    case waiting
    case waitingWithPrompt
}

@MainActor func updateTrayText() {
    if !isUnitTest {
        TrayMenuModel.shared.syncWorkspaceColorsWatchers()
    }
    let sortedMonitors = sortedMonitorInfos
    let focus = focus
    let newTrayText = (activeMode?.takeIf { $0 != mainModeId }?.first.map { "(\($0.uppercased())) " } ?? "") +
        sortedMonitors
        .map {
            let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
            let activeWorkspaceName = hasFullscreenWindows ? "[\($0.activeWorkspace.name)]" : $0.activeWorkspace.name
            return ($0.activeWorkspace == focus.workspace && sortedMonitors.count > 1 ? "*" : "") + activeWorkspaceName
        }
        .joined(separator: " │ ")
    if TrayMenuModel.shared.trayText != newTrayText {
        TrayMenuModel.shared.trayText = newTrayText
    }
    let fileColors = isUnitTest ? [:] : TrayMenuModel.shared.experimentalUISettings.loadFileWorkspaceColors()
    TrayMenuModel.shared.lastFileColors = fileColors
    let newWorkspaces = Workspace.all.map {
        let apps = $0.allLeafWindowsRecursive.map { $0.app.name?.takeIf { !$0.isEmpty } }.filterNotNil().toSet()
        let dash = " - "
        let suffix = switch true {
            case !apps.isEmpty: dash + apps.sorted().joinTruncating(separator: ", ", length: 25)
            case $0.isVisible: dash + $0.workspaceMonitor.name
            default: ""
        }
        let hasFullscreenWindows = $0.allLeafWindowsRecursive.contains { $0.isFullscreen }
        let customColorRaw = isUnitTest
            ? nil
            : TrayMenuModel.shared.experimentalUISettings.workspaceColorRaw(for: $0.name, fileColors: fileColors)
        return WorkspaceViewModel(
            name: $0.name,
            suffix: suffix,
            isFocused: focus.workspace == $0,
            isEffectivelyEmpty: $0.isEffectivelyEmpty,
            isVisible: $0.isVisible,
            hasFullscreenWindows: hasFullscreenWindows,
            customColorRaw: customColorRaw,
        )
    }
    if TrayMenuModel.shared.workspaces != newWorkspaces {
        TrayMenuModel.shared.workspaces = newWorkspaces
    }
    var items = sortedMonitors.map {
        let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return TrayItem(
            type: .workspace,
            name: $0.activeWorkspace.name,
            isActive: $0.activeWorkspace == focus.workspace,
            hasFullscreenWindows: hasFullscreenWindows,
        )
    }
    let mode = activeMode?.takeIf { $0 != mainModeId }?.first.map {
        TrayItem(type: .mode, name: $0.uppercased(), isActive: true, hasFullscreenWindows: false)
    }
    if let mode {
        items.insert(mode, at: 0)
    }
    if TrayMenuModel.shared.trayItems != items {
        TrayMenuModel.shared.trayItems = items
    }
}

struct WorkspaceViewModel: Hashable {
    let name: String
    let suffix: String
    let isFocused: Bool
    let isEffectivelyEmpty: Bool
    let isVisible: Bool
    let hasFullscreenWindows: Bool
    let customColorRaw: String?
}

enum TrayItemType: String, Hashable {
    case mode
    case workspace
}

private let validLetters = "A" ... "Z"

struct TrayItem: Hashable, Identifiable {
    let type: TrayItemType
    let name: String
    let isActive: Bool
    let hasFullscreenWindows: Bool
    var systemImageName: String? {
        // System image type is only valid for numbers 0 to 50 and single capital char workspace name
        switch Int(name) {
            case let number?: if !(0 ... 50).contains(number) { return nil }
            case nil where name.count == 1: if !validLetters.contains(name) { return nil }
            default: return nil
        }
        let lowercasedName = name.lowercased()
        return switch type {
            case .mode: "\(lowercasedName).circle"
            case .workspace where isActive: "\(lowercasedName).square.fill"
            case .workspace: "\(lowercasedName).square"
        }
    }
    var id: String {
        return type.rawValue + name
    }
}
