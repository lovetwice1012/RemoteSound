import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    private var sourceSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedSourceID },
            set: { model.selectSource(id: $0) }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                RemoteConnectionCard(model: model)
                    .padding(.horizontal)
                    .padding(.top)

                if model.sources.isEmpty {
                    ContentUnavailableView(
                        "No Sources Connected",
                        systemImage: "waveform.badge.plus",
                        description: Text("Start the Windows audio server on the same LAN, then connect to its reliable HLS URL above.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(model.sources, selection: sourceSelection) { source in
                        SourceRow(source: source)
                            .tag(source.id)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("RemoteSound")
        } detail: {
            if let source = model.selectedSource {
                SourceDetailView(model: model, source: source)
            } else {
                ContentUnavailableView(
                    "Select a Source",
                    systemImage: "slider.horizontal.3",
                    description: Text("Choose a connected stream to change its mute state, level, or EQ.")
                )
            }
        }
    }
}

private struct RemoteConnectionCard: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.serverIsRunning ? "Source Connected" : "Source Disconnected", systemImage: model.serverIsRunning ? "dot.radiowaves.left.and.right" : "cable.connector")
                .font(.headline)

            Text(model.serverMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(model.audioStatusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Auto-connect discovered source", isOn: $model.autoConnectDiscoveredSource)

            Text(model.discoveryMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("http://192.168.1.10:8766/stream.m3u8", text: $model.remoteURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.body, design: .monospaced))

            HStack {
                Button(model.serverIsRunning ? "Reconnect" : "Connect") {
                    model.connectToRemoteSource()
                }
                .buttonStyle(.borderedProminent)

                Button("Scan") {
                    model.scanForRemoteSources()
                }
                .buttonStyle(.bordered)

                Button("Disconnect") {
                    model.disconnectRemoteSource()
                }
                .buttonStyle(.bordered)
                .disabled(!model.serverIsRunning && model.sources.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct SourceRow: View {
    let source: RemoteSourceState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(source.isEnabled ? .teal : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.headline)

                Text(source.endpointDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(source.isActivelyPlaying ? "Streaming now" : "Connected, waiting for audio")
                    .font(.caption2)
                    .foregroundStyle(source.isActivelyPlaying ? .green : .secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(source.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text("\(source.queuedBufferCount) queued")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SourceDetailView: View {
    let model: AppModel
    let source: RemoteSourceState

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Name", value: source.name)
                LabeledContent("Client ID", value: source.stableID)
                LabeledContent("Endpoint", value: source.endpointDescription)
                LabeledContent("Codec", value: source.codec)
                LabeledContent("Channels", value: "\(source.channels)")
                LabeledContent("Sample Rate", value: "\(Int(source.sampleRate)) Hz")
                LabeledContent("Connected", value: source.connectedAt.formatted(date: .omitted, time: .standard))
            }

            Section("Playback") {
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { source.isEnabled },
                        set: { model.setEnabled($0, for: source.id) }
                    )
                )

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Volume", value: "\(Int(source.volume * 100))%")
                    Slider(
                        value: Binding(
                            get: { source.volume },
                            set: { model.setVolume($0, for: source.id) }
                        ),
                        in: 0...2
                    )
                }

                LabeledContent("Streaming", value: source.isActivelyPlaying ? "Active" : "Idle")
                LabeledContent("Queued Buffers", value: "\(source.queuedBufferCount)")
                LabeledContent("Dropped Frames", value: "\(source.droppedFrameCount)")
                LabeledContent("Received Frames", value: "\(source.receivedFrameCount)")

                if let lastFrameAt = source.lastFrameAt {
                    LabeledContent("Last Frame", value: lastFrameAt.formatted(date: .omitted, time: .standard))
                }
            }

            Section("Source Actions") {
                Button("Reset Mute, Volume, and EQ") {
                    model.resetSourceMix(for: source.id)
                }

                Button("Disconnect Source") {
                    model.disconnectSource(id: source.id)
                }
                .foregroundStyle(.red)
            }

            Section("Equalizer") {
                EqualizerSlider(
                    title: "Low",
                    value: source.lowGain,
                    action: { model.setLowGain($0, for: source.id) }
                )
                EqualizerSlider(
                    title: "Mid",
                    value: source.midGain,
                    action: { model.setMidGain($0, for: source.id) }
                )
                EqualizerSlider(
                    title: "High",
                    value: source.highGain,
                    action: { model.setHighGain($0, for: source.id) }
                )
            }
        }
        .navigationTitle(source.name)
    }
}

private struct EqualizerSlider: View {
    let title: String
    let value: Double
    let action: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: String(format: "%.1f dB", value))
            Slider(
                value: Binding(
                    get: { value },
                    set: action
                ),
                in: -18...18
            )
        }
    }
}
