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

import SwiftUI
import PlayerCore

struct InspectorView: View {
    var session: PlayerSession
    @State private var tab = "Play"
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Inspector").font(.headline); Spacer(); Button { session.showInspector = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close inspector") }.padding(16)
            Picker("Inspector section", selection: $tab) { ForEach(["Play", "Subs", "Audio", "Video", "Info"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case "Subs": subtitles
                    case "Audio": audio
                    case "Video": video
                    case "Info": information
                    default: playback
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button("Reset Current File Adjustments") { session.perform(.resetAdjustments) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(14).disabled(!session.loaded)
        }.background(.background)
    }
    private var speedOptions: [Double] {
        var presets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0, 4.0]
        let current = PlaybackEngine.normalized("speed", session.speed)
        if (0.25...4.0).contains(current), !presets.contains(where: { abs($0 - current) < 0.001 }) {
            presets.append(current)
            presets.sort()
        }
        return presets
    }
    private var playback: some View {
        Group {
            section("Playback") {
                Picker("Speed", selection: Binding(get: { PlaybackEngine.normalized("speed", session.speed) }, set: { session.set("speed", $0) })) {
                    ForEach(speedOptions, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                HStack { Button("Previous Frame") { session.perform(.frameBackward) }; Button("Next Frame") { session.perform(.frameForward) } }.controlSize(.small)
                Button("Go to Time…") { session.perform(.jumpToTime) }.disabled(!session.seekable)
            }
            section("A–B repeat") {
                LabeledContent("Start", value: loopTime("ab-loop-a"))
                LabeledContent("End", value: loopTime("ab-loop-b"))
                HStack { Button("Set A") { session.perform(.loopA) }; Button("Set B") { session.perform(.loopB) }; Button("Clear") { session.perform(.clearLoop) } }.controlSize(.small)
            }
            if !session.chapters.isEmpty {
                section("Chapters") {
                    ForEach(session.chapters) { chapter in Button { session.seek(chapter.time) } label: { HStack { Text(chapter.title).lineLimit(2); Spacer(); Text(TimeText.string(chapter.time)).monospacedDigit().foregroundStyle(.secondary) } }.buttonStyle(.plain) }
                }
            }
        }.disabled(!session.loaded)
    }
    private var subtitles: some View {
        Group {
            section("Tracks") {
                trackPicker("Primary", type: "sub", property: "sid")
                trackPicker("Secondary", type: "sub", property: "secondary-sid")
                Button("Add Subtitle…") { session.perform(.attachSubtitle) }
            }
            section("Timing and appearance") {
                delay("Delay", property: "sub-delay")
                adjustment("Scale", property: "sub-scale", range: 0.5...3, fallback: 1, style: .decimal)
                adjustment("Vertical position", property: "sub-pos", range: 0...100, fallback: 100, style: .percent)
                Text("Positive delay shows subtitles later. ASS subtitles retain their authored styling.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.disabled(!session.loaded)
    }
    private var audio: some View {
        Group {
            section("Audio") {
                Group {
                    trackPicker("Track", type: "audio", property: "aid")
                    delay("A/V delay", property: "audio-delay")
                }.disabled(!session.loaded)
                adjustment("Volume", property: "volume", range: 0...100, fallback: 70, style: .percent)
                let devices = session.values["audio-device-list"]?.array ?? []
                Picker("Output", selection: Binding(get: { session.values["audio-device"]?.string ?? "auto" }, set: { session.set("audio-device", $0) })) {
                    if devices.isEmpty {
                        Text("Automatic").tag("auto")
                    } else {
                        ForEach(devices, id: \.mapID) { device in Text(device["description"].string).tag(device["name"].string) }
                    }
                }
                Text("Playback speed preserves pitch. Output devices follow the system when set to automatic.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var video: some View {
        let aspectSelection = Binding<Double>(
            get: {
                guard case let .number(value) = session.values["video-aspect-override"] else { return -2.0 }
                return value <= 0 ? -2.0 : value
            },
            set: { newValue in
                if newValue <= 0 { session.set("video-aspect-override", "no") }
                else { session.set("video-aspect-override", newValue) }
            }
        )
        return Group {
            section("Geometry") {
                Picker("Aspect", selection: aspectSelection) { Text("Original").tag(-2.0); Text("16:9").tag(16.0 / 9); Text("4:3").tag(4.0 / 3); Text("2.35:1").tag(2.35) }
                Picker("Rotation", selection: number("video-rotate")) { ForEach([0.0, 90, 180, 270], id: \.self) { Text("\(Int($0))°").tag($0) } }
                adjustment("Zoom", property: "video-zoom", range: -1...2, style: .decimal)
                adjustment("Horizontal pan", property: "video-pan-x", range: -1...1, style: .decimal)
                adjustment("Vertical pan", property: "video-pan-y", range: -1...1, style: .decimal)
            }
            section("Image") {
                adjustment("Brightness", property: "brightness", range: -100...100, style: .integer)
                adjustment("Contrast", property: "contrast", range: -100...100, style: .integer)
                adjustment("Saturation", property: "saturation", range: -100...100, style: .integer)
                adjustment("Gamma", property: "gamma", range: -100...100, style: .integer)
                Toggle("Deinterlace", isOn: Binding(get: { session.values["deinterlace"]?.flag ?? false }, set: { session.set("deinterlace", $0) }))
                Button("Save Screenshot…") { session.perform(.screenshot) }
            }
        }.disabled(!session.loaded)
    }
    private var information: some View {
        let params = session.values["video-params"] ?? .none
        let width = Int(params["w"].number), height = Int(params["h"].number)
        let hasVideo = session.loaded && session.tracks.contains { $0.type == "video" }
        let fps = session.finite("estimated-vf-fps")
        let hw = session.values["hwdec-current"]?.string ?? ""
        let decoderText = hw.isEmpty ? (hasVideo ? "Software" : "—") : hw
        return Group {
            section("Media") {
                info("File", session.currentItem?.title ?? "No media")
                info("Video", session.values["video-codec"]?.string ?? "—")
                info("Audio", session.values["audio-codec-name"]?.string ?? "—")
                info("Resolution", width > 0 && height > 0 ? "\(width) × \(height)" : "—")
                info("Source transfer", params["gamma"].string)
                info("Frame rate", fps > 0 ? String(format: "%.3f fps", fps) : "—")
                info("Duration", session.duration > 0 ? TimeText.string(session.duration) : "—")
            }
            section("Playback diagnostics") {
                info("Decoder", decoderText)
                info("Dropped frames", hasVideo ? "\(Int(session.finite("frame-drop-count")))" : "—")
                info("Decoder drops", hasVideo ? "\(Int(session.finite("decoder-frame-drop-count")))" : "—")
                info("Presentation", "OpenGL · SDR / tone mapped")
                info("Engine", session.engineVersion)
                info("State", session.phase)
                Text("HDR sources are tone mapped to SDR in this rendering path.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private enum SliderFormat { case decimal, integer, percent }
    private func formatSliderValue(_ value: Double, style: SliderFormat) -> String {
        switch style {
        case .integer: "\(Int(value.rounded()))"
        case .percent: "\(Int(value.rounded()))%"
        case .decimal: String(format: "%.2f", value)
        }
    }
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary); content().font(.system(size: 12)) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func info(_ title: String, _ value: String) -> some View { LabeledContent(title) { Text(value.isEmpty ? "—" : value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled) } }
    private func number(_ key: String, fallback: Double = 0) -> Binding<Double> {
        Binding(get: {
            if case let .number(val) = session.values[key] { return val }
            return fallback
        }, set: { session.set(key, $0) })
    }
    private func delay(_ title: String, property: String) -> some View {
        let current = number(property).wrappedValue
        return HStack {
            Text(title)
            Spacer()
            if abs(current) > 0.001 {
                Button { session.set(property, 0) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reset \(title.lowercased())").accessibilityLabel("Reset \(title)")
            }
            TextField("Seconds", value: number(property), format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).frame(width: 62).accessibilityLabel("\(title) in seconds")
            Stepper("\(title) in seconds", value: number(property), in: -60...60, step: 0.1).labelsHidden()
            Text("s").foregroundStyle(.secondary)
        }
    }
    private func adjustment(_ title: String, property: String, range: ClosedRange<Double>, fallback: Double = 0, style: SliderFormat = .decimal) -> some View {
        let current = number(property, fallback: fallback).wrappedValue
        return VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if abs(current - fallback) > 0.005 {
                    Button { session.set(property, fallback) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Reset \(title.lowercased())").accessibilityLabel("Reset \(title)")
                }
                Text(formatSliderValue(current, style: style)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: number(property, fallback: fallback), in: range).accessibilityLabel(title)
        }
    }
    private func trackPicker(_ title: String, type: String, property: String) -> some View {
        let available = session.tracks.filter { $0.type == type }
        let selection = Binding<Int>(
            get: {
                switch session.values[property] {
                case let .number(id): return Int(id)
                case let .string(text) where text == "auto": return available.first?.id ?? 0
                default: return 0
                }
            },
            set: { session.selectTrack(property, id: $0) }
        )
        return Picker(title, selection: selection) {
            Text("None").tag(0)
            ForEach(available) { Text($0.label).tag($0.id) }
        }
    }
    private func loopTime(_ key: String) -> String { if case let .number(value) = session.values[key] { TimeText.string(value) } else { "Not set" } }
}

extension EngineValue { nonisolated var mapID: String { self["name"].string } }
