// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import MachO
import MetricKit
import os

/// Reports to the feedback server: what the user writes in Send Feedback, and,
/// once error reports are on, the error log hourly and MetricKit's crash
/// diagnostics. A report the server can't take yet waits in an outbox.
nonisolated enum Reports {
    private static let endpoint = URL(string: "https://feedback.artemisbrowser.app/v1/reports")!
    static let enabledKey = "sendsErrorReports"
    /// what turning automatic reports on agrees to, wherever it can be turned on
    static let disclosure =
        "Sends errors and crash reports with your Mac model, installed extensions and Artemis and macOS versions. Never your pages or browsing."
    static let emailKey = "feedbackEmail"
    fileprivate static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private static let outbox = AppStorageLocation.file("Outbox")
    static let outboxCap = 10
    /// one flush at a time: a second would post the files the first is still sending
    private static let isFlushing = OSAllocatedUnfairLock(initialState: false)
    /// diagnostics MetricKit delivered while reports were off, until sent or declined
    fileprivate static let pendingCrashes = AppStorageLocation.file("Crashes")
    private static let maxBody = 4_000_000
    private static let expendableSuffix = "-expendable.json"

    private static let installKey = "reportInstallID"
    private static let backoffKey = "reportBackoffUntil"
    private static let reportedThroughKey = "reportErrorsThrough"
    private static let session = URLSession(configuration: .ephemeral)

    static let request: URLRequest = {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }()

    /// `issue`: the public GitHub issue a feedback report became, when it became one
    enum Outcome: Equatable { case sent(issue: URL?), queued, rejected }

    // MARK: - The report

    static func body(
        kind: String, feedback: [String: any Sendable]? = nil, diagnostics: [String: any Sendable]? = nil,
        events: [Diagnostics.Event] = [], crashes: [Data] = [], attachments: [[String: String]] = []
    ) -> Data? {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let patch = os.patchVersion > 0 ? ".\(os.patchVersion)" : ""
        var report: [String: Any] = [
            "kind": kind,
            "install": installID,
            "app": [
                "version": info["CFBundleShortVersionString"] as? String ?? "",
                "build": build,
                "channel": Updates.buildChannel,
                "commit": Updates.buildCommit,
            ].compactMapValues { $0 },
            "os": "macOS \(os.majorVersion).\(os.minorVersion)\(patch) (\(sysctl("kern.osversion")))",
            "model": sysctl("hw.model"),
            "arch": sysctl("hw.machine"),
        ]
        if let feedback { report["feedback"] = feedback }
        if let diagnostics { report["diagnostics"] = diagnostics }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if !events.isEmpty, let encoded = try? encoder.encode(events) {
            report["events"] = try? JSONSerialization.jsonObject(with: encoded)
        }
        if !crashes.isEmpty { report["crashes"] = crashes.compactMap { try? JSONSerialization.jsonObject(with: $0) } }
        if !attachments.isEmpty { report["attachments"] = attachments }
        guard let data = try? JSONSerialization.data(withJSONObject: report), data.count <= maxBody
        else { return nil }
        return data
    }

    /// the start of this code's LC_UUID, which every build changes and which
    /// begins the name of the build's kept dSYM folder
    private static let build: String = {
        let header = #dsohandle
        var command = header + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.load(as: mach_header_64.self).ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                return String(UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString.prefix(13))
            }
            command += Int(load.cmdsize)
        }
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }()

    /// random, made the first time a report is built
    private static var installID: String {
        if let id = UserDefaults.standard.string(forKey: installKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: installKey)
        return id
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &value, &size, nil, 0)
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// what a UI bug needs to be reproduced, and nothing about who or what is browsing
    @MainActor static func snapshot(of manager: TabManager? = nil) -> [String: any Sendable] {
        let core = BrowserCore.shared
        let manager = manager ?? BrowserWindows.shared.current
        let appearance = manager?.currentSpace.appearance
        let workspace = NSWorkspace.shared
        return [
            "windows": BrowserWindows.shared.allManagers.count,
            "spaces": core.spaces.count,
            "tabs": core.spaces.reduce(0) { $0 + $1.tabs.count },
            "profiles": core.profiles.count,
            "extensions": ExtensionManager.shared.installed.map { ["name": $0.name, "version": $0.version ?? ""] },
            "extensionsOn": ExtensionManager.shared.isMasterEnabled,
            "blocker": ContentBlocker.shared.isEnabled,
            "sidebarCollapsed": manager?.isSidebarCollapsed ?? false,
            "toolbar": BrowserToolbar.isShown,
            "edgeInset": WindowChrome.edgeInset,
            "spaceFill": appearance?.fill.rawValue ?? "",
            "backgroundFrost": appearance?.backgroundFrost ?? 0,
            "sidebarFrost": appearance?.sidebarFrost ?? 0,
            "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
            "reduceMotion": workspace.accessibilityDisplayShouldReduceMotion,
            "dark": NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
        ]
    }

    // MARK: - Sending

    /// posts `body`, or keeps it in the outbox when the server can't take it now.
    /// An automatic report waits out a backoff, goes first when the outbox is
    /// full, and is dropped from it once reports are off
    @concurrent static func deliver(_ body: Data, automatic: Bool) async -> Outcome {
        let outcome = await post(body, heedingBackoff: automatic)
        switch outcome {
        case .sent: Task { await flushOutbox() }
        case .queued: enqueue(body, in: outbox, cap: outboxCap, expendable: automatic)
        case .rejected: break
        }
        return outcome
    }

    @concurrent private static func post(_ body: Data, heedingBackoff: Bool = true) async -> Outcome {
        let backoff = UserDefaults.standard.object(forKey: backoffKey) as? Date ?? .distantPast
        guard !heedingBackoff || Date.now >= backoff,
            let (data, response) = try? await session.upload(for: request, from: body),
            let response = response as? HTTPURLResponse
        else { return .queued }
        switch response.statusCode {
        case 200..<300:
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .sent(issue: (reply?["issue"] as? String).flatMap(URL.init(string:)))
        case 429:
            let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 3600
            UserDefaults.standard.set(Date.now + wait, forKey: backoffKey)
            return .queued
        case 400..<500:
            return .rejected
        default:
            return .queued
        }
    }

    @concurrent private static func flushOutbox() async {
        let claimed = isFlushing.withLock { busy in
            defer { busy = true }
            return !busy
        }
        guard claimed else { return }
        defer { isFlushing.withLock { $0 = false } }
        for file in queued(in: outbox) {
            if isExpendable(file), !isEnabled {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let body = try? Data(contentsOf: file) else { continue }
            if await post(body) == .queued { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// writes `data` into `folder`; past `cap` the oldest expendable files go
    /// first, then the oldest of the rest
    static func enqueue(_ data: Data, in folder: URL, cap: Int, expendable: Bool = false) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(Int(Date.now.timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        try? data.write(
            to: folder.appendingPathComponent(name + (expendable ? expendableSuffix : ".json")), options: .atomic)
        let files = queued(in: folder)
        let byPriority = files.filter(isExpendable) + files.filter { !isExpendable($0) }
        for stale in byPriority.prefix(max(0, files.count - cap)) { try? fm.removeItem(at: stale) }
    }

    private static func isExpendable(_ file: URL) -> Bool {
        file.lastPathComponent.hasSuffix(expendableSuffix)
    }

    /// oldest first
    static func queued(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Automatic

    /// subscribes to MetricKit, then from 30 s in, hourly retries the outbox and,
    /// while reports are on, sends crashes and the errors logged since last time
    @concurrent static func run() async {
        MXMetricManager.shared.add(CrashCatcher.shared)
        try? await Task.sleep(for: .seconds(30))
        while !Task.isCancelled {
            await flushOutbox()
            if isEnabled {
                await sendCrashes(automatic: true)
                await sendErrors()
            }
            try? await Task.sleep(for: .seconds(3600), tolerance: .seconds(300))
        }
    }

    @concurrent private static func sendErrors() async {
        let since = UserDefaults.standard.object(forKey: reportedThroughKey) as? Date ?? .distantPast
        let now = Date.now
        // the server takes at most 100 events a report
        let events = Diagnostics.events(after: since).suffix(100)
        guard now.timeIntervalSince(since) >= 3600, !events.isEmpty else { return }
        let diagnostics = await snapshot()
        guard let body = body(kind: "errors", diagnostics: diagnostics, events: Array(events)) else { return }
        _ = await deliver(body, automatic: true)
        UserDefaults.standard.set(now, forKey: reportedThroughKey)
    }

    /// every pending diagnostic, in as few reports as fit the size cap; one too
    /// big to send even alone is dropped
    @concurrent fileprivate static func sendCrashes(automatic: Bool) async {
        var files = queued(in: pendingCrashes)
        guard !files.isEmpty else { return }
        let diagnostics = await snapshot()
        let events = Array(Diagnostics.events(after: .distantPast).suffix(50))
        func report(_ batch: ArraySlice<URL>) -> Data? {
            Self.body(
                kind: "crash", diagnostics: diagnostics, events: events,
                crashes: batch.compactMap { try? Data(contentsOf: $0) })
        }
        while !files.isEmpty {
            var count = files.count
            var next = report(files.prefix(count))
            while next == nil, count > 1 {
                count -= 1
                next = report(files.prefix(count))
            }
            for file in files.prefix(count) { try? FileManager.default.removeItem(at: file) }
            files.removeFirst(count)
            if let next { _ = await deliver(next, automatic: automatic) }
        }
    }

    @MainActor private static var isAsking = false

    /// the one thing reports ever pop up, and only after a crash while they are off
    @MainActor fileprivate static func askAboutCrash() {
        guard !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        let alert = NSAlert()
        alert.messageText = "Artemis quit unexpectedly"
        alert.informativeText = "Send a report to help fix it?\n\n\(disclosure)"
        // no default button: Return sends nothing, only a click does
        alert.addButton(withTitle: "Send").keyEquivalent = ""
        alert.addButton(withTitle: "Always Send")
        alert.addButton(withTitle: "Don’t Send").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await sendCrashes(automatic: false) }
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(true, forKey: enabledKey)
            Task { await sendCrashes(automatic: false) }
        default:
            for file in queued(in: pendingCrashes) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// one MetricKit diagnostic as a report's crash entry, redacted like the log
    fileprivate static func crashEntry(_ diagnostic: MXDiagnostic) -> Data? {
        let summary =
            switch diagnostic {
            case let crash as MXCrashDiagnostic:
                "crash: exception \(crash.exceptionType?.stringValue ?? "?") signal \(crash.signal?.stringValue ?? "?")"
            case let hang as MXHangDiagnostic: "hang: \(hang.hangDuration.formatted())"
            case let cpu as MXCPUExceptionDiagnostic: "cpu exception: \(cpu.totalCPUTime.formatted())"
            case let disk as MXDiskWriteExceptionDiagnostic: "disk writes: \(disk.totalWritesCaused.formatted())"
            default: "diagnostic"
            }
        guard let raw = try? JSONSerialization.jsonObject(with: diagnostic.jsonRepresentation()),
            let text = try? JSONSerialization.data(withJSONObject: raw, options: .withoutEscapingSlashes),
            // the server refuses a payload over 1 MiB
            text.count <= 1_000_000,
            let payload = try? JSONSerialization.jsonObject(
                with: Data(Diagnostics.redact(String(decoding: text, as: UTF8.self)).utf8))
        else { return nil }
        // a hang's duration and an exception's totals vary between occurrences
        let kind = diagnostic is MXCrashDiagnostic ? summary : String(summary.prefix { $0 != ":" })
        let sig = Diagnostics.hash(([kind] + innermostFrames(payload)).joined(separator: "|"))
        return try? JSONSerialization.data(withJSONObject: ["sig": sig, "summary": summary, "payload": payload])
    }

    /// the attributed thread's innermost frames, which group one crash across
    /// reports and builds: eight outside Artemis as binary+offset, and each run
    /// of Artemis's own, which every build moves, as its bare name
    static func innermostFrames(_ payload: Any) -> [String] {
        let tree = (payload as? [String: Any])?["callStackTree"] as? [String: Any]
        let stacks = tree?["callStacks"] as? [[String: Any]] ?? []
        let thread = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        let app = ProcessInfo.processInfo.processName
        var frame = (thread?["callStackRootFrames"] as? [[String: Any]])?.first
        var out: [String] = []
        while let current = frame, out.count(where: { $0 != app }) < 8 {
            let binary = current["binaryName"] as? String ?? "?"
            if !binary.hasPrefix(app) {
                out.append("\(binary)+\(current["offsetIntoBinaryTextSegment"] ?? 0)")
            } else if out.last != app {
                out.append(app)
            }
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return out
    }
}

/// MetricKit hands over the previous runs' crashes, hangs and CPU and disk-write
/// exceptions, on a queue of its own
nonisolated final class CrashCatcher: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashCatcher()

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes: [MXDiagnostic] = payloads.flatMap { $0.crashDiagnostics ?? [] }
        let others: [MXDiagnostic] = payloads.flatMap {
            ($0.hangDiagnostics ?? []) as [MXDiagnostic] + ($0.cpuExceptionDiagnostics ?? [])
                + ($0.diskWriteExceptionDiagnostics ?? [])
        }
        for diagnostic in crashes + others {
            guard let entry = Reports.crashEntry(diagnostic) else { continue }
            Reports.enqueue(
                entry, in: Reports.pendingCrashes, cap: 5, expendable: !(diagnostic is MXCrashDiagnostic))
        }
        if Reports.isEnabled {
            Task { await Reports.sendCrashes(automatic: true) }
        } else if !crashes.isEmpty {
            // once the launch's first window is up
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                Reports.askAboutCrash()
            }
        }
    }
}
