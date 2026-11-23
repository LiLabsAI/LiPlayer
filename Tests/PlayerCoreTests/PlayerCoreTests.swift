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

import Foundation
import Testing
@testable import PlayerCore

@Test func queueIdentitySurvivesReordering() throws {
    let items = ["Episode 1.mkv", "Episode 2.mkv", "Episode 3.mkv"].map { MediaItem(url: URL(fileURLWithPath: "/tmp/\($0)")) }
    var queue = PlaybackQueue(); queue.replace(items)
    let selected = queue.select(items[1].id)
    #expect(selected)
    queue.move(items[1].id, offset: -1)
    #expect(queue.current?.id == items[1].id)
    #expect(queue.currentIndex == 0)
    queue.remove(items[1].id)
    #expect(queue.current?.id == items[0].id)
    queue.remove(items[0].id); queue.remove(items[2].id)
    #expect(queue.current == nil)
}

@Test func automaticRepeatDoesNotTrapManualNext() {
    let items = [MediaItem(url: URL(fileURLWithPath: "/a")), MediaItem(url: URL(fileURLWithPath: "/b"))]
    var queue = PlaybackQueue(); queue.replace(items); queue.repeatMode = .item
    let repeated = queue.next(automatic: true)
    let manual = queue.next()
    let end = queue.next()
    #expect(repeated?.id == items[0].id)
    #expect(manual?.id == items[1].id)
    #expect(end == nil)
    queue.repeatMode = .queue
    let wrapped = queue.next(automatic: true)
    let previous = queue.previous()
    #expect(wrapped?.id == items[0].id)
    #expect(previous == nil)
}

@Test func naturalOrderAndMediaTypes() {
    let urls = ["Episode 10.MKV", "Episode 2.mkv", "Episode 1.mkv"].map { URL(fileURLWithPath: "/\($0)") }
    #expect(MediaFiles.naturallySorted(urls).map(\.lastPathComponent) == ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.MKV"])
    #expect(MediaFiles.isMedia(urls[0]))
    #expect(MediaFiles.isSubtitle(URL(fileURLWithPath: "/subtitle.ASS")))
    #expect(!MediaFiles.isMedia(URL(fileURLWithPath: "/notes.txt")))
}

@Test(arguments: [("90", 90.0), ("01:02", 62), ("1:02:03.5", 3723.5), (" 0:05 ", 5)])
func timeParsing(_ value: String, expected: Double) { #expect(TimeText.parse(value) == expected) }

@Test(arguments: ["", "-1", "nan", "inf", "1:60", "1::2", ":5", "1:2:3:4", "1:99:00", "1.5:00", "1:2.5:03", "0x10", "1e2", "+5"])
func rejectsInvalidTimes(_ value: String) { #expect(TimeText.parse(value) == nil) }

@Test func formattingHandlesNonFiniteAndLongMedia() {
    #expect(TimeText.string(3723) == "1:02:03")
    #expect(TimeText.string(-62) == "−1:02")
    #expect(TimeText.string(.nan) == "—:—")
}

@Test func shortcutCanonicalizationAndConflicts() throws {
    #expect(Shortcut("shift+cmd+s")?.canonical == "cmd+shift+s")
    #expect(Shortcut("cmd+cmd+s") == nil)
    #expect(Shortcut("super+s") == nil)
    #expect(Shortcut.validate([:]) == nil)
    #expect(Shortcut.validate([PlayerCommand.open.rawValue: "space"]) != nil)
    #expect(Shortcut.validate([PlayerCommand.open.rawValue: ""]) == nil)
    #expect(Shortcut.validate([PlayerCommand.open.rawValue: "cmd+q"]) != nil)
}

@Test func resumeDoesNotRestartCompletedFilesNearEnd() {
    let url = URL(fileURLWithPath: "/test.mp4")
    #expect(ResumeRecord(url: url, position: 95, duration: 100).resumePosition == 0)
    #expect(ResumeRecord(url: url, position: 4, duration: 100).resumePosition == 0)
    #expect(ResumeRecord(url: url, position: 50, duration: 100).resumePosition == 50)
    #expect(ResumeRecord(url: url, position: 50, duration: 0).resumePosition == 0)
}

@Test func historyIsBoundedAndReplacesFileIdentity() {
    let records = (0..<250).map { ResumeRecord(url: URL(fileURLWithPath: "/\($0).mp4"), position: 20, duration: 100) }
    let replacement = ResumeRecord(url: records[10].url, position: 45, duration: 100)
    let bounded = DiskStore.retaining(records, replacing: replacement)
    #expect(bounded.count == 200)
    #expect(bounded[0].position == 45)
    #expect(bounded.filter { $0.url == replacement.url }.count == 1)
}

@Test func persistenceRoundTripAndCorruption() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiskStore(directory: directory)
    var preferences = Preferences(); preferences.rememberHistory = false; preferences.shortcuts["open"] = "cmd+alt+o"
    try store.write(preferences, name: "preferences.json")
    #expect(store.read(Preferences.self, name: "preferences.json") == preferences)
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("preferences.json"))
    #expect(store.read(Preferences.self, name: "preferences.json") == nil)
}

