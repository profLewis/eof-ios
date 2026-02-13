import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct AOIView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared
    private let log = ActivityLog.shared

    // Map state
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isDrawing = false
    @State private var drawStart: CLLocationCoordinate2D?
    @State private var drawEnd: CLLocationCoordinate2D?

    // Search
    @State private var searchText = ""
    @State private var searchService = PlaceSearchService()
    @State private var showingSearchResults = false

    // Location
    @State private var locationService = LocationService()
    @State private var locationDiameter: Double = 500

    // Import sheet
    @State private var showingImport = false

    // Feedback
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                searchBar

                // Map
                mapView

                // Bottom controls
                bottomControls
            }
            .navigationTitle("Area of Interest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                        .buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $showingImport) {
                importSheet
            }
            .onAppear {
                // Center map on current AOI if set
                if let geo = settings.aoiGeometry {
                    let c = geo.centroid
                    cameraPosition = .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon),
                        latitudinalMeters: 2000, longitudinalMeters: 2000
                    ))
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search place name...", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) {
                        searchService.queryFragment = searchText
                        showingSearchResults = !searchText.isEmpty
                    }
                if !searchText.isEmpty {
                    Button { searchText = ""; showingSearchResults = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            // Search results dropdown
            if showingSearchResults && !searchService.results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(searchService.results, id: \.self) { result in
                            Button {
                                selectSearchResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - Map

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: isDrawing ? [] : .all) {
                // Current AOI polygon
                if let geo = settings.aoiGeometry {
                    let coords = geo.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    MapPolygon(coordinates: coords)
                        .foregroundStyle(.green.opacity(0.15))
                        .stroke(.green, lineWidth: 2)
                }

                // Drawing rectangle preview
                if let s = drawStart, let e = drawEnd {
                    let corners = rectCorners(s, e)
                    MapPolygon(coordinates: corners)
                        .foregroundStyle(.blue.opacity(0.15))
                        .stroke(.blue, lineWidth: 2)
                }
            }
            .mapStyle(.hybrid(elevation: .flat))
            .gesture(
                isDrawing ?
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        drawStart = proxy.convert(value.startLocation, from: .local)
                        drawEnd = proxy.convert(value.location, from: .local)
                    }
                    .onEnded { _ in
                        if let s = drawStart, let e = drawEnd {
                            applyDrawnRect(start: s, end: e)
                        }
                        drawStart = nil
                        drawEnd = nil
                        isDrawing = false
                    }
                : nil
            )
            .overlay(alignment: .topTrailing) {
                if isDrawing {
                    Text("Drag to draw rectangle")
                        .font(.caption.bold())
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                }
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 8) {
            // Messages
            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let msg = successMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            // Current AOI summary
            if let geo = settings.aoiGeometry {
                let c = geo.centroid
                Text("\(settings.aoiSourceLabel) \u{2022} \(String(format: "%.4f, %.4f", c.lat, c.lon)) \u{2022} \(geo.polygon.count) vertices")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    isDrawing.toggle()
                    if isDrawing {
                        drawStart = nil
                        drawEnd = nil
                    }
                } label: {
                    Label(isDrawing ? "Cancel" : "Draw", systemImage: isDrawing ? "xmark" : "rectangle.dashed")
                        .font(.caption)
                }
                .buttonStyle(.glass)

                Button {
                    requestMyLocation()
                } label: {
                    Label("My Location", systemImage: "location.fill")
                        .font(.caption)
                }
                .buttonStyle(.glass)

                // Diameter stepper for location
                HStack(spacing: 4) {
                    Text("\(Int(locationDiameter))m")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Stepper("", value: $locationDiameter, in: 100...10000, step: 100)
                        .labelsHidden()
                        .scaleEffect(0.8)
                }

                Spacer()

                Button {
                    showingImport = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.glass)
            }

            // Recent AOIs
            if settings.aoiHistory.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(settings.aoiHistory) { entry in
                            Button {
                                settings.restoreAOI(entry)
                                clearMessages()
                                successMessage = "Restored: \(entry.label)"
                                flyToAOI()
                            } label: {
                                Text(entry.label)
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(entry.label == settings.aoiSourceLabel ? Color.green.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Import Sheet

    private var importSheet: some View {
        NavigationStack {
            ImportAOISheet(
                isPresented: $showingImport,
                settings: settings,
                onApply: { source, geometry, label in
                    settings.aoiSource = source
                    settings.aoiGeometry = geometry
                    settings.recordAOI()
                    clearMessages()
                    successMessage = label
                    flyToAOI()
                    showingImport = false
                }
            )
        }
    }

    // MARK: - Actions

    private func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        showingSearchResults = false
        searchText = result.title
        Task {
            if let coord = await searchService.selectResult(result) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 5000, longitudinalMeters: 5000
                ))
            }
        }
    }

    private func rectCorners(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let minLat = min(a.latitude, b.latitude)
        let maxLat = max(a.latitude, b.latitude)
        let minLon = min(a.longitude, b.longitude)
        let maxLon = max(a.longitude, b.longitude)
        return [
            CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
        ]
    }

    private func applyDrawnRect(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) {
        let minLat = min(start.latitude, end.latitude)
        let maxLat = max(start.latitude, end.latitude)
        let minLon = min(start.longitude, end.longitude)
        let maxLon = max(start.longitude, end.longitude)

        guard maxLat - minLat > 0.0001 && maxLon - minLon > 0.0001 else {
            errorMessage = "Rectangle too small — drag further"
            return
        }

        let geometry = AOIGeometry.generateRect(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        settings.aoiSource = .mapRect(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        settings.aoiGeometry = geometry
        settings.recordAOI()
        clearMessages()
        successMessage = "Map rectangle applied (\(geometry.polygon.count) vertices)"
        log.info("AOI: map rect \(String(format: "%.4f", minLat))-\(String(format: "%.4f", maxLat)), \(String(format: "%.4f", minLon))-\(String(format: "%.4f", maxLon))")
    }

    private func requestMyLocation() {
        clearMessages()
        locationService.requestLocation()
        // Watch for location updates
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if let coord = locationService.lastLocation {
                    let geometry = AOIGeometry.generate(
                        lat: coord.latitude, lon: coord.longitude,
                        diameter: locationDiameter, shape: .circle
                    )
                    settings.aoiSource = .location(lat: coord.latitude, lon: coord.longitude, diameter: locationDiameter)
                    settings.aoiGeometry = geometry
                    settings.recordAOI()
                    successMessage = "My location: \(String(format: "%.4f, %.4f", coord.latitude, coord.longitude))"
                    log.info("AOI: my location \(String(format: "%.4f, %.4f", coord.latitude, coord.longitude)), \(Int(locationDiameter))m")
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        latitudinalMeters: locationDiameter * 3, longitudinalMeters: locationDiameter * 3
                    ))
                    return
                }
                if let err = locationService.error {
                    errorMessage = err
                    return
                }
            }
            errorMessage = "Location timeout — try again"
        }
    }

    private func flyToAOI() {
        if let geo = settings.aoiGeometry {
            let c = geo.centroid
            let b = geo.bbox
            let latSpan = (b.maxLat - b.minLat) * 1.5
            let lonSpan = (b.maxLon - b.minLon) * 1.5
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon),
                span: MKCoordinateSpan(latitudeDelta: max(0.005, latSpan), longitudeDelta: max(0.005, lonSpan))
            ))
        }
    }
}

