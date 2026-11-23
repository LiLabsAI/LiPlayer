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

public enum Playlist {
    private struct Document: Codable { let version: Int; let entries: [URL] }
    public enum Failure: LocalizedError { case invalid
        public var errorDescription: String? { "This queue is invalid, uses an unsupported version, or contains unsupported addresses." }
    }
    public static func encode(_ urls: [URL]) throws -> Data {
        guard urls.count <= 10_000, urls.allSatisfy(valid) else { throw Failure.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(version: 1, entries: urls))
    }
    public static func decode(_ data: Data) throws -> [URL] {
        guard data.count <= 8_000_000 else { throw Failure.invalid }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.entries.count <= 10_000, document.entries.allSatisfy(valid) else { throw Failure.invalid }
        return document.entries
    }
    public static func read(_ url: URL) throws -> [URL]? {
        guard url.isFileURL else { return nil }
        let ext = url.pathExtension.lowercased()
        let isQueue = ["lpqueue", "vpqueue"].contains(ext)
        let isM3U = ["m3u", "m3u8"].contains(ext)
        guard isQueue || isM3U else { return nil }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 8_000_000 { throw Failure.invalid }
        if isQueue { return try decode(Data(contentsOf: url)) }
        let data = try Data(contentsOf: url)
        guard data.count <= 8_000_000, var text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        // HLS is one media source, not a queue of individual segments.
        if lines.contains(where: { $0.hasPrefix("#EXT-X-") }) { return nil }
        let baseDirectory = url.deletingLastPathComponent()
        let entries: [URL] = try lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { line in
            if hasExplicitScheme(line) {
                if let address = URL(string: line) { return address }
                if let encoded = line.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed), let address = URL(string: encoded) { return address }
                throw Failure.invalid
            }
            return URL(fileURLWithPath: line, relativeTo: baseDirectory).standardizedFileURL
        }
        guard entries.count <= 10_000, entries.allSatisfy(valid) else { throw Failure.invalid }
        return entries
    }
    private static func hasExplicitScheme(_ line: String) -> Bool {
        guard let range = line.range(of: "://") else { return false }
        let scheme = line[..<range.lowerBound]
        guard let first = scheme.first, first.isASCII && first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
    }
    private static func valid(_ url: URL) -> Bool { ["file", "http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") && !url.absoluteString.contains("\0") }
}