@Test func folderExpansionDoesNotRecurseOrIncludeDocuments() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("nested.mp4"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["clip10.mp4", "clip2.mp4", "notes.txt", ".hidden.mp4"] { try Data().write(to: directory.appendingPathComponent(name)) }
    let expanded = try await MediaFiles.expand([directory])
    #expect(expanded.map(\.lastPathComponent) == ["clip2.mp4", "clip10.mp4"])
}

@Test func playlistRoundTripAndAddressValidation() throws {
    let urls = [URL(fileURLWithPath: "/Volumes/Media/a movie 中文.mkv"), URL(string: "https://example.com/movie.mp4")!]
    #expect(try Playlist.decode(Playlist.encode(urls)) == urls)
    #expect(throws: (any Error).self) { try Playlist.encode([URL(string: "javascript:alert(1)")!]) }
    #expect(throws: (any Error).self) { try Playlist.decode(Data("{\"version\":99,\"entries\":[]}".utf8)) }
}

@Test func localM3UResolvesRelativeEntriesAndPreservesHLS() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("watch.m3u8")
    try Data("#EXTM3U\nclip1.mp4\nhttps://example.com/clip2.mp4\n".utf8).write(to: url)
    #expect(try Playlist.read(url)?.first == directory.appendingPathComponent("clip1.mp4"))
    try Data("#EXTM3U\n#EXT-X-TARGETDURATION:10\nsegment1.ts\n".utf8).write(to: url)
    #expect(try Playlist.read(url) == nil)
}

@Test func readsCurrentAndLegacyQueueExtensions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = [URL(fileURLWithPath: "/Volumes/Media/clip1.mkv"), URL(string: "https://example.com/clip2.mp4")!]
    let data = try Playlist.encode(urls)
    let lpqueue = directory.appendingPathComponent("Watch.lpqueue")
    let vpqueue = directory.appendingPathComponent("Legacy.vpqueue")
    try data.write(to: lpqueue)
    try data.write(to: vpqueue)
    #expect(try Playlist.read(lpqueue) == urls)
    #expect(try Playlist.read(vpqueue) == urls)
}

@Test func diskStoreMigratesLegacySupportFilesWithoutOverwriting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("VideoPlayer")
    let target = root.appendingPathComponent("LiPlayer")
    DiskStore.migrateIfNeeded(from: legacy, to: target)
    #expect(!FileManager.default.fileExists(atPath: target.path))

    let legacyStore = DiskStore(directory: legacy)
    var prefs = Preferences(); prefs.volume = 42; prefs.appearance = "dark"
    try legacyStore.write(prefs, name: "preferences.json")
    let record = ResumeRecord(url: URL(fileURLWithPath: "/sample.mp4"), position: 15, duration: 90)
    try legacyStore.write([record], name: "history.json")

    DiskStore.migrateIfNeeded(from: legacy, to: target)
    let migratedStore = DiskStore(directory: target)
    #expect(migratedStore.read(Preferences.self, name: "preferences.json") == prefs)
    #expect(migratedStore.read([ResumeRecord].self, name: "history.json") == [record])
    #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("preferences.json").path))

    var updated = prefs; updated.volume = 85
    try migratedStore.write(updated, name: "preferences.json")
    DiskStore.migrateIfNeeded(from: legacy, to: target)
    #expect(migratedStore.read(Preferences.self, name: "preferences.json")?.volume == 85)
}