// MARK: - Place Search Service

@Observable
class PlaceSearchService: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    var results: [MKLocalSearchCompletion] = []
    var queryFragment: String = "" {
        didSet { completer.queryFragment = queryFragment }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    func selectResult(_ result: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request(completion: result)
        let search = MKLocalSearch(request: request)
        let response = try? await search.start()
        return response?.mapItems.first?.placemark.coordinate
    }
}

// MARK: - Import Sheet (bundled, URL, file, manual)

struct ImportAOISheet: View {
    @Binding var isPresented: Bool
    let settings: AppSettings
    let onApply: (AppSettings.AOISource, GeoJSONGeometry, String) -> Void

    @State private var selectedMethod: ImportMethod = .bundled
    @State private var urlString = ""
    @State private var showingFilePicker = false
    @State private var manualLat = ""
    @State private var manualLon = ""
    @State private var manualDiameter = "500"
    @State private var manualShape: AppSettings.ManualShape = .circle
    @State private var isLoading = false
    @State private var errorMessage: String?

    enum ImportMethod: String, CaseIterable {
        case bundled = "Test Field"
        case url = "URL"
        case file = "File"
        case manual = "Coords"
    }

    var body: some View {
        Form {
            Section("Import Method") {
                Picker("Source", selection: $selectedMethod) {
                    ForEach(ImportMethod.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch selectedMethod {
            case .bundled:
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("South Africa wheat field")
                            .font(.subheadline.bold())
                        Text("28.744\u{00B0}E, 26.964\u{00B0}S \u{2022} ~390m across")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Use Test Field") { applyBundled() }
                }
            case .url:
                Section {
                    TextField("https://example.com/field.geojson", text: $urlString)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.caption)
                    Button("Fetch & Apply") { fetchFromURL() }
                        .disabled(urlString.isEmpty || isLoading)
                } footer: {
                    Text("GeoJSON, KML, or WKT polygon URL.")
                }
            case .file:
                Section {
                    Button("Choose File...") { showingFilePicker = true }
                } footer: {
                    Text("GeoJSON, KML, or WKT file.")
                }
            case .manual:
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
                        .disabled(manualLat.isEmpty || manualLon.isEmpty)
                }
            }

            if let err = errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Import AOI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.glass)
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [
                .json,
                UTType(filenameExtension: "geojson") ?? .json,
                UTType(filenameExtension: "kml") ?? .xml,
                .xml, .plainText,
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
    }

    private func applyBundled() {
        guard let url = Bundle.main.url(forResource: "SF_field", withExtension: "geojson") else {
            errorMessage = "SF_field.geojson not found in bundle"
            return
        }
        do {
            let geometry = try loadGeoJSON(from: url)
            onApply(.bundled, geometry, "Test field loaded (\(geometry.polygon.count) vertices)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchFromURL() {
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            return
        }
        isLoading = true
        Task {
            do {
                let geometry = try await loadAOIAsync(from: url)
                onApply(.url(urlString), geometry, "Loaded from URL (\(geometry.polygon.count) vertices)")
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
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
                onApply(.file(url), geometry, "Loaded \(url.lastPathComponent) (\(geometry.polygon.count) vertices)")
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func applyManual() {
        guard let lat = Double(manualLat), let lon = Double(manualLon),
              let diameter = Double(manualDiameter) else {
            errorMessage = "Invalid numeric values"
            return
        }
        guard (-90...90).contains(lat) else { errorMessage = "Latitude must be -90 to 90"; return }
        guard (-180...180).contains(lon) else { errorMessage = "Longitude must be -180 to 180"; return }
        guard diameter > 0 && diameter <= 100_000 else { errorMessage = "Diameter must be 1\u{2013}100,000 m"; return }

        let geometry = AOIGeometry.generate(lat: lat, lon: lon, diameter: diameter, shape: manualShape)
        onApply(
            .manual(lat: lat, lon: lon, diameter: diameter, shape: manualShape),
            geometry,
            "\(manualShape.rawValue) \(Int(diameter))m generated (\(geometry.polygon.count) vertices)"
        )
    }
}
