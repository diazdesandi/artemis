// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// one window's browser model: routes the tab API to the current space and
/// persists the session (urls only; web views rebuild lazily)
@Observable
final class TabManager {
    /// state every window shares: spaces, favourites, history, the closed tabs
    @ObservationIgnored let core: BrowserCore

    var spaces: [Space] {
        get { core.spaces }
        set { core.spaces = newValue }
    }

    /// which window this manager drives, and so which chrome it wears
    let kind: WindowKind

    /// one per window: the bubble draws in this window's own panel
    @ObservationIgnored let tooltipState = TooltipState()

    /// this window's sidebar is unlocked (peeks on hover). the last toggle in
    /// any window is what the next window opens with
    var isSidebarCollapsed = UserDefaults.standard.bool(forKey: TabManager.sidebarCollapsedKey) {
        didSet { UserDefaults.standard.set(isSidebarCollapsed, forKey: Self.sidebarCollapsedKey) }
    }
    private static let sidebarCollapsedKey = "isSidebarCollapsed"

    var selectedSpaceID: Space.ID

    /// fractional index into `spaces` driving the sidebar pager: 1.2 is 20% of
    /// the way from space 1 to space 2. springs with overshoot on a swipe release
    var spacePagePosition: Double = 0

    /// `spacePagePosition` for the backdrop colour: tracks a drag 1:1 but settles
    /// with a plain ease, so no overshoot blends in a third space's colour. equal
    /// to `spacePagePosition` at every rest point
    var backdropPosition: Double = 0 {
        didSet {
            let step = (backdropPosition * Self.tintSteps).rounded()
            if step != tintStep { tintStep = step }
        }
    }

    /// `backdropPosition` in quarters of a space, so swipe-blended colours change
    /// a few times per space rather than on every scroll event
    private(set) var tintStep: Double = 0
    private static let tintSteps = 4.0
    var tintPosition: Double { tintStep / Self.tintSteps }

    /// the profiles every window shares; the default one is always first
    var profiles: [Profile] {
        get { core.profiles }
        set { core.profiles = newValue }
    }

    /// the profile the current space browses as. an incognito window reads its
    /// opener's history for suggestions but never writes to it
    var currentProfile: Profile { core.profile(of: currentSpace) }

    /// the current profile's favourites, the icon grid at the top of the sidebar.
    /// an incognito window has none
    var essentials: [BrowserTab] {
        get { kind == .incognito ? [] : currentProfile.essentials }
        set {
            guard kind != .incognito else { return }
            currentProfile.essentials = newValue
        }
    }
    /// the favourite this window shows over each space's own tab. A window starts
    /// from what each space last showed in any window, then keeps its own
    private var essentialBySpace: [Space.ID: BrowserTab.ID] = [:]

    /// the favourite this window shows in `space` in place of the space's own tab
    func essential(in space: Space) -> BrowserTab? {
        guard kind != .incognito, let id = essentialBySpace[space.id] else { return nil }
        return core.profile(of: space).essentials.first { $0.id == id }
    }

    /// when set, this favourite is the active tab, overriding the current
    /// space's own selection for the url bar and web view
    var activeEssentialID: BrowserTab.ID? { essential(in: currentSpace)?.id }

    /// `space`, the current one by default, shows favourite `id`, or its own tab when nil
    /// or when `id` is not one of its profile's favourites
    private func showEssential(_ id: BrowserTab.ID?, in space: Space? = nil) {
        let space = space ?? currentSpace
        let id = id.flatMap { id in core.profile(of: space).essentials.first { $0.id == id }?.id }
        if let shown = essential(in: space), shown.id != id { shown.touch() }
        if essentialBySpace[space.id] != id { essentialBySpace[space.id] = id }
        space.selectedEssentialID = id
    }

    /// `tabs` stopped being favourites or went home: no space in any window lands on them
    func forgetEssentials(_ tabs: [BrowserTab]) {
        let ids = Set(tabs.map(\.id))
        for space in spaces where space.selectedEssentialID.map(ids.contains) == true {
            space.selectedEssentialID = nil
        }
        for manager in mainWindows {
            let shown = manager.essentialBySpace[manager.currentSpace.id]
            manager.essentialBySpace = manager.essentialBySpace.filter { !ids.contains($0.value) }
            guard let shown, ids.contains(shown) else { continue }
            tabs.first { $0.id == shown }?.touch()
            manager.prepareCurrentSpace()
        }
    }

