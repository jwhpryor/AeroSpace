import AppKit
import Common
import Foundation

@MainActor
public final class QuotaStatusBar: NSObject {
    public static let shared = QuotaStatusBar()

    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?

    private struct GaugeConfig: Codable, Sendable {
        let id: String
        let prefix: String
        let title: String
        let bucket_ids: [String]?
        let group_keywords: [String]?
        let model_keywords: [String]?
    }

    private struct MonitorConfig: Codable, Sendable {
        let token_files: [String]
        let oauth_token_url: String
        let client_id: String
        let client_secret: String
        let user_agent: String?
        let summary_url: String?
        let models_url: String?
        let request_body: String?
        let gauges: [GaugeConfig]
    }

    private struct GaugeQuotaState: Sendable {
        let remainingFraction: Double
        let description: String?
        let resetTimeISO: String?
    }

    private var activeConfig: MonitorConfig? = nil
    private var statesById: [String: GaugeQuotaState] = [:]
    private var lastUpdated: Date? = nil
    private var lastError: String? = nil

    private var cachedAccessToken: String? = nil
    private var cachedAccessTokenExpiry: Date = .distantPast

    private let showPercentDefaultsKey = "quotaStatusBarShowPercentBeneath"

    private var showPercentBeneath: Bool {
        get {
            if UserDefaults.standard.object(forKey: showPercentDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: showPercentDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showPercentDefaultsKey)
            updateDisplay()
        }
    }

    private override init() {
        super.init()
    }

