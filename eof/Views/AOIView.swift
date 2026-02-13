import SwiftUI
import UniformTypeIdentifiers

struct AOIView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared
    private let log = ActivityLog.shared

    // Local editing state
    @State private var selectedMethod: AOIMethod = .bundled
    @State private var urlString: String = ""
    @State private var showingFilePicker = false
    @State private var selectedFileURL: URL? = nil
    @State private var manualLat: String = ""
    @State private var manualLon: String = ""
    @State private var manualDiameter: String = "500"
    @State private var manualShape: AppSettings.ManualShape = .circle

    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    enum AOIMethod: String, CaseIterable {
        case bundled = "Test Field"
        case url = "URL"
        case file = "File"
        case manual = "Coords"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Input Method") {
                    Picker("Source", selection: $selectedMethod) {
                        ForEach(AOIMethod.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch selectedMethod {
                case .bundled:
                    bundledSection
                case .url:
                    urlSection
                case .file:
                    fileSection
                case .manual:
                    manualSection
                }

                // Current AOI summary
                if let geo = settings.aoiGeometry {
                    Section("Current AOI") {
                        LabeledContent("Source", value: settings.aoiSourceLabel)
                        LabeledContent("Center") {
                            let c = geo.centroid
                            Text(String(format: "%.4f, %.4f", c.lat, c.lon))
                                .monospacedDigit()
                        }
                        LabeledContent("Vertices", value: "\(geo.polygon.count)")
                        LabeledContent("Extent", value: settings.aoiSummary)
                    }
                }

                // Recent AOIs
                if settings.aoiHistory.count > 1 {
                    Section("Recent") {
                        ForEach(settings.aoiHistory) { entry in
                            Button {
                                settings.restoreAOI(entry)
                                clearMessages()
                                successMessage = "Restored: \(entry.label)"
                                syncFromSettings()
                            } label: {
                                HStack {
                                    Text(entry.label)
                                        .font(.subheadline)
                                    Spacer()
                                    if entry.label == settings.aoiSourceLabel {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let msg = successMessage {
                    Section {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Area of Interest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                        .buttonStyle(.glass)
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [
                    .json,
                    UTType(filenameExtension: "geojson") ?? .json,
                    UTType(filenameExtension: "kml") ?? .xml,
                    .xml,
                    .plainText,
                ],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading...")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .onAppear { syncFromSettings() }
        }
    }

    // MARK: - Input Sections

    private var bundledSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("South Africa wheat field")
                    .font(.subheadline.bold())
                Text("28.744\u{00B0}E, 26.964\u{00B0}S \u{2022} ~390m across \u{2022} 64 vertices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Use Test Field") { applyBundled() }
        }
    }

    private var urlSection: some View {
        Section {
            TextField("https://example.com/field.geojson", text: $urlString)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.caption)
            Button("Fetch & Apply") { fetchFromURL() }
                .disabled(urlString.isEmpty || isLoading)
        } header: {
            Text("GeoJSON URL")
        } footer: {
            Text("GeoJSON, KML, or WKT polygon URL.")
        }
    }

    private var fileSection: some View {
        Section {
            Button("Choose File...") { showingFilePicker = true }
            if let url = selectedFileURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("GeoJSON File")
        } footer: {
            Text("GeoJSON, KML, or WKT file.")
        }
    }

    private var manualSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text("Latitude").font(.caption).foregroundStyle(.secondary)
                    TextField("-26.964", text: $manualLat)
                        .keyboardType(.numbersAndPunctuation)
                }
                VStack(alignment: .leading) {
                    Text("Longitude").font(.caption).foregroundStyle(.secondary)
                    TextField("28.744", text: $manualLon)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
            VStack(alignment: .leading) {
                Text("Diameter (meters)").font(.caption).foregroundStyle(.secondary)
                TextField("500", text: $manualDiameter)
                    .keyboardType(.numberPad)
            }
            Picker("Shape", selection: $manualShape) {
                ForEach(AppSettings.ManualShape.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            Button("Generate & Apply") { applyManual() }
                .disabled(manualLat.isEmpty || manualLon.isEmpty || manualDiameter.isEmpty)
        } header: {
            Text("Manual Coordinates")
        } footer: {
            Text("Enter WGS84 lat/lon and diameter. A \(manualShape.rawValue.lowercased()) polygon will be generated.")
        }
    }

    // MARK: - Actions

    private func syncFromSettings() {
        switch settings.aoiSource {
        case .bundled:
            selectedMethod = .bundled
        case .url(let u):
            selectedMethod = .url
            urlString = u
        case .file(let u):
            selectedMethod = .file
            selectedFileURL = u
        case .manual(let lat, let lon, let d, let shape):
            selectedMethod = .manual
            manualLat = String(lat)
            manualLon = String(lon)
            manualDiameter = String(Int(d))
            manualShape = shape
        }
    }

    private func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    private func applyBundled() {
        clearMessages()
        guard let url = Bundle.main.url(forResource: "SF_field", withExtension: "geojson") else {
            errorMessage = "SF_field.geojson not found in bundle"
            return
        }
        do {
            let geometry = try loadGeoJSON(from: url)
            settings.aoiSource = .bundled
            settings.aoiGeometry = geometry
            settings.recordAOI()
            successMessage = "Test field loaded (\(geometry.polygon.count) vertices)"
            log.info("AOI: loaded bundled test field")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchFromURL() {
        clearMessages()
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            return
        }
        isLoading = true
        Task {
            do {
                let geometry = try await loadAOIAsync(from: url)
                settings.aoiSource = .url(urlString)
                settings.aoiGeometry = geometry
                settings.recordAOI()
                successMessage = "Loaded from URL (\(geometry.polygon.count) vertices)"
                log.info("AOI: loaded from URL \(urlString)")
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        clearMessages()
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let geometry = try loadAOI(from: url)
                selectedFileURL = url
                settings.aoiSource = .file(url)
                settings.aoiGeometry = geometry
                settings.recordAOI()
                successMessage = "Loaded \(url.lastPathComponent) (\(geometry.polygon.count) vertices)"
                log.info("AOI: loaded file \(url.lastPathComponent)")
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func applyManual() {
        clearMessages()
        guard let lat = Double(manualLat),
              let lon = Double(manualLon),
              let diameter = Double(manualDiameter) else {
            errorMessage = "Invalid numeric values"
            return
        }
        guard (-90...90).contains(lat) else {
            errorMessage = "Latitude must be between -90 and 90"
            return
        }
        guard (-180...180).contains(lon) else {
            errorMessage = "Longitude must be between -180 and 180"
            return
        }
        guard diameter > 0 && diameter <= 100_000 else {
            errorMessage = "Diameter must be 1\u{2013}100,000 meters"
            return
        }

        let geometry = AOIGeometry.generate(lat: lat, lon: lon, diameter: diameter, shape: manualShape)
        settings.aoiSource = .manual(lat: lat, lon: lon, diameter: diameter, shape: manualShape)
        settings.aoiGeometry = geometry
        settings.recordAOI()
        successMessage = "\(manualShape.rawValue) \(Int(diameter))m generated (\(geometry.polygon.count) vertices)"
        log.info("AOI: generated \(manualShape.rawValue) \(Int(diameter))m at \(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))")
    }
}
