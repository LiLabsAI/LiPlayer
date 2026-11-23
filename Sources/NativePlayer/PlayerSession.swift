// SPDX-License-Identifier: GPL-3.0-or-later
//
// LiPlayer — Native macOS video player built with Swift, AppKit, SwiftUI, and libmpv.
// Copyright (C) 2026 Ali Ahad <https://aliahad.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import AppKit
import Observation
import MediaPlayer
import IOKit.pwr_mgt
import PlayerCore
import UniformTypeIdentifiers
import os

struct MediaTrack: Identifiable {
    let id: Int
    let type: String
    let title: String
    let language: String
    let codec: String
    var label: String { [title.isEmpty ? "Track \(id)" : title, language, codec].filter { !$0.isEmpty }.joined(separator: " · ") }
}
struct Chapter: Identifiable { let id: Int; let title: String; let time: Double }

@Observable final class PlayerSession {
    var queue = PlaybackQueue() { didSet { saveWorkspace() } }
    let library: FolderLibrary
    let fullscreen = FullscreenControls()
    private var windowLibrary = false { didSet { saveWorkspace() } }
    private var fullscreenLibrary = false
    private var fullscreenSidebar: Sidebar?
    var showLibrary: Bool {
        get { fullscreen.active ? fullscreenLibrary : windowLibrary }
        set { if fullscreen.active { fullscreenLibrary = newValue; fullscreen.reveal() } else { windowLibrary = newValue } }
    }
    private(set) var workspaceSaveError: String?
    private(set) var workspaceSaving = false
    var currentItem: MediaItem?
    var values: [String: EngineValue] = [:]
    var loaded = false
    var phase = "Ready"
    var errorMessage: String?
    var notice: String?
    var hudMessage: String?
    private enum Sidebar: String { case queue, inspector }
    private var sidebar: Sidebar? { didSet { if !compact { saveWorkspace() } } }
    var showQueue: Bool {
        get { (fullscreen.active ? fullscreenSidebar : sidebar) == .queue }
        set {
            if fullscreen.active { if newValue { fullscreenSidebar = .queue } else if fullscreenSidebar == .queue { fullscreenSidebar = nil }; fullscreen.reveal() }
            else { if newValue { sidebar = .queue } else if sidebar == .queue { sidebar = nil } }
        }
    }
    var showInspector: Bool {
        get { (fullscreen.active ? fullscreenSidebar : sidebar) == .inspector }
        set {
            if fullscreen.active { if newValue { fullscreenSidebar = .inspector } else if fullscreenSidebar == .inspector { fullscreenSidebar = nil }; fullscreen.reveal() }
            else { if newValue { sidebar = .inspector } else if sidebar == .inspector { sidebar = nil } }
        }
    }
    var showCommands = false
    var showJump = false
    var floating = false
    var compact = false
    private var normalFrame: NSRect?
    private var normalFloating = false
    private var normalSidebar: Sidebar?
    var preferences: Preferences
    var history: [ResumeRecord]
    var engine: PlaybackEngine?
    var renderer: GLRenderer?
    weak var videoView: NSView?
    weak var window: NSWindow?
    var settingsAction: (() -> Void)?
    var bindingsChanged: (() -> Void)?
    private let store: DiskStore
    private let workspaceWriter: WorkspaceWriter
    private var workspaceRevision = 0
    private var workspaceReady = false
    private var closing = false
    private var savedWorkspace: WorkspaceState
    private var workspacePlayback: ResumeRecord?
    private var restoreTask: Task<Void, Never>?
    private var restoredSpeed: Double?
    private var workspaceSpeed = 1.0
    private var pendingWorkspacePosition: Double?
    private var startupResumeTarget: Double?
    private var startupSeekPending = false
    private var startupSeekFallbackTask: Task<Void, Never>?
    private var preserveNextLoadAdjustments = false
    private var pendingLibraryNotice: String?
    private var noticeTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var volumeSaveTask: Task<Void, Never>?
    private var activeEntry: Int64?
    private var activeLoadID: UUID?
    private var currentLoadID = UUID()
    private var registeredItems: [Int64: UUID] = [:]
    private var deferredLoadedEntry: Int64?
    private var pendingRestore: ResumeRecord?
    private var openTask: Task<Void, Never>?
    private var scopes: Set<URL> = []
    private var lastHistoryWrite = Date.distantPast
    private var lastSystemPlaybackUpdate = Date.distantPast
    private var powerAssertion: IOPMAssertionID = 0
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var openingID = UUID()
    var playbackRevision = 0
    var preventsDisplaySleep: Bool { powerAssertion != 0 }
    var engineVersion: String { engine?.mpvVersion ?? "libmpv" }
    private let globalProperties: Set<String> = ["pause", "volume", "mute", "audio-device-list", "audio-device"]

