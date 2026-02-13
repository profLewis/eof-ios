import SwiftUI
import Charts
import MapKit

struct ContentView: View {
    @State private var processor = NDVIProcessor()
    @State private var settings = AppSettings.shared
    @State private var currentFrameIndex = 0
    @State private var isPlaying = false
    @State private var timer: Timer?
    // settings.playbackSpeed now in settings
    @State private var showingLog = false
    @State private var showingSettings = false
    @State private var dragStartIndex = 0
    @State private var log = ActivityLog.shared
    @State private var lastStartDate: String = ""
    @State private var lastEndDate: String = ""
    @State private var lastNDVIThreshold: Float = 0.2
    @State private var lastSCLClasses: Set<Int> = [4, 5]
    @State private var lastCloudMask: Bool = true
    @State private var lastEnforceAOI: Bool = true
    @State private var basemapImage: CGImage?
    // Double logistic phenology fit
    @State private var dlBest: DLParams?
    @State private var dlEnsemble: [DLParams] = []
    @State private var dlSliders = DLParams(mn: 0.1, mx: 0.7, sos: 120, rsp: 0.05, eos: 280, rau: 0.05)
    @State private var showDLSliders = false
    // Per-pixel phenology
    @State private var pixelPhenology: PixelPhenologyResult?
    @State private var pixelFitProgress: Double = 0
    @State private var isRunningPixelFit = false
    @State private var phenologyDisplayParam: PhenologyParameter?
    @State private var showingClusterView = false
    @State private var showData = true
    // Cluster filter
    @State private var unfilteredPhenology: PixelPhenologyResult?
    @State private var isClusterFiltered = false
    @State private var showBadData = false
    @State private var tappedPixelDetail: PixelPhenology?
    @State private var showingPixelDetail = false
    // Sub-AOI selection
    @State private var isSelectMode = false
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var selectionItem: SelectionItem?
    // Zoom
    @State private var imageZoomScale: CGFloat = 1.0

    struct SelectionItem: Identifiable {
        let id = UUID()
        let minRow: Int, maxRow: Int, minCol: Int, maxCol: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    headerSection
                    statusSection

                    if processor.status == .idle {
                        fetchButton
                    }

