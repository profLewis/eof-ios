import SwiftUI

struct DataSourcesView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared
    @State private var isBenchmarking = false
    @State private var pcAPIKey: String = KeychainService.retrieve(key: "planetary.apikey") ?? ""
    @State private var cdseUsername: String = KeychainService.retrieve(key: "cdse.username") ?? ""
    @State private var cdsePassword: String = KeychainService.retrieve(key: "cdse.password") ?? ""
    @State private var earthdataUsername: String = KeychainService.retrieve(key: "earthdata.username") ?? ""
    @State private var earthdataPassword: String = KeychainService.retrieve(key: "earthdata.password") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(settings.sources.enumerated()), id: \.element.id) { index, source in
                        sourceRow(source: source, index: index)
                    }
                    .onMove { from, to in
                        settings.sources.move(fromOffsets: from, toOffset: to)
                    }
                } header: {
                    Text("Sources (drag to reorder trust priority)")
                } footer: {
                    Text("First source is most trusted. Drag to reorder. Disabled sources are skipped.")
                }

                Section("Benchmarks") {
                    Button {
                        runBenchmarks()
                    } label: {
                        HStack {
                            Label("Test Sources", systemImage: "speedometer")
                            if isBenchmarking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isBenchmarking)

                    ForEach(settings.benchmarkResults) { result in
                        benchmarkRow(result: result)
                    }

                    if !settings.benchmarkResults.isEmpty {
                        Toggle("Smart Stream Allocation", isOn: $settings.smartAllocation)
                        if settings.smartAllocation {
                            let allocation = SourceBenchmarkService.allocateStreams(
                                benchmarks: settings.benchmarkResults,
                                totalStreams: settings.maxConcurrent
                            )
                            ForEach(Array(allocation.sorted(by: { $0.key.rawValue < $1.key.rawValue })), id: \.key) { sourceID, streams in
                                LabeledContent(sourceID.rawValue.uppercased(), value: "\(streams) streams")
                                    .font(.caption)
                            }
                        }
                    }
                }

                // MARK: - Credentials

                Section("Planetary Computer") {
                    SecureField("API Key (optional)", text: $pcAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .onChange(of: pcAPIKey) {
                            if pcAPIKey.isEmpty {
                                KeychainService.delete(key: "planetary.apikey")
                            } else {
                                try? KeychainService.store(key: "planetary.apikey", value: pcAPIKey)
                            }
                        }
                    Text("Optional. Works without an API key but rate limits may apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Copernicus Data Space (CDSE)") {
                    TextField("Username (email)", text: $cdseUsername)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: cdseUsername) { storeCredential(key: "cdse.username", value: cdseUsername) }
                    SecureField("Password", text: $cdsePassword)
                        .textContentType(.password)
                        .onChange(of: cdsePassword) { storeCredential(key: "cdse.password", value: cdsePassword) }
                    Text("Free registration required. Provides Sentinel-2 L2A via Copernicus Data Space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Register at dataspace.copernicus.eu",
                         destination: URL(string: "https://dataspace.copernicus.eu")!)
                        .font(.caption)
                }

                Section("NASA Earthdata (HLS)") {
                    TextField("Username", text: $earthdataUsername)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: earthdataUsername) { storeCredential(key: "earthdata.username", value: earthdataUsername) }
                    SecureField("Password", text: $earthdataPassword)
                        .textContentType(.password)
                        .onChange(of: earthdataPassword) { storeCredential(key: "earthdata.password", value: earthdataPassword) }
                    Text("Free registration required. Provides Harmonized Landsat Sentinel-2 (HLS) at 30m.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Register at urs.earthdata.nasa.gov",
                         destination: URL(string: "https://urs.earthdata.nasa.gov/users/new")!)
                        .font(.caption)
                }

                Section("Google Earth Engine") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Requires GEE account", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Google Earth Engine provides access to all major EO sensors (Sentinel-2, Landsat, MODIS, VIIRS). Requires a Google Cloud project with Earth Engine API enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Open Earth Engine",
                             destination: URL(string: "https://earthengine.google.com")!)
                            .font(.caption)
                        Link("Setup Guide",
                             destination: URL(string: "https://developers.google.com/earth-engine/guides/access")!)
                            .font(.caption)
                    }
                }

                Section("Performance") {
                    Stepper(value: $settings.maxConcurrent, in: 1...12) {
                        HStack {
                            Text("Total Concurrent Streams")
                            Spacer()
                            Text("\(settings.maxConcurrent)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Data Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .buttonStyle(.glass)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func sourceRow(source: STACSourceConfig, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.sourceID.icon)
                .foregroundStyle(source.isEnabled ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(.subheadline)
                HStack(spacing: 4) {
                    Text(source.collection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if source.assetAuthType != .none {
                        Text("(\(source.assetAuthType.rawValue))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // Status dot
            if let benchmark = settings.benchmarkResults.first(where: { $0.sourceID == source.sourceID }) {
                Circle()
                    .fill(benchmark.isReachable ? .green : .red)
                    .frame(width: 8, height: 8)
            }

            Toggle("", isOn: Binding(
                get: { settings.sources[index].isEnabled },
                set: { settings.sources[index].isEnabled = $0 }
            ))
            .labelsHidden()
        }
    }

    private func benchmarkRow(result: SourceBenchmark) -> some View {
        HStack {
            Image(systemName: result.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.isReachable ? .green : .red)
                .font(.caption)
            Text(result.sourceID.rawValue.uppercased())
                .font(.caption.bold())
            Spacer()
            Text(result.latencyLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func storeCredential(key: String, value: String) {
        if value.isEmpty {
            KeychainService.delete(key: key)
        } else {
            try? KeychainService.store(key: key, value: value)
        }
    }

    private func runBenchmarks() {
        isBenchmarking = true
        Task {
            let service = SourceBenchmarkService()
            let results = await service.benchmarkAll(sources: settings.sources)
            await MainActor.run {
                settings.benchmarkResults = results
                isBenchmarking = false
            }
        }
    }
}