    init(directory explicitDirectory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = explicitDirectory ?? appSupport.appendingPathComponent("LiPlayer")
        if explicitDirectory == nil {
            DiskStore.migrateIfNeeded(from: appSupport.appendingPathComponent("VideoPlayer"), to: directory)
        }
        store = DiskStore(directory: directory)
        workspaceWriter = WorkspaceWriter(directory: directory)
        var settings = store.read(Preferences.self, name: "preferences.json") ?? Preferences()
        settings.sanitize()
        preferences = settings
        history = store.read([ResumeRecord].self, name: "history.json") ?? []
        if !settings.rememberHistory { history = [] }
        var restored = WorkspaceState()
        var restorationError: String?
        if settings.rememberWorkspace {
            do {
                let result = try WorkspaceStore(directory: directory).load()
                restored = result.state
                if result.recovered { notice = "Recovered your library and queue from the last saved backup." }
            } catch { restorationError = error.localizedDescription }
        }
        savedWorkspace = restored
        workspaceSpeed = restored.speed
        workspacePlayback = settings.rememberHistory ? restored.playback : nil
        library = FolderLibrary(folders: restored.folders)
        queue.replace(restored.queue)
        if let id = restored.currentID { queue.select(id) }
        queue.repeatMode = restored.repeatMode
        showLibrary = restored.showLibrary
        sidebar = restored.sidebar.flatMap(Sidebar.init(rawValue:))
        do {
            engine = try PlaybackEngine { [weak self] events in
                DispatchQueue.main.async { self?.receive(events) }
            }
            applyPreferences()
        } catch { errorMessage = error.localizedDescription }
        configureRemoteControls()
        library.changed = { [weak self] in self?.saveWorkspace() }
        library.reportError = { [weak self] in self?.errorMessage = $0 }
        library.relocated = { [weak self] previous, next in self?.relocateWorkspace(from: previous, to: next) }
        library.removedRoot = { [weak self] url in self?.releaseAccess(to: url) }
        workspaceSaveError = restorationError
        workspaceReady = true
        fullscreen.canHide = { [weak self] in
            guard let self else { return false }
            return self.playing && self.tracks.contains { $0.type == "video" } && self.values["paused-for-cache"]?.flag != true && self.errorMessage == nil && self.workspaceSaveError == nil && !self.showCommands && !self.showJump && !self.fullscreenLibrary && self.fullscreenSidebar == nil
        }
        fullscreen.onExit = { [weak self] in self?.fullscreenLibrary = false; self?.fullscreenSidebar = nil }
    }
    var position: Double { finite("time-pos") }
    var duration: Double { finite("duration") }
    var paused: Bool { values["pause"]?.flag ?? true }
    var playing: Bool { loaded && !paused }
    var volume: Double { values["volume"]?.number ?? preferences.volume }
    var speed: Double { values["speed"]?.number ?? 1 }
    var muted: Bool { values["mute"]?.flag ?? false }
    var seekable: Bool { values["seekable"]?.flag ?? false }
    var subtitleDelay: Double { finite("sub-delay") }
    var audioDelay: Double { finite("audio-delay") }
    var tracks: [MediaTrack] { (values["track-list"]?.array ?? []).map { MediaTrack(id: Int($0["id"].number), type: $0["type"].string, title: $0["title"].string, language: $0["lang"].string, codec: $0["codec"].string) } }
    var chapters: [Chapter] { (values["chapter-list"]?.array ?? []).enumerated().map { Chapter(id: $0.offset, title: $0.element["title"].string.isEmpty ? "Chapter \($0.offset + 1)" : $0.element["title"].string, time: $0.element["time"].number) } }
    func finite(_ key: String) -> Double { let value = values[key]?.number ?? 0; return value.isFinite ? value : 0 }
    func shortcut(_ command: PlayerCommand) -> String { Shortcut(preferences.shortcuts[command.rawValue] ?? command.defaultShortcut)?.display ?? "" }
    func canPerform(_ command: PlayerCommand) -> Bool {
        switch command {
        case .open, .openFolder, .openURL, .addFiles, .toggleLibrary, .toggleQueue, .toggleInspector, .commands, .fullscreen, .alwaysOnTop, .compactPlayer: return true
        case .saveQueue: return !queue.items.isEmpty
        case .togglePause: return currentItem != nil
        case .next: return queue.followingIndex(automatic: false) != nil
        case .previous: return (queue.currentIndex ?? 0) > 0
        case .backward, .forward, .longBackward, .longForward, .jumpToTime, .loopA, .loopB: return loaded && seekable
        case .volumeUp, .volumeDown, .mute: return true
        default: return loaded
        }
    }
    func showNotice(_ text: String, autoDismiss: Bool = true, duration seconds: Double = 4.0) {
        noticeTask?.cancel()
        notice = text
        guard autoDismiss else { return }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.notice == text else { return }
            self.notice = nil
        }
    }
    func showHUD(_ text: String) {
        hudTask?.cancel()
        hudMessage = text
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self, self.hudMessage == text else { return }
            self.hudMessage = nil
        }
    }
    private func scheduleVolumeSave() {
        volumeSaveTask?.cancel()
        volumeSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.closing else { return }
            try? self.store.write(self.preferences, name: "preferences.json")
        }
    }

    func applyPreferences() {
        engine?.set("volume", min(100, max(0, preferences.volume)))
        engine?.set("hwdec", preferences.hardwareDecoding ? "videotoolbox" : "no")
        engine?.set("sub-font", preferences.subtitleFont)
        engine?.set("sub-font-size", preferences.subtitleSize)
        NSApp.appearance = switch preferences.appearance { case "dark": NSAppearance(named: .darkAqua); case "light": NSAppearance(named: .aqua); default: nil }
    }
    func savePreferences() {
        if !preferences.rememberHistory { clearHistory() }
        do { try store.write(preferences, name: "preferences.json") }
        catch { errorMessage = "Could not save preferences: \(error.localizedDescription)" }
        saveWorkspace(sanitizeBackup: !preferences.rememberWorkspace || !preferences.rememberHistory)
    }
    func applyPreferenceChanges(from previous: Preferences) {
        if previous.hardwareDecoding != preferences.hardwareDecoding { engine?.set("hwdec", preferences.hardwareDecoding ? "videotoolbox" : "no") }
        if previous.subtitleFont != preferences.subtitleFont { engine?.set("sub-font", preferences.subtitleFont) }
        if previous.subtitleSize != preferences.subtitleSize { engine?.set("sub-font-size", preferences.subtitleSize) }
        if previous.appearance != preferences.appearance {
            NSApp.appearance = switch preferences.appearance { case "dark": NSAppearance(named: .darkAqua); case "light": NSAppearance(named: .aqua); default: nil }
        }
    }
    func clearHistory() {
        history = []
        workspacePlayback = nil
        do { try store.write(history, name: "history.json") }
        catch { errorMessage = "Could not clear history: \(error.localizedDescription)" }
        NSDocumentController.shared.clearRecentDocuments(nil)
        saveWorkspace(sanitizeBackup: true)
    }
    func openPanel(folder: Bool = false, append: Bool = false, subtitle: Bool = false) {
        window?.makeKeyAndOrderFront(nil)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !subtitle
        if subtitle {
            panel.allowedContentTypes = MediaFiles.subtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        } else if !folder {
            var types: [UTType] = [.movie, .audio, UTType(exportedAs: "com.aliahad.liplayer.queue", conformingTo: .json), UTType(importedAs: "com.aliahad.videoplayer.queue", conformingTo: .json)]
            for ext in MediaFiles.allOpenableExtensions {
                if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
            }
            panel.allowedContentTypes = types
        }
        panel.message = subtitle ? "Choose a subtitle file to attach to the current video." : folder ? "Add folders to your saved library. Expand subfolders to browse their videos." : "Choose media files."
        panel.prompt = append ? "Add" : "Open"
        guard panel.runModal() == .OK else { return }
        if subtitle { panel.urls.forEach(attachSubtitle) } else if folder { addLibraryFolders(panel.urls) } else { open(panel.urls, append: append) }
    }
    func openURL() {
        let alert = NSAlert(); alert.messageText = "Open Media URL"; alert.informativeText = "Enter a direct HTTP, HTTPS, RTSP, or RTMP media address."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24)); field.placeholderString = "https://example.com/video.mp4"
        alert.accessoryView = field; alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { errorMessage = "Enter a valid direct media URL."; return }
        open([url])
    }
    func open(_ urls: [URL], append: Bool = false) {
        guard !urls.isEmpty else { return }
        window?.makeKeyAndOrderFront(nil)
        restoreTask?.cancel()
        if urls.allSatisfy(MediaFiles.isSubtitle) { urls.forEach(attachSubtitle); return }
        openTask?.cancel()
        let request = UUID(); openingID = request
        for url in urls where url.isFileURL { retainAccess(to: url) }
        openTask = Task { [weak self] in
            do {
                let folders = try await Self.selectedFolders(in: urls)
                let files = urls.filter { !folders.contains($0) }
                let expanded = try await MediaFiles.expand(files)
                guard !Task.isCancelled, let self, self.openingID == request else { return }
                if !folders.isEmpty { self.addLibraryFolders(folders) }
                if files.isEmpty { return }
                let subtitles = expanded.filter(MediaFiles.isSubtitle)
                let items = expanded.filter { !MediaFiles.isSubtitle($0) }.map { url in MediaItem(url: url, bookmark: url.isFileURL ? try? url.bookmarkData(options: .withSecurityScope) : nil) }
                guard !items.isEmpty else { self.errorMessage = "No supported media files were found."; return }
                self.saveProgress()
                if !append { self.pendingSubtitles.removeAll() }
                if !subtitles.isEmpty {
                    var matched: [UUID: [URL]] = [:]
                    for sub in subtitles {
                        let stem = sub.deletingPathExtension().lastPathComponent.lowercased()
                        let owner = items.first(where: { $0.url.deletingPathExtension().lastPathComponent.lowercased() == stem }) ?? items[0]
                        matched[owner.id, default: []].append(sub)
                    }
                    for (id, list) in matched { self.pendingSubtitles[id, default: []].append(contentsOf: list) }
                }
                if append {
                    let wasEmpty = self.queue.items.isEmpty
                    self.queue.append(items)
                    if wasEmpty { self.load(items[0]) }
                    self.showQueue = true
                } else { self.queue.replace(items); self.load(items[0]) }
                if items.count > 1 { self.showQueue = true }
            } catch is CancellationError {} catch { self?.errorMessage = "Could not open media: \(error.localizedDescription)" }
        }
    }
    private var pendingSubtitles: [UUID: [URL]] = [:]
    func openRecent(_ record: ResumeRecord) {
        var url = record.url
        if let bookmark = record.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) { url = resolved }
        }
        open([url])
    }
    func select(_ item: MediaItem) { saveProgress(); guard queue.select(item.id) else { return }; load(item) }
    private func load(_ item: MediaItem, paused: Bool = false, restore: ResumeRecord? = nil, startupRestore: Bool = false, preserveAdjustments: Bool = false) {
        startupSeekFallbackTask?.cancel(); startupSeekFallbackTask = nil
        noticeTask?.cancel()
        currentLoadID = UUID()
        preserveNextLoadAdjustments = preserveAdjustments
        currentItem = item; loaded = false; phase = "Opening…"; errorMessage = nil; notice = nil
        if !startupRestore && !preserveAdjustments { workspaceSpeed = 1 }
        values = values.filter { globalProperties.contains($0.key) }
        values["pause"] = .flag(paused)
        pendingRestore = preserveAdjustments ? nil : (preferences.rememberHistory ? (restore ?? history.first { $0.url == item.url }) : nil)
        pendingWorkspacePosition = preserveAdjustments ? nil : restore.flatMap { $0.position.isFinite && $0.position >= 0 && $0.duration.isFinite && $0.duration > 0 && $0.position < $0.duration - 0.25 ? $0.position : nil }
        let willSeekOnStartup = startupRestore && preferences.resumePlayback && (pendingWorkspacePosition ?? 0) > 0
        startupResumeTarget = willSeekOnStartup ? pendingWorkspacePosition : nil
        startupSeekPending = willSeekOnStartup
        if item.url.isFileURL {
            if let folder = library.folders.first(where: { LibraryLocation.contains(item.url, inside: $0.url) }) { retainAccess(to: folder.url) }
            else { retainAccess(to: item.url) }
        }
        engine?.command(["loadfile", item.url.isFileURL ? item.url.path : item.url.absoluteString, "replace"], itemID: currentLoadID)
        engine?.set("pause", paused)
        window?.title = item.title
        saveWorkspace()
    }
    func attachSubtitle(_ url: URL) {
        guard loaded else { errorMessage = "Open a video before adding subtitles."; return }
        guard MediaFiles.isSubtitle(url) else { errorMessage = "Choose an SRT, ASS, VTT, or another supported subtitle file."; return }
        retainAccess(to: url)
        engine?.command(["sub-add", url.path, "select"])
    }
    func remove(_ item: MediaItem) {
        let current = item.id == currentItem?.id
        if current { saveProgress() }
        queue.remove(item.id)
        pendingSubtitles.removeValue(forKey: item.id)
        if item.url.isFileURL, !library.folders.contains(where: { LibraryLocation.contains(item.url, inside: $0.url) }), !queue.items.contains(where: { $0.url == item.url }) {
            releaseAccess(to: item.url)
        }
        if current { if let next = queue.current { load(next) } else { stop(); currentItem = nil; phase = "Ready"; window?.title = "LiPlayer" } }
    }
    func clearQueue() {
        saveProgress()
        let oldURLs = queue.items.map(\.url)
        pendingSubtitles.removeAll()
        queue.replace([])
        engine?.command(["stop"])
        loaded = false; currentItem = nil; phase = "Ready"; window?.title = "LiPlayer"
        for url in oldURLs where url.isFileURL && !library.folders.contains(where: { LibraryLocation.contains(url, inside: $0.url) }) {
            releaseAccess(to: url)
        }
        updateSystemPlayback(); saveWorkspace()
    }
    func moveQueueItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var reordered = queue.items
        let moving = offsets.map { reordered[$0] }
        let removedBefore = offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) { reordered.remove(at: index) }
        let insertionIndex = max(0, min(reordered.count, destination - removedBefore))
        reordered.insert(contentsOf: moving, at: insertionIndex)
        let selected = queue.currentID
        queue.replace(reordered)
        if let selected { queue.select(selected) }
    }
    func next(automatic: Bool = false) { saveProgress(); if let item = queue.next(automatic: automatic) { load(item) } }
    func previous() { saveProgress(); if let item = queue.previous() { load(item) } }
    func stop() { saveProgress(); engine?.command(["stop"]); loaded = false; phase = "Stopped"; updateSystemPlayback(); saveWorkspace() }
    func seek(_ seconds: Double) {
        guard loaded, seekable, seconds.isFinite else { return }
        startupResumeTarget = nil; startupSeekPending = false; startupSeekFallbackTask?.cancel()
        engine?.command(["seek", String(max(0, min(seconds, duration > 0 ? duration : seconds))), "absolute+exact"])
    }
    func set(_ name: String, _ value: Double) {
        guard value.isFinite else { return }
        var normalized = PlaybackEngine.normalized(name, value)
        if name == "volume" { normalized = min(100, max(0, normalized)) }
        else if name == "speed" { normalized = min(4, max(0.25, normalized)) }
        else if name == "sub-delay" || name == "audio-delay" { normalized = min(60, max(-60, normalized)) }
        values[name] = .number(normalized)
        if name == "speed" { workspaceSpeed = normalized }
        if name == "volume" { preferences.volume = normalized; scheduleVolumeSave() }
        engine?.set(name, normalized)
    }
    func set(_ name: String, _ value: Bool) { values[name] = .flag(value); engine?.set(name, value) }
    func set(_ name: String, _ value: String) {
        if name == "video-aspect-override", value == "no" { values[name] = .number(-2) }
        else { values[name] = .string(value) }
        engine?.set(name, value)
    }
    func selectTrack(_ property: String, id: Int) { values[property] = .number(Double(id)); engine?.set(property, id == 0 ? "no" : String(id)) }
    func togglePause() { if loaded { set("pause", !paused); updateSystemPlayback() } else if let item = currentItem { load(item) } }

    func perform(_ command: PlayerCommand) {
        switch command {
        case .open: openPanel(); case .openFolder: openPanel(folder: true); case .openURL: openURL(); case .addFiles: openPanel(append: true); case .saveQueue: saveQueue(); case .attachSubtitle: openPanel(subtitle: true)
        case .toggleLibrary: showLibrary.toggle()
        case .toggleQueue: showQueue.toggle(); if showQueue { showInspector = false }
        case .toggleInspector: showInspector.toggle(); if showInspector { showQueue = false }
        case .commands: showCommands = true
        case .fullscreen: if !fullscreen.transitioning { window?.toggleFullScreen(nil) }
        case .alwaysOnTop: floating.toggle(); window?.level = floating ? .floating : .normal
        case .compactPlayer: toggleCompact()
        case .togglePause: togglePause(); case .stop: stop(); case .previous: previous(); case .next: next()
        case .volumeUp:
            let nextVol = min(100, (volume + 5).rounded())
            set("volume", nextVol); showHUD("Volume \(Int(nextVol))%")
        case .volumeDown:
            let nextVol = max(0, (volume - 5).rounded())
            set("volume", nextVol); showHUD("Volume \(Int(nextVol))%")
        case .mute:
            let nextMuted = !muted
            set("mute", nextMuted); showHUD(nextMuted ? "Muted" : "Volume \(Int(volume))%")
        default:
            guard loaded else { return }
            switch command {
            case .jumpToTime:
                guard seekable else { errorMessage = "This media does not support seeking."; return }
                showJump = true
            case .backward:
                startupResumeTarget = nil; startupSeekPending = false
                engine?.command(["seek", String(-preferences.seekSeconds), "relative+exact"])
                showHUD("−\(Int(preferences.seekSeconds))s")
            case .forward:
                startupResumeTarget = nil; startupSeekPending = false
                engine?.command(["seek", String(preferences.seekSeconds), "relative+exact"])
                showHUD("+\(Int(preferences.seekSeconds))s")
            case .longBackward:
                startupResumeTarget = nil; startupSeekPending = false
                engine?.command(["seek", "-60", "relative+exact"]); showHUD("−1:00")
            case .longForward:
                startupResumeTarget = nil; startupSeekPending = false
                engine?.command(["seek", "60", "relative+exact"]); showHUD("+1:00")
            case .frameForward: engine?.command(["frame-step"])
            case .frameBackward: engine?.command(["frame-back-step"])
            case .speedUp:
                let nextSpeed = PlaybackEngine.normalized("speed", min(4, speed + 0.1))
                set("speed", nextSpeed); showHUD(String(format: "Speed %g×", nextSpeed))
            case .speedDown:
                let nextSpeed = PlaybackEngine.normalized("speed", max(0.25, speed - 0.1))
                set("speed", nextSpeed); showHUD(String(format: "Speed %g×", nextSpeed))
            case .normalSpeed:
                set("speed", 1); showHUD("Speed 1×")
            case .subtitleEarlier:
                let nextDelay = PlaybackEngine.normalized("sub-delay", subtitleDelay - 0.1)
                set("sub-delay", nextDelay); showHUD(String(format: "Subtitle delay %+.1fs", nextDelay))
            case .subtitleLater:
                let nextDelay = PlaybackEngine.normalized("sub-delay", subtitleDelay + 0.1)
                set("sub-delay", nextDelay); showHUD(String(format: "Subtitle delay %+.1fs", nextDelay))
            case .audioEarlier:
                let nextDelay = PlaybackEngine.normalized("audio-delay", audioDelay - 0.1)
                set("audio-delay", nextDelay); showHUD(String(format: "Audio delay %+.1fs", nextDelay))
            case .audioLater:
                let nextDelay = PlaybackEngine.normalized("audio-delay", audioDelay + 0.1)
                set("audio-delay", nextDelay); showHUD(String(format: "Audio delay %+.1fs", nextDelay))
            case .loopA: set("ab-loop-a", position); showNotice("Loop starts at \(TimeText.string(position))")
            case .loopB:
                if case .number(let a) = values["ab-loop-a"], position > a { set("ab-loop-b", position); showNotice("Loop ends at \(TimeText.string(position))") }
                else { errorMessage = "Set a loop start before the current position." }
            case .clearLoop: set("ab-loop-a", "no"); set("ab-loop-b", "no"); showNotice("A–B loop cleared")
            case .screenshot: screenshot()
            case .resetAdjustments: resetAdjustments()
            default: break
            }
        }
    }
    func saveQueue() {
        guard !queue.items.isEmpty else { errorMessage = "Add media files before saving a queue."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Watch queue.lpqueue"
        panel.allowedContentTypes = [UTType(exportedAs: "com.aliahad.liplayer.queue", conformingTo: .json)]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Playlist.encode(queue.items.map(\.url)).write(to: url, options: .atomic); showNotice("Queue saved") }
        catch { errorMessage = error.localizedDescription }
    }
    private func toggleCompact() {
        guard let window, !fullscreen.active, !fullscreen.transitioning, !window.styleMask.contains(.fullScreen) else { return }
        if compact {
            compact = false; window.minSize = NSSize(width: 720, height: 480)
            if let frame = normalFrame { window.setFrame(frame, display: true) }
            floating = normalFloating; window.level = floating ? .floating : .normal
            sidebar = normalSidebar; normalSidebar = nil
        } else {
            normalFrame = window.frame; normalFloating = floating; normalSidebar = sidebar
            compact = true; floating = true; sidebar = nil
            window.minSize = NSSize(width: 320, height: 220)
            window.setContentSize(NSSize(width: 480, height: 300)); window.level = .floating
        }
    }
    func resetAdjustments(showBanner: Bool = true) {
        for property in ["brightness", "contrast", "saturation", "gamma", "video-zoom", "video-pan-x", "video-pan-y", "video-rotate", "sub-delay", "audio-delay"] { set(property, 0) }
        set("speed", 1); set("sub-scale", 1); set("sub-pos", 100); set("video-aspect-override", "no")
        set("deinterlace", false); set("ab-loop-a", "no"); set("ab-loop-b", "no")
        if showBanner { showNotice("Current file adjustments reset") }
    }
    func screenshot() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        let stem = currentItem?.url.deletingPathExtension().lastPathComponent ?? "Frame"
        panel.nameFieldStringValue = String(format: "%@-%.1f.png", stem, position)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine?.command(["screenshot-to-file", url.path, "subtitles"])
        showNotice("Saving screenshot…", autoDismiss: false)
    }
    private func receive(_ events: [EngineEvent]) {
        for event in events {
            switch event {
            case let .registered(id, itemID):
                registeredItems[id] = itemID
                if registeredItems.count > 256 { for old in registeredItems.keys.sorted().prefix(registeredItems.count - 256) { registeredItems.removeValue(forKey: old) } }
                if activeEntry == id {
                    activeLoadID = itemID
                    if deferredLoadedEntry == id, itemID == currentLoadID { finishLoading() }
                }
            case let .started(id):
                activeEntry = id
                activeLoadID = registeredItems[id]
                deferredLoadedEntry = nil
            case let .property(name, value):
                guard activeLoadID == currentLoadID || globalProperties.contains(name) else { continue }
                updateProperty(name, value)
            case let .refreshed(itemID, name, value):
                guard itemID == currentLoadID, loaded else { continue }
                updateProperty(name, value)
            case .loaded:
                guard activeLoadID == currentLoadID else { if activeLoadID == nil { deferredLoadedEntry = activeEntry }; continue }
                finishLoading()
            case let .loadFailed(itemID, message):
                if itemID == currentLoadID { loaded = false; phase = "Could not play"; errorMessage = message; updateSystemPlayback() }
            case .restarted:
                playbackRevision += 1
                if loaded {
                    if startupSeekPending, values["seeking"]?.flag != true {
                        startupResumeTarget = nil; startupSeekPending = false; startupSeekFallbackTask?.cancel()
                    }
                    saveProgress()
                }
            case let .screenshotWritten(path): showNotice("Saved screenshot: \(URL(fileURLWithPath: path).lastPathComponent)")
            case let .ended(id, reason, error):
                guard id == activeEntry, activeLoadID == currentLoadID else { continue }
                if reason == 0 {
                    saveProgress(completed: true); loaded = false; phase = "Finished"
                    if queue.repeatMode == .item, let current = queue.current {
                        load(current, preserveAdjustments: true)
                    } else if preferences.autoNext || queue.repeatMode == .queue {
                        next(automatic: true)
                    }
                } else if let error {
                    loaded = false; phase = "Could not play"; errorMessage = "Playback failed: \(error). Check that the file or drive is available and contains readable media."
                }
                updateSystemPlayback()
            case let .error(message): errorMessage = message; if loaded { engine?.refresh(itemID: currentLoadID) }
            }
        }
        if loaded { phase = (values["paused-for-cache"]?.flag ?? false) ? "Buffering…" : (paused ? "Paused" : "Playing") }
    }
    private func updateProperty(_ name: String, _ value: EngineValue) {
        values[name] = value
        if name == "time-pos", loaded, let target = startupResumeTarget, abs(value.number - target) < 0.25 {
            startupResumeTarget = nil; startupSeekPending = false; startupSeekFallbackTask?.cancel()
            saveProgress()
        }
        if name == "speed", value.number.isFinite, (0.25...4).contains(value.number) { workspaceSpeed = PlaybackEngine.normalized("speed", value.number) }
        if name == "time-pos", loaded, Date().timeIntervalSince(lastHistoryWrite) > 5 { saveProgress() }
        if name == "time-pos", loaded, paused || Date().timeIntervalSince(lastSystemPlaybackUpdate) >= 1 { updateSystemPlayback() }
        if name == "pause" || name == "duration" || name == "speed" { updateSystemPlayback() }
        if name == "pause", value.flag, loaded { saveProgress() }
        if ["pause", "paused-for-cache", "track-list"].contains(name) { fullscreen.evaluate() }
        if name == "volume", value.number.isFinite {
            let clamped = min(100, max(0, value.number))
            if abs(preferences.volume - clamped) > 0.01 {
                preferences.volume = clamped
                scheduleVolumeSave()
            }
        }
    }
    private func finishLoading() {
        deferredLoadedEntry = nil
        loaded = true; phase = paused ? "Paused" : "Playing"
        let keepAdjustments = preserveNextLoadAdjustments
        preserveNextLoadAdjustments = false
        if !keepAdjustments { resetAdjustments(showBanner: false); notice = nil }
        var resumedNotice: String?
        if let record = pendingRestore {
            set("sub-delay", record.subtitleDelay); set("audio-delay", record.audioDelay)
            let resumePosition = pendingWorkspacePosition ?? record.resumePosition
            if preferences.resumePlayback, resumePosition > 0 {
                engine?.command(["seek", String(resumePosition), "absolute+exact"])
                resumedNotice = "Resumed at \(TimeText.string(resumePosition))"
                if startupSeekPending {
                    let loadID = currentLoadID
                    startupSeekFallbackTask?.cancel()
                    startupSeekFallbackTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled, let self, self.currentLoadID == loadID, self.startupSeekPending else { return }
                        self.startupResumeTarget = nil; self.startupSeekPending = false
                        self.saveProgress()
                    }
                }
            } else {
                startupResumeTarget = nil; startupSeekPending = false
            }
        } else {
            startupResumeTarget = nil; startupSeekPending = false
        }
        pendingRestore = nil
        pendingWorkspacePosition = nil
        if let restoredSpeed { set("speed", restoredSpeed); self.restoredSpeed = nil }
        let libraryNotice = pendingLibraryNotice
        pendingLibraryNotice = nil
        if let resumedNotice, let libraryNotice {
            showNotice("\(resumedNotice) · \(libraryNotice)", autoDismiss: false)
        } else if let resumedNotice {
            showNotice(resumedNotice, autoDismiss: true, duration: 8.0)
        } else if let libraryNotice {
            showNotice(libraryNotice, autoDismiss: false)
        }
        if let itemID = currentItem?.id { pendingSubtitles.removeValue(forKey: itemID)?.forEach(attachSubtitle) }
        engine?.refresh(itemID: currentLoadID)
        updateSystemPlayback()
        saveWorkspace()
    }
    func saveProgress(completed: Bool = false) {
        lastHistoryWrite = Date()
        defer { saveWorkspace() }
        guard preferences.rememberHistory, loaded, startupResumeTarget == nil, let item = currentItem, item.url.isFileURL else { return }
        let record = ResumeRecord(url: item.url, bookmark: item.bookmark, position: completed ? 0 : position, duration: duration, subtitleDelay: subtitleDelay, audioDelay: audioDelay)
        history = DiskStore.retaining(history, replacing: record)
        workspacePlayback = record
        lastHistoryWrite = Date()
        do { try store.write(history, name: "history.json") }
        catch { Logger(subsystem: "com.aliahad.liplayer", category: "history").error("Could not save playback history") }
    }
    private func configureRemoteControls() {
        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            let target = command.addTarget { _ in DispatchQueue.main.async(execute: action); return .success }
            remoteTargets.append((command, target))
        }
        register(center.togglePlayPauseCommand) { [weak self] in self?.togglePause() }
        register(center.playCommand) { [weak self] in
            guard let self else { return }
            if self.loaded { self.set("pause", false); self.updateSystemPlayback() }
            else if let item = self.currentItem { self.load(item) }
        }
        register(center.pauseCommand) { [weak self] in
            guard let self, self.loaded else { return }
            self.set("pause", true); self.updateSystemPlayback()
        }
        register(center.nextTrackCommand) { [weak self] in self?.next() }
        register(center.previousTrackCommand) { [weak self] in self?.previous() }
        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async { self?.seek(positionEvent.positionTime) }
            return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, seekTarget))
    }
    private func updateSystemPlayback() {
        lastSystemPlaybackUpdate = Date()
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = currentItem.map { [MPMediaItemPropertyTitle: $0.title, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0] }
        info.playbackState = playing ? .playing : .paused
        if playing, powerAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Video playback" as CFString, &powerAssertion)
        } else if !playing, powerAssertion != 0 { IOPMAssertionRelease(powerAssertion); powerAssertion = 0 }
    }
    func shutdown(_ completion: @escaping @Sendable () -> Void) {
        openTask?.cancel(); restoreTask?.cancel(); noticeTask?.cancel(); hudTask?.cancel(); volumeSaveTask?.cancel(); startupSeekFallbackTask?.cancel()
        library.stop(); fullscreen.exit(); saveProgress()
        let finalState = workspaceState()
        workspaceRevision += 1
        let revision = workspaceRevision
        closing = true
        try? store.write(preferences, name: "preferences.json")
        remoteTargets.forEach { $0.0.removeTarget($0.1) }; remoteTargets = []
        if powerAssertion != 0 { IOPMAssertionRelease(powerAssertion); powerAssertion = 0 }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        (videoView as? VideoOpenGLView)?.clearRenderer()
        renderer?.stop(); renderer = nil
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes.removeAll()
        let sanitizeBackup = !preferences.rememberWorkspace || !preferences.rememberHistory
        Task.detached(priority: .utility) { [workspaceWriter, engine] in
            do { try await workspaceWriter.save(finalState, revision: revision, sanitizeBackup: sanitizeBackup) }
            catch { Logger(subsystem: "com.aliahad.liplayer", category: "workspace").error("Could not save the final workspace: \(error.localizedDescription)") }
            if let engine { engine.shutdown(completion: completion) } else { completion() }
        }
    }

    @concurrent private static func selectedFolders(in urls: [URL]) async throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        return try urls.filter { url in
            try Task.checkCancellation()
            guard url.isFileURL, let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isPackage != true
        }
    }
    func addLibraryFolders(_ urls: [URL]) { library.add(urls); showLibrary = true }
    func playLibraryNode(_ node: LibraryNode) {
        guard !node.isFolder else { return }
        restoreTask?.cancel(); openTask?.cancel(); openingID = UUID()
        saveProgress()
        if let folder = library.folders.first(where: { $0.id == node.location.rootID }) { retainAccess(to: folder.url) }
        let siblings = library.mediaSiblings(of: node)
        let window = LibraryFiles.queueWindow(siblings, selecting: node.id)
        pendingLibraryNotice = window.count < siblings.count ? "This queue contains 10,000 nearby videos. Every video is still available in Library." : nil
        // One root bookmark grants access to its children; avoid filesystem work per file.
        let items = window.map { MediaItem(url: $0.url) }
        queue.replace(items)
        if let item = items.first(where: { $0.url == node.url }) { queue.select(item.id); load(item) }
    }
    private func retainAccess(to url: URL) {
        if !scopes.contains(url), url.startAccessingSecurityScopedResource() { scopes.insert(url) }
    }
    private func releaseAccess(to url: URL) {
        if scopes.remove(url) != nil { url.stopAccessingSecurityScopedResource() }
    }
    func prepareForLaunch(restorePlayback: Bool) {
        library.refreshAll()
        guard restorePlayback, preferences.rememberWorkspace, let item = queue.current else { return }
        currentItem = item; phase = "Ready to resume"
        restoreTask = Task { [weak self] in
            guard let self else { return }
            await self.library.waitForRoot(containing: item.url)
            guard !Task.isCancelled, let current = self.queue.current, current.id == item.id else { return }
            let result = await Self.resolveSavedItem(current)
            let resolved = result.item
            guard !Task.isCancelled, self.queue.current?.id == item.id else { return }
            if let previous = self.queue.current?.url, previous != resolved.url, self.workspacePlayback?.url == previous {
                self.workspacePlayback?.url = resolved.url
                self.workspacePlayback?.bookmark = resolved.bookmark
            }
            self.currentItem = resolved
            self.queue.update(resolved)
            guard resolved.url.isFileURL else { self.phase = "Ready to resume"; return }
            guard result.readable else { self.phase = "File unavailable"; self.notice = "Reconnect the drive or select a video in your library. Your queue has been kept."; return }
            self.restoredSpeed = self.savedWorkspace.speed
            let checkpoint = self.workspacePlayback.flatMap { $0.url == resolved.url ? $0 : nil }
            self.load(resolved, paused: true, restore: self.preferences.resumePlayback ? checkpoint : nil, startupRestore: true)
        }
    }
    @concurrent private static func resolveSavedItem(_ item: MediaItem) async -> (item: MediaItem, readable: Bool) {
        var resolved = item
        if let bookmark = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                resolved = MediaItem(url: url, id: item.id, bookmark: stale ? try? url.bookmarkData(options: .withSecurityScope) : bookmark)
            }
        }
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        return (resolved, !resolved.url.isFileURL || FileManager.default.isReadableFile(atPath: resolved.url.path))
    }
    private func workspaceState() -> WorkspaceState {
        guard preferences.rememberWorkspace else { return WorkspaceState() }
        var state = WorkspaceState()
        state.folders = library.folders; state.queue = queue.items; state.currentID = queue.currentID
        state.repeatMode = queue.repeatMode; state.showLibrary = windowLibrary; state.sidebar = (compact ? normalSidebar : sidebar)?.rawValue
        state.speed = workspaceSpeed
        if preferences.rememberHistory, let item = currentItem, item.id == queue.currentID, item.url == queue.current?.url, item.url.isFileURL {
            if loaded && startupResumeTarget == nil { state.playback = ResumeRecord(url: item.url, bookmark: item.bookmark, position: position, duration: duration, subtitleDelay: subtitleDelay, audioDelay: audioDelay) }
            else if workspacePlayback?.url == item.url { state.playback = workspacePlayback }
        }
        return state
    }
    func saveWorkspace(sanitizeBackup: Bool = false) {
        guard workspaceReady, !closing else { return }
        let state = workspaceState()
        workspaceRevision += 1
        let revision = workspaceRevision
        workspaceSaving = true
        Task { [weak self, workspaceWriter] in
            do {
                try await workspaceWriter.save(state, revision: revision, sanitizeBackup: sanitizeBackup)
                guard let self, self.workspaceRevision == revision else { return }
                self.workspaceSaving = false; self.workspaceSaveError = nil
            } catch {
                guard let self, self.workspaceRevision == revision else { return }
                self.workspaceSaving = false; self.workspaceSaveError = "Could not save the library: \(error.localizedDescription)"
            }
        }
    }
    private func relocateWorkspace(from previous: URL, to next: URL) {
        let prefix = LibraryLocation.pathPrefix(of: previous)
        func moved(_ url: URL) -> URL {
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(prefix) else { return url }
            return next.appendingPathComponent(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        func record(_ original: ResumeRecord) -> ResumeRecord {
            var result = original
            result.url = moved(original.url)
            if result.url != original.url { result.bookmark = nil }
            return result
        }
        workspacePlayback = workspacePlayback.map(record)
        pendingRestore = pendingRestore.map(record)
        let selected = queue.currentID
        let items = queue.items.map { item in
            let url = moved(item.url)
            return url == item.url ? item : MediaItem(url: url, id: item.id)
        }
        queue.replace(items)
        if let selected { queue.select(selected) }
        if let item = currentItem { currentItem = items.first { $0.id == item.id } ?? item }
        history = history.map(record)
        do { try store.write(history, name: "history.json") }
        catch { errorMessage = "Could not update history for the relocated folder." }
        saveWorkspace()
    }
}