                    if !processor.frames.isEmpty {
                        ndviSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            .navigationTitle("eof")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if processor.status == .idle {
                    startFetch()
                }
            }
            .onChange(of: processor.status) {
                // Auto-play when loading finishes
                if processor.status == .done && !processor.frames.isEmpty && !isPlaying {
                    currentFrameIndex = 0
                    togglePlayback()
                    // Load basemap if enabled
                    if settings.showBasemap && basemapImage == nil {
                        loadBasemap()
                    }
                    // Auto-fit double logistic
                    if processor.frames.count >= 4 {
                        runDLFit()
                    }
                }
            }
            .onChange(of: settings.showBasemap) {
                if settings.showBasemap && basemapImage == nil && !processor.frames.isEmpty {
                    loadBasemap()
                }
            }
            .onChange(of: settings.displayMode) {
                // Lazy-load missing bands in background — view re-renders instantly
                if !processor.frames.isEmpty {
                    Task {
                        await processor.loadMissingBands(for: settings.displayMode)
                    }
                }
            }
            .onChange(of: settings.aoiSourceLabel) {
                // Reset to idle when AOI changes so user re-fetches
                if processor.status == .done || processor.status == .error {
                    stopPlayback()
                    currentFrameIndex = 0
                    processor.resetGeometry()
                    processor.status = .idle
                    processor.frames = []
                    processor.progress = 0
                    processor.progressMessage = ""
                    processor.errorMessage = nil
                    basemapImage = nil  // clear stale basemap
                }
            }
            .onChange(of: showingSettings) {
                // When settings sheet is dismissed, check what changed
                if !showingSettings && processor.status == .done {
                    // Check if NDVI threshold or SCL settings changed → recompute stats
                    if settings.ndviThreshold != lastNDVIThreshold ||
                       settings.sclValidClasses != lastSCLClasses ||
                       settings.cloudMask != lastCloudMask ||
                       settings.enforceAOI != lastEnforceAOI {
                        lastNDVIThreshold = settings.ndviThreshold
                        lastSCLClasses = settings.sclValidClasses
                        lastCloudMask = settings.cloudMask
                        lastEnforceAOI = settings.enforceAOI
                        processor.recomputeStats()
                    }

                    // Check if dates changed → incremental update
                    let newStart = settings.startDateString
                    let newEnd = settings.endDateString
                    if newStart != lastStartDate || newEnd != lastEndDate {
                        guard let geo = settings.aoiGeometry else { return }
                        log.info("Date range changed: \(lastStartDate)–\(lastEndDate) → \(newStart)–\(newEnd)")
                        lastStartDate = newStart
                        lastEndDate = newEnd
                        stopPlayback()
                        currentFrameIndex = 0
                        Task {
                            await processor.updateDateRange(
                                geometry: geo,
                                startDate: newStart,
                                endDate: newEnd
                            )
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        if processor.status == .done || processor.status == .error {
                            Button {
                                resetAndFetch()
                            } label: {
                                Label("Redo", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.glass)
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.glass)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLog = true
                    } label: {
                        Label("Log", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $showingLog) {
                LogView(isPresented: $showingLog, processor: processor)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(isPresented: $showingSettings)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingClusterView) {
                if let pp = pixelPhenology {
                    ClusterView(isPresented: $showingClusterView, result: pp)
                        .presentationDetents([.large])
                }
            }
            .sheet(item: $selectionItem) { sel in
                SelectionAnalysisView(
                    minRow: sel.minRow, maxRow: sel.maxRow,
                    minCol: sel.minCol, maxCol: sel.maxCol,
                    frames: processor.frames,
                    pixelPhenology: pixelPhenology,
                    medianFit: dlBest
                )
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showingPixelDetail) {
                if let px = tappedPixelDetail {
                    PixelDetailSheet(pixel: px, frames: processor.frames)
                        .presentationDetents([.medium])
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 2) {
            Text("S2 \(settings.displayMode.rawValue) | \(settings.startDateString)–\(settings.endDateString) | \(settings.enabledSources.map { $0.shortName }.joined(separator: "+"))")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(settings.aoiSourceLabel)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .contextMenu {
                    if settings.aoiHistory.count > 1 {
                        ForEach(settings.aoiHistory) { entry in
                            Button {
                                settings.restoreAOI(entry)
                            } label: {
                                if entry.label == settings.aoiSourceLabel {
                                    Label(entry.label, systemImage: "checkmark")
                                } else {
                                    Text(entry.label)
                                }
                            }
                        }
                    }
                }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Group {
            switch processor.status {
            case .idle:
                EmptyView()
            case .searching, .processing:
                VStack(spacing: 8) {
                    HStack {
                        ProgressView(value: processor.progress) {
                            Text(processor.isPaused ? "Paused" : processor.progressMessage)
                                .font(.caption)
                                .foregroundStyle(processor.isPaused ? .orange : .primary)
                        }
                        if processor.status == .processing {
                            Button {
                                if processor.isPaused {
                                    processor.resumeFetch()
                                } else {
                                    processor.pauseFetch()
                                }
                            } label: {
                                Image(systemName: processor.isPaused ? "play.fill" : "pause.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(processor.isPaused ? .green : .orange)
                        }
                        Button {
                            processor.cancelFetch()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    if processor.status == .searching {
                        ProgressView()
                    }
                    if !processor.sourceProgresses.isEmpty {
                        SourceProgressView(progresses: processor.sourceProgresses)
                    }
                }
            case .done:
                Label(processor.progressMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        if processor.status == .done {
                            processor.progressMessage = ""
                        }
                    }
            case .error:
                Label(processor.errorMessage ?? "Unknown error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Fetch Button

    private var fetchButton: some View {
        Button(action: startFetch) {
            Label("Fetch Data", systemImage: "arrow.down.circle.fill")
                .font(.title3)
                .padding()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.blue)
    }

    // MARK: - NDVI Display

    private var ndviSection: some View {
        VStack(spacing: 16) {
            if currentFrameIndex < processor.frames.count {
                let frame = processor.frames[currentFrameIndex]

                VStack(spacing: 4) {
                    HStack {
                        Text(frame.dateString)
                            .font(.subheadline.monospacedDigit().bold())
                        Text("DOY \(frame.dayOfYear)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    let currentPhenoMap: [[Float]]? = phenologyDisplayParam.flatMap { param in
                        pixelPhenology?.parameterMap(param)
                    }
                    let currentRejectionMap: [[Float]]? = showBadData ? pixelPhenology?.rejectionReasonMap() : nil

                    GeometryReader { geo in
                        let fitScale = max(1, min(8, geo.size.width / CGFloat(frame.width)))
                        NDVIMapView(frame: frame, scale: fitScale, showPolygon: true, showColorBar: true,
                                    displayMode: settings.displayMode,
                                    cloudMask: settings.cloudMask,
                                    ndviThreshold: settings.ndviThreshold,
                                    sclValidClasses: settings.sclValidClasses,
                                    showSCLBoundaries: phenologyDisplayParam == nil && !showBadData && settings.showSCLBoundaries,
                                    enforceAOI: settings.enforceAOI,
                                    showMaskedClassColors: settings.showMaskedClassColors,
                                    basemapImage: settings.showBasemap ? basemapImage : nil,
                                    phenologyMap: showData && !showBadData ? currentPhenoMap : nil,
                                    phenologyParam: showData && !showBadData ? phenologyDisplayParam : nil,
                                    rejectionMap: showData ? currentRejectionMap : nil)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 2)
                            .opacity(showData ? 1.0 : 0.0)
                            .background {
                                if !showData, let bm = basemapImage {
                                    let imgW = CGFloat(frame.width) * fitScale
                                    Image(decorative: bm, scale: CGFloat(bm.width) / imgW)
                                        .interpolation(.high)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            .scaleEffect(imageZoomScale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    imageZoomScale = max(1.0, min(8.0, value.magnification))
                                }
                                .onEnded { value in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        imageZoomScale = max(1.0, min(8.0, value.magnification))
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                imageZoomScale = imageZoomScale > 1.5 ? 1.0 : 3.0
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if showBadData, let pp = pixelPhenology {
                                // Tap-to-inspect bad pixel
                                let col = Int(location.x / fitScale)
                                let row = Int(location.y / fitScale)
                                if row >= 0, row < pp.height, col >= 0, col < pp.width,
                                   let px = pp.pixels[row][col] {
                                    tappedPixelDetail = px
                                    showingPixelDetail = true
                                }
                            } else if isSelectMode {
                                selectionItem = nil
                                selectionStart = nil
                                selectionEnd = nil
                            } else {
                                togglePlayback()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    if isSelectMode {
                                        selectionStart = value.startLocation
                                        selectionEnd = value.location
                                    } else {
                                        stopPlayback()
                                        let frameCount = processor.frames.count
                                        guard frameCount > 1 else { return }
                                        let dragWidth: CGFloat = 300
                                        let fraction = value.translation.width / dragWidth
                                        let delta = Int(fraction * CGFloat(frameCount))
                                        let newIndex = max(0, min(frameCount - 1, dragStartIndex + delta))
                                        currentFrameIndex = newIndex
                                    }
                                }
                                .onEnded { _ in
                                    if isSelectMode {
                                        finalizeSelection(frame: frame, scale: fitScale)
                                    } else {
                                        dragStartIndex = currentFrameIndex
                                    }
                                }
                        )
                        // Selection rectangle overlay
                        .overlay {
                            if isSelectMode, let s = selectionStart, let e = selectionEnd {
                                let rect = CGRect(
                                    x: min(s.x, e.x), y: min(s.y, e.y),
                                    width: abs(e.x - s.x), height: abs(e.y - s.y)
                                )
                                Rectangle()
                                    .stroke(.yellow, lineWidth: 2)
                                    .background(Color.yellow.opacity(0.15))
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.caption)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(6)
                                .opacity(0.7)
                        }
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 4) {
                                Button {
                                    withAnimation { showData.toggle() }
                                } label: {
                                    Image(systemName: showData ? "eye.fill" : "eye.slash")
                                        .font(.caption)
                                        .padding(6)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                Button {
                                    openInMaps()
                                } label: {
                                    Image(systemName: "map")
                                        .font(.caption)
                                        .padding(6)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                Button {
                                    withAnimation {
                                        isSelectMode.toggle()
                                        if !isSelectMode {
                                            selectionStart = nil
                                            selectionEnd = nil
                                        }
                                    }
                                } label: {
                                    Image(systemName: isSelectMode ? "rectangle.dashed" : "selection.pin.in.out")
                                        .font(.caption)
                                        .padding(6)
                                        .background(isSelectMode ? AnyShapeStyle(.yellow.opacity(0.3)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                                }
                                Button {
                                    copyCurrentFrame(frame: frame)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .padding(6)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                            }
                            .padding(6)
                            .opacity(0.7)
                        }
                        .onAppear { dragStartIndex = currentFrameIndex }
                        .onChange(of: currentFrameIndex) { dragStartIndex = currentFrameIndex }
                    }
                    .frame(height: CGFloat(frame.height) * min(8, UIScreen.main.bounds.width / CGFloat(frame.width)) + 30)

                    HStack {
                        Text("Cloud: \(Int(frame.cloudFraction * 100))%")
                        Spacer()
                        let pct = frame.polyPixelCount > 0 ? Int(100 * Double(frame.validPixelCount) / Double(frame.polyPixelCount)) : 0
                        Text("\(frame.validPixelCount)/\(frame.polyPixelCount) px (\(pct)%)")
                        Spacer()
                        if let sid = frame.sourceID {
                            Text(sid.rawValue.uppercased())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // NDVI time series chart — synced with animation
            if processor.frames.count > 1 {
                ndviChart
                phenologySection
            }

            // Frame counter + compact SCL class key
            HStack {
                Text("\(currentFrameIndex + 1)/\(processor.frames.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(String(format: "%.1f", settings.playbackSpeed))x")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if settings.showSCLBoundaries {
                compactSCLKey
            }
        }
    }

    // MARK: - NDVI Time Series Chart

    private var ndviChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Median NDVI")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                if let pp = pixelPhenology, pp.outlierCount > 0 {
                    Text("Filtered")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
                Spacer()
                Text("Valid %")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }

            let sorted = processor.frames.sorted(by: { $0.date < $1.date })
            Chart {
                // NDVI line
                ForEach(sorted) { frame in
                    LineMark(
                        x: .value("Date", frame.date),
                        y: .value("NDVI", Double(frame.medianNDVI)),
                        series: .value("Series", "NDVI")
                    )
                    .foregroundStyle(.green.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                // Filtered median NDVI (after cluster filter) — open circles
                if let pp = pixelPhenology, pp.outlierCount > 0 {
                    let filteredMedians = pp.filteredMedianNDVI(frames: sorted)
                    ForEach(Array(zip(sorted.indices, sorted)), id: \.1.id) { idx, frame in
                        if idx < filteredMedians.count, !filteredMedians[idx].isNaN {
                            PointMark(
                                x: .value("Date", frame.date),
                                y: .value("NDVI", Double(filteredMedians[idx]))
                            )
                            .foregroundStyle(.yellow)
                            .symbol(.circle)
                            .symbolSize(30)
                        }
                    }
                }

                // Valid pixel % line (scaled to 0-1 range)
                ForEach(sorted) { frame in
                    let pct = frame.polyPixelCount > 0
                        ? Double(frame.validPixelCount) / Double(frame.polyPixelCount)
                        : 0
                    LineMark(
                        x: .value("Date", frame.date),
                        y: .value("NDVI", pct),
                        series: .value("Series", "Valid%")
                    )
                    .foregroundStyle(.blue.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                }

                // Small dots for NDVI
                ForEach(sorted) { frame in
                    PointMark(
                        x: .value("Date", frame.date),
                        y: .value("NDVI", Double(frame.medianNDVI))
                    )
                    .foregroundStyle(.green)
                    .symbolSize(15)
                }

                // Current frame indicator
                if currentFrameIndex < processor.frames.count {
                    let current = processor.frames[currentFrameIndex]
                    PointMark(
                        x: .value("Date", current.date),
                        y: .value("NDVI", Double(current.medianNDVI))
                    )
                    .foregroundStyle(.red)
                    .symbolSize(200)
                    .symbol(.circle)

                    RuleMark(x: .value("Current", current.date))
                        .foregroundStyle(.red.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                }

                // NDVI threshold line
                if settings.ndviThreshold != 0 {
                    RuleMark(y: .value("Threshold", Double(settings.ndviThreshold)))
                        .foregroundStyle(.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(String(format: "%.2f", settings.ndviThreshold))
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                }

                // Double logistic curves
                ForEach(dlCurvePoints(sorted: sorted), id: \.id) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value("NDVI", pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(pt.style)
                }

                // Phenology indicator lines (tangent slopes for rsp/rau)
                ForEach(phenologyIndicatorLines(sorted: sorted), id: \.id) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value("NDVI", pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
            .chartYAxis {
                AxisMarks(values: [-0.2, 0, 0.25, 0.5, 0.75, 1.0])
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let doy = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0
                            VStack(spacing: 1) {
                                Text(date, format: .dateTime.month(.abbreviated).day())
                                    .font(.system(size: 7))
                                Text("DOY \(doy)")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .chartYScale(domain: -0.25...1.05)
            .frame(height: 140)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        stopPlayback()
                        let frameCount = processor.frames.count
                        guard frameCount > 1 else { return }
                        // Use chart width to map drag position to frame index
                        let chartWidth = value.startLocation.x + (UIScreen.main.bounds.width - 32)
                        let fraction = max(0, min(1, value.location.x / (UIScreen.main.bounds.width - 32)))
                        let newIndex = Int(fraction * CGFloat(frameCount - 1))
                        currentFrameIndex = max(0, min(frameCount - 1, newIndex))
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: currentFrameIndex)
        }
    }

    // MARK: - Double Logistic Curve Data

    private struct DLCurvePoint: Identifiable {
        let id: String
        let date: Date
        let ndvi: Double
        let series: String
        let color: Color
        let style: StrokeStyle
    }

    private func dlCurvePoints(sorted: [NDVIFrame]) -> [DLCurvePoint] {
        guard let first = sorted.first, let last = sorted.last else { return [] }
        let cal = Calendar.current
        let year = cal.component(.year, from: first.date)
        let doyFirst = cal.ordinality(of: .day, in: .year, for: first.date) ?? 1
        let doyLast = cal.ordinality(of: .day, in: .year, for: last.date) ?? 365
        let step = max(1, (doyLast - doyFirst) / 80)
        let doys = stride(from: doyFirst, through: doyLast, by: step).map { $0 }

        var pts = [DLCurvePoint]()

        // Ensemble curves (semi-transparent)
        for (ei, ep) in dlEnsemble.prefix(15).enumerated() where ei > 0 {
            for doy in doys {
                if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                    pts.append(DLCurvePoint(
                        id: "e\(ei)_\(doy)", date: d,
                        ndvi: ep.evaluate(t: Double(doy)),
                        series: "ens\(ei)",
                        color: .yellow.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1)
                    ))
                }
            }
        }

        // Best fit
        if let dl = dlBest {
            for doy in doys {
                if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                    pts.append(DLCurvePoint(
                        id: "fit_\(doy)", date: d,
                        ndvi: dl.evaluate(t: Double(doy)),
                        series: "DL-fit",
                        color: .yellow.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2)
                    ))
                }
            }
        }

        // Slider curve
        if showDLSliders {
            for doy in doys {
                if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                    pts.append(DLCurvePoint(
                        id: "sl_\(doy)", date: d,
                        ndvi: dlSliders.evaluate(t: Double(doy)),
                        series: "DL-slider",
                        color: .cyan.opacity(0.8),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])
                    ))
                }
            }
        }

        return pts
    }

    // MARK: - Phenology Indicator Lines (precomputed for chart)

    /// Precompute tangent/slope lines for rsp/rau, or vertical/horizontal indicators
    /// for other phenology parameters. Returns DLCurvePoint array to render as LineMarks.
    private func phenologyIndicatorLines(sorted: [NDVIFrame]) -> [DLCurvePoint] {
        guard let param = phenologyDisplayParam, let fit = dlBest,
              let firstDate = sorted.first?.date else { return [] }
        let cal = Calendar.current
        let year = cal.component(.year, from: firstDate)
        var pts = [DLCurvePoint]()

        // rsp: tangent line at SOS showing green-up slope
        if param == .rsp || param == .sos || param == .seasonLength {
            let sosDoy = max(1, min(365, Int(fit.sos)))
            if let sosDate = cal.date(from: DateComponents(year: year, day: sosDoy)) {
                if param == .rsp {
                    let sosNDVI = fit.evaluate(t: fit.sos)
                    let halfSpan = 20.0
                    let slope = fit.rsp * (fit.mx - fit.mn) * 0.25
                    let d0 = max(1, sosDoy - Int(halfSpan))
                    let d1 = min(365, sosDoy + Int(halfSpan))
                    if let date0 = cal.date(from: DateComponents(year: year, day: d0)),
                       let date1 = cal.date(from: DateComponents(year: year, day: d1)) {
                        pts.append(DLCurvePoint(id: "rsp_t0", date: date0,
                            ndvi: sosNDVI - slope * halfSpan, series: "rsp-tangent",
                            color: .green, style: StrokeStyle(lineWidth: 2.5)))
                        pts.append(DLCurvePoint(id: "rsp_t1", date: date1,
                            ndvi: sosNDVI + slope * halfSpan, series: "rsp-tangent",
                            color: .green, style: StrokeStyle(lineWidth: 2.5)))
                    }
                    // Vertical dashed at SOS
                    pts.append(DLCurvePoint(id: "rsp_v0", date: sosDate, ndvi: -0.2,
                        series: "sos-rule", color: .green.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                    pts.append(DLCurvePoint(id: "rsp_v1", date: sosDate, ndvi: 1.0,
                        series: "sos-rule", color: .green.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                } else {
                    // SOS vertical line
                    pts.append(DLCurvePoint(id: "sos_v0", date: sosDate, ndvi: -0.2,
                        series: "sos-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
                    pts.append(DLCurvePoint(id: "sos_v1", date: sosDate, ndvi: 1.0,
                        series: "sos-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
                }
            }
        }

        // rau: tangent line at EOS showing senescence slope
        if param == .rau || param == .eos || param == .seasonLength {
            let eosDoy = max(1, min(365, Int(fit.eos)))
            if let eosDate = cal.date(from: DateComponents(year: year, day: eosDoy)) {
                if param == .rau {
                    let eosNDVI = fit.evaluate(t: fit.eos)
                    let halfSpan = 20.0
                    let slope = -fit.rau * (fit.mx - fit.mn) * 0.25
                    let d0 = max(1, eosDoy - Int(halfSpan))
                    let d1 = min(365, eosDoy + Int(halfSpan))
                    if let date0 = cal.date(from: DateComponents(year: year, day: d0)),
                       let date1 = cal.date(from: DateComponents(year: year, day: d1)) {
                        pts.append(DLCurvePoint(id: "rau_t0", date: date0,
                            ndvi: eosNDVI - slope * halfSpan, series: "rau-tangent",
                            color: .red, style: StrokeStyle(lineWidth: 2.5)))
                        pts.append(DLCurvePoint(id: "rau_t1", date: date1,
                            ndvi: eosNDVI + slope * halfSpan, series: "rau-tangent",
                            color: .red, style: StrokeStyle(lineWidth: 2.5)))
                    }
                    pts.append(DLCurvePoint(id: "rau_v0", date: eosDate, ndvi: -0.2,
                        series: "eos-rule", color: .red.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                    pts.append(DLCurvePoint(id: "rau_v1", date: eosDate, ndvi: 1.0,
                        series: "eos-rule", color: .red.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                } else {
                    pts.append(DLCurvePoint(id: "eos_v0", date: eosDate, ndvi: -0.2,
                        series: "eos-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
                    pts.append(DLCurvePoint(id: "eos_v1", date: eosDate, ndvi: 1.0,
                        series: "eos-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
                }
            }
        }

        // Peak NDVI horizontal line
        if param == .peakNDVI, let first = sorted.first?.date, let last = sorted.last?.date {
            pts.append(DLCurvePoint(id: "peak_h0", date: first, ndvi: fit.mx,
                series: "peak-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
            pts.append(DLCurvePoint(id: "peak_h1", date: last, ndvi: fit.mx,
                series: "peak-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
        }

        // Min NDVI horizontal line
        if param == .mn, let first = sorted.first?.date, let last = sorted.last?.date {
            pts.append(DLCurvePoint(id: "min_h0", date: first, ndvi: fit.mn,
                series: "min-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
            pts.append(DLCurvePoint(id: "min_h1", date: last, ndvi: fit.mn,
                series: "min-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
        }

        // RMSE horizontal line
        if param == .rmse, let first = sorted.first?.date, let last = sorted.last?.date {
            pts.append(DLCurvePoint(id: "rmse_h0", date: first, ndvi: fit.rmse,
                series: "rmse-line", color: .red.opacity(0.5),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
            pts.append(DLCurvePoint(id: "rmse_h1", date: last, ndvi: fit.rmse,
                series: "rmse-line", color: .red.opacity(0.5),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
        }

        return pts
    }

    // MARK: - Phenology (Double Logistic)

    private var phenologySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    withAnimation { showDLSliders.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showDLSliders ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        Text("Phenology")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.plain)

                if let dl = dlBest {
                    Text("RMSE \(String(format: "%.3f", dl.rmse))")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.yellow)
                    Text("[\(dlEnsemble.count) viable]")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fit") {
                    runDLFit()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(.yellow)
                Button("Per-Pixel") {
                    runPerPixelFit()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(dlBest == nil || isRunningPixelFit)
            }

            // Per-pixel progress
            if isRunningPixelFit {
                ProgressView(value: pixelFitProgress) {
                    Text("Fitting pixels...")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // Per-pixel results summary
            if let pp = pixelPhenology {
                HStack {
                    Text("\(pp.goodCount) good, \(pp.poorCount) poor, \(pp.skippedCount) skip")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    if pp.outlierCount > 0 {
                        Text(", \(pp.outlierCount) outlier")
                            .font(.system(size: 8))
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    Text("\(String(format: "%.1f", pp.computeTimeSeconds))s")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }

                // Cluster filter toggle + analysis
                HStack(spacing: 8) {
                    Toggle("Cluster Filter", isOn: Binding(
                        get: { isClusterFiltered },
                        set: { newValue in
                            if newValue {
                                applyClusterFilter()
                            } else {
                                removeClusterFilter()
                            }
                        }
                    ))
                    .toggleStyle(.button)
                    .font(.caption)
                    .tint(.purple)

                    Button("Analysis") {
                        showingClusterView = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.purple.opacity(0.7))

                    Toggle("Bad Data", isOn: $showBadData)
                        .toggleStyle(.button)
                        .font(.caption)
                        .tint(.red)
                }
            }

            // Parameter map selector
            if pixelPhenology != nil {
                HStack(spacing: 8) {
                    Menu {
                        Button {
                            phenologyDisplayParam = nil
                            startPlayback()
                        } label: {
                            if phenologyDisplayParam == nil {
                                Label("Live", systemImage: "checkmark")
                            } else {
                                Text("Live")
                            }
                        }
                        Divider()
                        ForEach(PhenologyParameter.allCases, id: \.self) { param in
                            Button {
                                phenologyDisplayParam = param
                                stopPlayback()
                            } label: {
                                if phenologyDisplayParam == param {
                                    Label(param.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(param.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 9))
                            Text(phenologyDisplayParam?.rawValue ?? "Live")
                                .font(.system(size: 9).bold())
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .tint(phenologyDisplayParam != nil ? .orange : .green)
                    Spacer()
                }
            }

            // Best-fit parameters
            if let dl = dlBest {
                HStack(spacing: 8) {
                    dlParamLabel("mn", dl.mn, fmt: "%.2f")
                    dlParamLabel("mx", dl.mx, fmt: "%.2f")
                    dlParamLabel("sos", dl.sos, fmt: "%.0f")
                    dlParamLabel("rsp", dl.rsp, fmt: "%.3f")
                    dlParamLabel("eos", dl.eos, fmt: "%.0f")
                    dlParamLabel("rau", dl.rau, fmt: "%.3f")
                }
            }

            // Sliders
            if showDLSliders {
                VStack(spacing: 6) {
                    dlSlider("mn", $dlSliders.mn, range: -0.2...0.5, step: 0.01)
                    dlSlider("mx", $dlSliders.mx, range: 0.2...1.0, step: 0.01)
                    dlSlider("sos", $dlSliders.sos, range: 1...250, step: 1)
                    dlSlider("rsp", $dlSliders.rsp, range: 0.005...0.3, step: 0.005)
                    dlSlider("eos", $dlSliders.eos, range: 150...366, step: 1)
                    dlSlider("rau", $dlSliders.rau, range: 0.005...0.3, step: 0.005)

                    // Live RMSE for slider values
                    let sliderRMSE = DoubleLogistic.rmse(
                        params: dlSliders,
                        data: processor.frames.map {
                            DoubleLogistic.DataPoint(doy: Double($0.dayOfYear), ndvi: Double($0.medianNDVI))
                        }
                    )
                    HStack {
                        Text("Slider RMSE: \(String(format: "%.4f", sliderRMSE))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.cyan)
                        if let dl = dlBest {
                            Text("(best: \(String(format: "%.4f", dl.rmse)))")
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("Use as start \u{2192} Fit") {
                            runDLFitFrom(dlSliders)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.cyan)
                        if let dl = dlBest {
                            Button("Reset to best") {
                                dlSliders = dl
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func dlParamLabel(_ name: String, _ value: Double, fmt: String) -> some View {
        VStack(spacing: 1) {
            Text(name)
                .font(.system(size: 7).bold())
                .foregroundStyle(.yellow.opacity(0.7))
            Text(String(format: fmt, value))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func dlSlider(_ name: String, _ value: Binding<Double>,
                          range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 8).bold())
                .frame(width: 24, alignment: .trailing)
                .foregroundStyle(.cyan)
            Slider(value: value, in: range, step: step)
            Text(String(format: step < 0.01 ? "%.3f" : (step < 1 ? "%.2f" : "%.0f"), value.wrappedValue))
                .font(.system(size: 8).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func logDistributions(label: String, base: DLParams, p: Double, sp: Double, nRuns: Int, minSL: Double, maxSL: Double) {
        let f3 = { (v: Double) in String(format: "%.3f", v) }
        let f1 = { (v: Double) in String(format: "%.1f", v) }
        log.info("\(label): \(nRuns) runs, perturbation=\(Int(p*100))%, slope=\(Int(sp*100))%, season=\(Int(minSL))-\(Int(maxSL))d")
        log.info("  mn:  \(f3(base.mn))  * U(\(f3(1-p)), \(f3(1+p))) → [\(f3(base.mn*(1-p))), \(f3(base.mn*(1+p)))]")
        log.info("  mx:  \(f3(base.mx))  * U(\(f3(1-p)), \(f3(1+p))) → [\(f3(base.mx*(1-p))), \(f3(base.mx*(1+p)))]")
        log.info("  sos: \(f1(base.sos)) * U(\(f3(1-p)), \(f3(1+p))) → [\(f1(base.sos*(1-p))), \(f1(base.sos*(1+p)))]")
        log.info("  rsp: \(f3(base.rsp)) * U(\(f3(1-sp)), \(f3(1+sp))) → [\(f3(base.rsp*(1-sp))), \(f3(base.rsp*(1+sp)))]")
        log.info("  eos: \(f1(base.eos)) * U(\(f3(1-p)), \(f3(1+p))) → [\(f1(base.eos*(1-p))), \(f1(base.eos*(1+p)))]")
        log.info("  rau: \(f3(base.rau)) * U(\(f3(1-sp)), \(f3(1+sp))) → [\(f3(base.rau*(1-sp))), \(f3(base.rau*(1+sp)))]")
    }

    private func runDLFit() {
        let data = processor.frames.map { f in
            DoubleLogistic.DataPoint(doy: Double(f.dayOfYear), ndvi: Double(f.medianNDVI))
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)

        // Log the initial guess and perturbation ranges
        let filtered = DoubleLogistic.filterCycleContamination(data: data)
        let guess = DoubleLogistic.initialGuess(data: filtered)
        logDistributions(label: "Median DL fit", base: guess, p: p, sp: sp, nRuns: 50, minSL: minSL, maxSL: maxSL)

        Task.detached {
            let result = DoubleLogistic.ensembleFit(data: data,
                perturbation: p, slopePerturbation: sp,
                minSeasonLength: minSL, maxSeasonLength: maxSL)
            await MainActor.run {
                dlBest = result.best
                dlEnsemble = result.ensemble
                dlSliders = result.best
                log.success("DL fit: RMSE=\(String(format: "%.4f", result.best.rmse)), \(result.ensemble.count) viable of 50")
            }
        }
    }

    private func runPerPixelFit() {
        guard let medianFit = dlBest else { return }
        guard let first = processor.frames.first else { return }

        isRunningPixelFit = true
        pixelFitProgress = 0
        isClusterFiltered = false
        unfilteredPhenology = nil
        let frames = processor.frames
        let polygon = first.polygonNorm
        let fitSettings = PhenologyFitSettings(
            ensembleRuns: settings.pixelEnsembleRuns,
            perturbation: settings.pixelPerturbation,
            slopePerturbation: settings.pixelSlopePerturbation,
            maxIter: 500,
            rmseThreshold: settings.pixelFitRMSEThreshold,
            minObservations: settings.pixelMinObservations,
            minSeasonLength: Double(settings.minSeasonLength),
            maxSeasonLength: Double(settings.maxSeasonLength)
        )

        logDistributions(label: "Per-pixel DL fit", base: medianFit, p: settings.pixelPerturbation,
                         sp: settings.pixelSlopePerturbation, nRuns: settings.pixelEnsembleRuns,
                         minSL: Double(settings.minSeasonLength), maxSL: Double(settings.maxSeasonLength))

        let enforceAOI = settings.enforceAOI
        Task.detached {
            let result = await PixelPhenologyFitter.fitAllPixels(
                frames: frames,
                medianParams: medianFit,
                settings: fitSettings,
                polygon: polygon,
                enforceAOI: enforceAOI,
                onProgress: { progress in
                    Task { @MainActor in
                        pixelFitProgress = progress
                    }
                }
            )

            await MainActor.run {
                pixelPhenology = result
                isRunningPixelFit = false
                log.success("Per-pixel fit: \(result.goodCount) good, \(result.poorCount) poor, \(result.skippedCount) skipped in \(String(format: "%.1f", result.computeTimeSeconds))s")
            }
        }
    }

    private func applyClusterFilter() {
        guard let pp = pixelPhenology else { return }
        // Save unfiltered state for undo
        unfilteredPhenology = pp
        let filtered = pp.clusterFiltered(threshold: settings.clusterFilterThreshold)
        let nOutliers = filtered.outlierCount - pp.outlierCount
        pixelPhenology = filtered
        isClusterFiltered = true
        log.info("Cluster filter: \(nOutliers) outliers flagged, \(filtered.goodCount) good remaining")

        // Log parameter uncertainties
        let uncertainties = filtered.parameterUncertainty()
        if !uncertainties.isEmpty {
            let desc = uncertainties.map { "\($0.name)=\(String(format: "%.3f", $0.median))±\(String(format: "%.3f", $0.iqr))" }.joined(separator: ", ")
            log.info("Parameter IQR: \(desc)")
        }

        // Refit median NDVI using only good pixels, then refit DL
        let filteredMedians = filtered.filteredMedianNDVI(frames: processor.frames)
        let frames = processor.frames
        var data = [DoubleLogistic.DataPoint]()
        for (i, frame) in frames.enumerated() {
            let m = filteredMedians[i]
            guard !m.isNaN else { continue }
            data.append(DoubleLogistic.DataPoint(doy: Double(frame.dayOfYear), ndvi: Double(m)))
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        Task.detached {
            let result = DoubleLogistic.ensembleFit(data: data,
                perturbation: p, slopePerturbation: sp,
                minSeasonLength: minSL, maxSeasonLength: maxSL)
            await MainActor.run {
                dlBest = result.best
                dlSliders = result.best
                dlEnsemble = result.ensemble
                log.success("Refit on filtered median: RMSE=\(String(format: "%.4f", result.best.rmse))")
            }
        }
    }

    private func removeClusterFilter() {
        guard let original = unfilteredPhenology else { return }
        pixelPhenology = original
        unfilteredPhenology = nil
        isClusterFiltered = false
        log.info("Cluster filter removed, restored \(original.goodCount) good pixels")

        // Refit DL on original (unfiltered) median NDVI
        let data = processor.frames.map { f in
            DoubleLogistic.DataPoint(doy: Double(f.dayOfYear), ndvi: Double(f.medianNDVI))
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        Task.detached {
            let result = DoubleLogistic.ensembleFit(data: data,
                perturbation: p, slopePerturbation: sp,
                minSeasonLength: minSL, maxSeasonLength: maxSL)
            await MainActor.run {
                dlBest = result.best
                dlSliders = result.best
                dlEnsemble = result.ensemble
                log.success("Refit on original median: RMSE=\(String(format: "%.4f", result.best.rmse))")
            }
        }
    }

    private func runDLFitFrom(_ start: DLParams) {
        let data = processor.frames.map { f in
            DoubleLogistic.DataPoint(doy: Double(f.dayOfYear), ndvi: Double(f.medianNDVI))
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        Task.detached {
            let fitted = DoubleLogistic.fit(data: data, initial: start,
                                           minSeasonLength: minSL, maxSeasonLength: maxSL)
            await MainActor.run {
                dlBest = fitted
                dlSliders = fitted
                // Re-run ensemble from this better starting point
                let result = DoubleLogistic.ensembleFit(data: data,
                    perturbation: p, slopePerturbation: sp,
                    minSeasonLength: minSL, maxSeasonLength: maxSL)
                dlEnsemble = result.ensemble
                if result.best.rmse < fitted.rmse {
                    dlBest = result.best
                    dlSliders = result.best
                }
                log.success("DL refit: RMSE=\(String(format: "%.4f", dlBest!.rmse)), \(dlEnsemble.count) viable")
            }
        }
    }

    // MARK: - SCL Class Key

    /// SCL classes present across ALL frames (computed once, stable across playback)
    private var allFrameSCLClasses: Set<UInt16> {
        var classes = Set<UInt16>()
        for frame in processor.frames {
            if let scl = frame.sclBand {
                for row in scl { for v in row { classes.insert(v) } }
            }
        }
        return classes
    }

    private var compactSCLKey: some View {
        let allClasses: [(val: UInt16, name: String)] = [
            (0, "No Data"), (1, "Saturated"), (2, "Dark"),
            (3, "Cld Shadow"), (4, "Veg"), (5, "Not Veg"),
            (6, "Water"), (7, "Unclass"), (8, "Cld Med"),
            (9, "Cld High"), (10, "Cirrus"), (11, "Snow"),
        ]
        let present = allFrameSCLClasses
        let relevant = allClasses.filter { present.contains($0.val) }
        let valid = settings.sclValidClasses
        // Split into rows: ceil(count/2) on top, rest on bottom — centered
        let topCount = (relevant.count + 1) / 2
        let topRow = Array(relevant.prefix(topCount))
        let botRow = Array(relevant.dropFirst(topCount))

        return VStack(spacing: 3) {
            sclKeyRow(topRow, validClasses: valid)
            if !botRow.isEmpty {
                sclKeyRow(botRow, validClasses: valid)
            }
        }
    }

    private func sclKeyRow(_ items: [(val: UInt16, name: String)], validClasses: Set<Int>) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(items, id: \.val) { cls in
                HStack(spacing: 3) {
                    let (r, g, b) = NDVIMapView.sclColor(cls.val)
                    let isMasked = !validClasses.contains(Int(cls.val))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
                        .frame(width: 16, height: 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                        .overlay {
                            if isMasked {
                                Text("\u{2717}")
                                    .font(.system(size: 7).bold())
                                    .foregroundStyle(.white)
                            }
                        }
                    Text(cls.name)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .opacity(isMasked ? 0.5 : 1.0)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func startFetch() {
        log.clear()

        // Use existing AOI geometry, or load bundled default on first launch
        let geometry: GeoJSONGeometry
        if let existing = settings.aoiGeometry {
            geometry = existing
            log.info("Using AOI: \(settings.aoiSourceLabel)")
        } else {
            log.info("Loading default GeoJSON from bundle...")
            guard let geojsonURL = Bundle.main.url(forResource: "SF_field", withExtension: "geojson") else {
                processor.errorMessage = "SF_field.geojson not found in bundle"
                processor.status = .error
                log.error("SF_field.geojson not found in app bundle")
                return
            }
            do {
                geometry = try loadGeoJSON(from: geojsonURL)
                settings.aoiSource = .bundled
                settings.aoiGeometry = geometry
                settings.recordAOI()
            } catch {
                processor.errorMessage = error.localizedDescription
                processor.status = .error
                log.error("Failed to load GeoJSON: \(error.localizedDescription)")
                return
            }
        }

        log.success("AOI loaded: \(geometry.polygon.count) vertices")
        let c = geometry.centroid
        log.info("Centroid: \(String(format: "%.4f", c.lon))E, \(String(format: "%.4f", c.lat))N")

        lastStartDate = settings.startDateString
        lastEndDate = settings.endDateString
        lastNDVIThreshold = settings.ndviThreshold
        lastSCLClasses = settings.sclValidClasses
        lastCloudMask = settings.cloudMask
        lastEnforceAOI = settings.enforceAOI

        Task {
            await processor.fetch(
                geometry: geometry,
                startDate: settings.startDateString,
                endDate: settings.endDateString
            )
        }
    }

    private func resetAndFetch() {
        stopPlayback()
        currentFrameIndex = 0
        processor.status = .idle
        processor.frames = []
        processor.progress = 0
        processor.progressMessage = ""
        processor.errorMessage = nil
        startFetch()
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        timer?.invalidate()
        timer = nil
        isPlaying = true
        let interval = 1.0 / settings.playbackSpeed
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                if currentFrameIndex >= processor.frames.count - 1 {
                    currentFrameIndex = 0
                } else {
                    currentFrameIndex += 1
                }
            }
        }
    }

    private func stopPlayback() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func nextFrame() {
        if currentFrameIndex < processor.frames.count - 1 {
            currentFrameIndex += 1
        }
    }

    private func previousFrame() {
        if currentFrameIndex > 0 {
            currentFrameIndex -= 1
        }
    }

    // MARK: - Basemap

    private func loadBasemap() {
        guard let geo = settings.aoiGeometry,
              let first = processor.frames.first else { return }
        let bbox = geo.bbox
        let center = CLLocationCoordinate2D(latitude: (bbox.minLat + bbox.maxLat) / 2,
                                            longitude: (bbox.minLon + bbox.maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: bbox.maxLat - bbox.minLat,
                                    longitudeDelta: bbox.maxLon - bbox.minLon)
        let region = MKCoordinateRegion(center: center, span: span)

        let opts = MKMapSnapshotter.Options()
        opts.mapType = .satellite
        opts.region = region
        // Match the S2 frame pixel dimensions * scale for crisp rendering
        let targetW = CGFloat(first.width) * 8  // use main display scale
        let targetH = CGFloat(first.height) * 8
        opts.size = CGSize(width: targetW, height: targetH)
        opts.scale = 1  // we manage resolution ourselves

        let snapshotter = MKMapSnapshotter(options: opts)
        snapshotter.start { snapshot, error in
            if let snapshot {
                DispatchQueue.main.async {
                    self.basemapImage = snapshot.image.cgImage
                    self.log.success("Basemap loaded (\(Int(targetW))x\(Int(targetH)))")
                }
            } else if let error {
                DispatchQueue.main.async {
                    self.log.warn("Basemap failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finalizeSelection(frame: NDVIFrame, scale: CGFloat = 8) {
        guard let s = selectionStart, let e = selectionEnd else { return }
        let minCol = max(0, Int(min(s.x, e.x) / scale))
        let maxCol = min(frame.width - 1, Int(max(s.x, e.x) / scale))
        let minRow = max(0, Int(min(s.y, e.y) / scale))
        let maxRow = min(frame.height - 1, Int(max(s.y, e.y) / scale))

        guard maxCol > minCol && maxRow > minRow else {
            log.warn("Selection too small — drag a larger rectangle")
            selectionStart = nil
            selectionEnd = nil
            return
        }

        // Check if any valid pixels exist in selection
        var validCount = 0
        for row in minRow...maxRow {
            for col in minCol...maxCol {
                let val = frame.ndvi[row][col]
                if !val.isNaN { validCount += 1 }
            }
        }

        if validCount == 0 {
            log.warn("No valid pixels in selection (\(maxCol - minCol + 1)x\(maxRow - minRow + 1) px)")
            selectionStart = nil
            selectionEnd = nil
            return
        }

        selectionItem = SelectionItem(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol)
        log.info("Selected \(maxCol - minCol + 1)x\(maxRow - minRow + 1) px, \(validCount) valid")
    }

    @MainActor
    private func copyCurrentFrame(frame: NDVIFrame) {
        let currentPhenoMap: [[Float]]? = phenologyDisplayParam.flatMap { p in
            pixelPhenology?.parameterMap(p)
        }
        let rejMap: [[Float]]? = showBadData ? pixelPhenology?.rejectionReasonMap() : nil
        let view = NDVIMapView(
            frame: frame, scale: 8, showPolygon: true, showColorBar: true,
            displayMode: settings.displayMode,
            cloudMask: settings.cloudMask,
            ndviThreshold: settings.ndviThreshold,
            sclValidClasses: settings.sclValidClasses,
            showSCLBoundaries: settings.showSCLBoundaries,
            enforceAOI: settings.enforceAOI,
            showMaskedClassColors: settings.showMaskedClassColors,
            basemapImage: settings.showBasemap ? basemapImage : nil,
            phenologyMap: showData && !showBadData ? currentPhenoMap : nil,
            phenologyParam: showData && !showBadData ? phenologyDisplayParam : nil,
            rejectionMap: showData ? rejMap : nil
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        if let uiImage = renderer.uiImage {
            UIPasteboard.general.image = uiImage
            log.info("Copied frame \(frame.dateString) to clipboard")
        }
    }

    private func openInMaps() {
        guard let geo = settings.aoiGeometry else { return }
        let bbox = geo.bbox
        let center = CLLocationCoordinate2D(
            latitude: (bbox.minLat + bbox.maxLat) / 2,
            longitude: (bbox.minLon + bbox.maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (bbox.maxLat - bbox.minLat) * 1.5,
            longitudeDelta: (bbox.maxLon - bbox.minLon) * 1.5
        )
        let placemark = MKPlacemark(coordinate: center)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "AOI: \(settings.aoiSourceLabel)"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapTypeKey: MKMapType.satellite.rawValue,
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: span)
        ])
    }
}

// MARK: - Log View

struct LogView: View {
    @Binding var isPresented: Bool
    @State private var log = ActivityLog.shared
    @State private var settings = AppSettings.shared
    @State private var showingImages = false
    var processor: NDVIProcessor

    private let gridColumns = [
        GridItem(.adaptive(minimum: 70, maximum: 100), spacing: 6)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if showingImages && !processor.frames.isEmpty {
                    imageGrid
                } else {
                    logList
                }
            }
            .navigationTitle(showingImages ? "Image Previews" : "Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        if !showingImages {
                            Button {
                                log.clear()
                                processor.frames = []
                            } label: {
                                Label("Clear", systemImage: "trash")
                            }
                            .buttonStyle(.glass)
                            .tint(.red)
                        }

                        if !processor.frames.isEmpty {
                            Button {
                                withAnimation { showingImages.toggle() }
                            } label: {
                                Label(showingImages ? "Log" : "Images",
                                      systemImage: showingImages ? "doc.text" : "photo.on.rectangle")
                            }
                            .buttonStyle(.glass)
                            .tint(showingImages ? .blue : .green)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Label("Close", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: - Image Grid

    private var imageGrid: some View {
        ScrollView {
            VStack(spacing: 8) {
                if settings.displayMode == .ndvi {
                    NDVIColorBar()
                        .padding(.horizontal, 8)
                } else if settings.displayMode == .scl {
                    SCLLegend()
                        .padding(.horizontal, 8)
                }
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(processor.frames.sorted(by: { $0.date < $1.date })) { frame in
                        VStack(spacing: 2) {
                            NDVIMapView(frame: frame, scale: 2, showPolygon: true,
                                        showColorBar: false, displayMode: settings.displayMode,
                                        cloudMask: settings.cloudMask,
                                        ndviThreshold: settings.ndviThreshold,
                                        sclValidClasses: settings.sclValidClasses,
                                        showSCLBoundaries: settings.showSCLBoundaries,
                                        enforceAOI: settings.enforceAOI,
                                        showMaskedClassColors: settings.showMaskedClassColors)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(frame.dateString)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Log List

    private var logList: some View {
        LogTextView(entries: log.entries)
    }
}

// MARK: - Log Text View (UIKit-backed, guaranteed scrollable)

struct LogTextView: UIViewRepresentable {
    let entries: [ActivityLog.LogEntry]

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.showsVerticalScrollIndicator = true
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let atBottom = tv.contentOffset.y >= tv.contentSize.height - tv.bounds.height - 40

        let text = NSMutableAttributedString()
        let mono = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        for entry in entries {
            let color: UIColor = switch entry.level {
            case .info: .label
            case .success: .systemGreen
            case .warning: .systemOrange
            case .error: .systemRed
            }
            let icon: String = switch entry.level {
            case .info: "\u{2139}"
            case .success: "\u{2713}"
            case .warning: "\u{26A0}"
            case .error: "\u{2717}"
            }

            let line = NSAttributedString(
                string: "\(entry.timeString) \(icon) \(entry.message)\n",
                attributes: [.font: mono, .foregroundColor: color]
            )
            text.append(line)
        }

        tv.attributedText = text

        if atBottom && !entries.isEmpty {
            let range = NSRange(location: text.length - 1, length: 1)
            tv.scrollRangeToVisible(range)
        }
    }
}
