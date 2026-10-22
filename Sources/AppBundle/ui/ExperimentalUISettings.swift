import Foundation
import SwiftUI

struct ExperimentalUISettings {
    var displayStyle: MenuBarStyle {
        get {
            switch UserDefaults.standard.string(forKey: ExperimentalUISettingsItems.displayStyle.rawValue) {
                case let value?: MenuBarStyle(rawValue: value) ?? .monospacedText
                case nil: .monospacedText
            }
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: ExperimentalUISettingsItems.displayStyle.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    var workspaceColorsEnabled: Bool {
        get {
            switch UserDefaults.standard.object(forKey: ExperimentalUISettingsItems.workspaceColorsEnabled.rawValue) {
                case let value as Bool: value
                default: true
            }
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: ExperimentalUISettingsItems.workspaceColorsEnabled.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    var workspaceColors: [String: String] {
        UserDefaults.standard.dictionary(forKey: ExperimentalUISettingsItems.workspaceColors.rawValue) as? [String: String] ?? [:]
    }

    var workspaceColorsDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        if let customDir = UserDefaults.standard.string(forKey: ExperimentalUISettingsItems.workspaceColorsDir.rawValue),
           !customDir.isEmpty
        {
            let expanded = (customDir as NSString).expandingTildeInPath
            dirs.append(URL(filePath: expanded))
        }
        dirs.append(home.appending(path: ".aerospace_config/workspace_colors"))
        dirs.append(home.appending(path: ".aerospace_config"))
        dirs.append(home.appending(path: ".config/aerospace/workspace-colors"))
        return dirs
    }

    func loadFileWorkspaceColors() -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        // Iterate in reverse priority order so higher-priority directories win
        for dirUrl in workspaceColorsDirectories.reversed() {
            guard let entries = try? fm.contentsOfDirectory(at: dirUrl, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for fileUrl in entries {
                guard (try? fileUrl.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                if let content = try? String(contentsOf: fileUrl, encoding: .utf8) {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        result[fileUrl.lastPathComponent] = trimmed
                    }
                }
            }
        }
        return result
    }

    func workspaceColorRaw(for workspaceName: String, fileColors: [String: String]? = nil) -> String? {
        guard workspaceColorsEnabled else { return nil }
        let resolvedFileColors = fileColors ?? loadFileWorkspaceColors()
        if let exactFile = resolvedFileColors[workspaceName], parseWorkspaceColor(exactFile) != nil {
            return exactFile
        }
        if let dashIdx = workspaceName.firstIndex(of: "-") {
            let suffix = String(workspaceName[workspaceName.index(after: dashIdx)...])
            if !suffix.isEmpty, let suffixColor = resolvedFileColors[suffix], parseWorkspaceColor(suffixColor) != nil {
                return suffixColor
            }
            let prefix = String(workspaceName[..<dashIdx])
            if !prefix.isEmpty, let prefixColor = resolvedFileColors[prefix], parseWorkspaceColor(prefixColor) != nil {
                return prefixColor
            }
        }
        let colors = workspaceColors
        if let exact = colors[workspaceName], parseWorkspaceColor(exact) != nil {
            return exact
        }
        let wildcardMatch = colors
            .filter { key, _ in key.hasSuffix("*") && workspaceName.hasPrefix(String(key.dropLast())) }
            .max { $0.key.count < $1.key.count }
        if let raw = wildcardMatch?.value, parseWorkspaceColor(raw) != nil {
            return raw
        }
        return nil
    }

    func workspaceColor(for workspaceName: String, fileColors: [String: String]? = nil) -> Color? {
        guard let raw = workspaceColorRaw(for: workspaceName, fileColors: fileColors) else { return nil }
        return parseWorkspaceColor(raw)
    }
}

func parseWorkspaceColor(_ raw: String) -> Color? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch trimmed {
        case "working", "running", "in_progress", "busy", "thinking": return .yellow
        case "failed", "error", "fail": return .red
        case "completed", "complete", "done", "success", "finished", "ready": return .green
        case "idle", "default", "none", "clear", "": return nil
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "cyan": return .cyan
        case "pink": return .pink
        case "mint": return .mint
        case "teal": return .teal
        case "indigo": return .indigo
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "white": return .white
        case "black": return .black
        default: break
    }
    let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    let expandedHex: String
    switch hex.count {
        case 3:
            expandedHex = hex.map { "\($0)\($0)" }.joined()
        case 6:
            expandedHex = hex
        default:
            return nil
    }
    guard let rgb = UInt64(expandedHex, radix: 16) else { return nil }
    let r = Double((rgb >> 16) & 0xFF) / 255.0
    let g = Double((rgb >> 8) & 0xFF) / 255.0
    let b = Double(rgb & 0xFF) / 255.0
    return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Equatable, Hashable {
    case monospacedText
    case systemText
    case squares
    case i3
    case i3Ordered
    var id: String { rawValue }
    var title: String {
        switch self {
            case .monospacedText: "Monospaced font"
            case .systemText: "System font"
            case .squares: "Square images"
            case .i3: "i3 style grouped"
            case .i3Ordered: "i3 style ordered"
        }
    }
}

enum ExperimentalUISettingsItems: String {
    case displayStyle
    case workspaceColorsEnabled
    case workspaceColors
    case workspaceColorsDir
}

@MainActor
func getExperimentalUISettingsMenu(viewModel: TrayMenuModel) -> some View {
    let color = AppearanceTheme.current == .dark ? Color.white : Color.black
    return Menu {
        Text("Menu bar style (macOS 14 or later):")
        ForEach(MenuBarStyle.allCases, id: \.id) { style in
            MenuBarStyleButton(style: style, color: color).environmentObject(viewModel)
        }
        Divider()
        Text("Menu dropdown:")
        Button {
            viewModel.experimentalUISettings.workspaceColorsEnabled.toggle()
        } label: {
            Toggle(isOn: .constant(viewModel.experimentalUISettings.workspaceColorsEnabled)) {
                Text("Enable custom workspace colors")
            }
        }
    } label: {
        Text("Experimental UI Settings (No stability guarantees)")
    }
}

@MainActor
struct MenuBarStyleButton: View {
    @EnvironmentObject var viewModel: TrayMenuModel
    let style: MenuBarStyle
    let color: Color

    var body: some View {
        Button {
            viewModel.experimentalUISettings.displayStyle = style
        } label: {
            Toggle(isOn: .constant(viewModel.experimentalUISettings.displayStyle == style)) {
                MenuBarLabel(style: style, color: color)
                    .environmentObject(viewModel)
                Text(" -  " + style.title)
            }
        }
    }
}
