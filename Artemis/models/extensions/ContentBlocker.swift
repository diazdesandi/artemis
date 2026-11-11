// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CryptoKit
import WebKit

/// one subscribable filter list
struct Blocklist: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let url: URL
    let onByDefault: Bool
    /// how long a downloaded copy stays current, from the lists' `Expires:` header
    var maxAge: TimeInterval = 4 * 86_400

    fileprivate var enabledKey: String { "blocklist.\(id).enabled" }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? onByDefault
    }
}

/// native content blocking via `WKContentRuleListStore`, from EasyList-format lists converted by
/// `AdblockConverter`. a chunk's identifier embeds a hash of its JSON, so an unchanged chunk is
/// looked up in WebKit's on-disk store instead of compiled again
@Observable
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    static let catalog: [Blocklist] = [
        Blocklist(
            id: "easylist", name: "EasyList",
            detail: "The primary ad-blocking list.",
            url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
            onByDefault: true),
        Blocklist(
            id: "easyprivacy", name: "EasyPrivacy",
            detail: "Trackers, analytics and beacons.",
            url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            onByDefault: true),
        Blocklist(
            id: "annoyances", name: "Cookie Notices",
            detail: "Cookie banners and consent walls.",
            url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!,
            onByDefault: false),
        Blocklist(
            id: "social", name: "Social Widgets",
            detail: "Embedded share buttons and social trackers.",
            url: URL(string: "https://easylist.to/easylist/fanboy-social.txt")!,
            onByDefault: false),
    ]

    static let enabledKey = "contentBlockingEnabledV1"
    private static let lastUpdateKey = "contentBlockingLastUpdate"
    /// identifiers of the compiled chunks in WebKit's store, and their rule counts, which launch
    /// installs without converting the lists again
    private static let compiledIdentifiersKey = "contentBlockingCompiledIDs"
    private static let compiledStatsKey = "contentBlockingCompiledStats"
    /// fingerprint of the `siteFixes` the compiled chunks were built with; a mismatch forces a rebuild
    private static let compiledFixesKey = "contentBlockingCompiledFixes"
    private static let fixesFingerprint: String = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest(String(data: (try? encoder.encode(siteFixes)) ?? Data(), encoding: .utf8) ?? "")
    }()
    /// how often a running app looks for lists past their `maxAge`
    private static let refreshCheck: Duration = .seconds(3600)

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { Task { await apply() } } else { uninstall() }
        }
    }

    /// live status for Settings: rule count, when the lists were fetched, and
    /// how many filters the converter couldn't express
    private(set) var ruleCount = 0
    private(set) var droppedCount = 0
    private(set) var lastUpdated: Date?
    private(set) var isUpdating = false
    private(set) var lastError: String?

    @ObservationIgnored private var installed: [WKContentRuleList] = []
    /// serializes every install: an overlapping `apply()` and `updateLists` could each prune
    /// the chunks the other recorded as compiled
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private let cacheDirectory = AppStorageLocation.directory
        .appendingPathComponent("blocklists", isDirectory: true)

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        lastUpdated = UserDefaults.standard.object(forKey: Self.lastUpdateKey) as? Date
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        // a profile's controller made after the lists went in gets the live ones
        SharedWebContent.everywhere { [weak self] ucc in
            guard let self, self.isEnabled else { return }
            for list in self.installed { ucc.add(list) }
        }
    }

    /// one-line summary under the Settings toggle
    var statusLine: String {
        if let lastError { return "Couldn't update: \(lastError)" }
        guard isEnabled else { return "Blocking is off — pages load with their ads and trackers." }
        guard !enabledLists.isEmpty else { return "No lists selected." }
        guard ruleCount > 0 else { return "Preparing blocklists…" }
        let updated = lastUpdated.map {
            $0.formatted(date: .abbreviated, time: .omitted)
        } ?? "never"
        let dropped = droppedCount > 0 ? ", \(droppedCount.formatted()) unsupported filters skipped" : ""
        return "\(ruleCount.formatted()) rules active — updated \(updated)\(dropped)."
    }

    private var enabledLists: [Blocklist] { Self.catalog.filter(\.isEnabled) }

    func setList(_ list: Blocklist, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: list.enabledKey)
        // the compiled set no longer matches the subscription, so launch must not reuse it
        UserDefaults.standard.removeObject(forKey: Self.compiledIdentifiersKey)
        Task { await updateLists(force: true) }
    }

    // MARK: - Applying

    /// returns once nothing is compiling or installing, including the launch rebuild, which
    /// `isUpdating` doesn't cover
    func waitForIdle() async {
        await work?.value
    }

    /// run `body` after any install already in flight has finished
    private func serialized(_ body: @escaping @MainActor () async -> Void) async {
        let previous = work
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        work = task
        await task.value
    }

    /// hosts the privacy list blocks, so a blocked request can be reported as a
    /// tracker; anything else blocked counts as an ad
    @ObservationIgnored private var trackerHosts: Set<String> = []
    private var trackerHostsCache: URL {
        cacheDirectory.appendingPathComponent("trackerhosts.txt")
    }

    /// does the privacy list recognise this request's host, or a parent of it?
    /// `requestDomains` semantics: a rule for example.com also covers a.example.com
    func isTracker(_ url: URL) -> Bool {
        guard !trackerHosts.isEmpty, var host = url.host()?.lowercased() else { return false }
        while host.contains(".") {
            if trackerHosts.contains(host) { return true }
            guard let dot = host.firstIndex(of: ".") else { return false }
            host = String(host[host.index(after: dot)...])
        }
        return false
    }

    private func rememberTrackerHosts(from source: String) async {
        trackerHosts = await Self.parseTrackerHosts(source, savingTo: trackerHostsCache)
    }

    @concurrent nonisolated private static func parseTrackerHosts(
        _ source: String, savingTo file: URL
    ) async -> Set<String> {
        let hosts = AdblockConverter.blockedHosts(in: source)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? hosts.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return hosts
    }

    @concurrent nonisolated private static func readTrackerHosts(_ file: URL) async -> Set<String> {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    /// a rule list reaches a document only when the document loads after it is
    /// installed, so a page that is already open has to run again
    private static func reloadLoadedTabs() {
        guard let manager = ExtensionManager.shared.tabManager else { return }
        for tab in manager.allTabs where !tab.isHibernated && tab.url != nil {
            tab.webView.reload()
        }
    }

    /// install (or remove) the compiled lists on the shared user-content
    /// controller every tab already uses
    func apply() async {
        await serialized { await self.applyLocked() }
    }

    /// at once, ahead of any download or compile in flight, which then records its lists
    /// without adding them
    private func uninstall() {
        guard !installed.isEmpty else { return }
        for ucc in SharedWebContent.all { for list in installed { ucc.remove(list) } }
        installed = []
        Self.reloadLoadedTabs()
    }

    private func applyLocked() async {
        guard isEnabled else { return uninstall() }
        let hadCache = enabledLists.contains {
            (try? cacheURL($0).checkResourceIsReachable()) == true
        }
        if installed.isEmpty {
            await rebuild()
        } else {
            for ucc in SharedWebContent.all { for list in installed { ucc.add(list) } }
        }
        // with cached rules already in, a newer download reaches pages as they
        // next load; with only the starter list in, open pages run again
        await refreshIfStaleLocked(reloadTabs: !hadCache)
        refresher = refresher ?? Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshCheck, tolerance: .seconds(300))
                guard isEnabled else { continue }
                await serialized { await self.refreshIfStaleLocked(reloadTabs: false) }
            }
        }
    }

    /// fetch fresh copies of lists past their `maxAge`, inside the serialized section
    private func refreshIfStaleLocked(reloadTabs: Bool) async {
        guard enabledLists.contains(where: { !isFresh($0) }) else { return }
        await updateListsLocked(force: false, reloadTabs: reloadTabs)
    }

    private func cacheURL(_ list: Blocklist) -> URL {
        cacheDirectory.appendingPathComponent("\(list.id).txt")
    }

    private func isFresh(_ list: Blocklist) -> Bool {
        let modified = try? cacheURL(list).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return modified.map { Date().timeIntervalSince($0) < list.maxAge } ?? false
    }

    /// download every enabled list, convert, compile and install.
    /// `force` re-downloads even when the cache is fresh (the Settings button)
    func updateLists(force: Bool) async {
        await serialized { await self.updateListsLocked(force: force, reloadTabs: true) }
    }

    private func updateListsLocked(force: Bool, reloadTabs: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        lastError = nil
        defer { isUpdating = false }
        guard !enabledLists.isEmpty else { return await removeLists(reloadTabs: reloadTabs) }

        var sources: [String] = []
        var changed = false
        for list in enabledLists {
            if let (text, isNew) = await fetch(list, force: force) {
                sources.append(text)
                changed = changed || isNew
                if list.id == "easyprivacy" { await rememberTrackerHosts(from: text) }
            }
        }
        guard !sources.isEmpty else {
            lastError = lastError ?? "no lists available offline"
            await install(sources: [Self.starterList], stamp: false, reloadTabs: reloadTabs)
            return
        }
        guard force || changed || installed.isEmpty else { return }
        await install(sources: sources, stamp: true, reloadTabs: reloadTabs)
    }

    /// download one list, falling back to (and refreshing) the on-disk cache.
    /// `isNew` when the text differs from what was cached
    private func fetch(_ list: Blocklist, force: Bool) async -> (text: String, isNew: Bool)? {
        let cached = cacheURL(list)
        let previous = try? String(contentsOf: cached, encoding: .utf8)
        if !force, isFresh(list), let previous, !previous.isEmpty {
            return (previous, false)
        }
        do {
            var request = URLRequest(url: list.url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                let text = String(data: data, encoding: .utf8), !text.isEmpty
            else { throw URLError(.badServerResponse) }
            try? text.write(to: cached, atomically: true, encoding: .utf8)
            return (text, text != previous)
        } catch {
            debugLog("blocklist \(list.id) fetch failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return previous.map { ($0, false) }
        }
    }

    /// convert, compile and install, converting off the main actor
    private func install(sources: [String], stamp: Bool, reloadTabs: Bool) async {
        let fixes = Self.siteFixes
        let converted = await Task.detached(priority: reloadTabs ? .userInitiated : .utility) {
            AdblockConverter.convert(sources, extraExceptions: fixes)
        }.value

        var compiled: [WKContentRuleList] = []
        let store = WKContentRuleListStore.default()
        for (index, json) in converted.chunks.enumerated() {
            let identifier = "artemis-block-\(Self.digest(json))-\(index)"
            if let existing = try? await store?.contentRuleList(forIdentifier: identifier) {
                compiled.append(existing)
                continue
            }
            do {
                if let list = try await store?.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: json) {
                    compiled.append(list)
                }
            } catch {
                debugLog("blocklist chunk \(index) failed to compile: \(error.localizedDescription)")
                // WebKit puts the parser's own message in the help anchor; the
                // localized description is only "compile failed"
                let detail = (error as NSError).userInfo[NSHelpAnchorErrorKey] as? String
                let failure = "rule chunk \(index + 1) of \(converted.chunks.count) "
                    + "failed to compile: \(detail ?? error.localizedDescription)"
                lastError = failure
                Diagnostics.record(area: "blocker", message: failure)
            }
        }
        guard !compiled.isEmpty else { return }

        // the same chunks already in: nothing to swap, and no open page has to run again
        if compiled.map(\.identifier) != installed.map(\.identifier) {
            replaceInstalled(with: compiled)
            if reloadTabs, isEnabled { Self.reloadLoadedTabs() }
        }
        ruleCount = converted.ruleCount
        droppedCount = converted.droppedCount
        UserDefaults.standard.set(compiled.map(\.identifier), forKey: Self.compiledIdentifiersKey)
        UserDefaults.standard.set(Self.fixesFingerprint, forKey: Self.compiledFixesKey)
        UserDefaults.standard.set(
            [converted.ruleCount, converted.droppedCount], forKey: Self.compiledStatsKey)
        if stamp, lastError == nil {
            lastUpdated = Date()
            UserDefaults.standard.set(lastUpdated, forKey: Self.lastUpdateKey)
        }
        await pruneStaleCompiledLists(keeping: Set(compiled.map(\.identifier)))
        debugLog("blocklists installed: \(compiled.count) chunks, \(converted.ruleCount) rules")
    }

    /// build from the cached lists without the network, reusing the last build's bytecode
    /// while it is still current
    private func rebuild() async {
        guard !enabledLists.isEmpty else { return await removeLists(reloadTabs: false) }
        if await installPreviouslyCompiled() { return }

        var sources: [String] = []
        for list in enabledLists {
            if let text = try? String(contentsOf: cacheURL(list), encoding: .utf8), !text.isEmpty {
                sources.append(text)
                if list.id == "easyprivacy" { await rememberTrackerHosts(from: text) }
            }
        }
        await install(
            sources: sources.isEmpty ? [Self.starterList] : sources, stamp: false, reloadTabs: true)
    }

    /// look the last build's chunks up by identifier and install them as-is.
    /// false if any is missing, in which case the caller rebuilds from source
    @discardableResult
    func installPreviouslyCompiled() async -> Bool {
        let defaults = UserDefaults.standard
        guard let identifiers = defaults.array(forKey: Self.compiledIdentifiersKey) as? [String],
            !identifiers.isEmpty, let store = WKContentRuleListStore.default(),
            defaults.string(forKey: Self.compiledFixesKey) == Self.fixesFingerprint
        else { return false }

        var lists: [WKContentRuleList] = []
        for identifier in identifiers {
            guard let list = try? await store.contentRuleList(forIdentifier: identifier)
            else { return false }
            lists.append(list)
        }

        replaceInstalled(with: lists)
        if let stats = defaults.array(forKey: Self.compiledStatsKey) as? [Int], stats.count == 2 {
            ruleCount = stats[0]
            droppedCount = stats[1]
        }
        if trackerHosts.isEmpty { trackerHosts = await Self.readTrackerHosts(trackerHostsCache) }
        debugLog("blocklists: reused \(lists.count) already-compiled chunks")
        return true
    }

    /// no list subscribed: nothing blocks, not even the starter list
    private func removeLists(reloadTabs: Bool) async {
        let hadLists = !installed.isEmpty
        replaceInstalled(with: [])
        if hadLists, reloadTabs, isEnabled { Self.reloadLoadedTabs() }
        ruleCount = 0
        droppedCount = 0
        UserDefaults.standard.removeObject(forKey: Self.compiledIdentifiersKey)
        UserDefaults.standard.removeObject(forKey: Self.compiledStatsKey)
        await pruneStaleCompiledLists(keeping: [])
    }

    private func replaceInstalled(with lists: [WKContentRuleList]) {
        for ucc in SharedWebContent.all {
            for list in installed { ucc.remove(list) }
            if isEnabled { for list in lists { ucc.add(list) } }
        }
        installed = lists
    }

    /// every compile stores a new blob under its content hash, so the superseded ones are removed
    private func pruneStaleCompiledLists(keeping identifiers: Set<String>) async {
        guard let store = WKContentRuleListStore.default() else { return }
        let existing = (try? await store.availableIdentifiers()) ?? []
        for identifier in existing
        where identifier.hasPrefix("artemis-block") && !identifiers.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    private static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: - Artemis' own site fixes

    /// exceptions appended after every converted list. Prime Video's player aborts ("Video
    /// Unavailable") while `amazon-adsystem.com` is blocked on Amazon pages, and YouTube's tears
    /// its stream down while `/api/stats/qoe` is blocked
    static let siteFixes: [ContentRule] = {
        let amazonHosts = [
            "*amazon.co.uk", "*amazon.com", "*amazon.de", "*amazon.fr", "*amazon.es",
            "*amazon.it", "*amazon.ca", "*amazon.co.jp", "*primevideo.com",
        ]
        return [
            ContentRule(
                trigger: .init(
                    urlFilter: "^https?://([^/]+\\.)?amazon-adsystem\\.com",
                    ifDomain: amazonHosts),
                action: .init(type: "ignore-previous-rules")),
            ContentRule(
                trigger: .init(
                    urlFilter: "^https?://([^/]+\\.)?youtube\\.com/api/stats/qoe",
                    ifDomain: ["*youtube.com"]),
                action: .init(type: "ignore-previous-rules")),
        ]
    }()

    /// the most prolific ad and tracker domains, installed until a list first downloads
    private static let starterList: String = {
        let domains = [
            "doubleclick.net", "googlesyndication.com", "google-analytics.com",
            "googleadservices.com", "googletagservices.com", "googletagmanager.com",
            "2mdn.net", "adnxs.com", "advertising.com", "adsystem.com",
            "amazon-adsystem.com", "scorecardresearch.com", "moatads.com",
            "rubiconproject.com", "pubmatic.com", "criteo.com", "criteo.net",
            "taboola.com", "outbrain.com", "quantserve.com", "openx.net",
            "casalemedia.com", "adform.net", "bidswitch.net", "hotjar.com",
            "mixpanel.com", "segment.com", "branch.io", "appsflyer.com",
            "doubleverify.com", "yieldmo.com", "sharethrough.com", "smartadserver.com",
            "teads.tv", "zedo.com", "adroll.com", "bluekai.com", "demdex.net", "krxd.net",
        ]
        return domains.map { "||\($0)^$third-party" }.joined(separator: "\n")
    }()
}
