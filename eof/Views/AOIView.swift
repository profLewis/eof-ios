import SwiftUI
import MapKit
import UniformTypeIdentifiers

// MARK: - Flow Layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(maxWidth: bounds.width, subviews: subviews)
        for (i, pos) in result.positions.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layout(maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, sz.height)
            x += sz.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Drawing Mode

enum AOIDrawMode: String, CaseIterable {
    case view = "View"
    case edit = "Edit"
    case freestyle = "Freestyle"
    case polygon = "Polygon"
    case circle = "Circle"
    case rectangle = "Rectangle"

    var icon: String {
        switch self {
        case .view: return "eye"
        case .edit: return "pencil"
        case .freestyle: return "scribble"
        case .polygon: return "pentagon"
        case .circle: return "circle.dashed"
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

    // Freestyle drawing
    @State private var freestylePoints: [CLLocationCoordinate2D] = []
    @State private var isFreestyleDrawing: Bool = false

    // Circle drawing
    @State private var circleCenter: CLLocationCoordinate2D?
    @State private var circleEdge: CLLocationCoordinate2D?

    // Edit mode: shape translation
    @State private var isDraggingShape: Bool = false
    @State private var dragShapeStart: CLLocationCoordinate2D?

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

    // Crop map overlay
    @State private var cropMapRaster: CropMapRaster?
    @State private var cropMapBlocks: [CropMapBlock] = []
    @State private var cropMapFields: [ExtractedField] = []
    @State private var highlightedFieldID: UUID?
    @State private var showCropMapOverlay: Bool = true
    @State private var cropMapOpacity: Double = 0.5
    @State private var isDownloadingCropMap: Bool = false
    @State private var cropMapDownloadTask: Task<Void, Never>?
    @State private var enabledCropCodes: Set<UInt8> = []
    @State private var cropClassSummary: [(code: UInt8, count: Int, name: String)] = []
    @State private var selectedMaskSourceOverride: CropMapDataSource? = nil
    private let cropMapService = CropMapService()

    // Track whether AOI was modified in this session
    @State private var aoiGenerationOnEntry: Int = 0

    // Auto crop map download on camera stop
    @State private var autoCropMapTask: Task<Void, Never>?
    @State private var lastCameraRegion: MKCoordinateRegion?

    // Feedback
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var statusMessage: String?  // ongoing activity
    @State private var showingLog: Bool = false

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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        // Cancel any running downloads/tasks
                        autoCropMapTask?.cancel()
                        cropMapDownloadTask?.cancel()
                        isDownloadingCropMap = false
                        isPresented = false
                    }
                    .font(.subheadline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // If no AOI set yet, use visible map region
                        if settings.aoiGeometry == nil, let region = lastCameraRegion {
                            let c = region.center
                            let s = region.span
                            let latH = min(s.latitudeDelta, 0.1) / 2
                            let lonH = min(s.longitudeDelta, 0.1) / 2
                            let verts: [(lat: Double, lon: Double)] = [
                                (c.latitude - latH, c.longitude - lonH),
                                (c.latitude - latH, c.longitude + lonH),
                                (c.latitude + latH, c.longitude + lonH),
                                (c.latitude + latH, c.longitude - lonH),
                            ]
                            settings.aoiGeometry = AOIGeometry.fromVertices(verts)
                            settings.aoiSource = .mapRect(minLat: c.latitude - latH, minLon: c.longitude - lonH, maxLat: c.latitude + latH, maxLon: c.longitude + lonH)
                            settings.aoiGeneration += 1
                        }
                        isPresented = false
                    } label: {
                        Label("Confirm", systemImage: "checkmark")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $showingImport) {
                importSheet
            }
            .sheet(isPresented: $showingLog) {
                NavigationStack {
                    aoiLogView
                        .navigationTitle("Activity Log")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showingLog = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .onAppear {
                aoiGenerationOnEntry = settings.aoiGeneration
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
                    // Auto-download crop map using priority order
                    if cropMapRaster == nil {
                        downloadCropMap()
                    }
                } else {
                    // No AOI yet — set initial view based on location or locale
                    setInitialRegionFromLocationOrLocale()
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
            Map(position: $cameraPosition, interactionModes: [.rectangle, .freestyle, .circle, .edit].contains(drawMode) ? [] : .all) {
                // Crop map colored blocks (from CDL/WorldCover download)
                if showCropMapOverlay && cropMapOpacity > 0.05 {
                    ForEach(cropMapBlocks) { block in
                        MapPolygon(coordinates: [
                            CLLocationCoordinate2D(latitude: block.minLat, longitude: block.minLon),
                            CLLocationCoordinate2D(latitude: block.minLat, longitude: block.maxLon),
                            CLLocationCoordinate2D(latitude: block.maxLat, longitude: block.maxLon),
                            CLLocationCoordinate2D(latitude: block.maxLat, longitude: block.minLon),
                        ])
                        .foregroundStyle(Color(
                            red: Double(block.r)/255,
                            green: Double(block.g)/255,
                            blue: Double(block.b)/255
                        ).opacity(cropMapOpacity))
                    }

                    // Extracted field outlines (largest fields only, for tap targets)
                    ForEach(cropMapFields.prefix(20)) { field in
                        let isHighlighted = highlightedFieldID == field.id
                        let coords = field.vertices.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        }
                        MapPolygon(coordinates: coords)
                            .foregroundStyle(isHighlighted ? .green.opacity(0.25) : .white.opacity(0.08))
                            .stroke(isHighlighted ? Color.green : Color.yellow, lineWidth: isHighlighted ? 3 : 1.5)
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: field.centroid.lat, longitude: field.centroid.lon
                        )) {
                            Text("\(field.cropName) \(formatArea(field.areaSqM))")
                                .font(.system(size: 7).bold())
                                .foregroundStyle(isHighlighted ? .green : .white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(isHighlighted ? .green.opacity(0.2) : .black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(isHighlighted ? .green : .clear, lineWidth: 1))
                                .onTapGesture {
                                    if highlightedFieldID == field.id {
                                        // Second tap confirms selection
                                        selectExtractedField(field)
                                    } else {
                                        // First tap highlights
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            highlightedFieldID = field.id
                                        }
                                    }
                                }
                        }
                    }

                    // Tap-to-select field polygons (transparent overlay for polygon tap)
                    ForEach(cropMapFields.prefix(20)) { field in
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: field.centroid.lat - 0.0001,
                            longitude: field.centroid.lon
                        )) {
                            Color.clear
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if highlightedFieldID == field.id {
                                        selectExtractedField(field)
                                    } else {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            highlightedFieldID = field.id
                                        }
                                    }
                                }
                        }
                    }
                }

                // Current AOI polygon (green) — view or edit mode with edit vertices
                if (drawMode == .view || drawMode == .edit), editVertices.count >= 3 {
                    MapPolygon(coordinates: editVertices)
                        .foregroundStyle(.green.opacity(0.15))
                        .stroke(.green, lineWidth: 2)
                } else if drawMode != .view && drawMode != .edit, let geo = settings.aoiGeometry {
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

                // Drawing preview: freestyle path
                if drawMode == .freestyle, freestylePoints.count >= 2 {
                    MapPolyline(coordinates: freestylePoints)
                        .stroke(.orange, lineWidth: 2.5)
                }

                // Drawing preview: circle
                if drawMode == .circle, let center = circleCenter, let edge = circleEdge {
                    let circleVerts = generateCircleVertices(center: center, edge: edge, count: 36)
                    MapPolygon(coordinates: circleVerts)
                        .foregroundStyle(.blue.opacity(0.15))
                        .stroke(.blue, lineWidth: 2)
                }

                // Vertex handles (edit mode)
                if drawMode == .edit, editVertices.count >= 3 {
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
            .mapControls {
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                lastCameraRegion = context.region
                scheduleAutoCropMapDownload()
            }
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
        } else if drawMode == .freestyle {
            Color.clear.contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if let coord = proxy.convert(value.location, from: .local) {
                                if !isFreestyleDrawing {
                                    freestylePoints = []
                                    isFreestyleDrawing = true
                                }
                                if let last = freestylePoints.last {
                                    let dist = hypot(coord.latitude - last.latitude, coord.longitude - last.longitude)
                                    if dist > 0.00002 { freestylePoints.append(coord) }
                                } else {
                                    freestylePoints.append(coord)
                                }
                            }
                        }
                        .onEnded { _ in
                            isFreestyleDrawing = false
                            finalizeFreestyle()
                        }
                )
        } else if drawMode == .circle {
            Color.clear.contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            circleCenter = proxy.convert(value.startLocation, from: .local)
                            circleEdge = proxy.convert(value.location, from: .local)
                        }
                        .onEnded { _ in
                            if let center = circleCenter, let edge = circleEdge {
                                applyDrawnCircle(center: center, edge: edge)
                            }
                            circleCenter = nil
                            circleEdge = nil
                            drawMode = .view
                        }
                )
        } else if drawMode == .edit {
            Color.clear.contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            guard let coord = proxy.convert(value.location, from: .local) else { return }
                            if !isDraggingShape {
                                if let startCoord = proxy.convert(value.startLocation, from: .local),
                                   pointInPolygonGeo(startCoord, polygon: editVertices) {
                                    isDraggingShape = true
                                    dragShapeStart = startCoord
                                }
                            }
                            if isDraggingShape, let start = dragShapeStart {
                                let dLat = coord.latitude - start.latitude
                                let dLon = coord.longitude - start.longitude
                                editVertices = editVertices.map {
                                    CLLocationCoordinate2D(latitude: $0.latitude + dLat, longitude: $0.longitude + dLon)
                                }
                                dragShapeStart = coord
                            }
                        }
                        .onEnded { _ in
                            if isDraggingShape { applyEditVertices() }
                            isDraggingShape = false
                            dragShapeStart = nil
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
            case .view:
                EmptyView()
            case .edit:
                if editVertices.count >= 3 {
                    Text("Drag shape to move \u{2022} Tap vertex to select")
                        .font(.caption.bold())
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                }
            case .freestyle:
                Text("Drag to draw freehand shape")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            case .polygon:
                Text(drawingVertices.isEmpty ? "Tap to add vertices" :
                     drawingVertices.count < 3 ? "Tap to add more vertices (\(drawingVertices.count)/3 min)" :
                     "Tap to add, or tap first vertex to close")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            case .circle:
                Text("Drag from center outward")
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
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 4) {
            // === TOP SECTION: Crop layer key + transparency + dates (directly under map) ===

            // Crop map class key (wrapping chips)
            if !cropClassSummary.isEmpty {
                FlowLayout(spacing: 3) {
                    ForEach(cropClassSummary.prefix(12), id: \.code) { entry in
                        let isOn = enabledCropCodes.contains(entry.code)
                        let classColor = cropClassColor(entry.code)
                        Button {
                            if isOn {
                                enabledCropCodes.remove(entry.code)
                            } else {
                                enabledCropCodes.insert(entry.code)
                            }
                            refreshCropMapOverlay()
                        } label: {
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(classColor)
                                    .frame(width: 8, height: 8)
                                Text(entry.name)
                                    .font(.system(size: 7))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(isOn ? classColor.opacity(0.25) : Color.secondary.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(isOn ? classColor : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Transparency slider + data source attribution
            if !cropClassSummary.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: $cropMapOpacity, in: 0...0.8, step: 0.1)
                        .frame(maxWidth: 120)
                    Text("\(Int(cropMapOpacity * 100))%")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    let applicableLayers = settings.cropMapLayers.filter { layer in
                        if layer.coverage == .conus && !isUSLocation { return false }
                        return layer.enabled
                    }
                    if applicableLayers.count > 1 {
                        Menu {
                            ForEach(applicableLayers) { layer in
                                Button {
                                    redownloadCropMapWithSource(layer.id == "cdl" ? .cdl : .worldCover)
                                } label: {
                                    let isCurrent = (cropMapRaster?.source == .cdl && layer.id == "cdl") ||
                                                    (cropMapRaster?.source == .worldCover && layer.id == "worldcover")
                                    Label("\(layer.name) (\(layer.resolution)m)", systemImage: isCurrent ? "checkmark" : (layer.id == "cdl" ? "map" : "globe"))
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(cropMapRaster?.source == .cdl ? "CDL \(selectedYear)" : "WorldCover")
                                    .font(.system(size: 7).bold())
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 6))
                            }
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(applicableLayers.first?.name ?? "WorldCover")
                            .font(.system(size: 7).bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Date range
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $settings.startDate, displayedComponents: .date)
                    .labelsHidden()
                    .scaleEffect(0.8, anchor: .leading)
                    .fixedSize()
                Text("\u{2013}")
                    .font(.system(size: 9))
                DatePicker("", selection: $settings.endDate, displayedComponents: .date)
                    .labelsHidden()
                    .scaleEffect(0.8, anchor: .leading)
                    .fixedSize()
                Spacer()
            }

            // Status + messages
            if errorMessage != nil || successMessage != nil || statusMessage != nil {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        if let err = errorMessage {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                        if let msg = successMessage {
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        }
                        if let status = statusMessage {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(status).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
            }

            // === MIDDLE: Mode + action buttons ===

            // Mode selector + action buttons in one row
            HStack(spacing: 4) {
                Menu {
                    ForEach(AOIDrawMode.allCases, id: \.self) { mode in
                        Button { drawMode = mode } label: {
                            Label(mode.rawValue, systemImage: mode.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: drawMode.icon).font(.caption)
                        Text(drawMode.rawValue).font(.caption.bold())
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .onChange(of: drawMode) {
                    selectedVertexIndex = nil
                    if drawMode == .polygon { drawingVertices = [] }
                    if drawMode == .rectangle { rectStart = nil; rectEnd = nil }
                    if drawMode == .freestyle { freestylePoints = []; isFreestyleDrawing = false }
                    if drawMode == .circle { circleCenter = nil; circleEdge = nil }
                    if drawMode == .edit || drawMode == .view, let geo = settings.aoiGeometry { loadEditVertices(from: geo) }
                    isDraggingShape = false
                }
                .onChange(of: selectedYear) {
                    // Update date fields to new year
                    var cal = Calendar.current
                    cal.timeZone = TimeZone(identifier: "UTC")!
                    if let startMonth = cal.dateComponents([.month], from: settings.startDate).month,
                       let endMonth = cal.dateComponents([.month], from: settings.endDate).month {
                        let startDay = cal.component(.day, from: settings.startDate)
                        let endDay = cal.component(.day, from: settings.endDate)
                        let endYear = endMonth < startMonth ? selectedYear + 1 : selectedYear
                        if let newStart = cal.date(from: DateComponents(year: selectedYear, month: startMonth, day: startDay)),
                           let newEnd = cal.date(from: DateComponents(year: endYear, month: endMonth, day: endDay)) {
                            settings.startDate = newStart
                            settings.endDate = newEnd
                        }
                    }
                    // Re-download crop map for new year if we have one loaded
                    if cropMapRaster != nil {
                        cropMapBlocks = []
                        cropMapFields = []
                        cropMapRaster = nil
                        cropClassSummary = []
                        downloadCropMap()
                    }
                }

                // Contextual buttons
                if drawMode == .polygon && drawingVertices.count >= 3 {
                    Button { closePolygon() } label: {
                        Image(systemName: "checkmark.circle").font(.caption)
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                }
                if drawMode == .polygon && !drawingVertices.isEmpty {
                    Button { drawingVertices.removeLast() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                if drawMode == .freestyle && !freestylePoints.isEmpty {
                    Button { freestylePoints = []; isFreestyleDrawing = false } label: {
                        Image(systemName: "arrow.uturn.backward").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                if drawMode == .edit, let idx = selectedVertexIndex, editVertices.count > 3 {
                    Button {
                        editVertices.remove(at: idx); selectedVertexIndex = nil; applyEditVertices()
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.bordered).tint(.red)
                }
                if drawMode == .edit, editVertices.count >= 3 {
                    Button {
                        let cx = editVertices.map(\.latitude).reduce(0, +) / Double(editVertices.count)
                        let cy = editVertices.map(\.longitude).reduce(0, +) / Double(editVertices.count)
                        let anchor = CLLocationCoordinate2D(latitude: cx, longitude: cy)
                        editVertices = rotateVertices(editVertices, by: .degrees(15), around: anchor)
                        applyEditVertices()
                    } label: {
                        Image(systemName: "rotate.right").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        let cx = editVertices.map(\.latitude).reduce(0, +) / Double(editVertices.count)
                        let cy = editVertices.map(\.longitude).reduce(0, +) / Double(editVertices.count)
                        let anchor = CLLocationCoordinate2D(latitude: cx, longitude: cy)
                        editVertices = rotateVertices(editVertices, by: .degrees(-15), around: anchor)
                        applyEditVertices()
                    } label: {
                        Image(systemName: "rotate.left").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button { requestMyLocation() } label: {
                    Image(systemName: "location.fill").font(.caption)
                }
                .buttonStyle(.bordered)

                Button { showingImport = true } label: {
                    Image(systemName: "square.and.arrow.down").font(.caption)
                }
                .buttonStyle(.bordered)

                Button { showingLog = true } label: {
                    Image(systemName: "doc.text").font(.caption)
                }
                .buttonStyle(.bordered)

                if settings.aoiGeometry != nil {
                    Button {
                        settings.aoiGeometry = nil; editVertices = []; drawingVertices = []
                        selectedVertexIndex = nil; clearMessages(); successMessage = "AOI cleared"
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.bordered).tint(.red)
                }
            }

            // AOI summary
            if let geo = settings.aoiGeometry {
                let c = geo.centroid
                Text("\(settings.aoiSourceLabel) \u{2022} \(String(format: "%.4f, %.4f", c.lat, c.lon)) \u{2022} \(editVertices.count)v")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // === BOTTOM: Crop field picker ===

            // Random crop field: compact icon pickers
            HStack(spacing: 2) {
                // Region
                Menu {
                    ForEach(CropMapSource.allCases) { source in
                        Button {
                            selectedCropMap = source
                            selectedCrop = "Any"
                            // Clear crop map data so crop list reverts to region defaults
                            cropClassSummary = []
                            cropMapRaster = nil
                            cropMapBlocks = []
                            cropMapFields = []
                        } label: {
                            Label(source.rawValue, systemImage: source == selectedCropMap ? "checkmark" : "globe")
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "globe").font(.system(size: 9))
                        Text(selectedCropMap.shortName).font(.system(size: 9).bold())
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }

                // Crop — show real crops from downloaded map, or region defaults
                Menu {
                    Button { selectedCrop = "Any" } label: { Text("Any") }
                    ForEach(availableCropNames, id: \.self) { crop in
                        Button { selectedCrop = crop } label: { Text(crop) }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "leaf").font(.system(size: 9))
                        Text(selectedCrop).font(.system(size: 9).bold()).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }

                // Year
                Menu {
                    let thisYear = Calendar.current.component(.year, from: Date())
                    ForEach((2017...thisYear).reversed(), id: \.self) { yr in
                        Button { selectedYear = yr } label: { Text(String(yr)) }
                    }
                } label: {
                    Text(String(selectedYear)).font(.system(size: 9).bold())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }

                Spacer()

                // Shuffle visible fields from current crop map
                if cropMapRaster != nil {
                    Button { refreshCropMapOverlay(shuffle: true) } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                // Random location from database
                Button { pickRandomField() } label: {
                    Image(systemName: "dice").font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    showFieldOverlays.toggle(); showCropMapOverlay.toggle()
                } label: {
                    Image(systemName: (showFieldOverlays || showCropMapOverlay) ? "eye.fill" : "eye.slash")
                        .font(.caption)
                        .foregroundStyle((showFieldOverlays || showCropMapOverlay) ? .orange : .secondary)
                }
                .buttonStyle(.bordered)

                Button { downloadCropMap() } label: {
                    if isDownloadingCropMap {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "map.fill").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDownloadingCropMap)
            }

            // Crop season info + source attribution
            if let sample = lastCropSample {
                let monthNames = Calendar.current.shortMonthSymbols
                let sowM = monthNames[sample.plantingMonth - 1]
                let harvM = monthNames[sample.harvestMonth - 1]
                HStack(spacing: 4) {
                    Image(systemName: "leaf").font(.system(size: 9)).foregroundStyle(.green)
                    Text("\(sample.crop), \(sample.region)").font(.system(size: 9).bold())
                    Text("\(sowM)\u{2013}\(harvM)").font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    Button { applyCropDates(sample) } label: {
                        Text("Use Dates").font(.system(size: 8).bold())
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
                Text("Crop calendar: \(selectedCropMap.rawValue) database")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Nearby field info
            if let info = nearbyFieldInfo {
                HStack(spacing: 4) {
                    Image(systemName: "leaf.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    Text(info).font(.system(size: 9)).foregroundStyle(.orange)
                    Spacer()
                }
            }

            // Recent AOIs + Search this area
            HStack(spacing: 6) {
                if settings.aoiHistory.count > 1 {
                    Menu {
                        ForEach(settings.aoiHistory) { entry in
                            Button {
                                settings.restoreAOI(entry)
                                if let geo = settings.aoiGeometry {
                                    loadEditVertices(from: geo)
                                }
                                clearMessages()
                                successMessage = "Restored: \(entry.label)"
                                flyToAOI()
                                downloadCropMap()
                            } label: {
                                if entry.label == settings.aoiSourceLabel {
                                    Label(entry.label, systemImage: "checkmark")
                                } else {
                                    Text(entry.label)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 9))
                            Text("History (\(settings.aoiHistory.count))").font(.system(size: 9).bold())
                            Image(systemName: "chevron.down").font(.system(size: 7))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                Button {
                    downloadCropMapForVisibleRegion()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "magnifyingglass").font(.system(size: 9))
                        Text("Search area").font(.system(size: 9).bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(isDownloadingCropMap || lastCameraRegion == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        }  // end ScrollView(.vertical)
        .frame(maxHeight: 300)
        .background(.ultraThinMaterial)
    }

    // MARK: - Log View

    private var aoiLogView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(log.entries.suffix(200)) { entry in
                        HStack(alignment: .top, spacing: 4) {
                            Text(entry.timeString)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue)
                                .font(.system(size: 8, design: .monospaced).bold())
                                .foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : entry.level == .success ? .green : .secondary)
                                .frame(width: 30, alignment: .leading)
                            Text(entry.message)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onAppear {
                if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
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
                    settings.aoiGeneration += 1
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
        settings.aoiGeneration += 1
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
                // Auto-download crop map for the new area
                try? await Task.sleep(for: .milliseconds(500))
                downloadCropMap()
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
        settings.aoiGeneration += 1
        settings.recordAOI()
        loadEditVertices(from: geometry)
        clearMessages()
        successMessage = "Rectangle applied"
        log.info("AOI: map rect \(String(format: "%.4f", minLat))-\(String(format: "%.4f", maxLat)), \(String(format: "%.4f", minLon))-\(String(format: "%.4f", maxLon))")
        checkNearbyField(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
    }

    // MARK: - Area Formatting

    /// Format area adaptively: m² for small areas, ha for larger ones.
    private func formatArea(_ sqm: Double) -> String {
        let ha = sqm / 10000
        if ha < 0.1 {
            return "\(Int(sqm))m\u{00B2}"
        } else if ha < 10 {
            return String(format: "%.1fha", ha)
        } else {
            return String(format: "%.0fha", ha)
        }
    }

    // MARK: - Circle Drawing

    private func generateCircleVertices(center: CLLocationCoordinate2D, edge: CLLocationCoordinate2D, count: Int = 36) -> [CLLocationCoordinate2D] {
        let dLat = edge.latitude - center.latitude
        let dLon = edge.longitude - center.longitude
        let cosLat = cos(center.latitude * .pi / 180)
        let dist = hypot(dLat, dLon * cosLat)
        let rLat = dist
        let rLon = dist / max(0.01, cosLat)
        return (0..<count).map { i in
            let angle = Double(i) * 2.0 * .pi / Double(count)
            return CLLocationCoordinate2D(
                latitude: center.latitude + rLat * sin(angle),
                longitude: center.longitude + rLon * cos(angle)
            )
        }
    }

    private func applyDrawnCircle(center: CLLocationCoordinate2D, edge: CLLocationCoordinate2D) {
        let cosLat = cos(center.latitude * .pi / 180)
        let dLat = edge.latitude - center.latitude
        let dLon = (edge.longitude - center.longitude) * cosLat
        let radiusMeters = hypot(dLat, dLon) * 111_320.0
        guard radiusMeters > 10 else {
            errorMessage = "Circle too small \u{2014} drag further"
            return
        }
        let circleVerts = generateCircleVertices(center: center, edge: edge, count: 36)
        editVertices = circleVerts
        applyEditVertices()
        clearMessages()
        successMessage = "Circle applied (~\(Int(radiusMeters))m radius)"
        log.info("AOI: circle at \(String(format: "%.4f, %.4f", center.latitude, center.longitude)), radius ~\(Int(radiusMeters))m")
        checkNearbyField(lat: center.latitude, lon: center.longitude)
    }

    // MARK: - Freestyle Drawing

    private func finalizeFreestyle() {
        guard freestylePoints.count >= 5 else {
            freestylePoints = []
            errorMessage = "Draw a larger shape"
            return
        }
        var simplified = simplifyPath(freestylePoints, epsilon: 0.00005)
        if simplified.count < 3 { simplified = freestylePoints }
        if simplified.count > 100 {
            let step = simplified.count / 50
            simplified = stride(from: 0, to: simplified.count, by: step).map { simplified[$0] }
        }
        editVertices = simplified
        freestylePoints = []
        applyEditVertices()
        drawMode = .view
        clearMessages()
        successMessage = "Freestyle polygon (\(editVertices.count) vertices)"
        if let geo = settings.aoiGeometry {
            let c = geo.centroid
            checkNearbyField(lat: c.lat, lon: c.lon)
        }
    }

    private func simplifyPath(_ points: [CLLocationCoordinate2D], epsilon: Double) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }
        var maxDist: Double = 0
        var maxIdx = 0
        let first = points.first!, last = points.last!
        for i in 1..<(points.count - 1) {
            let d = perpendicularDist(points[i], lineStart: first, lineEnd: last)
            if d > maxDist { maxDist = d; maxIdx = i }
        }
        if maxDist > epsilon {
            let left = simplifyPath(Array(points[0...maxIdx]), epsilon: epsilon)
            let right = simplifyPath(Array(points[maxIdx...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        } else {
            return [first, last]
        }
    }

    private func perpendicularDist(_ point: CLLocationCoordinate2D, lineStart: CLLocationCoordinate2D, lineEnd: CLLocationCoordinate2D) -> Double {
        let dx = lineEnd.longitude - lineStart.longitude
        let dy = lineEnd.latitude - lineStart.latitude
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else { return hypot(point.longitude - lineStart.longitude, point.latitude - lineStart.latitude) }
        let num = abs(dy * point.longitude - dx * point.latitude + lineEnd.longitude * lineStart.latitude - lineEnd.latitude * lineStart.longitude)
        return num / sqrt(lengthSq)
    }

    // MARK: - Edit Mode Helpers

    private func pointInPolygonGeo(_ point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        let n = polygon.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let yi = polygon[i].latitude, xi = polygon[i].longitude
            let yj = polygon[j].latitude, xj = polygon[j].longitude
            if ((yi > point.latitude) != (yj > point.latitude)) &&
                (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private func rotateVertices(_ vertices: [CLLocationCoordinate2D], by angle: Angle, around anchor: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let cosA = cos(angle.radians)
        let sinA = sin(angle.radians)
        return vertices.map { v in
            let dx = v.longitude - anchor.longitude
            let dy = v.latitude - anchor.latitude
            return CLLocationCoordinate2D(
                latitude: anchor.latitude + dy * cosA - dx * sinA,
                longitude: anchor.longitude + dx * cosA + dy * sinA
            )
        }
    }

    // MARK: - Location

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
                    settings.aoiGeneration += 1
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

    /// Crop names available: from downloaded crop map if available, else from region database.
    private var availableCropNames: [String] {
        if !cropClassSummary.isEmpty {
            return cropClassSummary.map { $0.name }.sorted()
        }
        return selectedCropMap.availableCrops
    }

    private func selectCropField(_ sample: CropFieldSample) {
        let verts = selectedCropMap.fieldPolygon(for: sample)
        let geometry = AOIGeometry.fromVertices(verts)

        // Set dates BEFORE incrementing generation (which triggers fetch)
        let dates = CropMapSource.dateRange(
            plantingMonth: sample.plantingMonth,
            harvestMonth: sample.harvestMonth,
            year: selectedYear
        )
        settings.startDate = dates.start
        settings.endDate = dates.end

        // Now set AOI and trigger fetch
        settings.aoiSource = .cropSample(crop: sample.crop, region: sample.region, sowMonth: sample.plantingMonth, harvMonth: sample.harvestMonth)
        settings.aoiGeometry = geometry
        settings.recordAOI()
        loadEditVertices(from: geometry)
        lastCropSample = sample

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

        // Increment generation LAST to trigger fetch with correct dates/geometry
        settings.aoiGeneration += 1
    }

    private func pickRandomField() {
        let cropFilter = selectedCrop == "Any" ? nil : selectedCrop
        let fieldW = selectedCropMap.typicalFieldWidth
        let mapSource = selectedCropMap
        let year = selectedYear

        clearMessages()
        statusMessage = "Finding crop field..."
        drawMode = .view
        isDownloadingCropMap = true

        Task {
            // Try up to 3 random locations to find one with actual crop fields
            for attempt in 1...3 {
                let sample = mapSource.randomField(crop: cropFilter)

                await MainActor.run {
                    lastCropSample = sample
                    statusMessage = "Finding \(sample.crop) near \(sample.region)... (\(attempt)/3)"
                }

                let aoiRadius = fieldW * 2.0
                let metersPerDegLat = 111_320.0
                let metersPerDegLon = max(1, 111_320.0 * cos(sample.lat * .pi / 180))
                let dLat = aoiRadius / metersPerDegLat
                let dLon = aoiRadius / metersPerDegLon

                let bbox = (
                    minLon: sample.lon - dLon,
                    minLat: sample.lat - dLat,
                    maxLon: sample.lon + dLon,
                    maxLat: sample.lat + dLat
                )
                let isUS = bbox.minLon > -130 && bbox.maxLon < -60 && bbox.minLat > 24 && bbox.maxLat < 50

                do {
                    let raster: CropMapRaster
                    if isUS {
                        raster = try await cropMapService.downloadCDL(bbox: bbox, year: year)
                    } else {
                        raster = try await cropMapService.downloadWorldCover(bbox: bbox)
                    }

                    // Find target crop codes
                    let targetCodes: [UInt8]
                    if isUS {
                        targetCodes = CDLCropType.codes(forCrop: sample.crop)
                    } else {
                        targetCodes = [40]
                    }

                    // Extract fields
                    var allFields = [ExtractedField]()
                    for code in targetCodes {
                        let fields = await cropMapService.extractFields(from: raster, cropCode: code, minPixels: 4)
                        allFields.append(contentsOf: fields)
                    }
                    if allFields.isEmpty && isUS {
                        for code: UInt8 in [1, 2, 3, 4, 5, 21, 23, 24, 36] {
                            let fields = await cropMapService.extractFields(from: raster, cropCode: code, minPixels: 4)
                            allFields.append(contentsOf: fields)
                        }
                    }

                    // No fields found — retry with different location
                    if allFields.isEmpty && attempt < 3 {
                        await MainActor.run {
                            log.info("AOI: No crops at \(sample.region), retrying...")
                        }
                        continue
                    }

                    // Score fields by proximity to ideal size
                    let targetAreaSqM = fieldW * fieldW * 1.5
                    allFields.sort { f1, f2 in
                        abs(Darwin.log(max(1, f1.areaSqM) / targetAreaSqM)) <
                        abs(Darwin.log(max(1, f2.areaSqM) / targetAreaSqM))
                    }

                    let hist = raster.histogram()

                    // Set dates from crop calendar
                    let dates = CropMapSource.dateRange(
                        plantingMonth: sample.plantingMonth,
                        harvestMonth: sample.harvestMonth,
                        year: year
                    )

                    await MainActor.run {
                        settings.startDate = dates.start
                        settings.endDate = dates.end
                        cropMapRaster = raster
                        cropClassSummary = hist

                        if let bestField = allFields.first {
                            log.success("AOI: Found \(bestField.cropName) field — \(formatArea(bestField.areaSqM))")
                            enabledCropCodes = Set(targetCodes.isEmpty ? [bestField.cropCode] : targetCodes.map { $0 })
                            refreshCropMapOverlay()

                            let verts = bestField.vertices
                            let geometry = AOIGeometry.fromVertices(verts)
                            settings.aoiSource = .cropSample(crop: sample.crop, region: sample.region, sowMonth: sample.plantingMonth, harvMonth: sample.harvestMonth)
                            settings.aoiGeometry = geometry
                            settings.recordAOI()
                            loadEditVertices(from: geometry)

                            statusMessage = nil
                            successMessage = "\(bestField.cropName) — \(formatArea(bestField.areaSqM)) (\(sample.region))"

                            cameraPosition = .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: bestField.centroid.lat, longitude: bestField.centroid.lon),
                                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                            ))
                            settings.aoiGeneration += 1
                        } else {
                            log.warn("AOI: No crop fields found after \(attempt) attempts, using database")
                            enabledCropCodes = Set(targetCodes)
                            refreshCropMapOverlay()
                            selectCropField(sample)
                            statusMessage = nil
                            successMessage = "\(sample.crop) — \(sample.region) (database location)"
                        }

                        isDownloadingCropMap = false
                        cameraPosition = .region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: sample.lat, longitude: sample.lon),
                            span: MKCoordinateSpan(latitudeDelta: dLat * 3, longitudeDelta: dLon * 3)
                        ))
                    }
                    return // success — exit retry loop
                } catch {
                    if attempt == 3 {
                        await MainActor.run {
                            isDownloadingCropMap = false
                            statusMessage = nil
                            log.warn("AOI: Crop mask failed (\(error.localizedDescription)), using database")
                            selectCropField(sample)
                        }
                    }
                    // else retry
                }
            }
        }
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

    private func applyCropDates(_ sample: CropFieldSample) {
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
        successMessage = "Dates: \(fmt.string(from: dates.start)) \u{2013} \(fmt.string(from: dates.end))"
    }

    // MARK: - Crop Map Download

    /// Whether a coordinate is within CONUS (CDL coverage).
    private func isUSCoordinate(lat: Double, lon: Double) -> Bool {
        lon > -130 && lon < -60 && lat > 24 && lat < 50
    }

    /// Whether the current AOI or visible region is within CONUS.
    private var isUSLocation: Bool {
        if let geo = settings.aoiGeometry {
            let c = geo.centroid
            return isUSCoordinate(lat: c.lat, lon: c.lon)
        }
        if let region = lastCameraRegion {
            return isUSCoordinate(lat: region.center.latitude, lon: region.center.longitude)
        }
        return false
    }

    /// Schedule auto crop map download after camera stops (2 second debounce).
    /// Only triggers when no crop map is loaded yet (initial exploration).
    private func scheduleAutoCropMapDownload() {
        // Don't auto-download if we already have a crop map loaded
        guard cropMapRaster == nil else { return }
        autoCropMapTask?.cancel()
        autoCropMapTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard !isDownloadingCropMap else { return }
            guard cropMapRaster == nil else { return }
            // Only auto-download in view mode (don't interrupt drawing)
            guard drawMode == .view else { return }
            downloadCropMapForVisibleRegion()
        }
    }

    /// Download crop map for the visible map region, setting it as the AOI bbox.
    private func downloadCropMapForVisibleRegion() {
        guard let region = lastCameraRegion else {
            clearMessages()
            errorMessage = "No map region available"
            return
        }
        let center = region.center
        let span = region.span
        // Don't download for very large or very small regions
        guard span.latitudeDelta < 1.5 && span.longitudeDelta < 1.5 else {
            clearMessages()
            errorMessage = "Zoom in more to search area"
            log.info("AOI: Region too large for crop map (\(String(format: "%.2f°×%.2f°", span.latitudeDelta, span.longitudeDelta)))")
            return
        }
        guard span.latitudeDelta > 0.0005 else { return }
        // Use a ~10km window centred on the map (keeps raster small + fast)
        let windowDeg = 0.1
        let latHalf = min(span.latitudeDelta, windowDeg) / 2
        let lonHalf = min(span.longitudeDelta, windowDeg) / 2
        let minLat = center.latitude - latHalf
        let maxLat = center.latitude + latHalf
        let minLon = center.longitude - lonHalf
        let maxLon = center.longitude + lonHalf

        // Set visible window as AOI rectangle
        let vertices: [(lat: Double, lon: Double)] = [
            (minLat, minLon), (minLat, maxLon), (maxLat, maxLon), (maxLat, minLon)
        ]
        let geometry = AOIGeometry.fromVertices(vertices)
        settings.aoiSource = .mapRect(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        settings.aoiGeometry = geometry
        editVertices = vertices.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        settings.aoiGeneration += 1

        downloadCropMap()
    }

    /// Re-download crop map with a specific source (user switched via menu).
    private func redownloadCropMapWithSource(_ source: CropMapDataSource) {
        selectedMaskSourceOverride = source
        cropMapBlocks = []
        cropMapFields = []
        cropMapRaster = nil
        cropClassSummary = []
        downloadCropMap()
    }

    private func downloadCropMap() {
        guard !isDownloadingCropMap else { return }

        // Determine bbox: use current AOI or visible map region
        var bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)
        if let geo = settings.aoiGeometry {
            let b = geo.bbox
            let latPad = (b.maxLat - b.minLat) * 0.1
            let lonPad = (b.maxLon - b.minLon) * 0.1
            bbox = (b.minLon - lonPad, b.minLat - latPad, b.maxLon + lonPad, b.maxLat + latPad)
            // Clamp padded bbox to keep crop map raster small (~10km window)
            let maxSpan = 0.12
            let latSpan = bbox.maxLat - bbox.minLat
            let lonSpan = bbox.maxLon - bbox.minLon
            if latSpan > maxSpan {
                let mid = (bbox.minLat + bbox.maxLat) / 2
                bbox.minLat = mid - maxSpan / 2
                bbox.maxLat = mid + maxSpan / 2
            }
            if lonSpan > maxSpan {
                let mid = (bbox.minLon + bbox.maxLon) / 2
                bbox.minLon = mid - maxSpan / 2
                bbox.maxLon = mid + maxSpan / 2
            }
        } else if let region = lastCameraRegion {
            // Use visible map region as fallback
            let center = region.center
            let span = region.span
            bbox = (
                center.longitude - span.longitudeDelta / 2,
                center.latitude - span.latitudeDelta / 2,
                center.longitude + span.longitudeDelta / 2,
                center.latitude + span.latitudeDelta / 2
            )
        } else {
            clearMessages()
            errorMessage = "Pan the map to an area, then download crop map"
            return
        }

        // Check bbox isn't too large (WorldCover tiles are 3°x3°, CDL can handle ~1°)
        let bboxLatSpan = bbox.maxLat - bbox.minLat
        let bboxLonSpan = bbox.maxLon - bbox.minLon
        if bboxLatSpan > 0.5 || bboxLonSpan > 0.5 {
            clearMessages()
            errorMessage = "Zoom in more to load crop map (max ~50km)"
            return
        }

        // Determine source from priority list or manual override
        let useSource: CropMapDataSource
        if let overrideSource = selectedMaskSourceOverride {
            useSource = overrideSource
        } else {
            let isUS = isUSLocation
            if let match = settings.cropMapLayers.first(where: { layer in
                guard layer.enabled else { return false }
                if layer.coverage == .conus && !isUS { return false }
                return true
            }) {
                useSource = match.id == "cdl" ? .cdl : .worldCover
            } else {
                useSource = .worldCover
            }
        }
        selectedMaskSourceOverride = nil

        isDownloadingCropMap = true
        clearMessages()
        let sourceName = useSource == .cdl ? "USDA CDL \(selectedYear)" : "ESA WorldCover"
        statusMessage = "Downloading \(sourceName)..."
        log.info("AOI: Downloading \(sourceName) for bbox \(String(format: "%.3f,%.3f,%.3f,%.3f", bbox.minLon, bbox.minLat, bbox.maxLon, bbox.maxLat))")

        let isUS = isUSLocation
        cropMapDownloadTask?.cancel()
        cropMapDownloadTask = Task {
            do {
                let raster: CropMapRaster
                if useSource == .cdl && isUS {
                    raster = try await cropMapService.downloadCDL(bbox: bbox, year: selectedYear)
                } else {
                    raster = try await cropMapService.downloadWorldCover(bbox: bbox)
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    statusMessage = "Processing \(raster.width)x\(raster.height) raster..."
                    log.info("AOI: Got \(raster.width)x\(raster.height) \(sourceName) raster")
                }

                let hist = raster.histogram()

                var defaultCodes = Set<UInt8>()
                if selectedCrop != "Any" {
                    let codes = CDLCropType.codes(forCrop: selectedCrop)
                    defaultCodes = Set(codes)
                }
                if defaultCodes.isEmpty {
                    let cropCodes: Set<UInt8> = Set((1...60).map { UInt8($0) } + [176])
                    let wcCropCode: UInt8 = 40
                    for entry in hist.prefix(8) {
                        if raster.source == .cdl && cropCodes.contains(entry.code) {
                            defaultCodes.insert(entry.code)
                        } else if raster.source == .worldCover && entry.code == wcCropCode {
                            defaultCodes.insert(entry.code)
                        }
                    }
                }
                if defaultCodes.isEmpty, let top = hist.first {
                    defaultCodes.insert(top.code)
                }

                await MainActor.run {
                    cropMapRaster = raster
                    cropClassSummary = hist
                    enabledCropCodes = defaultCodes
                    isDownloadingCropMap = false

                    if hist.isEmpty {
                        statusMessage = nil
                        errorMessage = "No land cover data in this area (ocean or no coverage)"
                        log.warn("AOI: Crop map empty — no land cover classes found")
                    } else {
                        let topCrops = hist.prefix(3).map { $0.name }.joined(separator: ", ")
                        statusMessage = "Extracting fields from \(topCrops)..."
                        log.info("AOI: \(raster.width)x\(raster.height) raster — \(topCrops)")
                        // Extract fields async — result message set inside refreshCropMapOverlay
                        refreshCropMapOverlay()
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloadingCropMap = false
                    statusMessage = nil
                    errorMessage = "Crop map: \(error.localizedDescription)"
                    log.error("AOI: Crop map failed — \(error.localizedDescription)")
                }
            }
        }
    }

    /// Refresh the map overlay blocks and extracted fields for enabled classes.
    /// If `shuffle` is true, randomise the field selection order to show different candidates.
    private func refreshCropMapOverlay(shuffle: Bool = false) {
        highlightedFieldID = nil
        guard let raster = cropMapRaster else {
            cropMapBlocks = []
            cropMapFields = []
            return
        }

        let codes = enabledCropCodes
        Task {
            await MainActor.run {
                statusMessage = "Building map overlay..."
            }

            // Use larger blocks to keep polygon count manageable for SwiftUI Map (~500 max)
            let maxDim = max(raster.width, raster.height)
            let blockSize = max(4, maxDim / 30)  // ~30 blocks per axis → ~900 max blocks
            var blocks = await cropMapService.generateBlocks(from: raster, enabledCodes: codes, blockSize: blockSize)
            if blocks.count > 500 { blocks = Array(blocks.prefix(500)) }

            await MainActor.run {
                statusMessage = "Extracting crop fields (\(codes.count) class\(codes.count == 1 ? "" : "es"))..."
            }

            // Extract fields — use low minPixels (4) for small windows
            var allFields = [ExtractedField]()
            for code in codes {
                let fields = await cropMapService.extractFields(from: raster, cropCode: code, minPixels: 4)
                allFields.append(contentsOf: fields)
            }

            // If no fields with enabled codes, try all crop codes as fallback
            if allFields.isEmpty {
                await MainActor.run {
                    statusMessage = "No fields for selected crops — trying all crop types..."
                }
                let fallbackCodes: [UInt8] = raster.source == .worldCover ? [40] : Array((1...60).map { UInt8($0) })
                for code in fallbackCodes where !codes.contains(code) {
                    let fields = await cropMapService.extractFields(from: raster, cropCode: code, minPixels: 4)
                    allFields.append(contentsOf: fields)
                }
            }

            // Filter to approximately field-sized: 0.5–500 hectares, not too thin
            let minFieldArea = 5_000.0    // 0.5 ha
            let maxFieldArea = 5_000_000.0 // 500 ha
            let maxAspect = 5.0 // reject fields thinner than 5:1
            let fieldSized = allFields.filter { f in
                guard f.areaSqM >= minFieldArea && f.areaSqM <= maxFieldArea else { return false }
                // Check aspect ratio from bbox (use metres for lat/lon correction)
                let latSpan = abs(f.bbox.maxLat - f.bbox.minLat)
                let lonSpan = abs(f.bbox.maxLon - f.bbox.minLon)
                guard latSpan > 0 && lonSpan > 0 else { return false }
                let cosLat = cos(f.centroid.lat * .pi / 180)
                let h = latSpan * 111_320
                let w = lonSpan * 111_320 * cosLat
                let aspect = max(h, w) / max(min(h, w), 1)
                return aspect <= maxAspect
            }
            // Sort by proximity to ideal field size (~20 ha) and compactness, or shuffle
            let idealArea = 200_000.0 // 20 ha
            func fieldScore(_ f: ExtractedField) -> Double {
                let sizeScore = abs(Darwin.log(max(1, f.areaSqM) / idealArea))
                let latSpan = abs(f.bbox.maxLat - f.bbox.minLat)
                let lonSpan = abs(f.bbox.maxLon - f.bbox.minLon)
                let cosLat = cos(f.centroid.lat * .pi / 180)
                let h = latSpan * 111_320
                let w = lonSpan * 111_320 * cosLat
                let aspect = max(h, w) / max(min(h, w), 1)
                return sizeScore + (aspect - 1) * 0.3 // penalise elongated fields
            }
            let sorted: [ExtractedField]
            if fieldSized.isEmpty {
                sorted = shuffle ? allFields.shuffled() : allFields.sorted { $0.areaSqM > $1.areaSqM }
            } else if shuffle {
                sorted = fieldSized.shuffled()
            } else {
                sorted = fieldSized.sorted { fieldScore($0) < fieldScore($1) }
            }

            let finalFields = Array(sorted.prefix(30))
            let totalFound = allFields.count
            let fieldSizedCount = fieldSized.count

            await MainActor.run {
                cropMapBlocks = blocks
                cropMapFields = finalFields

                if finalFields.isEmpty {
                    statusMessage = nil
                    if totalFound == 0 {
                        errorMessage = "No crop fields found in this area"
                    } else {
                        errorMessage = "Found \(totalFound) regions but none field-sized"
                    }
                    log.warn("AOI: No suitable fields (\(totalFound) total, \(fieldSizedCount) field-sized)")
                } else {
                    let topNames = Array(Set(finalFields.prefix(5).map { $0.cropName })).prefix(3).joined(separator: ", ")
                    statusMessage = nil
                    successMessage = "\(finalFields.count) fields — \(topNames)"
                    log.success("AOI: \(finalFields.count) fields from \(totalFound) total (\(fieldSizedCount) field-sized)")
                }
            }
        }
    }

    private func cropClassColor(_ code: UInt8) -> Color {
        if let raster = cropMapRaster {
            switch raster.source {
            case .cdl:
                if let c = CDLCropType(rawValue: code) {
                    return Color(red: Double(c.color.r)/255, green: Double(c.color.g)/255, blue: Double(c.color.b)/255)
                }
            case .worldCover:
                if let c = WorldCoverClass(rawValue: code) {
                    return Color(red: Double(c.color.r)/255, green: Double(c.color.g)/255, blue: Double(c.color.b)/255)
                }
            }
        }
        return .gray
    }

    private func selectExtractedField(_ field: ExtractedField) {
        // Cancel any pending auto-download
        autoCropMapTask?.cancel()
        highlightedFieldID = nil

        // Clear heavy overlays FIRST to prevent SwiftUI render crash
        cropMapBlocks = []
        cropMapFields = []

        let verts = field.vertices
        guard verts.count >= 3 else {
            errorMessage = "Field has too few vertices"
            return
        }
        let geometry = AOIGeometry.fromVertices(verts)

        // Set dates from crop calendar — use sample if available, otherwise estimate
        let sowMonth: Int
        let harvMonth: Int
        let regionName: String
        if let sample = lastCropSample {
            sowMonth = sample.plantingMonth
            harvMonth = sample.harvestMonth
            regionName = sample.region
        } else {
            let cal = estimateCropCalendar(cropName: field.cropName, latitude: field.centroid.lat)
            sowMonth = cal.sow
            harvMonth = cal.harv
            regionName = cal.region
        }
        let dates = CropMapSource.dateRange(plantingMonth: sowMonth, harvestMonth: harvMonth, year: selectedYear)
        settings.startDate = dates.start
        settings.endDate = dates.end
        settings.aoiSource = .cropSample(crop: field.cropName, region: regionName, sowMonth: sowMonth, harvMonth: harvMonth)

        settings.aoiGeometry = geometry
        settings.recordAOI()
        loadEditVertices(from: geometry)

        clearMessages()
        successMessage = "\(field.cropName) field — \(formatArea(field.areaSqM))"
        drawMode = .view

        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: field.centroid.lat, longitude: field.centroid.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        ))

        // Increment generation LAST to trigger fetch with correct dates/geometry
        settings.aoiGeneration += 1

        // Dismiss the AOI tool — field selected, ready to fetch
        isPresented = false
    }

    /// On first launch with no AOI, centre map on the default SF_field area.
    private func setInitialRegionFromLocationOrLocale() {
        // Default: SF_field.geojson area (South Africa, near Johannesburg)
        let defaultCenter = CLLocationCoordinate2D(latitude: -26.964, longitude: 28.744)
        let spanDeg = 0.1  // ~10km — compatible with crop map window

        cameraPosition = .region(MKCoordinateRegion(
            center: defaultCenter,
            span: MKCoordinateSpan(latitudeDelta: spanDeg, longitudeDelta: spanDeg)
        ))
        log.info("AOI: Initial view — SF_field default area")
    }

    /// Estimate crop calendar (sow/harvest months) from crop name and latitude.
    private func estimateCropCalendar(cropName: String, latitude: Double) -> (sow: Int, harv: Int, region: String) {
        let name = cropName.lowercased()
        let isNorth = latitude >= 0
        let isTropical = abs(latitude) < 23.5

        // Winter crops (wheat, barley, rye, rapeseed/canola)
        let isWinter = name.contains("winter") || name.contains("barley") || name.contains("rye") ||
                        name.contains("canola") || name.contains("rapeseed")
        // Summer crops (maize, corn, soy, cotton, rice, sunflower, sorghum)
        let isSummer = name.contains("maize") || name.contains("corn") || name.contains("soy") ||
                       name.contains("cotton") || name.contains("rice") || name.contains("sunflower") ||
                       name.contains("sorghum") || name.contains("millet")

        if isTropical {
            // Tropical: year-round growing, approximate wet season
            if isNorth {
                return (sow: 6, harv: 12, region: "Tropical N")
            } else {
                return (sow: 11, harv: 5, region: "Tropical S")
            }
        }

        if isWinter {
            // Winter crops: sow autumn, harvest early summer
            if isNorth {
                return latitude > 45 ? (sow: 9, harv: 7, region: "N Temperate") : (sow: 10, harv: 6, region: "N Warm")
            } else {
                return latitude < -35 ? (sow: 4, harv: 12, region: "S Temperate") : (sow: 5, harv: 11, region: "S Warm")
            }
        }

        if isSummer {
            if isNorth {
                return (sow: 4, harv: 10, region: "N Temperate")
            } else {
                return (sow: 10, harv: 4, region: "S Temperate")
            }
        }

        // Default: full growing season
        if isNorth {
            return (sow: 3, harv: 10, region: "N Hemisphere")
        } else {
            return (sow: 9, harv: 4, region: "S Hemisphere")
        }
    }

    /// Returns a random coordinate within agricultural regions of the device locale's country.
    private func randomPointInLocaleCountry() -> CLLocationCoordinate2D {
        let code = Locale.current.region?.identifier ?? "US"
        // Approximate agricultural bounding boxes per country
        let boxes: [String: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)] = [
            "US": (30, 45, -105, -80),
            "GB": (51, 53, -3, 1),
            "FR": (44, 49, -1, 5),
            "DE": (48, 53, 7, 14),
            "ES": (37, 42, -5, 2),
            "IT": (41, 45, 9, 15),
            "IN": (15, 28, 73, 85),
            "CN": (28, 40, 105, 120),
            "BR": (-25, -10, -52, -42),
            "AU": (-35, -28, 140, 152),
            "ZA": (-32, -26, 24, 30),
            "JP": (33, 38, 130, 140),
            "CA": (44, 52, -105, -75),
            "UA": (48, 52, 30, 38),
            "AR": (-38, -30, -63, -58),
            "NL": (51.5, 53, 4, 6.5),
            "PL": (50, 53, 17, 23),
        ]
        let box = boxes[code] ?? boxes["US"]!
        let lat = Double.random(in: box.minLat...box.maxLat)
        let lon = Double.random(in: box.minLon...box.maxLon)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
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