    public func start() {
        guard !isUnitTest, statusItem == nil else { return }
        guard let cfg = Self.loadMonitorConfig(), !cfg.gauges.isEmpty else { return }
        activeConfig = cfg

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateDisplay()

        Task {
            await refreshQuota()
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshQuota()
            }
        }
    }

    private nonisolated static func loadMonitorConfig() -> MonitorConfig? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configUrl = home.appending(path: ".config/aerospace/quota_monitors.json")
        guard let data = try? Data(contentsOf: configUrl) else { return nil }
        return try? JSONDecoder().decode(MonitorConfig.self, from: data)
    }

    @objc private func handleRefreshNow() {
        Task { @MainActor in
            if let reloaded = Self.loadMonitorConfig(), !reloaded.gauges.isEmpty {
                activeConfig = reloaded
            }
            await refreshQuota(forceTokenRefresh: false)
        }
    }

    @objc private func handleToggleShowPercent() {
        showPercentBeneath.toggle()
    }

    private func updateDisplay() {
        guard let item = statusItem, let button = item.button, let cfg = activeConfig else { return }

        let showPct = showPercentBeneath
        let columns: [(prefix: String, fraction: Double?)] = cfg.gauges.map { g in
            (g.prefix, statesById[g.id]?.remainingFraction)
        }

        let image = Self.renderStatusBarImage(
            columns: columns,
            showPercentBeneath: showPct
        )
        image.isTemplate = false
        button.image = image
        button.title = ""

        var tooltipLines: [String] = []
        for g in cfg.gauges {
            if let state = statesById[g.id] {
                let pct = Int((state.remainingFraction * 100.0).rounded())
                tooltipLines.append("\(g.title): \(pct)% remaining")
                if let desc = state.description, !desc.isEmpty {
                    tooltipLines.append("  \(desc)")
                }
            } else {
                tooltipLines.append("\(g.title): Loading...")
            }
        }

        if let err = lastError, statesById.isEmpty {
            tooltipLines.append("Error: \(err)")
        }
        button.toolTip = tooltipLines.joined(separator: "\n")

        item.menu = buildMenu(config: cfg)
    }

    private func buildMenu(config: MonitorConfig) -> NSMenu {
        let menu = NSMenu()

        for (index, g) in config.gauges.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            appendQuotaSection(
                to: menu,
                title: g.title,
                state: statesById[g.id]
            )
        }

        if let err = lastError, statesById.isEmpty {
            menu.addItem(.separator())
            let errItem = NSMenuItem(title: "Status: \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        }

        menu.addItem(.separator())

        let togglePctItem = NSMenuItem(
            title: "Show Percentage Beneath Dial",
            action: #selector(handleToggleShowPercent),
            keyEquivalent: ""
        )
        togglePctItem.target = self
        togglePctItem.state = showPercentBeneath ? .on : .off
        menu.addItem(togglePctItem)

        let refreshItem = NSMenuItem(
            title: "Refresh Quota Now",
            action: #selector(handleRefreshNow),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        return menu
    }

    private func appendQuotaSection(to menu: NSMenu, title: String, state: GaugeQuotaState?) {
        let headerTitle: String
        if let state {
            let pct = Int((state.remainingFraction * 100.0).rounded())
            headerTitle = "\(title): \(pct)% remaining"
        } else {
            headerTitle = "\(title): Loading..."
        }
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if let desc = state?.description, !desc.isEmpty {
            let descItem = NSMenuItem(title: desc, action: nil, keyEquivalent: "")
            descItem.isEnabled = false
            menu.addItem(descItem)
        }

        if let resetISO = state?.resetTimeISO, let resetDate = Self.parseISO8601(resetISO) {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let resetItem = NSMenuItem(title: "Resets at \(formatter.string(from: resetDate))", action: nil, keyEquivalent: "")
            resetItem.isEnabled = false
            menu.addItem(resetItem)
        }
    }

    private static func quotaColor(for fraction: Double?) -> NSColor {
        guard let fraction else {
            return NSColor.black.withAlphaComponent(0.55)
        }
        if fraction < 0.20 {
            return NSColor(srgbRed: 0.92, green: 0.18, blue: 0.18, alpha: 1.0) // Red (< 20%)
        } else if fraction < 0.50 {
            return NSColor(srgbRed: 0.88, green: 0.62, blue: 0.0, alpha: 1.0) // Yellow (20% - 49%)
        } else {
            return NSColor.black // Black (50% - 100%)
        }
    }

    private static func renderStatusBarImage(
        columns: [(prefix: String, fraction: Double?)],
        showPercentBeneath: Bool
    ) -> NSImage {
        let count = max(1, columns.count)
        let colWidth: CGFloat = showPercentBeneath ? 35.0 : 20.0
        let gap: CGFloat = 2.0
        let widthPt: CGFloat = colWidth * CGFloat(count) + gap * CGFloat(max(0, count - 1))
        let heightPt: CGFloat = 22.0
        let scale: CGFloat = 2.0
        let pxW = Int(widthPt * scale)
        let pxH = Int(heightPt * scale)

        guard let rep = unsafe NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: widthPt, height: heightPt))
        }
        rep.size = NSSize(width: widthPt, height: heightPt)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx

            for (idx, col) in columns.enumerated() {
                let xOffset = CGFloat(idx) * (colWidth + gap)
                let cx = xOffset + colWidth / 2.0
                let color = quotaColor(for: col.fraction)
                let dialFraction = col.fraction ?? 1.0

                drawSpeedometerDial(
                    cx: cx,
                    cy: 14.2,
                    r: 5.3,
                    strokeWidth: 1.3,
                    fraction: dialFraction,
                    color: color
                )

                let labelText: NSString
                if showPercentBeneath {
                    if let frac = col.fraction {
                        let pct = Int((max(0.0, min(1.0, frac)) * 100.0).rounded())
                        labelText = (col.prefix.isEmpty ? "\(pct)%" : "\(col.prefix) \(pct)%") as NSString
                    } else {
                        labelText = (col.prefix.isEmpty ? "--%" : "\(col.prefix) --%") as NSString
                    }
                } else {
                    labelText = col.prefix as NSString
                }

                if labelText.length > 0 {
                    let font = NSFont.monospacedDigitSystemFont(ofSize: 8.0, weight: .semibold)
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: style,
                    ]
                    labelText.draw(
                        in: NSRect(x: xOffset, y: -0.5, width: colWidth, height: 10.2),
                        withAttributes: attrs
                    )
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: widthPt, height: heightPt))
        image.addRepresentation(rep)
        return image
    }

    private static func drawSpeedometerDial(
        cx: CGFloat,
        cy: CGFloat,
        r: CGFloat,
        strokeWidth: CGFloat,
        fraction: Double,
        color: NSColor
    ) {
        color.setStroke()
        color.setFill()

        let startDeg: CGFloat = 212.0
        let endDeg: CGFloat = -32.0
        let startRad = startDeg * .pi / 180.0
        let startPt = NSPoint(x: cx + r * cos(startRad), y: cy + r * sin(startRad))

        let housing = NSBezierPath()
        housing.move(to: startPt)
        housing.appendArc(
            withCenter: NSPoint(x: cx, y: cy),
            radius: r,
            startAngle: startDeg,
            endAngle: endDeg,
            clockwise: true
        )
        housing.line(to: startPt)
        housing.lineWidth = strokeWidth
        housing.lineCapStyle = .round
        housing.lineJoinStyle = .round
        housing.stroke()

        let clamped = CGFloat(max(0.0, min(1.0, fraction)))
        let angleDeg: CGFloat = 142.0 - clamped * 104.0
        let angleRad = angleDeg * .pi / 180.0
        let perpRad = angleRad + .pi / 2.0

        let bulbR = strokeWidth * 0.98
        let tipLen = r * 0.72
        let tipR = strokeWidth * 0.34

        let tipX = cx + cos(angleRad) * tipLen
        let tipY = cy + sin(angleRad) * tipLen

        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: cx + cos(perpRad) * bulbR, y: cy + sin(perpRad) * bulbR))
        needle.appendArc(
            withCenter: NSPoint(x: cx, y: cy),
            radius: bulbR,
            startAngle: angleDeg + 90.0,
            endAngle: angleDeg + 270.0,
            clockwise: false
        )
        needle.line(to: NSPoint(x: tipX - cos(perpRad) * tipR, y: tipY - sin(perpRad) * tipR))
        needle.appendArc(
            withCenter: NSPoint(x: tipX, y: tipY),
            radius: tipR,
            startAngle: angleDeg - 90.0,
            endAngle: angleDeg + 90.0,
            clockwise: false
        )
        needle.close()
        needle.fill()
    }

    private func refreshQuota(forceTokenRefresh: Bool = false) async {
        if let reloaded = Self.loadMonitorConfig(), !reloaded.gauges.isEmpty {
            activeConfig = reloaded
        }
        guard let config = activeConfig else { return }

        do {
            let accessToken = try await getValidAccessToken(config: config, forceRefresh: forceTokenRefresh)
            let fetched = try await Self.fetchQuotaStates(config: config, accessToken: accessToken)
            if !fetched.isEmpty {
                for (k, v) in fetched {
                    statesById[k] = v
                }
                lastUpdated = Date()
                lastError = nil
                updateDisplay()
            }
        } catch {
            if !forceTokenRefresh {
                do {
                    let accessToken = try await getValidAccessToken(config: config, forceRefresh: true)
                    let fetched = try await Self.fetchQuotaStates(config: config, accessToken: accessToken)
                    if !fetched.isEmpty {
                        for (k, v) in fetched {
                            statesById[k] = v
                        }
                        lastUpdated = Date()
                        lastError = nil
                        updateDisplay()
                        return
                    }
                } catch {
                    lastError = error.localizedDescription
                    updateDisplay()
                }
            } else {
                lastError = error.localizedDescription
                updateDisplay()
            }
        }
    }

    private func getValidAccessToken(config: MonitorConfig, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let token = cachedAccessToken, Date() < cachedAccessTokenExpiry {
            return token
        }
        let refreshed = try await Self.fetchFreshAccessToken(config: config)
        cachedAccessToken = refreshed.accessToken
        cachedAccessTokenExpiry = Date().addingTimeInterval(max(60.0, refreshed.expiresIn - 300.0))
        return refreshed.accessToken
    }

    private struct TokenRefreshResult: Sendable {
        let accessToken: String
        let expiresIn: TimeInterval
    }

    private nonisolated static func expandTilde(_ path: String) -> URL {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: String(path.dropFirst(2)))
        }
        return URL(filePath: path)
    }

    private nonisolated static func loadRefreshTokenFromDisk(config: MonitorConfig) throws -> String {
        for rawPath in config.token_files {
            let url = expandTilde(rawPath)
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let tokenObj = root["token"] as? [String: Any],
               let refresh = tokenObj["refresh_token"] as? String,
               !refresh.isEmpty
            {
                return refresh
            }
            if let refresh = root["refresh_token"] as? String, !refresh.isEmpty {
                return refresh
            }
        }
        throw NSError(domain: "QuotaStatusBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "No OAuth refresh token found"])
    }

    private nonisolated static func fetchFreshAccessToken(config: MonitorConfig) async throws -> TokenRefreshResult {
        let refreshToken = try loadRefreshTokenFromDisk(config: config)
        guard let tokenUrl = URL(string: config.oauth_token_url) else {
            throw NSError(domain: "QuotaStatusBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid oauth_token_url"])
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.client_id),
            URLQueryItem(name: "client_secret", value: config.client_secret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        let bodyString = components.percentEncodedQuery ?? ""

        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)
        request.timeoutInterval = 10.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw NSError(domain: "QuotaStatusBar", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to refresh OAuth token"])
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600.0
        return TokenRefreshResult(accessToken: accessToken, expiresIn: expiresIn)
    }

    private nonisolated static func fetchQuotaStates(
        config: MonitorConfig,
        accessToken: String
    ) async throws -> [String: GaugeQuotaState] {
        var combined: [String: GaugeQuotaState] = [:]

        if let summaryUrlStr = config.summary_url,
           let summaryUrl = URL(string: summaryUrlStr),
           let fromSummary = try? await fetchFromSummaryEndpoint(
               url: summaryUrl,
               config: config,
               accessToken: accessToken
           )
        {
            for (k, v) in fromSummary {
                combined[k] = v
            }
        }

        if combined.count < config.gauges.count,
           let modelsUrlStr = config.models_url,
           let modelsUrl = URL(string: modelsUrlStr),
           let fromModels = try? await fetchFromModelsEndpoint(
               url: modelsUrl,
               config: config,
               accessToken: accessToken
           )
        {
            for (k, v) in fromModels where combined[k] == nil {
                combined[k] = v
            }
        }

        return combined
    }

    private nonisolated static func fetchFromSummaryEndpoint(
        url: URL,
        config: MonitorConfig,
        accessToken: String
    ) async throws -> [String: GaugeQuotaState]? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ua = config.user_agent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = Data((config.request_body ?? "{}").utf8)
        request.timeoutInterval = 10.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]]
        else {
            return nil
        }

        var results: [String: GaugeQuotaState] = [:]

        for group in groups {
            let groupDesc = (group["description"] as? String) ?? ""
            let groupName = (group["displayName"] as? String) ?? ""
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }

            for bucket in buckets {
                let bucketId = (bucket["bucketId"] as? String) ?? ""
                let frac = (bucket["remainingFraction"] as? Double) ??
                    ((bucket["remainingFraction"] as? NSNumber)?.doubleValue) ??
                    ((bucket["disabled"] as? Bool == true) ? 0.0 : 1.0)
                let desc = bucket["description"] as? String
                let reset = bucket["resetTime"] as? String
                let state = GaugeQuotaState(remainingFraction: frac, description: desc, resetTimeISO: reset)

                for gauge in config.gauges where results[gauge.id] == nil {
                    let matchesBucket = (gauge.bucket_ids ?? []).contains(bucketId)
                    let matchesKeyword = (gauge.group_keywords ?? []).contains { kw in
                        groupDesc.localizedCaseInsensitiveContains(kw) ||
                            groupName.localizedCaseInsensitiveContains(kw)
                    }
                    if matchesBucket || matchesKeyword {
                        results[gauge.id] = state
                    }
                }
            }
        }

        return results
    }

    private nonisolated static func fetchFromModelsEndpoint(
        url: URL,
        config: MonitorConfig,
        accessToken: String
    ) async throws -> [String: GaugeQuotaState] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ua = config.user_agent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = Data((config.request_body ?? "{}").utf8)
        request.timeoutInterval = 10.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: [String: Any]]
        else {
            return [:]
        }

        var results: [String: GaugeQuotaState] = [:]

        for (modelId, details) in models {
            let displayName = (details["displayName"] as? String) ?? ""
            guard let quotaInfo = details["quotaInfo"] as? [String: Any] else { continue }
            let frac = (quotaInfo["remainingFraction"] as? Double) ??
                ((quotaInfo["remainingFraction"] as? NSNumber)?.doubleValue) ?? 0.0
            let reset = quotaInfo["resetTime"] as? String
            let state = GaugeQuotaState(remainingFraction: frac, description: nil, resetTimeISO: reset)

            for gauge in config.gauges where results[gauge.id] == nil {
                let matchesModel = (gauge.model_keywords ?? []).contains { kw in
                    displayName.localizedCaseInsensitiveContains(kw) ||
                        modelId.localizedCaseInsensitiveContains(kw)
                }
                if matchesModel {
                    results[gauge.id] = state
                }
            }
        }

        return results
    }

    private static func parseISO8601(_ str: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }
}
