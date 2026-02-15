import SwiftUI
import MapKit
import UniformTypeIdentifiers

// MARK: - Drawing Mode

enum AOIDrawMode: String, CaseIterable {
    case view = "View"
    case polygon = "Polygon"
    case rectangle = "Rectangle"

    var icon: String {
        switch self {
        case .view: return "hand.point.up"
        case .polygon: return "pentagon"
        case .rectangle: return "rectangle.dashed"
        }
    }
}

struct AOIView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared
    private let log = ActivityLog.shared

    // Map state
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var drawMode: AOIDrawMode = .view

    // Rectangle drawing
    @State private var rectStart: CLLocationCoordinate2D?
    @State private var rectEnd: CLLocationCoordinate2D?

    // Polygon digitizing
    @State private var drawingVertices: [CLLocationCoordinate2D] = []

    // Vertex editing
    @State private var editVertices: [CLLocationCoordinate2D] = []
    @State private var selectedVertexIndex: Int? = nil
    @State private var dragOriginal: CLLocationCoordinate2D? = nil

    // Search
    @State private var searchText = ""
    @State private var searchService = PlaceSearchService()
    @State private var showingSearchResults = false

    // Location
    @State private var locationService = LocationService()
    @State private var locationDiameter: Double = 500

    // Crop map random field
    @State private var selectedCropMap: CropMapSource = .global
    @State private var selectedCrop: String = "Any"
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date()) - 1
    @State private var lastCropSample: CropFieldSample?
    @State private var showFieldOverlays: Bool = true
    @State private var nearbyFieldInfo: String?

    // Import sheet
    @State private var showingImport = false

    // Feedback
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                mapView
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
                if let geo = settings.aoiGeometry {
                    loadEditVertices(from: geo)
                    let c = geo.centroid
                    let b = geo.bbox
                    let latSpan = (b.maxLat - b.minLat) * 2.0
                    let lonSpan = (b.maxLon - b.minLon) * 2.0
                    cameraPosition = .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon),
                        span: MKCoordinateSpan(latitudeDelta: max(0.005, latSpan), longitudeDelta: max(0.005, lonSpan))
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
            Map(position: $cameraPosition, interactionModes: drawMode == .rectangle ? [] : .all) {
                // Crop field overlays from database
                if showFieldOverlays {
                    let filteredSamples = cropFieldsForMap
                    ForEach(Array(filteredSamples.enumerated()), id: \.offset) { _, sample in
                        let verts = selectedCropMap.fieldPolygon(for: sample)
                        let coords = verts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                        MapPolygon(coordinates: coords)
                            .foregroundStyle(.orange.opacity(0.25))
                            .stroke(.orange, lineWidth: 1.5)
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: sample.lat, longitude: sample.lon)) {
                            Text(sample.crop)
                                .font(.system(size: 8).bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                                .onTapGesture { selectCropField(sample) }
                        }
                    }
                }

                // Current AOI polygon (green) — only in view mode with edit vertices
                if drawMode == .view, editVertices.count >= 3 {
                    MapPolygon(coordinates: editVertices)
                        .foregroundStyle(.green.opacity(0.15))
                        .stroke(.green, lineWidth: 2)
                } else if drawMode != .view, let geo = settings.aoiGeometry {
                    // Show existing AOI while drawing
                    let coords = geo.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    MapPolygon(coordinates: coords)
                        .foregroundStyle(.green.opacity(0.1))
                        .stroke(.green.opacity(0.5), lineWidth: 1)
                }

                // Drawing preview: polygon vertices
                if drawMode == .polygon {
                    // Lines between vertices
                    if drawingVertices.count >= 2 {
                        MapPolyline(coordinates: drawingVertices)
                            .stroke(.blue, lineWidth: 2)
                    }
                    // Vertex dots
                    ForEach(Array(drawingVertices.enumerated()), id: \.offset) { i, coord in
                        Annotation("", coordinate: coord) {
                            Circle()
                                .fill(i == 0 && drawingVertices.count >= 3 ? .yellow : .blue)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }

                // Drawing preview: rectangle
                if drawMode == .rectangle, let s = rectStart, let e = rectEnd {
                    let corners = rectCorners(s, e)
                    MapPolygon(coordinates: corners)
                        .foregroundStyle(.blue.opacity(0.15))
                        .stroke(.blue, lineWidth: 2)
                }

                // Vertex handles (view mode editing)
                if drawMode == .view, editVertices.count >= 3 {
                    // Main vertices
                    ForEach(Array(editVertices.enumerated()), id: \.offset) { i, coord in
                        Annotation("", coordinate: coord) {
                            vertexHandle(index: i)
                        }
                    }
                    // Midpoint handles for inserting vertices
                    ForEach(0..<editVertices.count, id: \.self) { i in
                        let next = (i + 1) % editVertices.count
                        let mid = CLLocationCoordinate2D(
                            latitude: (editVertices[i].latitude + editVertices[next].latitude) / 2,
                            longitude: (editVertices[i].longitude + editVertices[next].longitude) / 2
                        )
                        Annotation("", coordinate: mid) {
                            midpointHandle(insertAfter: i)
                        }
                    }
                }
            }
            .mapStyle(.hybrid(elevation: .flat))
            .overlay {
                mapGestureOverlay(proxy: proxy)
            }
            .overlay(alignment: .top) {
                modeOverlay
            }
        }
    }

    // MARK: - Vertex Handle

    private func vertexHandle(index: Int) -> some View {
        Circle()
            .fill(selectedVertexIndex == index ? .yellow : .white)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(.green, lineWidth: 2.5))
            .shadow(radius: 2)
            .onTapGesture {
                if selectedVertexIndex == index {
                    selectedVertexIndex = nil
                } else {
                    selectedVertexIndex = index
                }
            }
    }

    private func midpointHandle(insertAfter index: Int) -> some View {
        Circle()
            .fill(.white.opacity(0.6))
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.green.opacity(0.5), lineWidth: 1.5))
            .onTapGesture {
                let next = (index + 1) % editVertices.count
                let mid = CLLocationCoordinate2D(
                    latitude: (editVertices[index].latitude + editVertices[next].latitude) / 2,
                    longitude: (editVertices[index].longitude + editVertices[next].longitude) / 2
                )
                editVertices.insert(mid, at: next)
                selectedVertexIndex = next
                applyEditVertices()
            }
    }

    // MARK: - Map Gesture

    @ViewBuilder
    private func mapGestureOverlay(proxy: MapProxy) -> some View {
        if drawMode == .polygon {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { location in
                    if let coord = proxy.convert(location, from: .local) {
                        handleMapTap(coord)
                    }
                }
        } else if drawMode == .rectangle {
            Color.clear.contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            rectStart = proxy.convert(value.startLocation, from: .local)
                            rectEnd = proxy.convert(value.location, from: .local)
                        }
                        .onEnded { _ in
                            if let s = rectStart, let e = rectEnd {
                                applyDrawnRect(start: s, end: e)
                            }
                            rectStart = nil
                            rectEnd = nil
                            drawMode = .view
                        }
                )
        }
    }

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        guard drawMode == .polygon else { return }
        clearMessages()

        // Check if tapping near first vertex to close polygon
        if drawingVertices.count >= 3 {
            let first = drawingVertices[0]
            let dist = hypot(coord.latitude - first.latitude, coord.longitude - first.longitude)
            if dist < 0.0005 { // ~50m at mid latitudes
                closePolygon()
                return
            }
        }

        drawingVertices.append(coord)
    }

    // MARK: - Mode Overlay

    private var modeOverlay: some View {
        Group {
            switch drawMode {
            case .polygon:
                Text(drawingVertices.isEmpty ? "Tap to add vertices" :
                     drawingVertices.count < 3 ? "Tap to add more vertices (\(drawingVertices.count)/3 min)" :
                     "Tap to add, or tap first vertex to close")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            case .rectangle:
                Text("Drag to draw rectangle")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            case .view:
                EmptyView()
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 6) {
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

            // AOI summary
            if let geo = settings.aoiGeometry {
                let c = geo.centroid
                Text("\(settings.aoiSourceLabel) \u{2022} \(String(format: "%.4f, %.4f", c.lat, c.lon)) \u{2022} \(editVertices.count)v")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Mode selector
            Picker("Mode", selection: $drawMode) {
                ForEach(AOIDrawMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: drawMode) {
                selectedVertexIndex = nil
                if drawMode == .polygon {
                    drawingVertices = []
                }
                if drawMode == .rectangle {
                    rectStart = nil
                    rectEnd = nil
                }
                if drawMode == .view, let geo = settings.aoiGeometry {
                    loadEditVertices(from: geo)
                }
            }

            // Action buttons row
            HStack(spacing: 8) {
                // Close polygon (only in polygon mode with ≥3 vertices)
                if drawMode == .polygon && drawingVertices.count >= 3 {
                    Button {
                        closePolygon()
                    } label: {
                        Label("Close", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                // Undo vertex (polygon mode)
                if drawMode == .polygon && !drawingVertices.isEmpty {
                    Button {
                        drawingVertices.removeLast()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                // Delete vertex (view mode with selection)
                if drawMode == .view, let idx = selectedVertexIndex, editVertices.count > 3 {
                    Button {
                        editVertices.remove(at: idx)
                        selectedVertexIndex = nil
                        applyEditVertices()
                    } label: {
                        Label("Delete Vertex", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Spacer()

                // My Location
                Button {
                    requestMyLocation()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                // Import
                Button {
                    showingImport = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                // Clear AOI
                if settings.aoiGeometry != nil {
                    Button {
                        settings.aoiGeometry = nil
                        editVertices = []
                        drawingVertices = []
                        selectedVertexIndex = nil
                        clearMessages()
                        successMessage = "AOI cleared"
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            // Location diameter (compact)
            HStack(spacing: 4) {
                Text("Location \u{00F8}:")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("\(Int(locationDiameter))m")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: $locationDiameter, in: 100...10000, step: 100)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .fixedSize()
                Spacer()
            }

            // Nearby field info (shown when user manually selects near a known crop area)
            if let info = nearbyFieldInfo {
                HStack(spacing: 4) {
                    Image(systemName: "leaf.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(info)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Spacer()
                    if let sample = lastCropSample {
                        Button {
                            let dates = CropMapSource.dateRange(
                                plantingMonth: sample.plantingMonth,
                                harvestMonth: sample.harvestMonth,
                                year: selectedYear
                            )
                            settings.startDate = dates.start
                            settings.endDate = dates.end
                            clearMessages()
                            let fmt = DateFormatter()
                            fmt.dateFormat = "d MMM yyyy"
                            successMessage = "Dates set: \(fmt.string(from: dates.start)) \u{2013} \(fmt.string(from: dates.end))"
                        } label: {
                            Text("Set Dates")
                                .font(.system(size: 9).bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            // Random crop field: region + crop + year + go
            HStack(spacing: 4) {
                Picker("Region", selection: $selectedCropMap) {
                    ForEach(CropMapSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .fixedSize()
                .onChange(of: selectedCropMap) {
                    // Reset crop filter when region changes
                    selectedCrop = "Any"
                }

                Picker("Crop", selection: $selectedCrop) {
                    Text("Any").tag("Any")
                    ForEach(selectedCropMap.availableCrops, id: \.self) { crop in
                        Text(crop).tag(crop)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .fixedSize()

                Picker("Year", selection: $selectedYear) {
                    let thisYear = Calendar.current.component(.year, from: Date())
                    ForEach((2017...thisYear).reversed(), id: \.self) { yr in
                        Text(String(yr)).tag(yr)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .fixedSize()

                Button {
                    pickRandomField()
                } label: {
                    Image(systemName: "dice")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    showFieldOverlays.toggle()
                } label: {
                    Image(systemName: showFieldOverlays ? "eye.fill" : "eye.slash")
                        .font(.caption)
                        .foregroundStyle(showFieldOverlays ? .orange : .secondary)
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            // Crop season info + set dates button
            if let sample = lastCropSample {
                let monthNames = Calendar.current.shortMonthSymbols
                let sowM = monthNames[sample.plantingMonth - 1]
                let harvM = monthNames[sample.harvestMonth - 1]
                HStack(spacing: 4) {
                    Image(systemName: "leaf")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                    Text("\(sample.crop), \(sample.region)")
                        .font(.system(size: 9).bold())
                    Text("Sow \(sowM) \u{2192} Harvest \(harvM)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let dates = CropMapSource.dateRange(
                            plantingMonth: sample.plantingMonth,
                            harvestMonth: sample.harvestMonth,
                            year: selectedYear
                        )
                        settings.startDate = dates.start
                        settings.endDate = dates.end
                        let fmt = DateFormatter()
                        fmt.dateFormat = "d MMM yyyy"
                        clearMessages()
                        successMessage = "Dates set: \(fmt.string(from: dates.start)) \u{2013} \(fmt.string(from: dates.end))"
                    } label: {
                        Text("Set Dates")
                            .font(.system(size: 9).bold())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            // Recent AOIs
            if settings.aoiHistory.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(settings.aoiHistory) { entry in
                            Button {
                                settings.restoreAOI(entry)
                                if let geo = settings.aoiGeometry {
                                    loadEditVertices(from: geo)
                                }
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
                    loadEditVertices(from: geometry)
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

    private func loadEditVertices(from geo: GeoJSONGeometry) {
        var verts = geo.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        // Remove closing vertex if it duplicates the first
        if verts.count > 1, let first = verts.first, let last = verts.last,
           abs(first.latitude - last.latitude) < 1e-10,
           abs(first.longitude - last.longitude) < 1e-10 {
            verts.removeLast()
        }
        editVertices = verts
    }

    private func applyEditVertices() {
        guard editVertices.count >= 3 else { return }
        let verts = editVertices.map { (lat: $0.latitude, lon: $0.longitude) }
        let geometry = AOIGeometry.fromVertices(verts)
        settings.aoiSource = .digitized
        settings.aoiGeometry = geometry
        settings.recordAOI()
    }

    private func closePolygon() {
        guard drawingVertices.count >= 3 else { return }
        editVertices = drawingVertices
        drawingVertices = []
        applyEditVertices()
        drawMode = .view
        clearMessages()
        successMessage = "Polygon created (\(editVertices.count) vertices)"
        if let geo = settings.aoiGeometry {
            let c = geo.centroid
            checkNearbyField(lat: c.lat, lon: c.lon)
        }
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
            errorMessage = "Rectangle too small \u{2014} drag further"
            return
        }

        let geometry = AOIGeometry.generateRect(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        settings.aoiSource = .mapRect(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        settings.aoiGeometry = geometry
        settings.recordAOI()
        loadEditVertices(from: geometry)
        clearMessages()
        successMessage = "Rectangle applied"
        log.info("AOI: map rect \(String(format: "%.4f", minLat))-\(String(format: "%.4f", maxLat)), \(String(format: "%.4f", minLon))-\(String(format: "%.4f", maxLon))")
        checkNearbyField(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
    }

    private func requestMyLocation() {
        clearMessages()
        locationService.requestLocation()
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
                    loadEditVertices(from: geometry)
                    successMessage = "My location: \(String(format: "%.4f, %.4f", coord.latitude, coord.longitude))"
                    log.info("AOI: my location \(String(format: "%.4f, %.4f", coord.latitude, coord.longitude)), \(Int(locationDiameter))m")
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        latitudinalMeters: locationDiameter * 3, longitudinalMeters: locationDiameter * 3
                    ))
                    checkNearbyField(lat: coord.latitude, lon: coord.longitude)
                    return
                }
                if let err = locationService.error {
                    errorMessage = err
                    return
                }
            }
            errorMessage = "Location timeout \u{2014} try again"
        }
    }

    /// Crop fields to display on map (filtered by current crop selection).
    private var cropFieldsForMap: [CropFieldSample] {
        let all = selectedCropMap.samples
        if selectedCrop == "Any" { return all }
        return all.filter { $0.crop == selectedCrop }
    }

    private func selectCropField(_ sample: CropFieldSample) {
        let verts = selectedCropMap.fieldPolygon(for: sample)
        let geometry = AOIGeometry.fromVertices(verts)
        settings.aoiSource = .cropSample(crop: sample.crop, region: sample.region)
        settings.aoiGeometry = geometry
        settings.recordAOI()
        loadEditVertices(from: geometry)
        lastCropSample = sample

        let dates = CropMapSource.dateRange(
            plantingMonth: sample.plantingMonth,
            harvestMonth: sample.harvestMonth,
            year: selectedYear
        )
        settings.startDate = dates.start
        settings.endDate = dates.end

        let monthNames = Calendar.current.shortMonthSymbols
        let sowM = monthNames[sample.plantingMonth - 1]
        let harvM = monthNames[sample.harvestMonth - 1]
        clearMessages()
        successMessage = "\(sample.crop) \u{2014} \(sample.region) (\(sowM)\u{2013}\(harvM) \(selectedYear))"
        drawMode = .view

        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: sample.lat, longitude: sample.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        ))
    }

    private func pickRandomField() {
        let cropFilter = selectedCrop == "Any" ? nil : selectedCrop
        let sample = selectedCropMap.randomField(crop: cropFilter)
        selectCropField(sample)
    }

    /// Check if a manually selected location is near a known crop field and inform the user.
    private func checkNearbyField(lat: Double, lon: Double) {
        nearbyFieldInfo = nil
        if let match = CropMapSource.nearestField(lat: lat, lon: lon) {
            let monthNames = Calendar.current.shortMonthSymbols
            let sowM = monthNames[match.sample.plantingMonth - 1]
            let harvM = monthNames[match.sample.harvestMonth - 1]
            nearbyFieldInfo = "Near \(match.source.rawValue): \(match.sample.crop), \(match.sample.region) (\(sowM)\u{2013}\(harvM)) \u{2014} \(String(format: "%.0f", match.distKm))km away"
            lastCropSample = match.sample
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