    /// what each space last showed in any window, for a window starting out
    private var rememberedEssentials: [Space.ID: BrowserTab.ID] {
        Dictionary(
            spaces.compactMap { space in space.selectedEssentialID.map { (space.id, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    var history: HistoryStore { currentProfile.history }
    /// auto-archive: stale Today tabs are closed for you and land here
    var archive: ArchiveStore { currentProfile.archive }

    /// tabs you closed, newest first: the undo stack behind ⇧⌘T. keeps each page's
    /// whole session, in memory only; the archive holds tabs Artemis closed for you
    var closedTabs: [ClosedTab] {
        get { core.closedTabs }
        set { core.closedTabs = newValue }
    }
    /// folder shapes removed by "Close Folder", newest first
    var closedFolders: [ClosedFolder] {
        get { core.closedFolders }
        set { core.closedFolders = newValue }
    }
    private static let closedTabLimit = 25

    /// this window's ⌘Z for sidebar acts. text fields, pages and Settings undo on
    /// their window's own stack instead
    @ObservationIgnored let undo: UndoManager = {
        let undo = UndoManager()
        undo.levelsOfUndo = 40
        return undo
    }()
    /// above zero while a layout change is recorded or put back: nested calls join it
    @ObservationIgnored private var layoutDepth = 0

    /// pending camera, microphone and location requests, any number at once; each
    /// carries a WebKit handler that must be called exactly once
    var permissionQueue: [PermissionRequest] {
        get { core.permissionQueue }
        set { core.permissionQueue = newValue }
    }

    var isFindBarVisible = false
    /// the next find bar opens in question mode (⌥⌘F)
    @ObservationIgnored var opensFindBarAsking = false
    var isCommandBarVisible = false {
        didSet {
            guard oldValue, !isCommandBarVisible else { return }
            commandBarEditsAddress = false
            commandBarSeed = nil
            // the keyboard the bar's field held goes back to the page
            DispatchQueue.main.async { [weak self] in self?.selectedTab?.webHost?.focusHostedWebView() }
        }
    }
    /// typed into the new-tab bar, as if the user had typed it; dropped when the bar closes
    var commandBarSeed: String?
    /// the ⌘T bar is open on the page's address, the toolbar's stand-in for
    /// the pill growing into it
    var commandBarEditsAddress = false
    /// ⌘L with the bar already up: it takes the keyboard back, on the address
    var commandBarFocusRequest = 0
    /// what the open command bar is narrowed to; the menu's ⌘1–4 set it
    var commandBarScope: CommandScope?
    /// the command bar is editing the page's address, grown out of this window
    /// rect (.zero: the pill is off screen). outlives the bar while it shrinks back
    var addressBarOrigin: CGRect?
    /// the sidebar url pill's frame, window coordinates, nil while unmounted
    @ObservationIgnored var urlPillFrame: CGRect?
    /// the tab the sidebar's one rename alert is open for
    var renamingTab: BrowserTab?
    /// the new-space creator is up; it is the only way a space is created
    var isSpaceCreatorVisible = false
    /// a window drag is in flight: the floating sidebar must not read the window
    /// moving under a still pointer as the pointer leaving
    var isDraggingWindow = false
    /// the import sheet; nil when closed
    var importer: ImportModel?
    /// the Send Feedback sheet, or nil when it isn't up
    var feedback: FeedbackDraft?
    /// the New Live Folder sheet, or nil when it isn't up
    var liveFolderDraft: LiveFolderDraft?
    /// the ⇧-click Peek preview, belonging to no space; nil when closed
    var peekTab: BrowserTab?
    /// the link under the pointer, for the status capsule
    var hoveredLinkURL: URL?
    /// the Library panel is open in place of the sidebar's tab list; the window
    /// layout widens the sidebar by its rail meanwhile
    var isLibraryOpen = false

    /// only a browser window has a Library: an incognito one has no way back out of it
    func openLibrary(_ mode: LibraryMode) {
        guard kind == .main else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: LibraryMode.storageKey)
        isLibraryOpen = true
    }
    /// the space a click-jump is leaving, while the slide runs. a jump of any
    /// length slides one slot: the strip starts one slot short of the
    /// destination with the origin drawn there, so 1 → 10 is drawn as 1 → 2
    private(set) var glideOrigin: Int?
    private var glideToken = 0

    /// `spaces` as the filmstrip, backdrop and switcher lay them out — the real
    /// order, except that during a jump the space being left sits in the slot
    /// next to the destination
    var stripSpaces: [Space] {
        if let privateSpace { return [privateSpace] }
        guard let glideOrigin, spaces.indices.contains(glideOrigin),
            let target = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
            abs(target - glideOrigin) > 1
        else { return spaces }
        var strip = spaces
        strip.swapAt(glideOrigin, target - (target > glideOrigin ? 1 : -1))
        return strip
    }
    var urlFieldFocusRequest = 0
    /// ⌘G / ⌘⇧G: bumped by the menu, watched by the find bar, which owns the search
    var findNextRequest = 0
    var findPreviousRequest = 0
    /// bumped to ask the top space header to open its editor (so the bottom
    /// icons' "Edit Space…" reuses the one editor anchored at the top)
    var editSpaceRequest = 0
    /// true while a sidebar-spawned popover (e.g. the space editor) is open,
    /// so the floating overlay sidebar won't dismiss out from under it
    var isSidebarPopoverOpen = false
    /// the sidebar is on screen and done sliding in, so a popover can anchor inside it
    var isSidebarSettled = true
    /// a folder's peek panel hangs off the sidebar's trailing edge, over the page
    var isFolderPeekOpen = false

    /// the theme the space editor's eye is previewing on the real space
    var gradientPreview: SpaceAppearance?
    /// the space's own theme: restored when the preview exits, and what a save writes meanwhile
    @ObservationIgnored var previewRevert: SpaceAppearance?
    /// the editor's in-progress edit, resumed when the preview closes
    @ObservationIgnored var resumeGradientEdit: (id: UUID, appearance: SpaceAppearance)?

    private var saveTask: Task<Void, Never>? {
        get { core.saveTask }
        set { core.saveTask = newValue }
    }
    private var archiveTimer: Timer? {
        get { core.archiveTimer }
        set { core.archiveTimer = newValue }
    }
    /// fires when the system is short on memory, so idle tabs can be released
    /// before the machine starts swapping
    private var memoryPressureSource: DispatchSourceMemoryPressure? {
        get { core.memoryPressureSource }
        set { core.memoryPressureSource = newValue }
    }
    /// kept alive so the shared content controller's strong ref has a stable owner
    private var linkHoverReporter: LinkHoverReporter? {
        get { core.linkHoverReporter }
        set { core.linkHoverReporter = newValue }
    }
    /// the same, for the media-state reporter behind the speaker indicator
    private var mediaStateReporter: MediaStateReporter? {
        get { core.mediaStateReporter }
        set { core.mediaStateReporter = newValue }
    }
    /// debounces clearing the hovered link so a quick link→link move can't blink
    @ObservationIgnored private var clearHoverTask: Task<Void, Never>?
    var miniPlayer: MiniPlayer { core.miniPlayer }
    /// the pre-Spaces global pinned-tab list, folded into the first space on the
    /// first launch that finds it
    private static let legacyPinnedKey = "pinnedTabURLs"
    /// hours a Today tab can sit untouched before it auto-archives (0 = off)
    static let autoArchiveHoursKey = "autoArchiveHours"
    static let defaultAutoArchiveHours: Double = 12

    /// when on, leaving a tab playing video pops it into Picture in Picture, and
    /// returning to it closes the PiP
    static let autoPictureInPictureKey = "autoPictureInPicture"
    /// two-finger swipes go back and forward, on unless turned off
    static let swipeNavigationKey = "swipeNavigation"
    static var swipesNavigate: Bool { UserDefaults.standard.object(forKey: swipeNavigationKey) as? Bool ?? true }

    static let defaultIcons = [
        "circle.fill", "star.fill", "bolt.fill", "leaf.fill",
        "flame.fill", "moon.fill", "sparkles", "cube.fill",
        "briefcase.fill", "house.fill", "gamecontroller.fill", "book.fill",
    ]

    /// The first manager loads the session and installs the app-wide hooks; every
    /// later window attaches to the core that is already running, choosing only
    /// which space it opens on.
    init(core: BrowserCore = .shared, kind: WindowKind = .main, startingOn space: Space.ID? = nil) {
        self.core = core
        self.kind = kind
        guard !core.isLoaded else {
            selectedSpaceID = space ?? core.persistedSpaceID ?? core.spaces[0].id
            // a Scout or incognito window replaces this the moment it opens its own space
            if kind == .main {
                essentialBySpace = rememberedEssentials
                prepareCurrentSpace()
            }
            return
        }
        core.isLoaded = true
        Bench.mark("TabManager.init begin")
        // build everything in locals first — stored properties must all be
        // initialized before `self` (and `self.spaces`) can be touched
        let session = SessionStore.load()
        // while a session that won't decode is on disk or set aside, its profiles and tabs are
        // unknown, so sweep nothing they own
        let sessionUnreadable =
            session == nil && FileManager.default.fileExists(atPath: SessionStore.fileURL.path)
            || FileManager.default.fileExists(atPath: SessionStore.fileURL.appendingPathExtension("unreadable").path)
        let loadedProfiles = session.map { $0.profiles.map(Self.makeProfile(from:)) }
            ?? [Self.makeProfile(from: .makeDefault())]
        let loadedSpaces: [Space]
        if let loaded = session?.spaces, !loaded.isEmpty {
            loadedSpaces = loaded.map(Self.makeSpace(from:))
        } else {
            let first = Space(
                name: "Personal", icon: "circle.fill",
                appearance: SpacePreset.all[0].appearance)
            // migrate legacy global pinned tabs into the first space
            let legacy = (UserDefaults.standard.array(forKey: Self.legacyPinnedKey) as? [String]) ?? []
            first.tabs = legacy.compactMap(URL.init(string:)).map {
                BrowserTab(restoring: $0, pinned: true)
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyPinnedKey)
            first.normalizeTree()
            loadedSpaces = [first]
        }

        let selected: Space.ID
        if let id = session?.selectedSpaceID, loadedSpaces.contains(where: { $0.id == id }) {
            selected = id
        } else {
            selected = loadedSpaces[0].id
        }

        Bench.mark("TabManager: session loaded")
        selectedSpaceID = selected
        core.persistedSpaceID = selected
        profiles = loadedProfiles
        spaces = loadedSpaces
        essentialBySpace = rememberedEssentials

        for space in spaces { for tab in space.tabs { wire(tab) } }
        for tab in core.allEssentials {
            wire(tab)
            tab.prefetchFavicon()  // show the real icon before it's ever selected
        }
        // rule lists only reach navigations started after they are installed, so
        // the restored tab waits on the already-compiled chunks (~2ms warm; a
        // cache miss returns at once and the rebuild reloads what is open)
        Task { @MainActor in
            await ContentBlocker.shared.installPreviouslyCompiled()
            prepareCurrentSpace()
            await ContentBlocker.shared.apply()
        }
        Bench.mark("TabManager: tabs wired")
        if !sessionUnreadable {
            // sweep on-disk jars no profile owns — left by a delete whose teardown
            // lost the "still in use" race
            ProfileStore.reconcile(keeping: Set(profiles.map(\.id)))
            // same reconciliation for the per-tab session blobs: a crash between
            // closing a tab and the next save leaves its file behind
            TabStateStore.sweep(keeping: Set(spaces.flatMap(\.tabs).map(\.id)))
            // a pinned tab names every page it visits: keep only the names for where tabs are
            let restored = spaces.flatMap(\.tabs) + core.allEssentials
            TabNameStore.shared.clearAllGenerated(keeping: restored.flatMap { [$0.pendingURL, $0.pinnedURL] })
            if session?.namesOnTabs != true {
                TabNameStore.shared.handOverCustomNames(to: restored, archives: profiles.map(\.archive))
            }
        }
        Bench.mark("TabManager: profiles reconciled")
        startArchiveSweeps()

        // bring the WebExtensions runtime online and let it drive these tabs
        ExtensionManager.shared.attach(tabManager: self)
        Bench.mark("TabManager: extensions attached")
        AgentBridge.shared.start()

        // fingerprint defence, before anything else goes into the shared
        // controller: it has to run at document start, ahead of page scripts
        SharedWebContent.everywhere { ucc in
            FingerprintNoise.install(into: ucc)
            ChromeDisguise.install(into: ucc)
        }

        // status-capsule link hover, reported from every tab via the shared UCC to
        // the window holding the page
        let reporter = LinkHoverReporter { webView, url in
            BrowserWindows.shared.manager(for: webView?.window)?.setHoveredLink(url)
        }
        SharedWebContent.everywhere { LinkHoverReporter.install(into: $0, handler: reporter) }
        linkHoverReporter = reporter

        // playing-media state, for the sidebar speaker indicator, tab mute and Now Playing
        let media = MediaStateReporter { [weak self] webView, info, frame, playing, pageMedia in
            guard let tab = self?.tab(hosting: webView) else { return }
            tab.setFramePlaying(playing, frame: frame)
            tab.setFrameMedia(pageMedia, frame: frame, info: info)
        }
        SharedWebContent.everywhere { ucc in
            MediaStateReporter.install(into: ucc, handler: media)
            WebNotifications.install(into: ucc)
            PasswordAutofill.install(into: ucc)
            Autofill.install(into: ucc)
            PasskeyBridge.install(into: ucc)
            EditingFocusReporter.install(into: ucc)
        }
        mediaStateReporter = media

        observeAppFocusForPiP()
        miniPlayer.onReturnToBrowser = { tab in tab.manager?.revealTab(tab) }
        Bench.mark("TabManager.init end")
    }

    /// is this window the one showing `tab` right now — the page on screen, a
    /// pane of a shown split, or its Peek preview
    func isShowing(_ tab: BrowserTab) -> Bool {
        if displayedContentTab === tab || peekTab === tab { return true }
        return displayedSplitTabs.contains { $0 === tab }
    }

    /// the window is going away: let go of anything only it was holding
    func windowWillClose() {
        closePeek()
        endContentSwitch()
        // already out of the registry a save reads previews from: the space takes its own theme back
        if let edit = resumeGradientEdit, let revert = previewRevert,
            let space = spaces.first(where: { $0.id == edit.id })
        {
            updateSpace(space, appearance: revert)
        }
        (resumeGradientEdit, previewRevert, gradientPreview) = (nil, nil, nil)
        if kind != .main {
            discardPrivateSpace()
            undo.removeAllActions()
            UndoRoute.shared.refresh()
        }
        settleTask?.cancel()
    }

    /// switch to `tab`'s space, select it and front its window, with no bar over it
    func revealTab(_ tab: BrowserTab) {
        focus(tab)
        isCommandBarVisible = false
        NSApp.activate(ignoringOtherApps: true)
        let window = BrowserWindows.shared.window(of: self)
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
    }

    /// show `tab`, wherever it lives — switching space first if it's elsewhere,
    /// or activating the favourites layer if it's a favourite
    func focus(_ tab: BrowserTab) {
        if tab.isEssential {
            // another profile's favourite shows from one of that profile's spaces
            if tab.profileID != currentProfile.id {
                guard let home = spaces.first(where: { $0.profileID == tab.profileID }) else { return }
                selectSpace(home)
            }
            selectedTabID = tab.id
        } else if let space = allSpaces.first(where: { $0.tabs.contains(where: { $0.id == tab.id }) }) {
            if space.id != selectedSpaceID { selectSpace(space) }
            selectedTabID = tab.id
        }
    }

    /// every live tab the model owns: all spaces, every profile's favourites, the
    /// Peek preview and any window's own pages (Scout, incognito)
    var allTabs: [BrowserTab] {
        var out = spaces.flatMap(\.tabs)
        out.append(contentsOf: core.allEssentials)
        out.append(contentsOf: core.windowLocal.allObjects)
        return out
    }

    /// the spaces this model can reach: the shared ones and this window's own
    var allSpaces: [Space] {
        guard let privateSpace else { return spaces }
        return spaces + [privateSpace]
    }

    /// the tab owning `webView`, for script-message handlers shared by every tab
    func tab(hosting webView: WKWebView) -> BrowserTab? {
        allTabs.first { $0.webView === webView }
    }

    /// the space a tab lives in — nil for favourites and the Peek preview,
    /// which belong to no space
    func space(of tab: BrowserTab) -> Space? {
        if let privateSpace, privateSpace.tabs.contains(where: { $0.id == tab.id }) {
            return privateSpace
        }
        return spaces.first { space in space.tabs.contains { $0.id == tab.id } }
    }

    /// update the hovered-link capsule; a clear is deferred a beat so moving
    /// straight from one link to another doesn't flash the capsule away
    private func setHoveredLink(_ url: URL?) {
        clearHoverTask?.cancel()
        if let url {
            hoveredLinkURL = url
        } else {
            clearHoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                if !Task.isCancelled { hoveredLinkURL = nil }
            }
        }
    }

    /// with auto-PiP on, another app or desktop hiding a window pops its playing video
    /// into the mini-player; the window showing again, or Artemis coming back, closes it
    private func observeAppFocusForPiP() {
        let center = NotificationCenter.default
        let player = miniPlayer
        // only once the window is out of view, never for a switch that leaves the page in view.
        // occlusion can land before the app resigns, and a desktop swipe may not resign it at all
        center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                if window.occlusionState.contains(.visible) {
                    if NSApp.isActive, window.isOnActiveSpace {
                        player.windowDidShow(selecting: BrowserWindows.shared.manager(for: window)?.selectedTab)
                    }
                } else {
                    let now = CACurrentMediaTime()
                    Self.hiddenAt = Self.hiddenAt.filter { now - $0.value < 1 }
                    Self.hiddenAt[ObjectIdentifier(window)] = now
                    Self.parkVideo(of: window, in: player)
                }
            }
        }
        for (source, name) in [
            (center, NSApplication.didResignActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
        ] {
            source.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    for window in NSApp.windows where now - (Self.hiddenAt[ObjectIdentifier(window)] ?? 0) < 1 {
                        Self.parkVideo(of: window, in: player)
                    }
                }
            }
        }
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                player.artemisDidBecomeActive()
                guard UserDefaults.standard.bool(forKey: Self.autoPictureInPictureKey),
                    let tab = BrowserWindows.shared.current?.selectedTab
                else { return }
                player.exitIfActive(for: tab)
            }
        }
    }

    /// when each window last went out of view: a resign or desktop sweep parks only one that
    /// just went, never one Artemis hid itself before
    private static var hiddenAt: [ObjectIdentifier: CFTimeInterval] = [:]

    /// `window` is out of view behind another app or on another desktop: its video moves out
    private static func parkVideo(of window: NSWindow, in player: MiniPlayer) {
        guard UserDefaults.standard.bool(forKey: autoPictureInPictureKey), !window.isMiniaturized,
            !window.occlusionState.contains(.visible), !NSApp.isActive || !window.isOnActiveSpace,
            let manager = BrowserWindows.shared.manager(for: window), manager.kind == .main,
            let tab = manager.selectedTab,
            // a space asking for Touch ID locks as Artemis goes, so its page stays put
            manager.space(of: tab)?.requiresUnlock != true
        else { return }
        player.enterAsHidden(tab)
    }

    var currentSpace: Space {
        if let privateSpace { return privateSpace }
        return spaces.first { $0.id == selectedSpaceID } ?? spaces[0]
    }

    /// a Scout or incognito window's own space: never in `core.spaces`, so no
    /// other window lists it and nothing persists it
    private(set) var privateSpace: Space?

    /// an incognito window's jar: every page it opens browses in it, and it goes
    /// when the window does
    @ObservationIgnored private var incognitoStore: WKWebsiteDataStore?

    /// the jar a new page in `space` is born in
    func dataStore(for space: Space) -> WKWebsiteDataStore {
        if let incognitoStore, space.id == privateSpace?.id { return incognitoStore }
        return ProfileStore.dataStore(for: space.profileID)
    }

    /// give this window a throwaway one-page space, themed and profiled like the opener's
    /// space, else the one the link would have landed in. a popup passes the opener's
    /// `configuration` instead of a url, and WebKit loads it into the returned view
    @discardableResult
    func openScoutSpace(
        on url: URL? = nil, like opener: Space? = nil, adopting configuration: WKWebViewConfiguration? = nil
    ) -> BrowserTab {
        let theme = opener ?? url.map { preferredSpace(for: $0) }
            ?? BrowserWindows.shared.browserScope?.currentSpace ?? currentSpace
        let space = Space(
            name: "Scout", icon: "binoculars.fill", appearance: theme.appearance,
            profileID: theme.profileID)
        privateSpace = space
        selectedSpaceID = space.id
        let tab = BrowserTab(
            configuration: configuration
                ?? BrowserTab.defaultConfiguration(dataStore: dataStore(for: space)))
        wire(tab)
        space.tabs = [tab]
        space.normalizeTree()
        space.selectedTabID = tab.id
        core.windowLocal.add(tab)
        ExtensionManager.shared.tabDidOpen(tab)
        if let url { tab.load(url) }
        return tab
    }

    /// make this an incognito window: one space nobody else sees, over a jar of its
    /// own, empty until its ⌘T bar opens a page. `parent` lends its history to the
    /// command bar, read-only
    func openIncognitoSpace(parent: Profile) {
        let space = Space(
            name: "Incognito", icon: "eyeglasses", appearance: .incognito, profileID: parent.id)
        if UserDefaults.standard.bool(forKey: SpaceLock.incognitoRequiresUnlockKey) {
            SpaceLock.shared.requireUnlock(for: space)
        }
        incognitoStore = ProfileStore.makePrivate(parent: parent.id)
        privateSpace = space
        selectedSpaceID = space.id
        ExtensionManager.shared.openPrivateWindow(of: self)
    }

    /// closing a Scout or incognito window takes its space, its pages and its jar with it
    private func discardPrivateSpace() {
        guard let space = privateSpace else { return }
        for tab in space.tabs {
            // only an incognito page's extension window closes with this one
            ExtensionManager.shared.tabDidClose(tab, windowIsClosing: tab.isPrivate)
            abandonQuestions(of: tab)
            miniPlayer.exitIfActive(for: tab)
            tab.stopLoading()
            core.windowLocal.remove(tab)
        }
        ExtensionManager.shared.windowDidClose(self)
        space.tabs = []
        privateSpace = nil
        incognitoStore = nil
        let anyIncognitoLeft = BrowserWindows.shared.allManagers.contains {
            $0 !== self && $0.kind == .incognito
        }
        if kind == .incognito, !anyIncognitoLeft {
            SitePermissionStore.shared.forgetEphemeral()
            ChromeDisguise.forgetEphemeral()
            CertificateTrust.forgetEphemeral()
        }
    }

    /// the two spaces the backdrop is between, and how far across. every tint
    /// reads this, not `spacePagePosition`, so chrome and background always agree
    private var backdropPair: (SpaceAppearance, SpaceAppearance, Double) {
        let strip = stripSpaces
        let p = min(max(tintPosition, 0), Double(max(strip.count - 1, 0)))
        let floor = Int(p.rounded(.down))
        let a = strip.indices.contains(floor) ? strip[floor] : currentSpace
        let b = strip.indices.contains(floor + 1) ? strip[floor + 1] : a
        return (a.appearance, b.appearance, p - p.rounded(.down))
    }

    /// the accent cross-faded in step with the backdrop
    var blendedAccent: Color {
        let (a, b, t) = backdropPair
        return SpaceAppearance.blend(a.accent, b.accent, t)
    }

    /// the sidebar ink cross-faded in step with the backdrop
    var blendedInk: Color {
        let (a, b, t) = backdropPair
        return SpaceAppearance.blend(a.chromeInk, b.chromeInk, t)
    }

    // MARK: - Tab API (delegates to the current space)

    var tabs: [BrowserTab] { currentSpace.tabs }

    /// every tab ⌘T can switch to: this space, the profile's favourites (which
    /// belong to no space, so no space-scoped list reaches them), then every
    /// other space. An incognito window offers only its own
    var switchableTabs: [BrowserTab] {
        var out = SpaceLock.shared.isLocked(currentSpace) ? [] : currentSpace.tabs
        guard kind == .main else { return out }
        out.append(contentsOf: essentials)
        for space in spaces where space.id != selectedSpaceID && !SpaceLock.shared.isLocked(space) {
            out.append(contentsOf: space.tabs)
        }
        return out
    }
    var pinnedTabs: [BrowserTab] { currentSpace.pinnedTabs }
    var todayTabs: [BrowserTab] { currentSpace.todayTabs }

    /// the active favourite, else the current space's selected tab: what the url
    /// bar and web view show
    var selectedTab: BrowserTab? {
        essential(in: currentSpace) ?? selectedTab(in: currentSpace)
    }

    /// what *this window* has chosen in each space. Two windows can sit on the
    /// same space with different pages open; `Space.selectedTabID` is the shared
    /// default a window starts from and the one the session remembers
    private var shownTabBySpace: [Space.ID: BrowserTab.ID] = [:]

    /// the tab this window shows in `space` — its own choice while that tab still
    /// exists, otherwise the space's own
    func selectedTab(in space: Space) -> BrowserTab? {
        if let id = shownTabBySpace[space.id], let tab = space.tabs.first(where: { $0.id == id }) {
            return tab
        }
        return space.selectedTab
    }

    func selectedTabID(in space: Space) -> BrowserTab.ID? { selectedTab(in: space)?.id }

    /// the page this window shows in `space`: its favourite, else its own tab
    func shownPage(in space: Space) -> BrowserTab? {
        essential(in: space) ?? selectedTab(in: space) ?? space.firstOpenTab
    }

    /// this window is now showing `id` in `space`. The space keeps it too, so a
    /// new window opens where you last were and the session restores it
    private func setSelectedTab(_ id: BrowserTab.ID?, in space: Space) {
        shownTabBySpace[space.id] = id
        space.selectedTabID = id
    }

    /// a tab that no longer exists can't stay any window's choice
    private func forgetSelection(of id: BrowserTab.ID) {
        shownTabBySpace = shownTabBySpace.filter { $0.value != id }
        if settledTab?.id == id { settledTab = nil }
    }

    var selectedTabID: BrowserTab.ID? {
        get { selectedTab?.id }
        set {
            let previous = selectedTab
            if previous?.id != newValue { closeAddressEdit() }
            // the tab being left was in use until now
            previous?.touch()
            let autoPiP = UserDefaults.standard.bool(forKey: Self.autoPictureInPictureKey)
            // before the switch: WebKit only lets the foreground video enter PiP
            if autoPiP, let previous, previous.id != newValue {
                miniPlayer.enterIfPlaying(previous)
            }
            if let newValue, essentials.contains(where: { $0.id == newValue }) {
                showEssential(newValue)
            } else {
                showEssential(nil)
                setSelectedTab(newValue, in: currentSpace)
                // a live folder's item is the user's once looked at
                if let newValue {
                    for folder in currentSpace.folders where folder.live?.items[newValue]?.opened == false {
                        folder.live?.items[newValue]?.opened = true
                        folder.live?.items[newValue]?.unread = false
                    }
                }
                // remember the focused pane so re-opening the split restores it
                if let newValue, let group = currentSpace.splitGroup(containing: newValue) {
                    group.lastFocusedID = newValue
                }
            }
            // warm the focused tab — and, if it's a split, every pane of it
            activateSplit(for: selectedTab)
            selectedTab?.touch()
            settleSelection()
            // returning to a tab floating in PiP closes the PiP
            if autoPiP, previous?.id != selectedTab?.id, let active = selectedTab {
                miniPlayer.exitIfActive(for: active)
            }
        }
    }

    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// the tab extensions were last told this window had active
    @ObservationIgnored private weak var settledTab: BrowserTab?

    /// selection side effects run once the swap has painted, for whatever page
    /// is shown by then; a burst of changes settles once
    private func settleSelection() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.settleTask = nil
            guard let active = self.selectedTab else { return self.offerHandoff() }
            active.probeReaderAvailability()
            if active !== self.settledTab {
                ExtensionManager.shared.tabDidActivate(active, previous: self.settledTab)
                self.settledTab = active
            }
            self.offerHandoff()
        }
    }

    /// ⌘T; a Scout window has no tab strip, so it ignores it
    func requestNewTab() {
        guard kind != .scout else { return }
        if activeEssentialID == nil, SpaceLock.shared.isLocked(currentSpace) {
            let space = currentSpace
            Task { await SpaceLock.shared.unlock(space) }
            return
        }
        if isCommandBarVisible {
            addressBarOrigin = nil
            isCommandBarVisible = false
        } else {
            openNewTabBar()
        }
    }

    /// the command bar, empty, for a new tab: ⌘T or the sidebar's New Tab row
    func openNewTabBar() {
        guard kind != .scout else { return }
        addressBarOrigin = nil
        commandBarEditsAddress = false
        isCommandBarVisible = true
        BrowserTab.prewarmWebProcess()
    }

    /// an address being edited belongs to the page it was opened on
    func closeAddressEdit() {
        if commandBarEditsAddress || addressBarOrigin != nil { isCommandBarVisible = false }
    }

    /// ⌘L or a click on the url pill: the command bar on the page's address,
    /// grown out of the sidebar's pill, or centred like ⌘T under the toolbar
    func editAddress() {
        guard kind != .scout else { return }
        if isCommandBarVisible {
            if BrowserToolbar.isShown { commandBarEditsAddress = true }
            commandBarFocusRequest += 1
            return
        }
        if BrowserToolbar.isShown {
            commandBarEditsAddress = true
        } else {
            addressBarOrigin = urlPillFrame.flatMap { $0.maxX > 0 ? $0 : nil } ?? .zero
        }
        isCommandBarVisible = true
    }

    @discardableResult
    func newTab(
        url: URL? = nil,
        configuration: WKWebViewConfiguration? = nil,
        select: Bool = true,
        in space: Space? = nil
    ) -> BrowserTab {
        let space = space ?? currentSpace
        // a passed-in configuration comes from window.open / target=_blank and
        // already inherits the opener's jar — keep it. otherwise bind the new tab
        // to the space's
        let config = configuration
            ?? BrowserTab.defaultConfiguration(dataStore: dataStore(for: space))
        let tab = BrowserTab(configuration: config)
        wire(tab)
        insert(tab, into: space, select: select)
        if let url {
            tab.load(url)
        } else if select, configuration == nil {
            openNewTabBar()
        }
        return tab
    }

    private func insert(_ tab: BrowserTab, into space: Space, select: Bool) {
        space.tabs.append(tab)
        // a window's own pages are reached through the weak registry, as Scout's are
        if space.id == privateSpace?.id { core.windowLocal.add(tab) }
        space.normalizeTree()
        ExtensionManager.shared.tabDidOpen(tab)
        if select { selectedTabID = tab.id }
        scheduleSave()
    }

    /// `wakesSuccessor` false leaves the tab chosen in its place asleep: a batch
    /// wakes whatever it leaves selected once, at the end
    func close(_ tab: BrowserTab, act: ClosedAct? = nil, wakesSuccessor: Bool = true) {
        // a favourite stays in the grid: closing it sends it back to its home
        if tab.isEssential { return closeAndKeepPinned(tab) }
        if tab.id == selectedTab?.id { closeAddressEdit() }
        let space = self.space(of: tab) ?? currentSpace
        guard let index = space.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let successor = space.successor(of: tab.id)
        rememberClosed(tab, from: space, act: act ?? ClosedAct(name: tab.isPinned ? "Archive Pinned Tab" : "Close Tab"))
        detachFromSplit(tab)
        // ✕ on a pinned tab archives it (incognito excepted: no disk)
        if tab.isPinned, !tab.isPrivate,
            let url = tab.pinnedURL ?? tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL
        {
            core.profile(of: space).archive.add(
                id: tab.id, url: url, title: tab.displayTitle, spaceName: space.name, name: tab.customName)
        }
        space.tabs.remove(at: index)
        space.normalizeTree()
        SpotlightIndex.forget(.items([tab.id]))
        letGo(of: tab)
        if space.selectedTabID == tab.id {
            space.selectedTabID = successor
            if wakesSuccessor { space.selectedTab?.activateIfNeeded() }
            settleSelection()
        }
        // an incognito window is its tabs: the last one closing closes it
        if kind == .incognito, space.tabs.isEmpty {
            BrowserWindows.shared.window(of: self)?.performClose(nil)
        }
        scheduleSave()
    }

    /// a link dropped into the sidebar: a background tab at the drop position,
    /// pinned when it landed in the pinned section
    @discardableResult
    func addTab(from url: URL, to container: SidebarContainer, at index: Int) -> BrowserTab {
        // a new tab is no move to take back
        layoutDepth += 1
        defer { layoutDepth -= 1 }
        let tab = newTab(url: url, select: false)
        moveTab(tab, to: container, at: index)
        return tab
    }

    /// ⌘W; an open pinned tab goes dormant and keeps its pin, which only ✕ or the
    /// context menu deletes
    func closeSelectedTab() {
        guard let selectedTab else { return }
        if selectedTab.isPinned, selectedTab.pendingURL == nil {
            if let group = currentSpace.splitGroup(containing: selectedTab.id) {
                requestClose(group, keepingPin: true)
            } else {
                requestClose(selectedTab, keepingPin: true)
            }
        } else {
            requestClose(selectedTab)
        }
    }

    /// `close` / `closeAndKeepPinned` once the page's `beforeunload` allows it. A page whose
    /// prompt appears is brought on screen (see `BrowserTab`); one that never answers closes after 3s
    func requestClose(_ tab: BrowserTab, keepingPin: Bool = false, act: ClosedAct? = nil) {
        let close = { [weak self, weak tab] in
            guard let self, let tab else { return }
            if keepingPin { closeAndKeepPinned(tab) } else { self.close(tab, act: act) }
        }
        if tab.tryClose() { return close() }
        tab.onConfirmedClose = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak tab] in
            guard let tab, tab.pendingDialog == nil, let pending = tab.onConfirmedClose else { return }
            tab.onConfirmedClose = nil
            pending()
        }
    }

    /// every pane of a split; `keepingPin` sleeps a pinned split's open panes
    /// at their pins and leaves the split whole
    func requestClose(_ group: SplitGroup, keepingPin: Bool = false) {
        let panes = currentSpace.tabs(in: group)
        let act = ClosedAct(name: panes.first?.isPinned == true ? "Archive Pinned Split" : "Close Split")
        for pane in panes where !keepingPin || !pane.isDormantPin {
            requestClose(pane, keepingPin: keepingPin, act: act)
        }
    }

    /// ⌘⇧P: pop the focused tab's video into the mini-player, or put it back
    func togglePictureInPicture() {
        guard let tab = unlockedContentTab else { return }
        miniPlayer.toggle(tab)
    }

    // MARK: - Tidy tab titles

    /// ask the on-device model for a short name for a pinned tab or favourite
    /// whose title is a mouthful; never touches a tab you named yourself
    private func tidyTitle(for tab: BrowserTab, url: URL, title: String) {
        guard Intelligence.isOn(Intelligence.tidyTitlesKey), Intelligence.isReady else {
            tidyBreadcrumb("skip (switch/readiness) \(url.host() ?? "?")")
            return
        }
        guard tab.isPinned || tab.isEssential else { return }
        guard tab.customName == nil else {
            tidyBreadcrumb("skip (custom name set) \(url.host() ?? "?")")
            return
        }
        guard !title.isEmpty, let key = TabNameStore.key(url) else { return }

        // a loading page's title churns, so ask once it holds still for 1.2s, per
        // tab; a page already loaded asks at once
        let settledAlready = !tab.isLoading && tab.title == title
        tidyDebounce[tab.id]?.cancel()
        tidyDebounce[tab.id] = Task { [weak self, weak tab] in
            if !settledAlready { try? await Task.sleep(for: .milliseconds(1200)) }
            guard !Task.isCancelled, let self, let tab else { return }
            self.tidyDebounce[tab.id] = nil
            // ask about the title as it stands NOW, not as it was 1.2s ago
            let settled = Self.normalisedTitle(tab.title)
            guard !settled.isEmpty, settled != "New Tab" else { return }
            // already named from this exact title, in this launch or an earlier one
            guard TabNameStore.shared.generatedFrom(for: url) != settled else {
                self.tidyBreadcrumb("already named from this title")
                return
            }
            let request = "\(key)\u{1F}\(settled)"
            guard !self.tidyRequested.contains(request) else { return }
            self.tidyRequested.insert(request)
            self.tidyBreadcrumb("asking for: \(settled.prefix(60))")

            // the page's own text, read from the DOM on device, so a title like
            // "Pricing" can be named after whose it is
            let context = await PageText.summaryContext(from: tab.webView)

            // the site's own name suits its front page only
            let isFrontPage = url.path().isEmpty || url.path() == "/"
            var name = await Intelligence.shared.tidyTitle(
                pageTitle: settled, host: url.host() ?? "", context: context,
                isFrontPage: isFrontPage)
            // the model sometimes declines under back-to-back load
            if name == nil {
                try? await Task.sleep(for: .milliseconds(600))
                name = await Intelligence.shared.tidyTitle(
                    pageTitle: settled, host: url.host() ?? "", context: context,
                    isFrontPage: isFrontPage)
            }
            guard let name else {
                self.tidyBreadcrumb("model declined twice for: \(settled.prefix(40))")
                return
            }
            // pages rewrite their own url while the model thinks, so the tab need
            // only still be at the name key
            guard TabNameStore.key(tab.url ?? tab.pendingURL) == key else {
                self.tidyBreadcrumb("tab left \(key) before '\(name)' arrived")
                return
            }
            // an answer counts only for the title the tab shows now
            guard Self.normalisedTitle(tab.title) == settled else {
                self.tidyBreadcrumb("title moved on before '\(name)' landed")
                return
            }
            TabNameStore.shared.setGenerated(name, from: settled, for: url)
            self.tidyBreadcrumb("named: \(name)")
        }
    }

    /// in-flight debounced rename work, one slot per tab
    @ObservationIgnored private var tidyDebounce: [UUID: Task<Void, Never>] = [:]
    /// `title` without the leading unread counts, like "(14) ", that sites add
    /// and drop as notifications arrive
    static func normalisedTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let match = text.range(of: unreadPrefix, options: .regularExpression) {
            text.removeSubrange(match)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let unreadPrefix = "^\\(\\d+\\)\\s*"

    /// the count a title's leading "(n)" announces; nil for none or zero
    static func unreadCount(in title: String) -> Int? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(of: unreadPrefix, options: .regularExpression),
            let count = Int(text[match].filter(\.isNumber)), count > 0
        else { return nil }
        return count
    }
    /// (name key, title) pairs already asked about, so a page that settles on
    /// the same title twice doesn't queue a second model call
    @ObservationIgnored private var tidyRequested: Set<String> = []

    /// the tidy pipeline's last 40 decisions, in memory only; ARTEMIS_DIAG=ai prints it
    @ObservationIgnored private(set) var tidyTrail: [String] = []
    private func tidyBreadcrumb(_ line: String) {
        tidyTrail.append(line)
        if tidyTrail.count > 40 { tidyTrail.removeFirst(tidyTrail.count - 40) }
        debugLog("tidy: \(line)")
    }

    /// ask for a tidy name now, from the title the page already has: a page
    /// pinned after loading sees no further title change to trigger `tidyTitle`
    func requestTidyName(for tab: BrowserTab) {
        guard !tab.isPrivate else { return }
        guard let url = tab.url ?? tab.lastAttemptedURL else { return }
        tidyTitle(for: tab, url: url, title: tab.title)
    }

    /// name a tab yourself; an empty name drops the model's name too
    func rename(_ tab: BrowserTab, to name: String?) {
        guard !tab.isPrivate else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return usePageTitle(for: tab) }
        guard trimmed != tab.customName else { return }
        registerName(of: tab, as: "Rename Tab")
        tab.customName = trimmed
        scheduleSave()
    }

    /// drop both names for this tab and show the page's own title again
    func usePageTitle(for tab: BrowserTab) {
        guard !tab.isPrivate else { return }
        let page = tab.url ?? tab.pendingURL
        guard tab.customName != nil || TabNameStore.shared.generated(for: page) != nil else { return }
        registerName(of: tab, as: "Use Page Title")
        tab.customName = nil
        TabNameStore.shared.clearGenerated(for: page)
        scheduleSave()
    }

    /// ⌘Z for a tab's names: puts back both, and registers the rename again as the redo
    private func registerName(of tab: BrowserTab, as action: String) {
        let old = tab.customName
        let page = tab.url ?? tab.pendingURL
        let generated = TabNameStore.shared.generated(for: page).map { ($0, TabNameStore.shared.generatedFrom(for: page)) }
        // by id: a close and its undo bring the tab back as a new object
        let id = tab.id
        undo.registerUndo(withTarget: self) { manager in
            guard let tab = manager.allTabs.first(where: { $0.id == id }) else { return }
            let new = tab.customName
            manager.undo.registerUndo(withTarget: manager) { manager in
                guard let tab = manager.allTabs.first(where: { $0.id == id }) else { return }
                if let new { manager.rename(tab, to: new) } else { manager.usePageTitle(for: tab) }
            }
            manager.undo.setActionName(action)
            tab.customName = old
            if let generated { TabNameStore.shared.setGenerated(generated.0, from: generated.1, for: page) }
            manager.scheduleSave()
        }
        undo.setActionName(action)
    }

    // MARK: - Full-text index

    /// add the page's text to the local search index when that's on, 1.5s after
    /// the load, walking the DOM since `innerText` forces a layout
    private func indexPageText(_ tab: BrowserTab, into index: FullTextIndex, url: URL, title: String) {
        guard UserDefaults.standard.bool(forKey: FullTextIndex.enabledKey) else { return }
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        Task { [weak tab] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let tab, tab.url == url else { return }
            guard let text = await PageText.extract(from: tab.webView) else { return }
            await index.record(url: url, title: title, body: text)
        }
    }

    // MARK: - Recently closed

    /// put a tab on the closed stack on its way out, as part of `act`, before it leaves its split.
    /// no space means a favourite leaving its profile's grid
    private func rememberClosed(_ tab: BrowserTab, from space: Space?, act: ClosedAct) {
        // incognito leaves no trace, the undo stack included
        guard !tab.isPrivate else { return }
        guard let url = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL else { return }
        if let group = space?.splitGroup(containing: tab.id), !act.splits.contains(where: { $0.id == group.id }) {
            act.splits.append(
                .init(id: group.id, root: group.root, linkSourceID: group.linkSourceID, linkTargetID: group.linkTargetID))
        }
        let grid = space == nil ? profiles.first { $0.essentials.contains { $0.id == tab.id } } : nil
        let gridHome = grid.flatMap { grid in
            currentSpace.profileID == grid.id ? currentSpace : spaces.first { $0.profileID == grid.id }
        }
        guard let home = space ?? gridHome ?? spaces.first
        else { return }
        // read the slot while the tree still holds the tab — the caller removes
        // it right after
        let container = space?.parent(of: .tab(tab.id))
        let slot = grid.map { $0.essentials.firstIndex { $0.id == tab.id } ?? 0 }
            ?? container.flatMap { home.entries(in: $0).firstIndex(of: .tab(tab.id)) } ?? 0
        closedTabs.insert(
            ClosedTab(
                id: tab.id,
                url: url,
                title: tab.title.isEmpty ? url.host() ?? url.absoluteString : tab.title,
                spaceID: home.id,
                folderID: { if case .folder(let id) = container { id } else { nil } }(),
                folderName: {
                    if case .folder(let id) = container { home.folder(id)?.name } else { nil }
                }(),
                index: slot,
                isPinned: tab.isPinned,
                pinnedURL: tab.pinnedURL,
                customName: tab.customName,
                // WebKit's session blob: reopening replays the page's back/forward
                // list and scroll position instead of starting a fresh load
                interactionState: tab.persistableInteractionState,
                closedAt: Date(),
                act: act,
                profileID: grid?.id),
            at: 0)
        if !act.isRegistered { registerReopen(act) }
        // the stack drops whole acts, oldest first, and never the one in progress
        while closedTabs.count > Self.closedTabLimit, let last = closedTabs.last, last.act !== act {
            closedTabs.removeAll { $0.act === last.act }
            closedFolders.removeAll { $0.act === last.act }
            forget(last.act)
        }
    }

    /// ⌘Z for a close: reopens the whole act, unless ⇧⌘T got there first
    private func registerReopen(_ act: ClosedAct) {
        act.isRegistered = true
        // the handler holds the act: an undo manager never retains its target
        undo.registerUndo(withTarget: act) { [weak self, act] _ in self?.reopen(act: act) }
        undo.setActionName(act.name)
    }

    /// a reopened or trimmed act leaves every window's ⌘Z
    private func forget(_ act: ClosedAct) {
        guard act.isRegistered else { return }
        for stack in everyUndoStack {
            // a stack mid-undo drops entries once it is done; one dropped inside an open group
            // leaves an empty Undo behind, so that waits for the group to close
            if stack.isUndoing || stack.isRedoing {
                DispatchQueue.main.async { stack.removeAllActions(withTarget: act) }
            } else if stack.groupingLevel > 0 {
                Task {
                    if stack.groupingLevel > 0 {
                        for await _ in NotificationCenter.default.notifications(
                            named: .NSUndoManagerDidCloseUndoGroup, object: stack)
                        where stack.groupingLevel == 0 { break }
                    }
                    stack.removeAllActions(withTarget: act)
                    UndoRoute.shared.refresh()
                }
            } else {
                stack.removeAllActions(withTarget: act)
            }
        }
        UndoRoute.shared.refresh()
    }

    /// every window's ⌘Z stack, and the one the next window takes
    private var everyUndoStack: [UndoManager] {
        ([self] + BrowserWindows.shared.allManagers + [BrowserWindows.shared.seed].compactMap { $0 }).map(\.undo)
    }

    /// empty every window's ⌘Z, Settings' included: what it held no longer matches the spaces or
    /// profiles, or names pages a clear took
    func clearAllUndo() {
        for stack in everyUndoStack { stack.removeAllActions() }
        for window in NSApp.windows { window.undoManager?.removeAllActions(withTarget: ProfilesNavigator.shared) }
        UndoRoute.shared.refresh()
    }

    /// drop the closed tabs and folders that match, and any act they leave empty
    func forgetClosed(where matches: (_ spaceID: Space.ID, _ closedAt: Date) -> Bool) {
        let acts = closedTabs.filter { matches($0.spaceID, $0.closedAt) }.map(\.act)
            + closedFolders.filter { matches($0.spaceID, $0.closedAt) }.map(\.act)
        closedTabs.removeAll { matches($0.spaceID, $0.closedAt) }
        closedFolders.removeAll { matches($0.spaceID, $0.closedAt) }
        for act in acts where !closedTabs.contains(where: { $0.act === act }) && !closedFolders.contains(where: { $0.act === act }) {
            forget(act)
        }
    }

    /// drop the newest entry without reopening it — only the suite needs this,
    /// to get to the empty-stack case
    @discardableResult
    func removeFirstForTesting() -> ClosedTab? {
        closedTabs.isEmpty ? nil : closedTabs.removeFirst()
    }

    /// what ⇧⌘T brings back next: a folder deleted more recently than the newest
    /// closed tab, and not as part of the same act, comes back on its own
    var reopensFolderNext: Bool {
        guard let folder = closedFolders.first else { return false }
        return folder.closedAt >= (closedTabs.first?.closedAt ?? .distantPast)
            && closedTabs.first?.act !== folder.act
    }

    /// ⇧⌘T: bring back what you just closed, in the space and at the position it
    /// was closed from
    @discardableResult
    func reopenLastClosedTab() -> BrowserTab? {
        // a folder deleted with nothing in it has no tab to come back with
        if reopensFolderNext, let folder = closedFolders.first { return reopen(act: folder.act) }
        return closedTabs.first.flatMap { reopen(act: $0.act) }
    }

    /// bring back every tab and folder `act` closed. it leaves ⌘Z either way, and
    /// ⌘Z then closes them again
    @discardableResult
    private func reopen(act: ClosedAct) -> BrowserTab? {
        let shape = closedFolders.first { $0.act === act }
        let records = closedTabs.filter { $0.act === act }
        guard shape != nil || !records.isEmpty else { return nil }
        // the folders they were filed in go back first, so they have somewhere to land
        if let shape { restore(shape) }
        closedFolders.removeAll { $0.act === act }
        // newest first: each slot was read once the act's earlier closes had left,
        // so only the reverse order puts every tab back beside its old neighbours
        let reopened = records.compactMap(reopenTab)
        for split in act.splits { retile(split) }
        forget(act)
        let name = undo.isUndoing || undo.isRedoing ? act.name : shape == nil ? "Reopen Closed Tab" : "Reopen Closed Folder"
        let ids = reopened.map(\.id)
        let folder = shape?.nodes.first?.id
        let archives = act.archives
        undo.registerUndo(withTarget: self) { manager in
            manager.closeAgain(ids, folder: folder, as: ClosedAct(name: name, archives: archives))
        }
        undo.setActionName(name)
        return reopened.last
    }

    /// a split a close took panes from, tiled again over whichever of its panes are open
    private func retile(_ split: ClosedAct.Split) {
        guard let space = allSpaces.first(where: { space in space.tabs.contains { split.root.contains($0.id) } })
        else { return }
        let group = space.splitGroups.first { $0.id == split.id } ?? SplitGroup(id: split.id, root: split.root)
        group.root = split.root
        group.linkSourceID = split.linkSourceID
        group.linkTargetID = split.linkTargetID
        // a pane gone since, or tiled elsewhere since, stays out
        for id in group.tabIDs
        where !space.tabs.contains(where: { $0.id == id })
            || space.splitGroups.contains(where: { $0 !== group && $0.contains(id) })
        {
            group.removeLeaf(id)
        }
        space.splitGroups.removeAll { $0 === group }
        if group.leafCount >= SplitGroup.minPanes { space.splitGroups.append(group) }
        regroupContiguous(in: space)
        scheduleSave()
    }

    /// what a reopen brought back, closed again as one act: the folder when there was one
    private func closeAgain(_ ids: [BrowserTab.ID], folder: TabFolder.ID?, as act: ClosedAct) {
        if let folder, let held = allSpaces.lazy.compactMap({ $0.folder(folder) }).first {
            return closeFolder(held, act: act)
        }
        let tabs = allTabs.filter { ids.contains($0.id) }
        for tab in tabs where tab.isEssential { removeEssential(tab, act: act) }
        for space in allSpaces {
            let doomed = tabs.filter { tab in space.tabs.contains { $0 === tab } }
            guard !doomed.isEmpty else { continue }
            if act.archives {
                archiveAndClose(doomed, in: space, act: act)
            } else {
                for tab in doomed { close(tab, act: act, wakesSuccessor: false) }
            }
        }
        prepareCurrentSpace()
    }

    /// reopen one closed tab, whatever act it was part of
    @discardableResult
    func reopen(_ closed: ClosedTab) -> BrowserTab? {
        let tab = reopenTab(closed)
        if !closedTabs.contains(where: { $0.act === closed.act }), !closedFolders.contains(where: { $0.act === closed.act }) {
            forget(closed.act)
        }
        return tab
    }

    private func reopenTab(_ closed: ClosedTab) -> BrowserTab? {
        closedTabs.removeAll { $0.id == closed.id }
        // the tab takes its own id back, so what ⌘Z holds about where it sat still names it
        let id = allTabs.contains { $0.id == closed.id } ? UUID() : closed.id
        if let profileID = closed.profileID {
            guard let profile = core.profile(profileID) else { return nil }
            let tab = BrowserTab(id: id, restoring: closed.url, pinned: false, dataStore: profile.dataStore)
            tab.isEssential = true
            tab.pinnedURL = closed.pinnedURL ?? closed.url
            tab.customName = closed.customName
            tab.adopt(restoredTitle: closed.title)
            tab.adopt(interactionState: closed.interactionState)
            wire(tab)
            tab.prefetchFavicon()
            profile.essentials.insert(tab, at: min(closed.index, profile.essentials.count))
            ExtensionManager.shared.tabDidOpen(tab)
            // back in the space it was removed from, while that space is still its profile's
            if currentSpace.profileID != profileID,
                let home = spaces.first(where: { $0.id == closed.spaceID && $0.profileID == profileID })
            {
                selectSpace(home)
            }
            focus(tab)
            scheduleSave()
            return tab
        }
        // the space it came from, unless that space is gone too
        let space = spaces.first { $0.id == closed.spaceID } ?? currentSpace
        if space.id != selectedSpaceID { selectSpace(space) }

        let tab = BrowserTab(
            id: id, configuration: BrowserTab.defaultConfiguration(dataStore: dataStore(for: space)))
        tab.isPinned = closed.isPinned
        tab.pinnedURL = closed.pinnedURL
        tab.customName = closed.customName
        wire(tab)
        space.tabs.append(tab)
        // back into the folder it was filed in, rebuilding that folder if the
        // close took it too (undoing "close folder" gets the folder back)
        var container: SidebarContainer = .section(closed.isPinned ? .pinned : .today)
        if let folderID = closed.folderID {
            if space.folder(folderID) == nil {
                let folder = TabFolder(id: folderID, name: closed.folderName ?? "Folder")
                space.folders.append(folder)
                space.insertEntry(.folder(folderID), into: container, at: space.entries(in: container).count)
            }
            container = .folder(folderID)
        }
        space.insertEntry(.tab(tab.id), into: container, at: closed.index)
        space.normalizeTree()
        // what the close filed in the archive is open again
        core.profile(of: space).archive.forget { $0.id == closed.id }
        ExtensionManager.shared.tabDidOpen(tab)
        selectedTabID = tab.id

        if let state = closed.interactionState {
            // assigning the session blob *is* the navigation — WebKit replays the
            // entry rather than starting a fresh load, so the page comes back
            // where you left it
            tab.webView.interactionState = state
            // …unless WebKit declines a stale blob, in which case fall back to an
            // ordinary load so the tab never comes back blank
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak tab] in
                guard let tab, tab.webView.url == nil, !tab.webView.isLoading else { return }
                tab.load(closed.url)
            }
        } else {
            tab.load(closed.url)
        }
        scheduleSave()
        return tab
    }

    // MARK: - Site permissions

    /// the first queued question from a page this window owns; the queue is
    /// shared by every window
    var currentPermissionRequest: PermissionRequest? {
        permissionQueue.first { owns($0.tabID) }
    }

    /// is `id` a page this window is responsible for
    private func owns(_ id: BrowserTab.ID?) -> Bool {
        guard let id else { return kind == .main }
        if onScreenTabIDs.contains(id) { return true }
        guard kind == .main else { return false }
        return spaces.contains { $0.tabs.contains { $0.id == id } }
            || core.allEssentials.contains { $0.id == id }
    }

    /// the remembered answer to all of `permissions`; one "no" is a no, so a page that asked
    /// for camera *and* microphone doesn't get half of it
    private static func remembered(
        _ permissions: [SitePermission], origin: String, ephemeral: Bool
    ) -> PermissionDecision? {
        let decisions = permissions.map { SitePermissionStore.shared.decision(for: origin, $0, ephemeral: ephemeral) }
        guard decisions.allSatisfy({ $0 != nil }) else { return nil }
        return decisions.contains(.deny) ? .deny : .allow
    }

    /// A page asked for something. Answer from memory if this site has been
    /// asked before, otherwise put the question to the user; a question already
    /// waiting from the same page gets the one answer
    func requestPermission(
        _ permissions: [SitePermission], origin: String, tab: BrowserTab?,
        decide: @escaping (PermissionDecision) -> Void
    ) {
        let isEphemeral = tab?.isPrivate ?? false
        if let decision = Self.remembered(permissions, origin: origin, ephemeral: isEphemeral) {
            return decide(decision)
        }
        if let waiting = permissionQueue.first(where: {
            $0.tabID == tab?.id && $0.origin == origin && $0.permissions == permissions
        }) {
            return waiting.alsoAnswer(decide)
        }
        permissionQueue.append(
            PermissionRequest(
                origin: origin, permissions: permissions, tabID: tab?.id,
                isEphemeral: isEphemeral, respond: decide))
    }

    /// answer the question on screen. `remember` is the "don't ask again for
    /// this site" case — an unremembered answer covers this request only
    func answerPermission(_ decision: PermissionDecision, remember: Bool) {
        guard let index = permissionQueue.firstIndex(where: { owns($0.tabID) }) else { return }
        let request = permissionQueue.remove(at: index)
        if remember {
            for permission in request.permissions {
                SitePermissionStore.shared.set(
                    decision, for: request.origin, permission, ephemeral: request.isEphemeral)
            }
        }
        request.answer(decision)
        guard remember else { return }
        // the site's other waiting questions that this answer now settles
        let settled = permissionQueue.compactMap { queued in
            Self.remembered(queued.permissions, origin: queued.origin, ephemeral: queued.isEphemeral).map { (queued, $0) }
        }
        permissionQueue.removeAll { queued in settled.contains { $0.0 === queued } }
        for (queued, decision) in settled { queued.answer(decision) }
    }

    /// what a tab removed for good still holds: pending permission and dialog callbacks,
    /// the mini-player, its saved page state, extensions' view of it, any window's selection
    func letGo(of tab: BrowserTab) {
        abandonQuestions(of: tab)
        miniPlayer.exitIfActive(for: tab)
        // a closed page can outlive its tab (a view still fading out holds it): it must fall silent now
        tab.webView.pauseAllMediaPlayback(completionHandler: nil)
        tab.webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        tab.stopLoading()
        TabStateStore.remove(tab.id)
        ExtensionManager.shared.tabDidClose(tab)
        for manager in BrowserWindows.shared.allManagers { manager.forgetSelection(of: tab.id) }
    }

    /// a page going away takes its unanswered questions and its notifications with
    /// it — WebKit is still holding a handler for each question, and it has to be called
    private func abandonQuestions(of tab: BrowserTab) {
        let doomed = permissionQueue.filter { $0.tabID == tab.id }
        permissionQueue.removeAll { $0.tabID == tab.id }
        for request in doomed { request.abandon() }
        WebNotifications.shared.forgetPage(in: tab.id)
        tab.abandonDialog()
    }

    // MARK: - Peek / Glance

    /// open `url` in the floating Peek preview (⇧-click a link). reuses the open
    /// preview if there is one. born in the current space's jar so logins carry over.
    func peek(_ url: URL) {
        if let existing = peekTab {
            // a repeat of the open link must not restart its page
            if existing.url != url, existing.lastAttemptedURL != url { existing.load(url) }
            return
        }
        let config = BrowserTab.defaultConfiguration(dataStore: dataStore(for: currentSpace))
        let tab = BrowserTab(configuration: config)
        wire(tab)
        core.windowLocal.add(tab)
        tab.load(url)
        peekTab = tab
    }

    /// dismiss the Peek preview, stopping its web view so nothing keeps playing
    func closePeek() {
        guard let peek = peekTab else { return }
        abandonQuestions(of: peek)
        peek.stopLoading()
        core.windowLocal.remove(peek)
        peekTab = nil
    }

    /// promote the Peek preview into a real tab in the current space. The live page
    /// moves over (scroll, forms, playback) when it shares the space's jar, else reloads there
    @discardableResult
    func promotePeek(select: Bool = true) -> BrowserTab? {
        guard let peek = peekTab, let url = peek.url ?? peek.lastAttemptedURL else {
            closePeek()
            return nil
        }
        guard peek.dataStore === dataStore(for: currentSpace) else {
            closePeek()
            return newTab(url: url, select: select)
        }
        peekTab = nil
        core.windowLocal.remove(peek)
        insert(peek, into: currentSpace, select: select)
        return peek
    }

    /// promote the Peek preview and tile it beside the selected tab, or just open
    /// it when there's nothing to pair it with
    func splitPeekWithCurrent() {
        let current = selectedTab
        guard let promoted = promotePeek(select: false) else { return }
        guard let current, !current.isEssential,
            currentSpace.tabs.contains(where: { $0.id == current.id })
        else {
            selectedTabID = promoted.id
            return
        }
        createSplit([current, promoted], anchor: current)
    }

    /// where a modified click from this window really opens. A Scout holds one page
    /// and draws no Peek: ⇧ loads in place (nil), its tabs open in the browser proper.
    /// A private page never reaches Scout, and a private Scout's links load in place
    func destination(of click: LinkClick, isPrivate: Bool) -> LinkClick? {
        switch click {
        case .peek where kind == .scout: nil
        case .peek: .peek
        case _ where kind == .scout && isPrivate: nil
        case .scout: isPrivate ? .backgroundTab : .scout
        case .split where kind == .scout: .backgroundTab
        default: click
        }
    }

    /// a link clicked with modifiers held
    private func openLink(_ url: URL, as click: LinkClick, from tab: BrowserTab?) {
        switch destination(of: click, isPrivate: tab?.isPrivate == true) {
        case nil:
            tab?.load(url)
        case .peek:
            peek(url)
        case .scout:
            ScoutWindow.open(url, like: tab.flatMap(space(of:)) ?? currentSpace)
        case .foregroundTab where kind == .scout:
            if let browser = BrowserWindows.shared.browserScope {
                browser.revealTab(browser.newTab(url: url, select: true))
            }
        case .foregroundTab:
            newTab(url: url, select: true)
        case .split:
            openBeside(newTab(url: url, select: false))
        case .backgroundTab where kind == .scout:
            BrowserWindows.shared.browserScope?.newTab(url: url, select: false)
        case .backgroundTab:
            newTab(url: url, select: false)
        }
    }

    /// tile `tab` beside the focused page: another pane when a split is shown,
    /// else a new split. just shows `tab` when there's nothing to pair it with
    func openBeside(_ tab: BrowserTab) {
        guard let current = selectedTab, current.id != tab.id, !current.isEssential,
            !tab.isEssential
        else {
            focus(tab)
            return
        }
        if let group = displayedSplitGroup {
            addToSplit(group, tab: tab)
        } else {
            createSplit([current, tab], anchor: current)
        }
    }

    // MARK: - Scout (external links)

    /// open `url` as a real tab in `space`, switching to that space and bringing
    /// the app forward
    func adoptIntoBrowser(_ url: URL, into space: Space) {
        if space.id != selectedSpaceID { selectSpace(space) }
        revealTab(newTab(url: url))
    }

    /// the space that best fits `url`: a routing rule's, else one already holding
    /// a tab on the same base domain, else the current space. `profile` keeps the
    /// choice among its own spaces, the first standing in for a current one outside it
    func preferredSpace(for url: URL, in profile: Profile.ID? = nil) -> Space {
        func fits(_ space: Space) -> Bool { profile == nil || space.profileID == profile }
        let home = fits(currentSpace) ? currentSpace : spaces.first(where: fits) ?? currentSpace
        if let routed = routedSpace(for: url), fits(routed) { return routed }
        guard let target = Self.baseDomain(of: url) else { return home }
        // the home space wins ties, so an unrelated link stays put
        if spaceHosts(home).contains(target) { return home }
        return spaces.first { fits($0) && spaceHosts($0).contains(target) } ?? home
    }

    /// the space a routing rule sends this url to, if one claims it and still
    /// names a space that exists
    func routedSpace(for url: URL) -> Space? {
        guard let rule = RoutingStore.shared.rule(for: url) else { return nil }
        return spaces.first { $0.id == rule.spaceID }
    }

    /// base domains of every tab a space holds (pinned + today)
    private func spaceHosts(_ space: Space) -> Set<String> {
        Set(space.tabs.compactMap { tab in
            (tab.url ?? tab.lastAttemptedURL ?? tab.pinnedURL).flatMap(Self.baseDomain)
        })
    }

    /// the registrable domain, so subdomains group together (`docs.github.com` →
    /// `github.com`, `bbc.co.uk` stays whole); the host itself for an IP or a bare name
    private static func baseDomain(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return PasswordStore.registrableDomain(host) ?? host
    }

    /// the pinned/today split is a position as much as a flag: pinning lands at
    /// the foot of the pins, unpinning at the top of Today
    func togglePin(_ tab: BrowserTab) {
        let pin = !tab.isPinned
        guard let space = allSpaces.first(where: { $0.tabs.contains { $0.id == tab.id } }) else {
            tab.isPinned = pin
            tab.pinnedURL = pin ? (tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL) : nil
            if pin { requestTidyName(for: tab) }
            scheduleSave()
            return
        }
        recordingLayout(pin ? "Pin Tab" : "Unpin Tab") {
            moveTab(
                tab, in: space, to: .section(pin ? .pinned : .today),
                at: pin ? space.pinnedEntries.count : 0)
        }
    }

    /// "–" on an open pinned tab or favourite: the page goes dormant at its pinned url
    /// and the tab stays where it is; selection moves off it as a close would
    func closeAndKeepPinned(_ tab: BrowserTab) {
        guard tab.isPinned || tab.isEssential else { return }
        if let state = tab.persistableInteractionState {
            // ⌘Z wakes it back on the page it was on
            let id = tab.id
            undo.registerUndo(withTarget: self) { manager in
                guard let tab = manager.allTabs.first(where: { $0.id == id }) else { return }
                tab.adopt(interactionState: state)
                tab.hasUnsavedState = true
                manager.focus(tab)
                manager.undo.registerUndo(withTarget: manager) { manager in
                    if let tab = manager.allTabs.first(where: { $0.id == id }) { manager.closeAndKeepPinned(tab) }
                }
                manager.undo.setActionName("Close Tab")
            }
            undo.setActionName("Close Tab")
        }
        if tab.id == selectedTab?.id { closeAddressEdit() }
        if tab.isEssential {
            tab.closeToPinned()
            forgetEssentials([tab])
            scheduleSave()
            return
        }
        let space = self.space(of: tab) ?? currentSpace
        // a pinned split sleeps whole and stays a split: showing any pane wakes them all
        let group = space.splitGroup(containing: tab.id)
        tab.closeToPinned()
        // it is a dormant pin now, not a page: no window should still be on it
        for manager in BrowserWindows.shared.allManagers {
            for id in group?.tabIDs ?? [tab.id] { manager.forgetSelection(of: id) }
        }
        if let selected = space.selectedTabID, selected == tab.id || group?.contains(selected) == true {
            // pick the nearest tab that's still open; a row of dormant pins
            // is nothing to land on
            let index = space.tabs.firstIndex { $0.id == tab.id } ?? 0
            let open = space.tabs.enumerated().filter {
                !$0.element.isDormantPin && group?.contains($0.element.id) != true
            }
            let nearest = open.min { abs($0.offset - index) < abs($1.offset - index) }
            space.selectedTabID = nearest?.element.id
            space.selectedTab?.activateIfNeeded()
            settleSelection()
        }
        scheduleSave()
    }

    /// a split pins and unpins as one: at the foot of the pins, or the top of Today
    func togglePin(_ group: SplitGroup) {
        let space = currentSpace
        let members = space.tabs(in: group)
        guard let first = members.first else { return }
        let pin = !first.isPinned
        recordingLayout(pin ? "Pin Split" : "Unpin Split") {
            moveGroup(group, to: .section(pin ? .pinned : .today), at: pin ? space.pinnedEntries.count : 0)
        }
        if pin { members.forEach(requestTidyName) }
    }

    // MARK: - Favourites (essentials)

    /// promote a space tab into the profile's favourites grid, or demote a
    /// favourite back into the current space. the tab instance (and its live
    /// web view) is preserved across the move, so nothing reloads
    func toggleEssential(_ tab: BrowserTab) {
        guard kind == .main else { return }
        recordingLayout(tab.isEssential ? "Move to Tabs" : "Add to Favourites") {
            if tab.isEssential {
                essentials.removeAll { $0.id == tab.id }
                tab.isEssential = false
                currentSpace.tabs.append(tab)
                currentSpace.normalizeTree()
                selectedTabID = tab.id  // lands as the current space's selected tab
                forgetEssentials([tab])
            } else {
                // a favourite belongs to no space, so it can't stay tiled in a split
                detachFromSplit(tab)
                // pull it out of whichever space currently holds it
                for space in spaces {
                    space.tabs.removeAll { $0.id == tab.id }
                    space.normalizeTree()
                }
                tab.isEssential = true
                tab.isPinned = false
                tab.pinnedURL = tab.pinnedURL ?? tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL
                essentials.append(tab)
                requestTidyName(for: tab)
                // any space that just lost its selected tab gets a fresh one
                for space in spaces where space.selectedTab == nil {
                    space.selectedTabID = space.firstOpenTab?.id
                }
                showEssential(tab.id)
                tab.activateIfNeeded()
            }
            scheduleSave()
        }
    }

    /// fully remove a favourite from the grid (the ✕ on its tile)
    func removeEssential(_ tab: BrowserTab, act: ClosedAct? = nil) {
        rememberClosed(tab, from: nil, act: act ?? ClosedAct(name: "Remove from Favourites"))
        for profile in profiles { profile.essentials.removeAll { $0.id == tab.id } }
        SpotlightIndex.forget(.items([tab.id]))
        letGo(of: tab)
        forgetEssentials([tab])
        scheduleSave()
    }

    /// move a favourite to an absolute slot in the grid (drag-to-reorder, any
    /// position). `index` is the target slot once the tab itself is removed
    func reorderEssential(_ tab: BrowserTab, to index: Int) {
        guard let from = essentials.firstIndex(where: { $0.id == tab.id }) else { return }
        recordingLayout("Move Favourite") {
            let moved = essentials.remove(at: from)
            essentials.insert(moved, at: max(0, min(index, essentials.count)))
        }
        scheduleSave()
    }

    /// promote a space tab into the favourites grid at a specific slot
    func promoteEssential(_ tab: BrowserTab, at index: Int) {
        guard kind == .main else { return }
        guard !tab.isEssential else {
            reorderEssential(tab, to: index)
            return
        }
        recordingLayout("Add to Favourites") {
            detachFromSplit(tab)
            for space in spaces {
                space.tabs.removeAll { $0.id == tab.id }
                space.normalizeTree()
            }
            tab.isEssential = true
            tab.isPinned = false
            tab.pinnedURL = tab.pinnedURL ?? tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL
            essentials.insert(tab, at: max(0, min(index, essentials.count)))
            for space in spaces where space.selectedTab == nil {
                space.selectedTabID = space.firstOpenTab?.id
            }
            showEssential(tab.id)
            tab.activateIfNeeded()
            scheduleSave()
        }
    }

    /// demote a favourite back into the current space's tabs at a chosen spot
    func demoteEssential(_ tab: BrowserTab, to container: SidebarContainer, at index: Int) {
        guard tab.isEssential else { return }
        recordingLayout("Move to Tabs") {
            essentials.removeAll { $0.id == tab.id }
            tab.isEssential = false
            // moveTab adopts it into the current space and slots it in
            moveTab(tab, to: container, at: index)
            selectedTabID = tab.id
            forgetEssentials([tab])
        }
    }

    /// send an off-pinned tab back to its anchored url, and focus it; one at home only gains focus
    func returnToPinnedURL(_ tab: BrowserTab) {
        guard let pinnedURL = tab.pinnedURL else { return }
        selectedTabID = tab.id
        if tab.isOffPinnedURL { tab.load(pinnedURL) }
        isCommandBarVisible = false
    }

    /// split an off-pinned tab into the page you navigated to and its pinned
    /// anchor, kept and placed per the user's settings; focus follows the page
    func separateFromPinned(_ tab: BrowserTab) {
        guard tab.isOffPinnedURL, let deviated = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL,
            let pinnedURL = tab.pinnedURL
        else { return }
        recordingLayout("Separate from Pinned") {
            let separatedURL: URL
            let deviationStaysInPinned: Bool
            switch PinnedSeparationKeep.current {
            case .pinnedStays:
                // the existing pinned tab snaps back to its anchor; the page you
                // navigated to splits off
                tab.load(pinnedURL)
                separatedURL = deviated
                deviationStaysInPinned = false
            case .deviationStays:
                // the page you navigated to becomes the pinned tab, re-anchored here;
                // the original pinned url splits off
                tab.pinnedURL = deviated
                separatedURL = pinnedURL
                deviationStaysInPinned = true
            }

            let separated = newTab(url: separatedURL, select: false)
            place(separated, at: PinnedSeparationDestination.current, near: tab)

            // keep viewing the page you'd navigated to, wherever it now lives
            selectedTabID = deviationStaysInPinned ? tab.id : separated.id
            isCommandBarVisible = false
            scheduleSave()
        }
    }

    /// "Make This the Pinned Page" and the favourite's: the tab's home becomes `url`
    func rehome(_ tab: BrowserTab, at url: URL) {
        recordingLayout(tab.isEssential ? "Change Favourite's Page" : "Change Pinned Page") { tab.pinnedURL = url }
        scheduleSave()
    }

    func toggleKeepsLoaded(_ tab: BrowserTab) {
        let id = tab.id
        undo.registerUndo(withTarget: self) { manager in
            if let tab = manager.allTabs.first(where: { $0.id == id }) { manager.toggleKeepsLoaded(tab) }
        }
        // an undo's redo is the act it undid
        undo.setActionName(tab.keepsLoaded != undo.isUndoing ? "Stop Keeping Loaded" : "Keep Loaded")
        tab.keepsLoaded.toggle()
        scheduleSave()
    }

    /// move a freshly-created split-off tab to its destination — beside its
    /// anchor, in whatever folder the anchor is in, or at either end of Today
    private func place(_ tab: BrowserTab, at destination: PinnedSeparationDestination, near anchor: BrowserTab) {
        let space = currentSpace
        space.removeEntry(.tab(tab.id))
        switch destination {
        case .pinnedAbove, .pinnedBelow:
            tab.isPinned = true
            if tab.pinnedURL == nil {
                tab.pinnedURL = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL
            }
            requestTidyName(for: tab)
            let container = space.parent(of: .tab(anchor.id)) ?? .section(.pinned)
            let anchorIndex =
                space.entries(in: container).firstIndex(of: .tab(anchor.id))
                ?? space.entries(in: container).count - 1
            space.insertEntry(
                .tab(tab.id), into: container,
                at: destination == .pinnedAbove ? anchorIndex : anchorIndex + 1)
        case .todayTop:
            tab.isPinned = false
            space.insertEntry(.tab(tab.id), into: .section(.today), at: 0)
        case .todayBottom:
            tab.isPinned = false
            space.insertEntry(.tab(tab.id), into: .section(.today), at: space.todayEntries.count)
        }
        space.normalizeTree()
    }

    /// drag-to-reorder within a space: `index` is a slot among `container`'s own
    /// children, once the tab has been lifted out of where it was. dragging a
    /// split pane's row out in the sidebar pulls it from the split
    func moveTab(
        _ tab: BrowserTab, in target: Space? = nil, to container: SidebarContainer, at index: Int
    ) {
        recordingLayout("Move Tab") {
            let space = target ?? currentSpace
            // a tab another space still holds (a drag carried across a space switch) moves over
            if !tab.isEssential, !space.tabs.contains(where: { $0.id == tab.id }) {
                moveTab(tab, toSpace: space)
                if space.id == currentSpace.id { selectedTabID = tab.id }
            }
            detachFromSplit(tab)
            // a favourite dragged back into the list joins the space here
            if !space.tabs.contains(where: { $0.id == tab.id }) { space.tabs.append(tab) }
            let pinned = space.section(of: container) == .pinned
            let becamePinned = pinned && !tab.isPinned
            tab.isPinned = pinned
            // becoming pinned anchors to the current spot; leaving drops the anchor
            if pinned, tab.pinnedURL == nil {
                tab.pinnedURL = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL
            }
            // pinning by drag asks for a tidy name
            if becamePinned { requestTidyName(for: tab) }
            space.moveEntry(.tab(tab.id), to: container, at: index)
            space.normalizeTree()
            // a reorder can land a tab amid another group's run — pull groups back
            // together so each stays one contiguous block
            regroupContiguous(in: space)
            scheduleSave()
        }
    }

    func selectNextTab() { shiftSelection(by: 1) }
    func selectPreviousTab() { shiftSelection(by: -1) }

    /// ⌘1–⌘8: jump to the Nth row of the sidebar, favourites first — the order
    /// you see, not the order the model happens to store
    func selectSidebarItem(at index: Int) {
        // the rows on screen: a collapsed folder or a split is one of them, and
        // what a folder hides is not there to be jumped to
        let rows = essentials + currentSpace.visibleRows.compactMap(\.tabs.first)
        guard rows.indices.contains(index) else { return }
        selectedTabID = rows[index].id
        isCommandBarVisible = false
    }

    /// ⌃⇥: the `offset`th most recently used other tab, by `lastAccessed`
    func selectRecentTab(offset: Int) {
        let reachable = core.allEssentials.filter { tab in spaces.contains { $0.profileID == tab.profileID } }
        let pool = kind == .main ? reachable + spaces.flatMap(\.tabs) : currentSpace.tabs
        let recent = pool
            .filter { $0.id != selectedTabID }
            .sorted { $0.lastAccessed > $1.lastAccessed }
        guard !recent.isEmpty else { return }
        let index = min(max(offset - 1, 0), recent.count - 1)
        // a recent tab can live in another space or profile — focus goes there first
        focus(recent[index])
    }

    /// ⌘⇧K: archive the space's Today tabs, keeping whatever any window or the
    /// mini-player shows and tabs in a split or a folder
    func clearTodayTabs() {
        let space = currentSpace
        let keep = visibleTabIDs
        let doomed = space.todayTabs.filter {
            !keep.contains($0.id) && space.splitGroup(containing: $0.id) == nil
                && !space.isFoldered($0.id)
        }
        guard !doomed.isEmpty else { return }
        archiveAndClose(doomed, in: space, act: ClosedAct(name: "Clear Today's Tabs", archives: true))
    }

    /// file `doomed` in the archive and close them as `act`
    private func archiveAndClose(_ doomed: [BrowserTab], in space: Space, act: ClosedAct) {
        SpotlightIndex.forget(.items(Set(doomed.map(\.id))))
        for tab in doomed {
            if !tab.isPrivate, let url = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL {
                core.profile(of: space).archive.add(
                    id: tab.id, url: url, title: tab.displayTitle, spaceName: space.name, name: tab.customName)
            }
            rememberClosed(tab, from: space, act: act)
            detachFromSplit(tab)
            letGo(of: tab)
            space.tabs.removeAll { $0.id == tab.id }
        }
        space.normalizeTree()
        if space.selectedTab == nil { space.selectedTabID = space.firstOpenTab?.id }
        prepareCurrentSpace()
        scheduleSave()
    }

    /// a second copy of a page, where the original stays put
    @discardableResult
    func duplicateTab(_ tab: BrowserTab) -> BrowserTab? {
        guard let url = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL else { return nil }
        return newTab(url: url)
    }

    private func shiftSelection(by offset: Int) {
        let space = currentSpace
        guard !space.tabs.isEmpty,
            let index = space.tabs.firstIndex(where: { $0.id == selectedTabID(in: space) })
        else { return }
        let next = (index + offset + space.tabs.count) % space.tabs.count
        selectedTabID = space.tabs[next].id
    }

    /// every callback acts on `tab.manager` when it fires: a shared tab's window
    /// is whichever has it then, not the one that made it
    func wire(_ tab: BrowserTab) {
        tab.maker = self
        tab.isShared = kind == .main
        tab.onRequestNewTab = { [weak tab] configuration, features in
            guard let tab, let owner = tab.manager else { return nil }
            // a page that asked for a sized window (a sign-in flow) gets one, and
            // so does anything opened from a Scout window — it has no tab strip
            // to put a second page in. the configuration carries the opener's jar
            if owner.kind == .scout || ScoutWindow.wantsOwnWindow(features) {
                return ScoutWindow.openPopup(configuration: configuration, features: features)
            }
            // beside its opener, whose jar it carries; shown only where that space is
            let home = owner.space(of: tab) ?? owner.currentSpace
            return owner.newTab(configuration: configuration, select: home === owner.currentSpace, in: home).webView
        }
        tab.onRequestClose = { [weak tab] in
            guard let tab, let owner = tab.manager else { return }
            // a Scout window *is* its page: closing the page closes the window
            if owner.kind == .scout {
                BrowserWindows.shared.window(of: owner)?.performClose(nil)
            } else {
                owner.close(tab)
            }
        }
        tab.onOpenLink = { [weak tab] url, click in
            tab?.manager?.openLink(url, as: click, from: tab)
        }
        // renaming keys off the settled title: at `didFinish` it is often still empty
        tab.onDidSettleTitle = { [weak tab] url, title in
            guard let tab, !tab.isPrivate else { return }
            tab.manager?.tidyTitle(for: tab, url: url, title: title)
        }
        tab.onDidNavigate = { [weak tab] url, title in
            guard let tab, let owner = tab.manager else { return }
            // neither incognito nor a diagnostic run, whose hundreds of pages aren't the user's, leaves
            // history; a lab copy's self-test does, into data of its own
            let diagnostic = !SelfTest.isRequested && ProcessInfo.processInfo.environment["ARTEMIS_DIAG"] != nil
            owner.scheduleSave()
            if !diagnostic, let profile = owner.core.profile(tab.profileID) {
                profile.history.record(url: url, title: title)
                owner.indexPageText(tab, into: profile.pageIndex, url: url, title: title)
            }
            if tab.id == owner.selectedTabID { owner.offerHandoff() }
        }
    }

    /// advertise the page on screen to the user's other devices. a locked space
    /// shows none of its pages, so it offers none either
    func offerHandoff() {
        guard let tab = selectedTab, activeEssentialID != nil || !SpaceLock.shared.isLocked(currentSpace)
        else { return continuity.withdraw() }
        continuity.offer(tab.url ?? tab.pendingURL, title: tab.displayTitle, isPrivate: tab.isPrivate)
    }

    var continuity: Continuity { core.continuity }

    // MARK: - Auto-archive

    /// sweep once now, then every 5 minutes, for stale Today tabs — and for
    /// background tabs worth putting to sleep
    private func startArchiveSweeps() {
        archiveStaleTabs()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.archiveStaleTabs()
            self?.hibernateIdleTabs()
        }
        archiveTimer?.tolerance = 60
        watchMemoryPressure()
    }

    // MARK: - Hibernation

    /// minutes a background tab may idle before its web view is released (0 = never)
    static let hibernateAfterMinutesKey = "hibernateAfterMinutes"
    static let defaultHibernateAfterMinutes: Double = 30

    private var hibernateInterval: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: Self.hibernateAfterMinutesKey) as? Double
            ?? Self.defaultHibernateAfterMinutes
        return minutes * 60
    }

    /// tabs that must stay awake no matter how long they've idled: whatever is
    /// on screen right now (including every pane of a shown split), the focused
    /// favourite, the Peek preview and the mini-player's page
    private var visibleTabIDs: Set<BrowserTab.ID> {
        // every window's page counts, not just this one's: a sweep run from one
        // window must not release the page another window is showing
        var ids = onScreenTabIDs
        for manager in BrowserWindows.shared.allManagers { ids.formUnion(manager.onScreenTabIDs) }
        if let playing = miniPlayer.tab { ids.insert(playing.id) }
        // each space keeps the page it shows live, so switching back is instant
        for space in spaces { ids.formUnion([space.selectedTabID, space.selectedEssentialID].compactMap { $0 }) }
        return ids
    }

    /// what this window has on screen right now — its page, every pane of a shown
    /// split, its Peek preview, its Scout page
    var onScreenTabIDs: Set<BrowserTab.ID> {
        var ids: Set<BrowserTab.ID> = []
        if let selected = selectedTab { ids.insert(selected.id) }
        if let override = contentOverride { ids.insert(override.id) }
        if let peekTab { ids.insert(peekTab.id) }
        if let group = displayedSplitGroup { ids.formUnion(group.tabIDs) }
        if let privateSpace { ids.formUnion(privateSpace.tabs.map(\.id)) }
        return ids
    }

    /// release the web view of any background tab left untouched past the
    /// threshold. the tab stays in the sidebar exactly as it was — selecting it
    /// restores scroll position and form state from its interaction blob
    private func hibernateIdleTabs() {
        let interval = hibernateInterval
        guard interval > 0 else { return }
        let cutoff = Date(timeIntervalSinceNow: -interval)
        let keep = visibleTabIDs
        for tab in allTabs where !keep.contains(tab.id) && tab.lastAccessed < cutoff {
            tab.hibernate()
        }
    }

    /// critical memory pressure sleeps every eligible background tab at once; a warning, which
    /// macOS raises often, only those idle a quarter of the chosen wait (five minutes at least), none at Never
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let keep = self.visibleTabIDs
            let critical = source?.data.contains(.critical) == true
            let idle = Date(timeIntervalSinceNow: -max(300, self.hibernateInterval / 4))
            var slept = 0
            for tab in self.allTabs where !keep.contains(tab.id) && (critical || self.hibernateInterval > 0 && tab.lastAccessed < idle) {
                if tab.canHibernate {
                    tab.hibernate()
                    slept += 1
                }
            }
            debugLog("memory pressure: hibernated \(slept) tabs")
        }
        source.resume()
        memoryPressureSource = source
    }

    /// file every Today tab untouched past its profile's threshold in the archive.
    /// nothing a window or the mini-player shows, and no space's selected tab, is touched
    func archiveStaleTabs() {
        let now = Date()
        let keep = visibleTabIDs
        var didChange = false

        // each space ages out on its own profile's clock
        for space in spaces {
            let interval = core.profile(of: space).archiveAfterHours * 3600
            guard interval > 0 else { continue }
            let stale = space.todayTabs.filter { tab in
                !keep.contains(tab.id)
                    // a tab tiled in a split is in active use — never auto-archive it
                    && space.splitGroup(containing: tab.id) == nil
                    // a tab filed in a folder was put there on purpose
                    && !space.isFoldered(tab.id)
                    && now.timeIntervalSince(tab.lastAccessed) >= interval
            }
            guard !stale.isEmpty else { continue }
            SpotlightIndex.forget(.items(Set(stale.map(\.id))))
            for tab in stale {
                if let url = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL {
                    core.profile(of: space).archive.add(
                        id: tab.id, url: url, title: tab.title, spaceName: space.name, name: tab.customName)
                }
                letGo(of: tab)
                space.tabs.removeAll { $0.id == tab.id }
            }
            space.normalizeTree()
            if space.selectedTab == nil {
                space.selectedTabID = space.firstOpenTab?.id
            }
            didChange = true
        }

        if didChange {
            prepareCurrentSpace()
            scheduleSave()
        }
    }

    /// reopen an archived tab in the current space and drop it from the archive
    func restoreFromArchive(_ entry: ArchiveEntry) {
        let tab = newTab(url: entry.url)
        if !tab.isPrivate { tab.customName = entry.name }
        archive.remove(entry)
    }

    // MARK: - Spaces

    /// true when the last switch moved to a space further right in the row, so
    /// the sidebar can push the tab list the matching way (carousel)
    private(set) var spaceSwitchForward = true
    /// whether the last switch slid the strip to its space; a committed swipe
    /// arrives with the strip already there
    @ObservationIgnored private(set) var switchSlides = false

    func selectSpace(_ space: Space, animatePosition: Bool = true) {
        guard kind == .main, space.id != selectedSpaceID, spaces.contains(where: { $0.id == space.id }) else { return }
        switchSlides = false
        selectedTab?.touch()
        if let from = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
            let to = spaces.firstIndex(where: { $0.id == space.id })
        {
            spaceSwitchForward = to >= from
        }
        selectedSpaceID = space.id
        // where the next launch — and the next window — starts
        core.persistedSpaceID = space.id
        // a staged split selection is per-space; leaving the space discards it
        clearSelection()
        closeAddressEdit()
        // the real selection now matches any release-time content override; drop
        // it so the web card reads straight from selectedTab again
        endContentSwitch()
        scheduleSave()
        // lands on what this window last showed here: a favourite or the space's own tab
        prepareCurrentSpace()
        selectedTab?.touch()
        // the switch, not the sidebar's pager, drives the backdrop cross-fade, so it
        // runs with the sidebar collapsed; a live swipe drives the position itself
        if animatePosition {
            animateSpacePosition(to: spaces.firstIndex(where: { $0.id == space.id }))
        }
    }

    /// glide both positions to a space index at the sidebar pager's pace (same
    /// key), so a shown filmstrip slides in step with the backdrop
    private func animateSpacePosition(to index: Int?) {
        guard let index else { return }
        let target = Double(index)
        guard target != spacePagePosition else { return }
        let duration =
            UserDefaults.standard.object(forKey: "spaceTransitionDuration") as? Double ?? 0.2
        // a jump of any length slides one slot (see `stripSpaces`): start one
        // slot short, with the origin drawn there
        let from = Int(spacePagePosition.rounded())
        if abs(index - from) > 1 {
            glideOrigin = from
            let start = target - (index > from ? 1 : -1)
            spacePagePosition = start
            backdropPosition = start
        }
        switchSlides = true
        glideToken += 1
        let token = glideToken
        // eased, not sprung, so the two positions move together without overshoot
        withAnimation(.easeInOut(duration: duration)) {
            spacePagePosition = target
            backdropPosition = target
        } completion: {
            if token == self.glideToken { self.glideOrigin = nil }
        }
    }

    func selectSpace(at index: Int, animatePosition: Bool = true) {
        guard spaces.indices.contains(index) else { return }
        selectSpace(spaces[index], animatePosition: animatePosition)
    }

    /// step to an adjacent space (clamped at the ends), for swipe navigation
    func cycleSpace(by delta: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else { return }
        selectSpace(at: min(max(i + delta, 0), spaces.count - 1))
    }

    /// materialise a configured space — the creator dialog's "Create" (every
    /// value was chosen there first), and the only way a space comes to exist
    @discardableResult
    func createSpace(
        name: String, icon: String, appearance: SpaceAppearance, profileID: Profile.ID
    ) -> Space {
        let space = Space(name: name, icon: icon, appearance: appearance, profileID: profileID)
        spaces.append(space)
        selectSpace(space)
        newTab()  // start it with a fresh tab + url focus
        scheduleSave()
        registerDeleting(space.id, as: "New Space")
        return space
    }

    /// turn another browser's bookmarks into spaces of pinned tabs, one per folder
    /// plus one for loose links; favourites join the profile's. nothing opens, and
    /// importing twice adds nothing. returns the space to land in
    @discardableResult
    func importBookmarks(_ result: BookmarkImport.Result, into profileID: Profile.ID? = nil) -> Space? {
        undo.disableUndoRegistration()
        defer { undo.enableUndoRegistration() }
        let profile = core.profile(profileID) ?? currentProfile
        var landed = result.folders.map { pin($0.links, inSpaceNamed: $0.name, icon: $0.icon, profile: profile.id) }
        if !result.loose.isEmpty {
            landed.append(pin(result.loose, inSpaceNamed: "Imported", icon: nil, profile: profile.id))
        }
        addFavourites(result.favourites, to: profile)
        if let first = landed.first { selectSpace(first) }
        scheduleSave()
        return landed.first
    }

    /// appends the links not already favourites to the profile's grid, unloaded
    func addFavourites(_ links: [BookmarkImport.Link], to profile: Profile) {
        var known = Self.favouriteLinks(in: profile)
        for link in links where known.insert(link.url.absoluteString).inserted {
            let tab = BrowserTab(restoring: link.url, pinned: false, dataStore: profile.dataStore)
            tab.isEssential = true
            tab.pinnedURL = link.url
            tab.adopt(restoredTitle: link.title)
            wire(tab)
            tab.prefetchFavicon()
            profile.essentials.append(tab)
        }
    }

    /// the links an import counts as already a favourite: each one's home and the page it is on
    private static func favouriteLinks(in profile: Profile) -> Set<String> {
        Set(profile.essentials.flatMap { [$0.pinnedURL, $0.url ?? $0.pendingURL] }.compactMap { $0?.absoluteString })
    }

    private func pin(_ links: [BookmarkImport.Link], inSpaceNamed name: String, icon: String?, profile: Profile.ID)
        -> Space
    {
        let space = spaces.first { $0.name == name && $0.profileID == profile } ?? {
            let preset = SpacePreset.all[spaces.count % SpacePreset.all.count]
            let made = Space(name: name, icon: icon ?? "square.stack", appearance: preset.appearance, profileID: profile)
            spaces.append(made)
            return made
        }()
        var pinned = Set(space.pinnedTabs.compactMap { ($0.pinnedURL ?? $0.url ?? $0.pendingURL)?.absoluteString })
        let fresh = links.filter { pinned.insert($0.url.absoluteString).inserted }
        let store = dataStore(for: space)
        for link in fresh {
            let tab = BrowserTab(restoring: link.url, pinned: true, pinnedURL: link.url, dataStore: store)
            // the name it was filed under beats the page's own title
            tab.customName = link.title.isEmpty ? nil : link.title
            wire(tab)
            space.tabs.append(tab)
        }
        space.normalizeTree()
        if space.selectedTabID == nil { space.selectedTabID = space.tabs.first?.id }
        return space
    }

    /// Land another browser's import: its profiles, then its spaces beside the ones here with
    /// folders, splits and pins intact, its favourites and its archive. A space an earlier
    /// import made is left as it is. Returns the spaces made and how many favourites and archived tabs landed.
    @discardableResult
    func importBrowser(_ haul: ImportHaul) -> (spaces: [Space], favourites: Int, archived: Int) {
        undo.disableUndoRegistration()
        defer { undo.enableUndoRegistration() }
        adoptProfiles(haul.profiles)
        let made = haul.spaces.filter { data in !spaces.contains { $0.id == data.id } }.map { data in
            var data = data
            // a destination profile deleted mid-import: the space lands in the default one, as its cookies do
            if core.profile(data.profileID) == nil { data.profileID = Profile.defaultID }
            return Self.makeSpace(from: data)
        }
        for space in made {
            for tab in space.tabs {
                wire(tab)
                ExtensionManager.shared.tabDidOpen(tab)
                if let url = tab.pendingURL?.absoluteString, let title = haul.titles[url] {
                    tab.adopt(restoredTitle: title)
                }
            }
        }
        spaces.append(contentsOf: made)

        var favourites = 0
        for (id, links) in haul.favourites {
            let home = core.profile(id) ?? core.defaultProfile
            for link in links {
                let known = Self.favouriteLinks(in: home)
                guard let page = URL(string: link.url), let homeURL = URL(string: link.home ?? link.url),
                    !known.contains(homeURL.absoluteString), !known.contains(page.absoluteString)
                else { continue }
                let tab = BrowserTab(restoring: page, pinned: false, dataStore: home.dataStore)
                tab.isEssential = true
                tab.pinnedURL = homeURL
                tab.customName = link.name
                if let title = link.title, !title.isEmpty { tab.adopt(restoredTitle: title) }
                wire(tab)
                ExtensionManager.shared.tabDidOpen(tab)
                tab.prefetchFavicon()
                home.essentials.append(tab)
                favourites += 1
            }
        }
        let archived = haul.archive.reduce(0) { total, group in
            total + (core.profile(group.key) ?? core.defaultProfile).archive.merge(group.value)
        }
        if let first = made.first { selectSpace(first) }
        scheduleSave()
        return (made, favourites, archived)
    }

    func deleteSpace(_ space: Space) {
        guard spaces.count > 1,
            let index = spaces.firstIndex(where: { $0.id == space.id })
        else { return }
        // what ⌘Z rebuilds it from: letting go deletes each tab's saved session
        let data = spaceData(of: space)
        let pages = Dictionary(
            space.tabs.map { ($0.id, SavedPage(state: $0.persistableInteractionState, title: $0.title)) },
            uniquingKeysWith: { first, _ in first })
        spaces.remove(at: index)
        SpotlightIndex.forget(.items(Set([space.id] + space.tabs.map(\.id))))
        for tab in space.tabs { letGo(of: tab) }
        let rules = RoutingStore.shared.forget(spaceID: space.id)
        // only New Space's ⌘Z deletes while undoing
        let name = undo.isUndoing ? "New Space" : "Delete Space"
        undo.registerUndo(withTarget: self) { $0.restoreSpace(data, at: index, pages: pages, rules: rules, as: name) }
        undo.setActionName(name)
        let fallback = spaces[min(index, spaces.count - 1)].id
        if core.persistedSpaceID == space.id { core.persistedSpaceID = fallback }
        for window in mainWindows {
            // a glide in flight names a slot by its old index
            window.glideOrigin = nil
            window.essentialBySpace[space.id] = nil
            if window.selectedSpaceID == space.id {
                window.selectedSpaceID = fallback
                window.prepareCurrentSpace()
            }
            // removal reindexes the row: snap both positions to the selected slot
            if let i = spaces.firstIndex(where: { $0.id == window.selectedSpaceID }) {
                window.spacePagePosition = Double(i)
                window.backdropPosition = Double(i)
            }
        }
        scheduleSave()
    }

    /// a deleted space's tab as ⌘Z brings it back
    private struct SavedPage {
        let state: Any?
        let title: String
    }

    private func restoreSpace(
        _ data: SpaceData, at index: Int, pages: [BrowserTab.ID: SavedPage], rules: [(Int, RoutingRule)],
        as name: String
    ) {
        guard !spaces.contains(where: { $0.id == data.id }) else { return }
        var data = data
        if core.profile(data.profileID) == nil { data.profileID = Profile.defaultID }
        let space = Self.makeSpace(from: data)
        showEssential(data.selectedEssentialID, in: space)
        for tab in space.tabs {
            if let page = pages[tab.id] {
                tab.adopt(interactionState: page.state)
                tab.hasUnsavedState = true
                tab.adopt(restoredTitle: page.title)
            }
            wire(tab)
            ExtensionManager.shared.tabDidOpen(tab)
        }
        spaces.insert(space, at: min(index, spaces.count))
        RoutingStore.shared.reinsert(rules)
        for window in mainWindows {
            window.glideOrigin = nil
            if let i = spaces.firstIndex(where: { $0.id == window.selectedSpaceID }) {
                window.spacePagePosition = Double(i)
                window.backdropPosition = Double(i)
            }
        }
        selectSpace(space)
        LiveRefresh.shared.reschedule()
        scheduleSave()
        registerDeleting(space.id, as: name)
    }

    /// ⌘Z for New Space and the redo of Delete Space. a locked space is deleted only once
    /// its owner opens it, as the Delete menu item asks
    private func registerDeleting(_ id: Space.ID, as name: String) {
        undo.registerUndo(withTarget: self) { manager in
            guard let space = manager.spaces.first(where: { $0.id == id }) else { return }
            guard SpaceLock.shared.isLocked(space) else { return manager.deleteSpace(space) }
            Task {
                guard await SpaceLock.shared.unlock(space, to: "delete the \u{201C}\(space.name)\u{201D} space")
                else { return }
                manager.deleteSpace(space)
            }
        }
        undo.setActionName(name)
    }

    /// every browser window's model, this one first whether or not its window registered
    private var mainWindows: [TabManager] {
        [self] + BrowserWindows.shared.mainManagers.filter { $0 !== self }
    }

    func updateSpace(
        _ space: Space, name: String? = nil, icon: String? = nil,
        appearance: SpaceAppearance? = nil
    ) {
        // a theme preview wears a look without choosing it
        let change: String? =
            if let name, name != space.name { "Rename Space" }
            else if let icon, icon != space.icon { "Change Space Icon" }
            else if let appearance, appearance != space.appearance { "Change Space Theme" }
            else { nil }
        if previewRevert == nil, let change {
            let (id, oldName, oldIcon, oldAppearance) = (space.id, space.name, space.icon, space.appearance)
            undo.registerUndo(withTarget: self) { manager in
                guard let space = manager.allSpaces.first(where: { $0.id == id }) else { return }
                manager.updateSpace(
                    space, name: name.map { _ in oldName }, icon: icon.map { _ in oldIcon },
                    appearance: appearance.map { _ in oldAppearance })
            }
            undo.setActionName(change)
        }
        if let name { space.name = name }
        if let icon { space.icon = icon }
        if let appearance { space.appearance = appearance }
        scheduleSave()
    }

    /// move a space to another profile, rebuilding its tabs' web views in that
    /// profile's jar. the pages reload signed in as the new profile
    func setProfile(_ profileID: Profile.ID, for space: Space) {
        guard space.profileID != profileID, let profile = core.profile(profileID) else { return }
        let (id, old, shown) = (space.id, space.profileID, essential(in: space)?.id)
        undo.registerUndo(withTarget: self) { manager in
            guard let space = manager.spaces.first(where: { $0.id == id }) else { return }
            manager.setProfile(old, for: space)
            manager.showEssential(shown, in: space)
            if manager.currentSpace === space { manager.prepareCurrentSpace() }
        }
        // an undo's redo moves the space back to where it is now
        let target = undo.isUndoing ? core.profile(old) ?? profile : profile
        undo.setActionName("Move Space to \(target.name)")
        space.profileID = profileID
        let store = dataStore(for: space)
        for tab in space.tabs { tab.rebuildWebView(with: store) }
        // the favourite it showed belongs to the profile it left
        space.selectedEssentialID = nil
        for manager in mainWindows {
            manager.essentialBySpace[space.id] = nil
            if manager.currentSpace === space { manager.prepareCurrentSpace() }
        }
        scheduleSave()
    }

    // MARK: - Profiles

    @discardableResult
    func createProfile(name: String, icon: String) -> Profile {
        let profile = Profile(name: name, icon: icon)
        profiles.append(profile)
        scheduleSave()
        return profile
    }

    /// another browser's profiles, keeping the ids their spaces already name
    func adoptProfiles(_ incoming: [ProfileData]) {
        undo.disableUndoRegistration()
        defer { undo.enableUndoRegistration() }
        for data in incoming where core.profile(data.id) == nil {
            profiles.append(Self.makeProfile(from: data))
        }
        scheduleSave()
    }

    func updateProfile(_ profile: Profile, name: String? = nil, icon: String? = nil) {
        if let name { profile.name = name }
        if let icon { profile.icon = icon }
        scheduleSave()
    }

    /// delete a profile and everything it holds. its spaces move to the default
    /// profile first, so no tab is lost with it
    func deleteProfile(_ profile: Profile) {
        guard !profile.isDefault else { return }
        // its incognito windows close before the jar goes: a new page in one rebuilds the jar
        // through the parent's extension controller
        for manager in BrowserWindows.shared.allManagers
        where manager.kind == .incognito && manager.currentSpace.profileID == profile.id {
            BrowserWindows.shared.window(of: manager)?.close()
        }
        for space in spaces where space.profileID == profile.id {
            setProfile(Profile.defaultID, for: space)
        }
        forgetEssentials(profile.essentials)
        for tab in profile.essentials {
            letGo(of: tab)
            tab.stopLoading()
        }
        profile.essentials = []
        profiles.removeAll { $0.id == profile.id }
        SpotlightIndex.forget(.profile(profile.id))
        LiveSource.forget(profile.id)
        PasswordStore.shared.deleteAll(in: profile.id)
        AutofillStore.shared.deleteAll(in: profile.id)
        // before the jar goes: an extension controller still holding it keeps it on disk
        ExtensionManager.shared.profileDeleted(profile.id)
        let id = profile.id
        Task {
            await profile.pageIndex.close()
            try? FileManager.default.removeItem(at: Profile.directory(for: id))
        }
        ProfileStore.destroy(id)
        // what ⌘Z holds could name its tabs and jar
        clearAllUndo()
        scheduleSave()
    }

    /// the page the web card shows: from swipe release, the incoming space's tab,
    /// so the content moves with the slide; otherwise `selectedTab`
    var displayedContentTab: BrowserTab? { contentOverride ?? selectedTab }
    /// `displayedContentTab`, but nil while that is a locked space's own page
    var unlockedContentTab: BrowserTab? {
        SpaceLock.shared.unlocked(displayedContentTab, in: currentSpace)
    }
    private var contentOverride: BrowserTab?

    /// at swipe release: show the incoming space's already-mounted page until
    /// `selectedTab` catches up at settle
    func beginContentSwitch(toSpaceAt index: Int) {
        guard spaces.indices.contains(index) else { return }
        let space = spaces[index]
        contentSpaceID = space.id
        // a locked space shows none of its own pages: its lock screen takes over at settle
        guard essential(in: space) != nil || !SpaceLock.shared.isLocked(space) else {
            contentOverride = nil
            return
        }
        let incoming = shownPage(in: space)
        activateSplit(for: incoming, in: space)
        contentOverride = incoming
    }

    /// the space whose page is shown ahead of the switch committing (a swipe
    /// released, or a run of quick swipes), or nil when it is the current one
    private(set) var contentSpaceID: Space.ID?

    /// a swipe came back to the current space: show its own page again
    func endContentSwitch() {
        contentOverride = nil
        contentSpaceID = nil
    }

    /// the current space and its neighbours, the only spaces whose pages stay
    /// mounted; each web view costs 200 MB+
    func neighborSpaceIDs() -> Set<Space.ID> {
        let center = contentSpaceID ?? selectedSpaceID
        guard let i = spaces.firstIndex(where: { $0.id == center }) else { return [] }
        var ids: Set<Space.ID> = [spaces[i].id]
        for j in [i - 1, i + 1] where spaces.indices.contains(j) { ids.insert(spaces[j].id) }
        return ids
    }

    /// load the neighbouring spaces' active pages once a switch settles, so a
    /// later swipe mounts nothing mid-transition
    func hydrateNeighbors() {
        let center = contentSpaceID ?? selectedSpaceID
        guard let i = spaces.firstIndex(where: { $0.id == center }) else { return }
        for j in [i - 1, i + 1] where spaces.indices.contains(j) {
            activateSplit(for: shownPage(in: spaces[j]), in: spaces[j])
        }
    }

    /// give the current space a valid selection and warm it. a closed Scout or
    /// incognito window falls back onto the shared spaces, which it must leave alone
    func prepareCurrentSpace() {
        guard kind == .main || privateSpace != nil else { return }
        let space = currentSpace
        if space.selectedTab == nil, let first = space.firstOpenTab {
            space.selectedTabID = first.id
        }
        // warm what the space shows: its favourite, or its focused tab and every pane of its split
        activateSplit(for: selectedTab)
        settleSelection()
    }

    /// load every lazy pane of the split `tab` belongs to, or just `tab`; `space`
    /// is the one holding `tab`, the current one by default
    private func activateSplit(for tab: BrowserTab?, in space: Space? = nil) {
        guard let tab else { return }
        let space = space ?? currentSpace
        if let group = space.splitGroup(containing: tab.id) {
            for pane in space.tabs(in: group) { pane.activateIfNeeded() }
        } else {
            tab.activateIfNeeded()
        }
    }

    // MARK: - Split view

    /// the split shown in the content area, or nil for the single-tab view. shown
    /// only when the focused space tab belongs to a group and nothing is
    /// overriding the view (a focused favourite, or an in-flight space swipe)
    var displayedSplitGroup: SplitGroup? {
        guard activeEssentialID == nil, contentOverride == nil,
            let sel = selectedTabID(in: currentSpace)
        else { return nil }
        return currentSpace.splitGroup(containing: sel)
    }

    /// the live tabs of the shown split, in pane order
    private var displayedSplitTabs: [BrowserTab] {
        guard let group = displayedSplitGroup else { return [] }
        return currentSpace.tabs(in: group)
    }

    /// tabs marked with ⌘/⇧-click in the sidebar, the target of every bulk action
    var selection: Set<BrowserTab.ID> = []

    /// the selected tabs in list order, so a bulk action happens top to bottom
    var selectedTabs: [BrowserTab] {
        currentSpace.tabs.filter { selection.contains($0.id) }
    }

    /// ⌘-click toggles a tab in the selection, seeding it with the focused
    /// tab so the first ⌘-click already pairs two tabs
    func toggleSelection(_ tab: BrowserTab) {
        if selection.isEmpty, let sel = selectedTabID, sel != tab.id,
            currentSpace.tabs.contains(where: { $0.id == sel })
        {
            selection.insert(sel)
        }
        if selection.contains(tab.id) {
            selection.remove(tab.id)
        } else {
            selection.insert(tab.id)
        }
    }

    /// ⇧-click selects the range from the focused tab to `tab` (in list order)
    func extendSelection(to tab: BrowserTab) {
        // the range spans what you can see: a shift-click must never reach into
        // a folded folder and stage tabs for a bulk close you can't look at
        let ordered = currentSpace.visibleRows.flatMap(\.tabs)
        guard let target = ordered.firstIndex(where: { $0.id == tab.id }) else { return }
        guard let anchorID = selectedTabID,
            let anchor = ordered.firstIndex(where: { $0.id == anchorID })
        else {
            toggleSelection(tab)
            return
        }
        for i in min(anchor, target)...max(anchor, target) {
            selection.insert(ordered[i].id)
        }
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
    }

    // MARK: Acting on the selection

    /// close every selected tab as one act, so one ⇧⌘T brings them all back
    func closeSelection() {
        let doomed = selectedTabs
        guard !doomed.isEmpty else { return }
        let act = ClosedAct(name: doomed.count == 1 ? "Close Tab" : "Close \(doomed.count) Tabs")
        for tab in doomed { close(tab, act: act, wakesSuccessor: false) }
        prepareCurrentSpace()
        clearSelection()
    }

    /// the space's other Today tabs, or only those below `tab`, reopened together by ⌘⇧T
    func closeTodayTabs(besides tab: BrowserTab, onlyBelow: Bool) {
        let today = currentSpace.todayTabs
        guard let index = today.firstIndex(where: { $0.id == tab.id }) else { return }
        let doomed = onlyBelow ? Array(today[(index + 1)...]) : today.filter { $0.id != tab.id }
        let act = ClosedAct(name: onlyBelow ? "Close Tabs Below" : "Close Other Tabs")
        for other in doomed { close(other, act: act, wakesSuccessor: false) }
        prepareCurrentSpace()
    }

    func setPinnedForSelection(_ pinned: Bool) {
        let moving = selectedTabs.filter { $0.isPinned != pinned }
        let noun = moving.count == 1 ? "Tab" : "\(moving.count) Tabs"
        recordingLayout(pinned ? "Pin \(noun)" : "Unpin \(noun)") {
            // pinning appends each at the foot of the pins, unpinning puts each at the top of Today
            for tab in pinned ? moving : moving.reversed() { togglePin(tab) }
        }
        clearSelection()
    }

    func setMutedForSelection(_ muted: Bool) {
        for tab in selectedTabs where tab.isMuted != muted { tab.toggleMuted() }
        clearSelection()
    }

    /// put the selection to sleep now, sparing whatever is on screen
    func hibernateSelection() {
        let keep = visibleTabIDs
        for tab in selectedTabs where !keep.contains(tab.id) && tab.canHibernate {
            tab.hibernate()
        }
        clearSelection()
    }

    func moveSelection(to space: Space) {
        let moving = selectedTabs
        recordingLayout(moving.count == 1 ? "Move Tab" : "Move \(moving.count) Tabs") {
            for tab in moving { moveTab(tab, toSpace: space) }
        }
        clearSelection()
    }

    /// tile every tab in the split selection together, focusing the one that was
    /// already focused (or the first)
    func createSplitFromSelection() {
        let chosen = currentSpace.tabs.filter { selection.contains($0.id) }
        guard chosen.count >= SplitGroup.minPanes else { return }
        let anchor = chosen.first { $0.id == selectedTabID } ?? chosen.first
        createSplit(chosen, anchor: anchor)
        clearSelection()
    }

    /// tile `tabs` as a new split in the current space around `anchor`, which keeps
    /// its slot, section and focus; the rest join beside it in that section. nil
    /// if fewer than two valid panes
    @discardableResult
    func createSplit(
        _ tabs: [BrowserTab], anchor: BrowserTab? = nil,
        orientation: SplitOrientation? = nil
    ) -> SplitGroup? {
        recordingLayout("Split View") { () -> SplitGroup? in
            let space = currentSpace
            // de-dupe, keep order, only this space's own non-favourite tabs
            var members: [BrowserTab] = []
            for tab in tabs where !tab.isEssential
                && space.tabs.contains(where: { $0.id == tab.id })
                && !members.contains(where: { $0.id == tab.id }) {
                members.append(tab)
            }
            guard members.count >= SplitGroup.minPanes else { return nil }
            let members4 = Array(members.prefix(SplitGroup.maxPanes))
            let anchorTab = anchor.flatMap { a in members4.first { $0.id == a.id } } ?? members4[0]

            // members leave their old splits, which keep any two panes left behind
            for member in members4 { detachFromSplit(member) }
            gather(members4, anchor: anchorTab, in: space)
            // an anchor that was a middle pane leaves its old split's panes apart
            regroupContiguous(in: space)
            let group = SplitGroup(
                tabIDs: members4.map(\.id),
                orientation: orientation ?? SplitOrientation.defaultForNewSplits)
            // opt-in: new splits can start in linked mode (first pane's links open in
            // the second), set in Customization
            if UserDefaults.standard.bool(forKey: "defaultSplitLinked"), group.tabIDs.count >= 2 {
                group.linkSourceID = group.tabIDs[0]
                group.linkTargetID = group.tabIDs[1]
            }
            space.splitGroups.append(group)
            for member in members4 { member.activateIfNeeded() }
            selectedTabID = anchorTab.id
            scheduleSave()
            return group
        }
    }

    /// add `tab` as another pane in `group` at `index` (default: end), keeping
    /// the run contiguous at the group's current spot, and focus it. no-op past
    /// the pane cap
    func addToSplit(_ group: SplitGroup, tab: BrowserTab, at index: Int? = nil) {
        recordingLayout("Add to Split") {
            let space = currentSpace
            guard !tab.isEssential, !group.contains(tab.id),
                group.tabIDs.count < SplitGroup.maxPanes,
                space.tabs.contains(where: { $0.id == tab.id }),
                let anchor = space.tabs(in: group).first
            else { return }
            // pull it out of any other split first
            if let other = space.splitGroup(containing: tab.id), other.id != group.id {
                other.removeLeaf(tab.id)
                if other.leafCount < SplitGroup.minPanes { dissolveSplit(other) }
            }
            let slot = max(0, min(index ?? group.leafCount, group.leafCount))
            var members = space.tabs(in: group)
            members.insert(tab, at: min(slot, members.count))
            // anchor stays an existing pane, so the run keeps its place in the list
            gather(members, anchor: anchor, in: space)
            group.appendLeaf(tab.id, at: slot)
            tab.activateIfNeeded()
            selectedTabID = tab.id
            scheduleSave()
        }
    }

    /// drop `tab` into `group` beside a pane or at the group's outer edge, keeping
    /// the run contiguous, and focus it; no-op past the pane cap
    func addPane(_ tab: BrowserTab, to group: SplitGroup, target: SplitDropTarget) {
        recordingLayout("Add to Split") {
            let space = currentSpace
            guard !tab.isEssential, !group.contains(tab.id),
                group.leafCount < SplitGroup.maxPanes,
                space.tabs.contains(where: { $0.id == tab.id })
            else { return }
            // pull it out of any other split first
            if let other = space.splitGroup(containing: tab.id), other.id != group.id {
                other.removeLeaf(tab.id)
                if other.leafCount < SplitGroup.minPanes { dissolveSplit(other) }
            }
            switch target {
            case .paneEdge(let leaf, let edge):
                guard group.contains(leaf) else { return }
                group.insertLeaf(tab.id, beside: leaf, axis: edge.axis, before: edge.before)
            case .outerEdge(let edge):
                group.insertLeaf(tab.id, atOuterEdge: edge.axis, before: edge.before)
            }
            if UserDefaults.standard.autoResizeSplitOnDrag {
                group.root = group.root.balancedRatios()
            }
            // keep the group's panes contiguous in the tab list (anchor on an existing
            // pane, so the run keeps its place)
            let members = space.tabs(in: group)
            if let anchor = members.first(where: { $0.id != tab.id }) { gather(members, anchor: anchor, in: space) }
            tab.activateIfNeeded()
            selectedTabID = tab.id
            scheduleSave()
        }
    }

    /// start a split by dropping `tab` against the lone focused page on a given
    /// edge (the side + axis come from the edge) — the single-page content drop
    @discardableResult
    func createSplit(
        dropping tab: BrowserTab, onto focused: BrowserTab, edge: SplitBoxEdge
    ) -> SplitGroup? {
        let members = edge.before ? [tab, focused] : [focused, tab]
        return createSplit(members, anchor: focused, orientation: edge.axis)
    }

    /// remove a single pane from its split, keeping the tab open in the space.
    /// dissolves the split if it falls below two panes; focus moves to a
    /// surviving pane so the split stays on screen
    func removeFromSplit(_ tab: BrowserTab) {
        recordingLayout("Remove from Split") {
            let space = currentSpace
            guard let group = space.splitGroup(containing: tab.id) else { return }
            let wasFocused = selectedTabID == tab.id
            group.removeLeaf(tab.id)
            if group.leafCount < SplitGroup.minPanes {
                dissolveSplit(group)
            } else {
                if wasFocused, let survivor = group.tabIDs.first {
                    selectedTabID = survivor
                }
                // the removed pane still sits between the survivors in the tab order
                regroupContiguous(in: space)
            }
            scheduleSave()
        }
    }

    /// disband a split — its tabs stay open and where they are, just no longer
    /// tiled. focus is untouched (still on a former pane → single view)
    func dissolveSplit(_ group: SplitGroup) {
        recordingLayout("Unsplit") {
            for space in allSpaces { space.splitGroups.removeAll { $0.id == group.id } }
        }
        scheduleSave()
    }

    /// move a whole split (all panes, kept contiguous) to a new spot in the tab
    /// list — reordering it as a unit, like dragging a single tab. panes are
    /// coerced into the target pinned/today section
    func moveGroup(_ group: SplitGroup, to container: SidebarContainer, at index: Int) {
        recordingLayout("Move Split") {
            let space = currentSpace
            let members = group.tabIDs.compactMap { id in space.tabs.first { $0.id == id } }
            guard !members.isEmpty else { return }
            let pinned = space.section(of: container) == .pinned
            for member in members where pinned && member.pinnedURL == nil {
                member.pinnedURL = member.url ?? member.lastAttemptedURL ?? member.pendingURL
            }
            for member in members { space.removeEntry(.tab(member.id)) }
            var list = space.entries(in: container)
            list.insert(
                contentsOf: members.map { SidebarEntry.tab($0.id) },
                at: max(0, min(index, list.count)))
            space.setEntries(list, in: container)
            space.normalizeTree()
            scheduleSave()
        }
    }

    /// reorder a lifted pane back into its own split at a new slot, keeping the
    /// sidebar run contiguous and the pane focused — the drop end of pulling a
    /// single pane out and sliding it left/right within the split
    func movePaneInSplit(_ group: SplitGroup, tab: BrowserTab, to index: Int) {
        var order = group.tabIDs
        guard let from = order.firstIndex(of: tab.id), from != index else { return }
        // sidebar reordering is a 1-D gesture, so it flattens the (possibly 2-D)
        // tiling back to a single flat split in the new pane order
        order.remove(at: from)
        order.insert(tab.id, at: max(0, min(index, order.count)))
        recordingLayout("Rearrange Split") {
            group.flatten(order: order)
            let space = currentSpace
            let members = space.tabs(in: group)
            if let anchor = members.first { gather(members, anchor: anchor, in: space) }
        }
        selectedTabID = tab.id
        scheduleSave()
    }

    /// keep each split group's members contiguous in the tab order so the sidebar
    /// renders one unbroken block. pulls every group's tabs together at the
    /// position of its earliest member, preserving pane order
    private func regroupContiguous(in space: Space) {
        for group in space.splitGroups {
            let members = group.tabIDs.compactMap { id in space.tabs.first { $0.id == id } }
            guard members.count == group.tabIDs.count, let anchor = members.first else { continue }
            gather(members, anchor: anchor, in: space)
        }
    }

    /// a divider drag ended: its ratios land on the split's tree and are saved
    func commitSplitLayout(_ group: SplitGroup) {
        group.endResize()
        scheduleSave()
    }

    /// rearrange a split's panes by dropping one beside another (`axis`/`before`),
    /// against a whole-group outer edge, or onto another pane's centre to swap.
    /// the dragged pane stays focused
    func rearrangeSplit(_ group: SplitGroup, _ action: SplitRearrange) {
        recordingLayout("Rearrange Split") {
            // linking points at tab ids, so it survives a move — but `removeLeaf` drops
            // it when an endpoint is the moved pane; restore both ends after
            let savedSource = group.linkSourceID
            let savedTarget = group.linkTargetID
            switch action {
            case .besideLeaf(let dragged, let target, let axis, let before):
                guard dragged != target else { return }
                // pull the pane out first, then drop it into the new half — otherwise
                // it'd be duplicated (it's still in the tree)
                group.removeLeaf(dragged)
                group.insertLeaf(dragged, beside: target, axis: axis, before: before)
            case .outerEdge(let dragged, let axis, let before):
                group.removeLeaf(dragged)
                group.insertLeaf(dragged, atOuterEdge: axis, before: before)
            }
            if group.linkSourceID == nil, let savedSource, let savedTarget,
                group.contains(savedSource), group.contains(savedTarget)
            {
                group.linkSourceID = savedSource
                group.linkTargetID = savedTarget
            }
            // re-even every split level so the panes stay balanced (Settings toggle)
            if UserDefaults.standard.autoResizeSplitOnDrag {
                group.root = group.root.balancedRatios()
            }
            selectedTabID = action.draggedID
            scheduleSave()
        }
    }

    /// link `source`'s plain link clicks to open in the chosen `target` pane
    func setSplitLink(_ group: SplitGroup, source: BrowserTab.ID, target: BrowserTab.ID) {
        guard source != target, group.contains(source), group.contains(target) else { return }
        recordingLayout("Link Panes") {
            group.linkSourceID = source
            group.linkTargetID = target
        }
        scheduleSave()
    }

    /// drop a split's linking entirely
    func clearSplitLink(_ group: SplitGroup) {
        recordingLayout("Unlink Panes") {
            group.linkSourceID = nil
            group.linkTargetID = nil
        }
        scheduleSave()
    }

    /// group-level link toggle (sidebar block button): off → first pane feeds the
    /// second; on → independent again
    func toggleSplitLinked(_ group: SplitGroup) {
        if group.isLinked {
            clearSplitLink(group)
        } else {
            let ids = group.tabIDs
            if ids.count >= 2 { setSplitLink(group, source: ids[0], target: ids[1]) }
        }
    }

    /// route a plain link click from a split's link-source pane into its chosen
    /// target pane instead of navigating in place. returns true when it consumed
    /// the navigation (the caller cancels the in-pane load)
    func routeLinkedNavigation(from tab: BrowserTab, to url: URL) -> Bool {
        guard let space = space(of: tab), let group = space.splitGroup(containing: tab.id),
            group.isLinked, group.linkSourceID == tab.id,
            let targetID = group.linkTargetID,
            let target = space.tabs.first(where: { $0.id == targetID })
        else { return false }
        target.load(url)  // focus stays on the source so you can keep clicking
        return true
    }

    /// keyboard/menu split toggle: unsplit if a split is shown, otherwise tile
    /// the focused tab with a partner — the next tab in its section, or a fresh
    /// tab when it's the space's only one
    func toggleSplit() {
        let splits = selection.count >= SplitGroup.minPanes || displayedSplitGroup == nil
        recordingLayout(splits ? "Split View" : "Unsplit") {
            // a staged multi-selection wins — tile exactly those
            if selection.count >= SplitGroup.minPanes {
                createSplitFromSelection()
                return
            }
            if let group = displayedSplitGroup {
                dissolveSplit(group)
                return
            }
            guard let focused = selectedTab(in: currentSpace), !focused.isEssential else { return }
            let others = currentSpace.tabs.filter { $0.id != focused.id }
            let partner = others.first { $0.isPinned == focused.isPinned }
                ?? others.first
                ?? newTab(select: false)  // lone tab → split it with a new one
            createSplit([focused, partner], anchor: focused)
        }
    }

    /// cycle focus to the next/previous pane within the shown split (⌥⌘] / ⌥⌘[)
    func focusAdjacentPane(_ offset: Int) {
        guard let group = displayedSplitGroup,
            let sel = selectedTabID(in: currentSpace),
            let i = group.tabIDs.firstIndex(of: sel)
        else { return }
        let next = (i + offset + group.tabIDs.count) % group.tabIDs.count
        selectedTabID = group.tabIDs[next]
    }

    /// ⌃⇧1…4: focus a split pane by its position, left to right
    func focusPane(at index: Int) {
        guard let group = displayedSplitGroup, group.tabIDs.indices.contains(index)
        else { return }
        selectedTabID = group.tabIDs[index]
    }

    /// pull `members` together as consecutive siblings at `anchor`'s slot, in the
    /// given order, so the split draws as one unbroken row. members are coerced
    /// into the anchor's container — a split lives in exactly one of them
    private func gather(_ members: [BrowserTab], anchor: BrowserTab, in space: Space) {
        for member in members where member.id != anchor.id {
            space.removeEntry(.tab(member.id))
        }
        guard let (container, index) = space.removeEntry(.tab(anchor.id)) else { return }
        if space.section(of: container) == .pinned {
            for member in members where member.pinnedURL == nil {
                member.pinnedURL = member.url ?? member.lastAttemptedURL ?? member.pendingURL
            }
        }
        var list = space.entries(in: container)
        list.insert(contentsOf: members.map { SidebarEntry.tab($0.id) }, at: min(index, list.count))
        space.setEntries(list, in: container)
        space.normalizeTree()
    }

    // MARK: - Folders

    /// a new, empty folder in `space`, else the current one, or nil at the nesting cap.
    /// `live` makes it a live folder
    @discardableResult
    func newFolder(
        named name: String = "New Folder", in container: SidebarContainer = .section(.today),
        at index: Int? = nil, space: Space? = nil, live: LiveFolder? = nil
    ) -> TabFolder? {
        let space = space ?? currentSpace
        guard space.canNestFolder(in: container) else { return nil }
        return recordingLayout(live == nil ? "New Folder" : "New Live Folder") { () -> TabFolder in
            let folder = TabFolder(name: name)
            folder.live = live
            space.folders.append(folder)
            space.insertEntry(
                .folder(folder.id), into: container,
                at: index ?? space.entries(in: container).count)
            space.normalizeTree()
            scheduleSave()
            return folder
        }
    }

    /// "New Folder with N Tabs": the folder takes the topmost tab's slot, and the
    /// tabs move into it in the order they were shown
    @discardableResult
    func newFolder(with tabs: [BrowserTab]) -> TabFolder? {
        recordingLayout("New Folder") { () -> TabFolder? in
            let space = currentSpace
            let members = tabs.filter { tab in space.tabs.contains { $0.id == tab.id } }
            guard let first = members.first else { return nil }
            let container = space.parent(of: .tab(first.id)) ?? .section(.today)
            let index = space.entries(in: container).firstIndex(of: .tab(first.id)) ?? 0
            guard let folder = newFolder(in: container, at: index) else { return nil }
            for member in members {
                space.moveEntry(
                    .tab(member.id), to: .folder(folder.id), at: folder.children.count)
            }
            space.normalizeTree()
            clearSelection()
            scheduleSave()
            return folder
        }
    }

    func rename(_ folder: TabFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = folder.name
        folder.name = trimmed.isEmpty ? "New Folder" : trimmed
        guard folder.name != old else { return }
        let id = folder.id
        undo.registerUndo(withTarget: self) { manager in
            guard let folder = manager.allSpaces.lazy.compactMap({ $0.folder(id) }).first else { return }
            manager.rename(folder, to: old)
        }
        undo.setActionName("Rename Folder")
        scheduleSave()
    }

    /// "Stop Updating": the folder keeps its rows as plain tabs
    func stopUpdating(_ folder: TabFolder) {
        recordingLayout("Stop Updating") { folder.live = nil }
        scheduleSave()
    }

    /// opening a live folder refreshes it, unless it was tried in the last two minutes
    func setExpanded(_ folder: TabFolder, _ expanded: Bool) {
        folder.isExpanded = expanded
        scheduleSave()
        if expanded, let live = folder.live,
            -(live.attempted ?? live.fetched ?? .distantPast).timeIntervalSinceNow > 120,
            let space = spaces.first(where: { $0.folder(folder.id) === folder })
        {
            Task { await refreshLive(folder, in: space) }
        }
    }

    func setPinnedCollapsed(_ space: Space, _ collapsed: Bool) {
        space.pinnedCollapsed = collapsed
        scheduleSave()
    }

    /// move a folder — its whole subtree travels with it. a folder can't be
    /// dropped inside itself, which is the one move that would make the tree a cycle
    func moveFolder(_ folder: TabFolder, to container: SidebarContainer, at index: Int) {
        let space = currentSpace
        guard !space.container(container, isWithin: folder.id),
            space.canNest(folder, in: container)
        else { return }
        recordingLayout("Move Folder") {
            space.moveEntry(.folder(folder.id), to: container, at: index)
            space.normalizeTree()
        }
        scheduleSave()
    }

    /// dissolve the folder, its children rising into the folder's own slot
    func ungroup(_ folder: TabFolder) {
        let space = currentSpace
        recordingLayout("Ungroup Folder") {
            guard let (container, index) = space.removeEntry(.folder(folder.id)) else { return }
            var list = space.entries(in: container)
            list.insert(contentsOf: folder.children, at: min(index, list.count))
            space.setEntries(list, in: container)
            space.folders.removeAll { $0.id == folder.id }
            space.normalizeTree()
        }
        scheduleSave()
    }

    /// close everything filed under the folder and delete it as one act, so ⇧⌘T or ⌘Z
    /// brings back the whole thing, nested and empty folders included
    func closeFolder(_ folder: TabFolder, act: ClosedAct? = nil) {
        let space = allSpaces.first { $0.folder(folder.id) === folder } ?? currentSpace
        let act = act ?? ClosedAct(name: "Delete Folder")
        let container = space.parent(of: .folder(folder.id)) ?? .section(.today)
        let index = space.entries(in: container).firstIndex(of: .folder(folder.id)) ?? 0

        var nodes = [
            ClosedFolder.Node(
                id: folder.id, name: folder.name, isExpanded: folder.isExpanded, parent: nil, live: folder.live)
        ]
        func walk(_ parent: TabFolder) {
            for case .folder(let id) in parent.children {
                guard let child = space.folder(id) else { continue }
                nodes.append(
                    ClosedFolder.Node(
                        id: id, name: child.name, isExpanded: child.isExpanded, parent: parent.id,
                        live: child.live))
                walk(child)
            }
        }
        walk(folder)

        // close the tabs while the tree still says where each one lived
        let doomed = space.tabIDs(under: .folder(folder.id))
            .compactMap { id in space.tabs.first { $0.id == id } }
        for tab in doomed { close(tab, act: act, wakesSuccessor: false) }
        prepareCurrentSpace()

        space.removeEntry(.folder(folder.id))
        space.folders.removeAll { removed in nodes.contains { $0.id == removed.id } }
        space.normalizeTree()
        // incognito leaves no trace, the undo stack included
        if kind != .incognito {
            closedFolders.insert(
                ClosedFolder(
                    act: act, spaceID: space.id, container: container, index: index,
                    nodes: nodes, closedAt: Date()),
                at: 0)
            while closedFolders.count > Self.closedTabLimit {
                let dropped = closedFolders.removeLast()
                if !closedTabs.contains(where: { $0.act === dropped.act }) { forget(dropped.act) }
            }
            if !act.isRegistered { registerReopen(act) }
        }
        scheduleSave()
    }

    /// put a removed folder shape back, parents before children
    private func restore(_ closed: ClosedFolder) {
        guard let space = spaces.first(where: { $0.id == closed.spaceID }) else { return }
        for node in closed.nodes where space.folder(node.id) == nil {
            let folder = TabFolder(id: node.id, name: node.name, isExpanded: node.isExpanded)
            folder.live = node.live
            space.folders.append(folder)
            if let parent = node.parent, space.folder(parent) != nil {
                space.insertEntry(
                    .folder(node.id), into: .folder(parent),
                    at: space.entries(in: .folder(parent)).count)
            } else {
                // the folder it hung in may itself be gone by now
                var container = closed.container
                if case .folder(let id) = container, space.folder(id) == nil {
                    container = .section(.today)
                }
                space.insertEntry(.folder(node.id), into: container, at: closed.index)
            }
        }
        space.normalizeTree()
        LiveRefresh.shared.reschedule()
        scheduleSave()
    }

    /// drop a tab from whatever split it's in, in whichever space holds it (used
    /// when a tab leaves a space's tab list — closed, promoted to a favourite,
    /// archived). dissolves a split that falls below two panes
    private func detachFromSplit(_ tab: BrowserTab) {
        for space in allSpaces {
            guard let group = space.splitGroup(containing: tab.id) else { continue }
            group.removeLeaf(tab.id)
            if group.leafCount < SplitGroup.minPanes {
                space.splitGroups.removeAll { $0.id == group.id }
            }
            return
        }
    }

    // MARK: - Undoing layout

    /// runs `body` as one ⌘Z named `action` that puts back whatever it moved, pinned,
    /// filed or tiled; a call inside another joins it, and a change to nothing registers nothing
    @discardableResult
    private func recordingLayout<T>(_ action: String, _ body: () -> T) -> T {
        guard layoutDepth == 0, undo.isUndoRegistrationEnabled else { return body() }
        layoutDepth += 1
        let before = sidebarLayout()
        let result = body()
        layoutDepth -= 1
        registerLayout(LayoutChange(from: sidebarLayout(), to: before), as: action)
        return result
    }

    private func registerLayout(_ change: LayoutChange, as action: String) {
        guard !change.isEmpty else { return }
        undo.registerUndo(withTarget: self) { manager in
            let locked = manager.allSpaces.filter { SpaceLock.shared.isLocked($0) && change.spaces.contains($0.id) }
            guard !locked.isEmpty else { return manager.apply(change, as: action) }
            // past the prompt the redo lands on the undo stack, so a second ⌘Z puts it back
            Task {
                for space in locked {
                    guard await SpaceLock.shared.unlock(space, to: "undo \(action.lowercased())") else { return }
                }
                manager.apply(change, as: action)
            }
        }
        undo.setActionName(action)
    }

    /// every space and favourites grid this window reaches, by id
    private func sidebarLayout() -> SidebarLayout {
        var layout = SidebarLayout()
        for space in allSpaces {
            layout.lists[.init(owner: space.id, container: .section(.pinned))] = space.pinnedEntries
            layout.lists[.init(owner: space.id, container: .section(.today))] = space.todayEntries
            for folder in space.folders {
                layout.lists[.init(owner: space.id, container: .folder(folder.id))] = folder.children
                layout.folders[folder.id] = .init(
                    space: space.id, name: folder.name, isExpanded: folder.isExpanded, live: folder.live)
            }
            for group in space.splitGroups {
                layout.splits[group.id] = .init(
                    space: space.id, root: group.root, linkSourceID: group.linkSourceID,
                    linkTargetID: group.linkTargetID)
            }
            for tab in space.tabs { layout.anchors[tab.id] = tab.pinnedURL }
            layout.selections[space.id] = selectedTabID(in: space)
            layout.favourites[space.id] = essential(in: space)?.id
        }
        for profile in profiles {
            layout.lists[.init(owner: profile.id, container: nil)] = profile.essentials.map { .tab($0.id) }
            for tab in profile.essentials { layout.anchors[tab.id] = tab.pinnedURL }
        }
        return layout
    }

    /// bring back `change.to` wherever the change differs, leaving what moved elsewhere since
    /// alone, and register the way back as the redo
    private func apply(_ change: LayoutChange, as action: String) {
        layoutDepth += 1
        defer { layoutDepth -= 1 }
        let (from, to, moved) = (change.from, change.to, change.moved)
        let spaces = allSpaces
        var live: [BrowserTab.ID: BrowserTab] = [:]
        for tab in spaces.flatMap(\.tabs) + core.allEssentials where live[tab.id] == nil { live[tab.id] = tab }

        func discard(_ tab: BrowserTab) {
            detachFromSplit(tab)
            for space in spaces { space.tabs.removeAll { $0 === tab } }
            live[tab.id] = nil
            SpotlightIndex.forget(.items([tab.id]))
            letGo(of: tab)
        }
        // a tab the change opened closes, and the redo opens it again
        var closed: [BrowserTab.ID: LayoutChange.Page] = [:]
        for id in from.tabIDs.subtracting(to.tabIDs) {
            guard let tab = live[id] else { continue }
            if !tab.isPrivate {
                closed[id] = .init(
                    url: tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL, title: tab.title, name: tab.customName,
                    state: tab.persistableInteractionState)
            }
            discard(tab)
        }
        for (id, page) in change.opened where live[id] == nil {
            guard let owner = to.lists.first(where: { $0.value.contains(.tab(id)) })?.key.owner,
                let store = spaces.first(where: { $0.id == owner }).map(dataStore(for:))
                    ?? core.profile(owner)?.dataStore
            else { continue }
            let tab =
                page.url.map { BrowserTab(id: id, restoring: $0, pinned: false, dataStore: store) }
                ?? BrowserTab(id: id, configuration: BrowserTab.defaultConfiguration(dataStore: store))
            tab.customName = page.name
            tab.adopt(restoredTitle: page.title)
            tab.adopt(interactionState: page.state)
            tab.hasUnsavedState = true
            wire(tab)
            ExtensionManager.shared.tabDidOpen(tab)
            live[id] = tab
        }

        // lift what moved. a folder the change made goes, and what was filed in it since stays
        // where it sat, all but a live folder's own rows
        for space in spaces {
            for entry in moved where space.parent(of: entry) != nil {
                guard case .folder(let id) = entry, to.folders[id] == nil, let folder = space.folder(id),
                    let (container, index) = space.removeEntry(entry)
                else {
                    space.removeEntry(entry)
                    continue
                }
                var slot = index
                for child in folder.children where !moved.contains(child) {
                    if case .tab(let tab) = child, folder.live?.items[tab] != nil, let tab = live[tab] {
                        discard(tab)
                        continue
                    }
                    space.insertEntry(child, into: container, at: slot)
                    slot += 1
                }
                folder.live?.items = [:]
                folder.live?.fetched = nil
                space.folders.removeAll { $0 === folder }
            }
        }
        var lifted: [(Profile, BrowserTab)] = []
        for profile in profiles {
            lifted += profile.essentials.filter { moved.contains(.tab($0.id)) }.map { (profile, $0) }
            profile.essentials.removeAll { moved.contains(.tab($0.id)) }
        }

        // each moved entry goes in after the nearest of its old neighbours still there
        func slot(after list: ArraySlice<SidebarEntry>, in here: [SidebarEntry]) -> Int {
            list.last { here.contains($0) }.flatMap { here.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        }
        for space in spaces {
            func adopt(_ entry: SidebarEntry) -> Bool {
                switch entry {
                case .tab(let id):
                    guard let tab = live[id] else { return false }
                    guard !space.tabs.contains(where: { $0 === tab }) else { return true }
                    for other in spaces { other.tabs.removeAll { $0 === tab } }
                    lifted.removeAll { $0.1 === tab }
                    tab.isEssential = false
                    tab.rebuildWebView(with: dataStore(for: space))
                    space.tabs.append(tab)
                    return true
                case .folder(let id):
                    if space.folder(id) != nil { return true }
                    guard let shape = to.folders[id], shape.space == space.id else { return false }
                    let folder = TabFolder(id: id, name: shape.name, isExpanded: shape.isExpanded)
                    folder.live = shape.live
                    space.folders.append(folder)
                    return true
                }
            }
            func place(_ container: SidebarContainer) {
                let list = to.lists[.init(owner: space.id, container: container)] ?? []
                for (i, entry) in list.enumerated() {
                    if moved.contains(entry), space.parent(of: entry) == nil, adopt(entry) {
                        let at = slot(after: list[..<i], in: space.entries(in: container))
                        space.insertEntry(entry, into: container, at: at)
                    }
                    if case .folder(let id) = entry, space.folder(id) != nil { place(.folder(id)) }
                }
            }
            place(.section(.pinned))
            place(.section(.today))
        }
        for profile in profiles {
            let list = to.lists[.init(owner: profile.id, container: nil)] ?? []
            for (i, entry) in list.enumerated() where moved.contains(entry) {
                guard case .tab(let id) = entry, let tab = live[id],
                    !profile.essentials.contains(where: { $0 === tab })
                else { continue }
                for space in spaces {
                    space.removeEntry(entry)
                    space.tabs.removeAll { $0 === tab }
                }
                lifted.removeAll { $0.1 === tab }
                tab.isEssential = true
                tab.isPinned = false
                tab.rebuildWebView(with: profile.dataStore)
                let at = slot(after: list[..<i], in: profile.essentials.map { .tab($0.id) })
                profile.essentials.insert(tab, at: at)
            }
        }
        // a favourite with nowhere to go stays a favourite
        for (profile, tab) in lifted { profile.essentials.append(tab) }

        for (id, shape) in to.folders where from.folders[id] != shape {
            guard let folder = spaces.lazy.compactMap({ $0.folder(id) }).first else { continue }
            folder.name = shape.name
            folder.isExpanded = shape.isExpanded
            if folder.live !== shape.live { folder.live = shape.live }
        }
        for id in Set(from.splits.keys).union(to.splits.keys) where from.splits[id] != to.splits[id] {
            let shape = to.splits[id]
            for space in spaces where space.id != shape?.space { space.splitGroups.removeAll { $0.id == id } }
            guard let shape, let space = spaces.first(where: { $0.id == shape.space }) else { continue }
            let group = space.splitGroups.first { $0.id == id } ?? SplitGroup(id: id, root: shape.root)
            if !space.splitGroups.contains(where: { $0 === group }) { space.splitGroups.append(group) }
            group.root = shape.root
            group.linkSourceID = shape.linkSourceID
            group.linkTargetID = shape.linkTargetID
        }
        for id in Set(from.anchors.keys).union(to.anchors.keys) where from.anchors[id] != to.anchors[id] {
            live[id]?.pinnedURL = to.anchors[id]
        }

        for space in spaces {
            // every pane is its space's own, and in one split only
            var tiled = Set<BrowserTab.ID>()
            for group in space.splitGroups {
                for id in group.tabIDs
                where !space.tabs.contains(where: { $0.id == id }) || !tiled.insert(id).inserted {
                    group.removeLeaf(id)
                }
            }
            space.splitGroups.removeAll { $0.leafCount < SplitGroup.minPanes }
            space.normalizeTree()
            regroupContiguous(in: space)
            if let id = to.selections[space.id], id != from.selections[space.id],
                space.tabs.contains(where: { $0.id == id })
            {
                setSelectedTab(id, in: space)
            } else if space.selectedTab == nil {
                space.selectedTabID = space.firstOpenTab?.id
            }
            if to.favourites[space.id] != from.favourites[space.id] { showEssential(to.favourites[space.id], in: space) }
        }
        let favourites = Set(profiles.flatMap(\.essentials).map(\.id))
        for space in spaces where space.selectedEssentialID.map(favourites.contains) == false {
            space.selectedEssentialID = nil
        }
        for window in mainWindows {
            window.essentialBySpace = window.essentialBySpace.filter { favourites.contains($0.value) }
            window.prepareCurrentSpace()
        }
        // a live folder back from a ⌘Z fills again
        for (id, shape) in to.folders where shape.live != nil && from.folders[id] == nil {
            guard let space = spaces.first(where: { $0.id == shape.space }), let folder = space.folder(id) else {
                continue
            }
            Task { await refreshLive(folder, in: space) }
        }
        LiveRefresh.shared.reschedule()
        scheduleSave()
        registerLayout(LayoutChange(from: to, to: from, opened: closed), as: action)
    }

    // MARK: - Persistence

    /// persist the session. the disk write happens off the main thread — this is
    /// called on every navigation, tab move and space switch
    func save() {
        SessionStore.saveInBackground(sessionSnapshot())
        saveTabStates()
        SpotlightIndex.scheduleRefresh()
    }

    /// persist synchronously, for app termination, where a background write dies
    /// with the process
    func saveNow() {
        SessionStore.save(sessionSnapshot())
        saveTabStates(immediately: true)
    }

    /// rebuild every space from `session.json` through the launch path, once a
    /// backup restore has written it, in every browser window
    func reloadFromDisk() {
        guard let session = SessionStore.load(), !session.spaces.isEmpty else { return }
        let rebuilt = session.spaces.map(Self.makeSpace(from:))
        let old = spaces.flatMap(\.tabs) + core.allEssentials
        if let shown = miniPlayer.tab, old.contains(where: { $0 === shown }) { miniPlayer.dismiss() }
        // a close's teardown, less TabStateStore.remove: a restored tab can carry the same id
        for tab in old {
            abandonQuestions(of: tab)
            ExtensionManager.shared.tabDidClose(tab)
            tab.stopLoading()
        }

        profiles = session.profiles.map(Self.makeProfile(from:))
        spaces = rebuilt
        selectedSpaceID = session.selectedSpaceID.flatMap { id in
            rebuilt.contains { $0.id == id } ? id : nil
        } ?? rebuilt[0].id
        core.persistedSpaceID = selectedSpaceID

        let restored = spaces.flatMap(\.tabs) + core.allEssentials
        if !session.namesOnTabs {
            TabNameStore.shared.handOverCustomNames(to: restored, archives: profiles.map(\.archive))
        }
        for tab in restored { wire(tab) }
        for tab in core.allEssentials { tab.prefetchFavicon() }
        TabStateStore.sweep(keeping: Set(spaces.flatMap(\.tabs).map(\.id)))
        for tab in restored { ExtensionManager.shared.tabDidOpen(tab) }
        for window in mainWindows {
            window.essentialBySpace = rememberedEssentials
            window.endContentSwitch()
            window.shownTabBySpace = [:]
            if !spaces.contains(where: { $0.id == window.selectedSpaceID }) { window.selectedSpaceID = selectedSpaceID }
            // nothing animates a restore, so the carousel and the backdrop have to be
            // put on the restored slot by hand or they park on the old one
            if let i = spaces.firstIndex(where: { $0.id == window.selectedSpaceID }) {
                window.spacePagePosition = Double(i)
                window.backdropPosition = Double(i)
            }
            window.prepareCurrentSpace()
        }
        ProfileStore.reconcile(keeping: Set(profiles.map(\.id)))
        LiveRefresh.shared.reschedule()
        clearAllUndo()
    }

    /// move a tab into another space (a drag onto its icon); the live page moves
    /// as is within a profile and rebuilds in the new jar across profiles
    func moveTab(_ tab: BrowserTab, toSpace destination: Space) {
        guard !tab.isEssential,
            let source = spaces.first(where: { space in space.tabs.contains { $0.id == tab.id } }),
            source.id != destination.id
        else { return }
        recordingLayout("Move Tab") {
            detachFromSplit(tab)
            let wasSelected = source.selectedTabID == tab.id
            source.tabs.removeAll { $0.id == tab.id }
            if wasSelected { source.selectedTabID = source.firstOpenTab?.id }

            // a pinned tab lands in the destination's pinned run
            source.normalizeTree()
            destination.tabs.insert(
                tab, at: tab.isPinned ? destination.pinnedTabs.count : destination.tabs.count)
            destination.normalizeTree()
            destination.selectedTabID = tab.id
            tab.rebuildWebView(with: dataStore(for: destination))
            tab.touch()
            if selectedSpaceID == source.id { prepareCurrentSpace() }
            scheduleSave()
        }
    }

    /// one space as the session stores it; `appearance` stands in for a theme being previewed
    private func spaceData(of space: Space, appearance: SpaceAppearance? = nil) -> SpaceData {
        // a tab with no url yet (a command bar left open) is not persistable.
        // Both the records and the split pane indices come off this one
        // filtered list, or a dropped tab shifts every pane index by one
        let saved = (space.pinnedTabs + space.todayTabs).filter { tabURL($0) != nil }
        let slot = Dictionary(saved.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let records = saved.map { tab in
            let url = tabURL(tab) ?? ""
            return TabRecord(
                id: tab.id, url: url,
                pinnedURL: tab.isPinned ? (tab.pinnedURL?.absoluteString ?? url) : nil,
                isPinned: tab.isPinned, lastAccessed: tab.lastAccessed,
                keepsLoaded: tab.keepsLoaded, name: tab.customName)
        }
        // splits store their tiling tree, with each pane as an index into the
        // same list; the flat fields are kept too for downgrade safety
        let splitData = space.splitGroups.compactMap { group -> SplitGroupData? in
            let indexOf: (BrowserTab.ID) -> Int? = { slot[$0] }
            guard let tree = group.root.toData(indexOf: indexOf) else { return nil }
            let indices = group.tabIDs.compactMap(indexOf)
            guard indices.count >= SplitGroup.minPanes else { return nil }
            let srcIndex = group.linkSourceID.flatMap(indexOf)
            let dstIndex = group.linkTargetID.flatMap(indexOf)
            return SplitGroupData(
                id: group.id, tree: tree,
                tabIDs: group.tabIDs.filter { indexOf($0) != nil }, tabIndices: indices,
                orientation: group.primaryAxis, ratios: [],
                linkSourceID: srcIndex == nil ? nil : group.linkSourceID,
                linkTargetID: dstIndex == nil ? nil : group.linkTargetID,
                linkSourceIndex: srcIndex, linkTargetIndex: dstIndex)
        }
        // an empty folder is written out — unlike a split, which is dropped
        // once it falls below two panes
        func entryData(_ list: [SidebarEntry], depth: Int) -> [EntryData] {
            guard depth <= Space.maxFolderDepth else { return [] }
            return list.compactMap { entry -> EntryData? in
                switch entry {
                case .tab(let id):
                    return slot[id] != nil ? EntryData(kind: "tab", id: id) : nil
                case .folder(let id):
                    guard let folder = space.folder(id) else { return nil }
                    return EntryData(
                        kind: "folder", id: id, name: folder.name,
                        expanded: folder.isExpanded,
                        children: entryData(folder.children, depth: depth + 1),
                        live: folder.live?.data(for: folder, in: space))
                }
            }
        }
        return SpaceData(
            id: space.id, name: space.name, icon: space.icon,
            appearance: appearance ?? space.appearance, profileID: space.profileID,
            splitGroups: splitData, tabs: records,
            selectedTabID: saved.first { $0.id == space.selectedTabID }?.id,
            selectedEssentialID: space.selectedEssentialID,
            pinnedEntries: entryData(space.pinnedEntries, depth: 0),
            todayEntries: entryData(space.todayEntries, depth: 0),
            requiresUnlock: space.requiresUnlock, pinnedCollapsed: space.pinnedCollapsed)
    }

    /// the session exactly as it stands — the shape both the on-disk save and the
    /// export file are built from
    func sessionSnapshot() -> BrowsingSession {
        let previewed = Dictionary(
            BrowserWindows.shared.allManagers.compactMap { manager in
                manager.resumeGradientEdit.flatMap { edit in manager.previewRevert.map { (edit.id, $0) } }
            },
            uniquingKeysWith: { first, _ in first })
        let data = spaces.map { spaceData(of: $0, appearance: previewed[$0.id]) }
        return BrowsingSession(
            profiles: profiles.map { profile in
                ProfileData(
                    id: profile.id, name: profile.name, icon: profile.icon,
                    favourites: profile.essentials.compactMap { tab in
                        tabURL(tab).map { url in
                            TabRecord(
                                id: tab.id, url: url, pinnedURL: tab.pinnedURL?.absoluteString ?? url,
                                lastAccessed: tab.lastAccessed, keepsLoaded: tab.keepsLoaded, name: tab.customName)
                        }
                    },
                    searchEngine: profile.isDefault ? nil : profile.searchEngine.rawValue,
                    searchSuggestions: profile.isDefault ? nil : profile.suggestsSearches,
                    archiveAfterHours: profile.isDefault ? nil : profile.archiveAfterHours)
            },
            spaces: data,
            essentialURLs: core.defaultProfile.essentials.compactMap { tab in
                tabURL(tab).map { tab.pinnedURL?.absoluteString ?? $0 }
            },
            selectedSpaceID: core.persistedSpaceID ?? selectedSpaceID)
    }

    /// write each shared-space tab's `interactionState` to its own file, so a
    /// restored tab keeps its scroll position, back/forward list and form
    /// contents; an incognito window's blobs are never written
    private func saveTabStates(immediately: Bool = false) {
        for space in spaces {
            for tab in space.tabs where tabURL(tab) != nil && (immediately || tab.hasUnsavedState) {
                tab.hasUnsavedState = false
                TabStateStore.save(
                    tab.persistableInteractionState, for: tab.id, immediately: immediately)
            }
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func tabURL(_ tab: BrowserTab) -> String? {
        (tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL)?.absoluteString
    }

    private static func makeProfile(from data: ProfileData) -> Profile {
        // the default profile's settings are the app-wide keys, which it reads itself
        let own = data.id != Profile.defaultID
        let profile = Profile(
            id: data.id, name: data.name, icon: data.icon,
            searchEngine: own ? data.searchEngine.flatMap(SearchEngine.init) : nil,
            suggestsSearches: own ? data.searchSuggestions : nil,
            archiveAfterHours: own ? data.archiveAfterHours : nil)
        profile.essentials = data.favourites.compactMap { record in
            guard let url = URL(string: record.url) else { return nil }
            let tab = BrowserTab(
                id: record.id, restoring: url, pinned: false, lastAccessed: record.lastAccessed,
                dataStore: profile.dataStore)
            tab.isEssential = true
            tab.pinnedURL = record.pinnedURL.flatMap(URL.init(string:)) ?? url
            tab.keepsLoaded = record.keepsLoaded
            tab.customName = record.name
            return tab
        }
        return profile
    }

    static func makeSpace(from data: SpaceData) -> Space {
        // resolve the space's jar up front so its restored tabs are born in it
        let profileID = data.profileID ?? Profile.defaultID
        let store = ProfileStore.dataStore(for: profileID)
        // pinned first, then today: the order the split pane indices are relative to
        let ordered = data.tabs.filter(\.isPinned) + data.tabs.filter { !$0.isPinned }
        let tabs = ordered.compactMap { record -> BrowserTab? in
            guard let url = URL(string: record.url) else { return nil }
            let tab = BrowserTab(
                id: record.id, restoring: url, pinned: record.isPinned,
                pinnedURL: record.pinnedURL.flatMap(URL.init(string:)),
                lastAccessed: record.lastAccessed, dataStore: store)
            tab.keepsLoaded = record.keepsLoaded
            tab.customName = record.name
            return tab
        }
        for tab in tabs { tab.adopt(interactionState: TabStateStore.load(tab.id)) }
        let space = Space(
            id: data.id, name: data.name, icon: data.icon,
            appearance: data.appearance, tabs: tabs, profileID: profileID)
        space.requiresUnlock = data.requiresUnlock
        space.pinnedCollapsed = data.pinnedCollapsed
        // the folder tree, deduped as it is read: a file can carry the same id
        // twice, or under itself, and the flatten would then never terminate
        var folders: [TabFolder] = []
        var seen = Set<UUID>()
        func tree(_ list: [EntryData], depth: Int) -> [SidebarEntry] {
            guard depth <= Space.maxFolderDepth else { return [] }
            return list.compactMap { node -> SidebarEntry? in
                guard seen.insert(node.id).inserted else { return nil }
                switch node.kind {
                case "tab":
                    return tabs.contains { $0.id == node.id } ? .tab(node.id) : nil
                case "folder":
                    let folder = TabFolder(
                        id: node.id, name: node.name ?? "Folder", isExpanded: node.expanded ?? true,
                        children: tree(node.children ?? [], depth: depth + 1))
                    folder.live = node.live.flatMap(LiveFolder.init)
                    for item in folder.live.map({ Array($0.items.values) }) ?? [] {
                        tabs.first { $0.id == item.tab }?.adopt(restoredTitle: item.title)
                    }
                    folders.append(folder)
                    return .folder(node.id)
                default:
                    return nil
                }
            }
        }
        let pinnedEntries = tree(data.pinnedEntries, depth: 0)
        let todayEntries = tree(data.todayEntries, depth: 0)
        space.folders = folders
        space.pinnedEntries = pinnedEntries
        space.todayEntries = todayEntries
        // a file with no tree at all leaves the tabs flat, in the order read
        space.normalizeTree()
        space.selectedTabID = tabs.first { $0.id == data.selectedTabID }?.id ?? space.firstOpenTab?.id
        space.selectedEssentialID = data.selectedEssentialID
        // rebuild splits from the tiling tree (or legacy flat fields), resolving
        // pane indices into the same [pinned…, today…] order
        space.splitGroups = data.splitGroups.compactMap { groupData -> SplitGroup? in
            // the id is authoritative; the index is what pre-id files carry, and
            // it means nothing once the flat order stops being a simple partition
            let known: (UUID?) -> BrowserTab.ID? = { id in
                id.flatMap { i in tabs.contains { $0.id == i } ? i : nil }
            }
            let resolve: (UUID?, Int) -> BrowserTab.ID? = { id, index in
                if let id { return known(id) }
                return tabs.indices.contains(index) ? tabs[index].id : nil
            }
            guard let root = groupData.effectiveRoot(resolve: resolve),
                root.leafCount >= SplitGroup.minPanes
            else { return nil }
            let source = known(groupData.linkSourceID)
                ?? groupData.linkSourceIndex.flatMap { resolve(nil, $0) }
            let target = known(groupData.linkTargetID)
                ?? groupData.linkTargetIndex.flatMap { resolve(nil, $0) }
            return SplitGroup(
                id: groupData.id, root: root, linkSourceID: source, linkTargetID: target)
        }
        return space
    }
}

/// a site's question nobody has answered yet; its WebKit handler must be called
/// exactly once
@MainActor
final class PermissionRequest: Identifiable {
    let id = UUID()
    let origin: String
    let permissions: [SitePermission]
    let tabID: BrowserTab.ID?
    /// asked from incognito: the answer is remembered in memory only
    let isEphemeral: Bool
    private var respond: ((PermissionDecision) -> Void)?

    init(
        origin: String, permissions: [SitePermission], tabID: BrowserTab.ID?,
        isEphemeral: Bool, respond: @escaping (PermissionDecision) -> Void
    ) {
        self.origin = origin
        self.permissions = permissions
        self.tabID = tabID
        self.isEphemeral = isEphemeral
        self.respond = respond
    }

    /// answer WebKit. safe to call more than once — the handler is dropped after
    /// the first, because calling a WKPermissionDecision handler twice traps
    func answer(_ decision: PermissionDecision) {
        let respond = self.respond
        self.respond = nil
        respond?(decision)
    }

    /// the tab went away with the question still on screen
    func abandon() { answer(.deny) }

    /// `decide` hears whatever this question is answered
    func alsoAnswer(_ decide: @escaping (PermissionDecision) -> Void) {
        respond = { [respond] in
            respond?($0)
            decide($0)
        }
    }

    var summary: String {
        permissions.map(\.request).formatted(.list(type: .and))
    }
}

/// the order and nesting of spaces and favourites grids, by id, so a ⌘Z can put a
/// move back without holding any page
private struct SidebarLayout {
    /// one list of a space's tree, or a profile's favourites grid when `container` is nil
    struct Slot: Hashable {
        let owner: UUID
        let container: SidebarContainer?
    }

    struct FolderShape: Equatable {
        let space: Space.ID
        let name: String
        let isExpanded: Bool
        let live: LiveFolder?

        static func == (a: Self, b: Self) -> Bool {
            a.space == b.space && a.name == b.name && a.isExpanded == b.isExpanded && a.live === b.live
        }
    }

    struct SplitShape: Equatable {
        let space: Space.ID
        let root: SplitNode
        let linkSourceID: BrowserTab.ID?
        let linkTargetID: BrowserTab.ID?
    }

    var lists: [Slot: [SidebarEntry]] = [:]
    var folders: [TabFolder.ID: FolderShape] = [:]
    var splits: [UUID: SplitShape] = [:]
    /// each pinned tab's and favourite's home
    var anchors: [BrowserTab.ID: URL] = [:]
    /// not compared: choosing a tab is no change to take back
    var selections: [Space.ID: BrowserTab.ID] = [:]
    /// the favourite this window shows over each space's own tab, not compared either
    var favourites: [Space.ID: BrowserTab.ID] = [:]

    var tabIDs: Set<BrowserTab.ID> {
        Set(lists.values.joined().compactMap { if case .tab(let id) = $0 { id } else { nil } })
    }
}

/// one act's layout as it left it (`from`) and as its ⌘Z puts it back (`to`)
private struct LayoutChange {
    /// a tab only `to` holds, closed by the ⌘Z this change is the redo of
    struct Page {
        let url: URL?
        let title: String
        let name: String?
        let state: Any?
    }

    let from: SidebarLayout
    let to: SidebarLayout
    var opened: [BrowserTab.ID: Page] = [:]

    var isEmpty: Bool {
        from.lists == to.lists && from.folders == to.folders && from.splits == to.splits && from.anchors == to.anchors
    }

    /// every space whose tree, folders or splits differ between the two
    var spaces: Set<UUID> {
        var out = Set<UUID>()
        for slot in Set(from.lists.keys).union(to.lists.keys) where from.lists[slot] != to.lists[slot] {
            out.insert(slot.owner)
        }
        for id in Set(from.folders.keys).union(to.folders.keys) where from.folders[id] != to.folders[id] {
            [from.folders[id]?.space, to.folders[id]?.space].compactMap { $0 }.forEach { out.insert($0) }
        }
        for id in Set(from.splits.keys).union(to.splits.keys) where from.splits[id] != to.splits[id] {
            [from.splits[id]?.space, to.splits[id]?.space].compactMap { $0 }.forEach { out.insert($0) }
        }
        return out
    }

    /// the entries `to` places differently: whatever keeps its order in a list stays put
    var moved: Set<SidebarEntry> {
        var out = Set<SidebarEntry>()
        for slot in Set(from.lists.keys).union(to.lists.keys) {
            for step in (to.lists[slot] ?? []).difference(from: from.lists[slot] ?? []) {
                switch step {
                case .insert(_, let entry, _), .remove(_, let entry, _): out.insert(entry)
                }
            }
        }
        return out
    }
}
