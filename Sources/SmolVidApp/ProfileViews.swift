import SmolVidCore
import SwiftUI

struct ProfileInspector: View {
    @Environment(AppModel.self) private var model

    private static let resolutions = [360, 480, 540, 720, 1080, 1440, 2160]
    private static let frameRates = [15, 24, 25, 30, 50, 60]
    private static let audioBitrates = [48, 64, 96, 128, 160, 192, 256, 320]

    @State private var gaugeHeight = 0.0
    /// How far the form is scrolled past its top, which the dial follows.
    @State private var scrolled = 0.0

    var body: some View {
        let profile = model.selectedProfile
        let binding = Binding<CompressionProfile>(
            get: { model.selectedProfile },
            set: { model.updateProfile($0) }
        )
        if #available(macOS 15, *) {
            // The dial can't live inside the form (macOS drops custom section headers), so it floats on top
            // of a margin reserved for it and moves along when the form scrolls.
            form(profile, binding)
                .contentMargins(.top, gaugeHeight, for: .scrollContent)
                .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                    scrolled = offset
                }
                .overlay(alignment: .top) {
                    gauge
                        .onGeometryChange(for: Double.self) { $0.size.height } action: { gaugeHeight = $0 }
                        .offset(y: -scrolled)
                }
        } else {
            VStack(spacing: 0) {
                gauge
                form(profile, binding)
            }
        }
    }

    private var gauge: some View {
        CompressionGauge()
            .padding(.top, 2)
            // Leave room for the dial's shadow, which the opaque form would otherwise cover.
            .padding(.bottom, 14)
    }

    private func form(_ profile: CompressionProfile, _ binding: Binding<CompressionProfile>) -> some View {
        Form {
            Section("Video") {
                Toggle("Re-encode video", isOn: binding.reencodeVideo)
                Group {
                    Picker("Codec", selection: binding.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Quality", value: Format.percent(profile.quality))
                        // Round in the binding instead of passing `step:`, which draws a tick mark per step on macOS.
                        Slider(value: Binding(
                            get: { profile.quality },
                            set: { binding.wrappedValue.quality = ($0 * 20).rounded() / 20 }
                        ), in: 0.05...1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "sparkles")
                        }
                        .labelsHidden()
                    }
                    Toggle("Limit resolution", isOn: Binding(
                        get: { profile.maxResolution != nil },
                        set: { binding.wrappedValue.maxResolution = $0 ? 1080 : nil }
                    ))
                    if let limit = profile.maxResolution {
                        Picker("Maximum", selection: Binding(
                            get: { limit },
                            set: { binding.wrappedValue.maxResolution = $0 }
                        )) {
                            ForEach(Set(Self.resolutions + [limit]).sorted(), id: \.self) { Text("\($0)p").tag($0) }
                        }
                    }
                    Toggle("Limit frame rate", isOn: Binding(
                        get: { profile.maxFrameRate != nil },
                        set: { binding.wrappedValue.maxFrameRate = $0 ? 30 : nil }
                    ))
                    if let fps = profile.maxFrameRate {
                        Picker("Maximum", selection: Binding(
                            get: { fps },
                            set: { binding.wrappedValue.maxFrameRate = $0 }
                        )) {
                            ForEach(Set(Self.frameRates + [fps]).sorted(), id: \.self) { Text("\($0) fps").tag($0) }
                        }
                    }
                    Toggle(isOn: binding.hardwareEncoding) {
                        Text("Hardware encoding")
                        Text("Much faster, but larger at the same quality")
                    }
                }
                .disabled(!profile.reencodeVideo)
            }
            .disabled(model.isCompressing)

            Section("Audio") {
                Toggle("Remove audio", isOn: binding.removeAudio)
                Picker(selection: binding.audioBitrate) {
                    ForEach(Set(Self.audioBitrates + [profile.audioBitrate]).sorted(), id: \.self) {
                        Text("\($0) kbit/s").tag($0)
                    }
                } label: {
                    Text("Bitrate")
                    Text("AAC, per stereo pair; audio at a lower bitrate is kept as it is")
                }
                .disabled(profile.removeAudio || !profile.reencodeVideo)
            }
            .disabled(model.isCompressing)

            Section("File") {
                Toggle("Remove metadata", isOn: binding.removeMetadata)
                Toggle("Remove chapters", isOn: binding.removeChapters)
                Toggle("Remove subtitles", isOn: binding.removeSubtitles)
            }
            .disabled(model.isCompressing)
        }
        .formStyle(.grouped)
    }
}