@Test func shortcutHandlesPlusKeyRejectsLiteralSpaceAndNormalizes() {
    #expect(Shortcut("+")?.canonical == "+")
    #expect(Shortcut("cmd++")?.canonical == "cmd++")
    #expect(Shortcut(" shift+cmd++ ")?.canonical == "cmd+shift++")
    #expect(Shortcut(" ") == nil)
    #expect(Shortcut("cmd+ ") == nil)
    let normalized = Shortcut.normalized([
        PlayerCommand.open.rawValue: " SHIFT+CMD+O ",
        PlayerCommand.mute.rawValue: "",
        "unknownCommand": "k",
        PlayerCommand.stop.rawValue: "invalid shortcut"
    ])
    #expect(normalized[PlayerCommand.open.rawValue] == "cmd+shift+o")
    #expect(normalized[PlayerCommand.mute.rawValue] == "")
    #expect(normalized["unknownCommand"] == nil)
    #expect(normalized[PlayerCommand.stop.rawValue] == nil)
}

@Test func networkMediaTitleDistinguishesPathsAndFallsBackToHost() {
    let ep1 = MediaItem(url: URL(string: "https://cdn.example.com/shows/episode1.mp4")!)
    let ep2 = MediaItem(url: URL(string: "https://cdn.example.com/shows/episode2.mp4")!)
    let bare = MediaItem(url: URL(string: "https://cdn.example.com/")!)
    #expect(ep1.title == "episode1.mp4")
    #expect(ep2.title == "episode2.mp4")
    #expect(ep1.title != ep2.title)
    #expect(bare.title == "cdn.example.com")
}

@Test func m3uHandlesColonFilenamesBOMAndEncodedURLs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let playlist = directory.appendingPathComponent("episodes.m3u")
    let content = "\u{FEFF}#EXTM3U\n10:00-clip.mp4\nPart 1: Intro.mp4\nvideo-#EXT-X-note.mp4\nhttps://example.com/my video.mp4\n"
    try Data(content.utf8).write(to: playlist)
    let entries = try #require(try Playlist.read(playlist))
    #expect(entries.count == 4)
    #expect(entries[0].isFileURL && entries[0].lastPathComponent == "10:00-clip.mp4")
    #expect(entries[1].isFileURL && entries[1].lastPathComponent == "Part 1: Intro.mp4")
    #expect(entries[2].isFileURL && entries[2].lastPathComponent == "video-#EXT-X-note.mp4")
    #expect(entries[3].scheme == "https" && entries[3].host == "example.com")

    let invalid = directory.appendingPathComponent("bad.m3u")
    try Data("#EXTM3U\nftp://example.com/clip.mp4\n".utf8).write(to: invalid)
    #expect(throws: Playlist.Failure.self) { _ = try Playlist.read(invalid) }
}

@Test func expandSkipsPackagesAndUnsupportedFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Fake.app"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("clip.mp4")
    let doc = directory.appendingPathComponent("notes.txt")
    let pkgVideo = directory.appendingPathComponent("Fake.app/inside.mp4")
    try Data().write(to: video)
    try Data().write(to: doc)
    try Data().write(to: pkgVideo)
    let expanded = try await MediaFiles.expand([directory.appendingPathComponent("Fake.app"), doc, video])
    #expect(expanded == [video])
}

@Test func preferencesSanitizesCorruptedValuesOnDecode() throws {
    let json = """
    {"seekSeconds":-10,"volume":999,"subtitleSize":-5,"subtitleFont":"   ","appearance":"invalid","shortcuts":{"open":"SHIFT+ALT+O","mute":"invalid key"}}
    """
    let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    #expect(prefs.seekSeconds == 5.0)
    #expect(prefs.volume == 100.0)
    #expect(prefs.subtitleSize == 12.0)
    #expect(prefs.subtitleFont == "sans-serif")
    #expect(prefs.appearance == "system")
    #expect(prefs.shortcuts[PlayerCommand.open.rawValue] == "alt+shift+o")
    #expect(prefs.shortcuts[PlayerCommand.mute.rawValue] == nil)
}
