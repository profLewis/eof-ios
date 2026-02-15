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
    @State private var pixelPhenologyBase: PixelPhenologyResult?  // original before RMSE reclassification
    @State private var pixelFitProgress: Double = 0
    @State private var isRunningPixelFit = false
    @State private var lastPixelFitSettingsHash: Int = 0
    @State private var phenologyDisplayParam: PhenologyParameter?
    @State private var showingClusterView = false
    @State private var showData = true
    @State private var dataOpacity: Double = 1.0
    // Cluster filter
    @State private var unfilteredPhenology: PixelPhenologyResult?
    @State private var isClusterFiltered = false
    @State private var showBadData = false
    @State private var tappedPixelDetail: PixelPhenology?
    @State private var showingPixelDetail = false
    @State private var showingSourceComparison = false
    // Sub-AOI selection
    @State private var isSelectMode = false
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var selectionItem: SelectionItem?
    // Zoom + pan
    @State private var zoomScale: CGFloat = 1.0
    @GestureState private var gestureZoom: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragLastTranslation: CGSize?
    // Pixel inspection (long-press to show per-pixel time series)
    @State private var inspectedPixelRow: Int = 0
    @State private var inspectedPixelCol: Int = 0
    @State private var isInspectingPixel = false
    @State private var pixelInspectTimer: Timer?
    @State private var pixelFitTask: Task<Void, Never>?
    // Spectral unmixing
    @State private var frameUnmixResults: [UUID: FrameUnmixResult] = [:]
    @State private var isRunningUnmix = false
    // Network & download estimation
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var showCellularAlert = false
    @State private var estimatedDownloadMB: Double = 0
    @State private var pendingGeometry: GeoJSONGeometry?

    struct SelectionItem: Identifiable {
        let id = UUID()
        let minRow: Int, maxRow: Int, minCol: Int, maxCol: Int
    }

    /// Reference year for continuous DOY (first frame's year)
    private var referenceYear: Int {
        processor.frames.first.map { Calendar.current.component(.year, from: $0.date) } ?? 2022
    }

    /// DOY bounds from loaded dataset (continuous, handles year boundaries)
    private var datasetDOYFirst: Int {
        processor.frames.first?.continuousDOY(referenceYear: referenceYear) ?? 1
    }
    private var datasetDOYLast: Int {
        processor.frames.last?.continuousDOY(referenceYear: referenceYear) ?? 365
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
            .task { await prefetchSASToken() }
            .onChange(of: processor.status) {
                // Auto-play when loading finishes
                if processor.status == .done && !processor.frames.isEmpty && !isPlaying {
                    // Show comparison results if in compare mode
                    if processor.compareSourcesMode && !processor.comparisonPairs.isEmpty {
                        processor.compareSourcesMode = false
                        showingSourceComparison = true
                        return
                    }
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
                    // Auto-run spectral unmixing if enabled
                    if settings.enableSpectralUnmixing {
                        runUnmixing()
                    }
                }
            }
            .onChange(of: settings.showBasemap) {
                if settings.showBasemap && basemapImage == nil && !processor.frames.isEmpty {
                    loadBasemap()
                }
            }
            .onChange(of: settings.enableSpectralUnmixing) {
                if settings.enableSpectralUnmixing && frameUnmixResults.isEmpty && !processor.frames.isEmpty {
                    runUnmixing()
                }
            }
            .onChange(of: settings.dlFitTarget) {
                if dlBest != nil {
                    runDLFit()
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
            .onChange(of: settings.vegetationIndex) {
                // Recompute VI values from raw bands when switching NDVI↔DVI
                if !processor.frames.isEmpty {
                    processor.recomputeVI()
                }
            }
            .onChange(of: settings.aoiSourceLabel) {
                // Cancel any in-progress download
                processor.cancelFetch()
                // Clear all data and restart when AOI changes
                stopPlayback()
                currentFrameIndex = 0
                processor.resetGeometry()
                processor.frames = []
                processor.progress = 0
                processor.progressMessage = ""
                processor.errorMessage = nil
                basemapImage = nil
                // Clear phenology state
                dlBest = nil
                dlEnsemble = []
                dlSliders = DLParams(mn: 0.1, mx: 0.7, sos: 120, rsp: 0.05, eos: 280, rau: 0.05)
                pixelPhenology = nil
                pixelPhenologyBase = nil
                unfilteredPhenology = nil
                pixelFitProgress = 0
                pixelFitTask?.cancel()
                pixelFitTask = nil
                isRunningPixelFit = false
                isClusterFiltered = false
                phenologyDisplayParam = nil
                showBadData = false
                // Clear unmixing
                frameUnmixResults = [:]
                isRunningUnmix = false
                // Clear pixel inspection
                isInspectingPixel = false
                // Clear sub-AOI selection
                isSelectMode = false
                selectionItem = nil
                // Reset zoom
                zoomScale = 1.0
                panOffset = .zero
                // Auto-restart fetch
                processor.status = .idle
                startFetch()
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
                SettingsView(isPresented: $showingSettings, onCompare: {
                    startComparisonFetch()
                })
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
            .sheet(isPresented: $showingSourceComparison) {
                SourceComparisonView(pairs: processor.comparisonPairs)
                    .presentationDetents([.large])
            }
            .alert("Cellular Download", isPresented: $showCellularAlert) {
                Button("Download") {
                    if let geo = pendingGeometry { launchFetch(geometry: geo) }
                    pendingGeometry = nil
                }
                Button("Always Allow") {
                    settings.allowCellularDownload = true
                    if let geo = pendingGeometry { launchFetch(geometry: geo) }
                    pendingGeometry = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingGeometry = nil
                }
            } message: {
                Text("Estimated download: ~\(Int(estimatedDownloadMB)) MB. You're on cellular data.")
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
                HStack {
                    Button(settings.dlFitTarget == .fveg && !frameUnmixResults.isEmpty ? "Fit fVeg" : "Fit") {
                        runDLFit()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                    Button(isRunningUnmix ? "Stop" : "Unmix") {
                        if isRunningUnmix {
                            isRunningUnmix = false
                        } else {
                            runUnmixing()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(isRunningUnmix ? .red : (frameUnmixResults.isEmpty ? .purple : .purple.opacity(0.5)))
                    if isRunningUnmix {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Button(isRunningPixelFit ? "Stop" : "Per-Pixel") {
                        if isRunningPixelFit {
                            pixelFitTask?.cancel()
                            pixelFitTask = nil
                            isRunningPixelFit = false
                        } else {
                            runPerPixelFit()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(isRunningPixelFit ? .red : (pixelPhenology == nil ? .orange : (pixelFitIsStale ? .green : .red)))
                    .disabled(dlBest == nil && !isRunningPixelFit)
                    if isRunningPixelFit {
                        ProgressView(value: pixelFitProgress)
                            .frame(width: 60)
                            .tint(.orange)
                    }
                    if pixelPhenology != nil || !frameUnmixResults.isEmpty {
                        liveMenu
                    }
                    Spacer()
                    if !processor.cachedFrames.isEmpty {
                        Button {
                            processor.revertToCached()
                            currentFrameIndex = 0
                        } label: {
                            Label("Revert (\(processor.cachedFrames.count))", systemImage: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
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

    private var compareButton: some View {
        Button(action: startComparisonFetch) {
            Label("Compare Sources", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline)
                .padding(8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(.orange)
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
                        if param.isFraction {
                            return fractionMap(for: frame, param: param)
                        }
                        return pixelPhenology?.parameterMap(param)
                    }
                    let currentRejectionMap: [[Float]]? = showBadData ? pixelPhenology?.rejectionReasonMap() : nil

                    GeometryReader { geo in
                        let fitScale = max(1, min(8, geo.size.width / CGFloat(frame.width)))
                        let currentZoom = min(8.0, max(1.0, zoomScale * gestureZoom))
                        let imageH = CGFloat(frame.height) * fitScale
                        let imageW = CGFloat(frame.width) * fitScale
                        let xInset = max(0, (geo.size.width - imageW) / 2)
                        let yInset = max(0, (geo.size.height - imageH) / 2)

                        ZStack(alignment: .topLeading) {
                            // Image layer (transformed, centered)
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
                                .opacity(showData ? dataOpacity : 0.0)
                                .background(alignment: .top) {
                                    if let bm = basemapImage {
                                        Image(decorative: bm, scale: 1)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: imageW, height: imageH)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .offset(x: xInset, y: yInset)
                                .scaleEffect(currentZoom, anchor: .topLeading)
                                .offset(panOffset)
                                .allowsHitTesting(false)

                            // Selection rectangle overlay (in screen coords)
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
                                    .allowsHitTesting(false)
                            }

                            // Pixel inspection crosshair
                            if isInspectingPixel {
                                let cx = (CGFloat(inspectedPixelCol) + 0.5) * fitScale * currentZoom + xInset * currentZoom + panOffset.width
                                let cy = (CGFloat(inspectedPixelRow) + 0.5) * fitScale * currentZoom + yInset * currentZoom + panOffset.height
                                let w = CGFloat(settings.pixelInspectWindow) * fitScale * currentZoom
                                Rectangle()
                                    .stroke(.cyan, lineWidth: 2)
                                    .frame(width: max(w, 6), height: max(w, 6))
                                    .position(x: cx, y: cy)
                                    .allowsHitTesting(false)
                            }

                            // Gesture catcher (untransformed, full geo size)
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    MagnifyGesture()
                                        .updating($gestureZoom) { value, state, _ in
                                            state = value.magnification
                                        }
                                        .onEnded { value in
                                            let newZoom = min(8.0, max(1.0, zoomScale * value.magnification))
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                zoomScale = newZoom
                                                if newZoom <= 1.0 {
                                                    panOffset = .zero
                                                } else {
                                                    panOffset = clampPan(panOffset, zoom: newZoom, geoSize: geo.size, imageH: imageH)
                                                }
                                            }
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        if zoomScale > 1.5 {
                                            zoomScale = 1.0
                                            panOffset = .zero
                                        } else {
                                            zoomScale = 3.0
                                        }
                                    }
                                }
                                .onTapGesture { location in
                                    if isInspectingPixel {
                                        isInspectingPixel = false
                                        return
                                    }
                                    let inset = CGSize(width: xInset, height: yInset)
                                    let (col, row) = screenToPixel(location, zoom: currentZoom, pan: panOffset, fitScale: fitScale, inset: inset)
                                    if showBadData, let pp = pixelPhenology {
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
                                            guard !isInspectingPixel else { return }
                                            if isSelectMode {
                                                selectionStart = value.startLocation
                                                selectionEnd = value.location
                                            } else if currentZoom > 1.05 {
                                                // Pan when zoomed
                                                let newOffset = CGSize(
                                                    width: panOffset.width + value.translation.width - (dragLastTranslation?.width ?? 0),
                                                    height: panOffset.height + value.translation.height - (dragLastTranslation?.height ?? 0)
                                                )
                                                panOffset = clampPan(newOffset, zoom: currentZoom, geoSize: geo.size, imageH: imageH)
                                                dragLastTranslation = value.translation
                                            } else {
                                                // Scrub frames
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
                                                finalizeSelectionZoomed(frame: frame, fitScale: fitScale, zoom: currentZoom, pan: panOffset, inset: CGSize(width: xInset, height: yInset))
                                            } else if currentZoom <= 1.05 {
                                                dragStartIndex = currentFrameIndex
                                            }
                                            dragLastTranslation = nil
                                        }
                                )
                                // Long-press to inspect per-pixel time series
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            if pixelInspectTimer == nil && pixelPhenology != nil && !isInspectingPixel {
                                                let startLoc = value.startLocation
                                                let capturedZoom = currentZoom
                                                let capturedPan = panOffset
                                                let capturedScale = fitScale
                                                let capturedInset = CGSize(width: xInset, height: yInset)
                                                pixelInspectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                                                    DispatchQueue.main.async {
                                                        let (col, row) = screenToPixel(startLoc, zoom: capturedZoom, pan: capturedPan, fitScale: capturedScale, inset: capturedInset)
                                                        updatePixelInspection(row: row, col: col)
                                                    }
                                                }
                                            }
                                            // Update pixel position while dragging after inspection started
                                            if isInspectingPixel {
                                                let capturedInset = CGSize(width: xInset, height: yInset)
                                                let (col, row) = screenToPixel(value.location, zoom: currentZoom, pan: panOffset, fitScale: fitScale, inset: capturedInset)
                                                updatePixelInspection(row: row, col: col)
                                            }
                                            // Cancel timer if finger moves too much before it fires
                                            if !isInspectingPixel {
                                                let dist = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))
                                                if dist > 10 {
                                                    pixelInspectTimer?.invalidate()
                                                    pixelInspectTimer = nil
                                                }
                                            }
                                        }
                                        .onEnded { _ in
                                            pixelInspectTimer?.invalidate()
                                            pixelInspectTimer = nil
                                            // Selection sticks — tap to dismiss
                                        }
                                )
                        }
                        .clipped()
                        .overlay(alignment: .topTrailing) {
                            VStack(spacing: 4) {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.ultraThinMaterial, in: Circle())
                                if showData && basemapImage != nil {
                                    Slider(value: $dataOpacity, in: 0.05...1.0)
                                        .frame(width: 100)
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 28, height: 100)
                                }
                            }
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
                            }
                            .padding(6)
                            .opacity(0.7)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if zoomScale > 1.05 || gestureZoom != 1.0 {
                                let z = min(8.0, max(1.0, zoomScale * gestureZoom))
                                Button {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        zoomScale = 1.0
                                        panOffset = .zero
                                    }
                                } label: {
                                    Text("\(String(format: "%.1f", z))x")
                                        .font(.system(size: 9).bold().monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                                .padding(6)
                                .opacity(0.8)
                            }
                        }
                        .onAppear { dragStartIndex = currentFrameIndex }
                        .onChange(of: currentFrameIndex) { dragStartIndex = currentFrameIndex }
                    }
                    .frame(height: CGFloat(frame.height) * min(8, UIScreen.main.bounds.width / CGFloat(frame.width)))

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

                    // Area-level fraction summary
                    if let _ = frameUnmixResults[frame.id] {
                        HStack(spacing: 8) {
                            if let fv = medianFraction(for: frame, param: .fveg) {
                                Text("fVeg \(String(format: "%.2f", fv))")
                                    .foregroundStyle(.green)
                            }
                            if let fn = medianFraction(for: frame, param: .fnpv) {
                                Text("fNPV \(String(format: "%.2f", fn))")
                                    .foregroundStyle(.brown)
                            }
                            if let fs = medianFraction(for: frame, param: .fsoil) {
                                Text("fSoil \(String(format: "%.2f", fs))")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.system(size: 9).monospacedDigit())
                    }
                }
            }

            // NDVI time series chart — synced with animation
            if processor.frames.count > 1 {
                ndviChart
                spectralChart
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

    private var viLabel: String { settings.vegetationIndex.rawValue }

    /// Hash of settings that affect per-pixel phenology fit.
    /// When this changes after a fit, results are stale and need re-running.
    private var pixelFitSettingsHash: Int {
        var h = Hasher()
        h.combine(settings.pixelEnsembleRuns)
        h.combine(settings.pixelPerturbation)
        h.combine(settings.pixelSlopePerturbation)
        h.combine(settings.pixelFitRMSEThreshold)
        h.combine(settings.pixelMinObservations)
        h.combine(settings.minSeasonLength)
        h.combine(settings.maxSeasonLength)
        h.combine(settings.slopeSymmetry)
        h.combine(settings.boundMnMin)
        h.combine(settings.boundMnMax)
        h.combine(settings.boundDeltaMin)
        h.combine(settings.boundDeltaMax)
        h.combine(settings.boundSosMin)
        h.combine(settings.boundSosMax)
        h.combine(settings.boundRspMin)
        h.combine(settings.boundRspMax)
        h.combine(settings.boundRauMin)
        h.combine(settings.boundRauMax)
        h.combine(settings.enableSecondPass)
        h.combine(settings.enforceAOI)
        h.combine(settings.ndviThreshold)
        h.combine(settings.cloudMask)
        // Include median fit identity
        if let dl = dlBest {
            h.combine(dl.mn)
            h.combine(dl.mx)
            h.combine(dl.sos)
        }
        return h.finalize()
    }

    /// True when per-pixel results exist but settings have changed since the fit was run.
    private var pixelFitIsStale: Bool {
        pixelPhenology != nil && lastPixelFitSettingsHash != pixelFitSettingsHash
    }

    /// Chart y-axis label and value depending on display mode.
    private var chartLabel: String {
        if isInspectingPixel {
            let w = settings.pixelInspectWindow
            let label = "Pixel (\(inspectedPixelCol), \(inspectedPixelRow))"
            return w > 1 ? "\(label) [\(w)\u{00D7}\(w)]" : label
        }
        switch settings.displayMode {
        case .ndvi, .fcc, .rcc, .scl: return "Median \(viLabel)"
        case .bandRed: return "Red (B04)"
        case .bandNIR: return "NIR (B08)"
        case .bandGreen: return "Green (B03)"
        case .bandBlue: return "Blue (B02)"
        }
    }

    /// Get the chart y-value for a frame depending on display mode.
    private func chartValue(for frame: NDVIFrame) -> Double {
        switch settings.displayMode {
        case .ndvi, .fcc, .rcc, .scl:
            return Double(frame.medianNDVI)
        case .bandRed:
            return medianReflectance(band: frame.redBand, frame: frame)
        case .bandNIR:
            return medianReflectance(band: frame.nirBand, frame: frame)
        case .bandGreen:
            return medianReflectance(band: frame.greenBand, frame: frame)
        case .bandBlue:
            return medianReflectance(band: frame.blueBand, frame: frame)
        }
    }

    /// Per-frame max VI (from valid pixels within AOI).
    private func maxVI(for frame: NDVIFrame) -> Double {
        var mx: Float = -.greatestFiniteMagnitude
        for row in frame.ndvi { for v in row where !v.isNaN { mx = max(mx, v) } }
        return mx > -.greatestFiniteMagnitude ? Double(mx) : Double(frame.medianNDVI)
    }

    /// Per-frame min VI (from valid pixels within AOI).
    private func minVI(for frame: NDVIFrame) -> Double {
        var mn: Float = .greatestFiniteMagnitude
        for row in frame.ndvi { for v in row where !v.isNaN { mn = min(mn, v) } }
        return mn < .greatestFiniteMagnitude ? Double(mn) : Double(frame.medianNDVI)
    }

    private func medianReflectance(band: [[UInt16]]?, frame: NDVIFrame) -> Double {
        guard let band = band else { return 0 }
        let ofs = frame.dnOffset
        var vals = [Float]()
        for row in 0..<min(frame.height, band.count) {
            for col in 0..<min(frame.width, band[row].count) {
                if !frame.ndvi[row][col].isNaN {  // only valid pixels
                    vals.append((Float(band[row][col]) + ofs) / 10000.0)
                }
            }
        }
        guard !vals.isEmpty else { return 0 }
        vals.sort()
        let mid = vals.count / 2
        return Double(vals.count % 2 == 0 ? (vals[mid-1] + vals[mid]) / 2 : vals[mid])
    }

    private var ndviChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(chartLabel)
                    .font(.caption.bold())
                    .foregroundStyle(isInspectingPixel ? .orange : .green)
                if let pp = pixelPhenology, pp.outlierCount > 0 {
                    Text("Filtered")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
                Spacer()
                Text("Valid")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }

            let sorted = processor.frames.sorted(by: { $0.date < $1.date })
            let validSorted = sorted.filter { $0.validPixelCount > 0 }
            Chart {
                // NDVI line (dimmed when inspecting pixel)
                ForEach(validSorted) { frame in
                    LineMark(
                        x: .value("Date", frame.date),
                        y: .value(viLabel, chartValue(for: frame)),
                        series: .value("Series", viLabel)
                    )
                    .foregroundStyle(.green.opacity(isInspectingPixel ? 0.15 : 0.6))
                    .lineStyle(StrokeStyle(lineWidth: isInspectingPixel ? 1 : 2,
                                           dash: isInspectingPixel ? [4, 2] : []))
                }

                // Area max/min envelope (when inspecting pixel, for context)
                if isInspectingPixel {
                    ForEach(validSorted) { frame in
                        LineMark(
                            x: .value("Date", frame.date),
                            y: .value(viLabel, maxVI(for: frame)),
                            series: .value("Series", "Max")
                        )
                        .foregroundStyle(.green.opacity(0.1))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                    }
                    ForEach(validSorted) { frame in
                        LineMark(
                            x: .value("Date", frame.date),
                            y: .value(viLabel, minVI(for: frame)),
                            series: .value("Series", "Min")
                        )
                        .foregroundStyle(.green.opacity(0.1))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                    }
                }

                // Per-pixel time series (when inspecting)
                if isInspectingPixel {
                    let pixData = pixelNDVIData(sorted: sorted)
                    ForEach(pixData) { pt in
                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value(viLabel, pt.ndvi),
                            series: .value("Series", "Pixel")
                        )
                        .foregroundStyle(.orange.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }

                // Filtered median NDVI (after cluster filter) — open circles
                if let pp = pixelPhenology, pp.outlierCount > 0 {
                    let filteredMedians = pp.filteredMedianNDVI(frames: sorted)
                    ForEach(Array(zip(sorted.indices, sorted)), id: \.1.id) { idx, frame in
                        if idx < filteredMedians.count, !filteredMedians[idx].isNaN {
                            PointMark(
                                x: .value("Date", frame.date),
                                y: .value(viLabel, Double(filteredMedians[idx]))
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
                        y: .value(viLabel, pct),
                        series: .value("Series", "Valid%")
                    )
                    .foregroundStyle(.blue.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                }

                // Small dots for NDVI
                ForEach(validSorted) { frame in
                    PointMark(
                        x: .value("Date", frame.date),
                        y: .value(viLabel, chartValue(for: frame))
                    )
                    .foregroundStyle(.green.opacity(isInspectingPixel ? 0.15 : 1.0))
                    .symbolSize(isInspectingPixel ? 8 : 15)
                }

                // Per-pixel NDVI dots
                if isInspectingPixel {
                    let pixData = pixelNDVIData(sorted: sorted)
                    ForEach(pixData) { pt in
                        PointMark(
                            x: .value("Date", pt.date),
                            y: .value(viLabel, pt.ndvi)
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(20)
                    }
                }

                // Current frame indicator
                if currentFrameIndex < processor.frames.count {
                    let current = processor.frames[currentFrameIndex]
                    let frameY = isInspectingPixel
                        ? (pixelValue(row: inspectedPixelRow, col: inspectedPixelCol, frame: current) ?? 0)
                        : chartValue(for: current)
                    PointMark(
                        x: .value("Date", current.date),
                        y: .value(viLabel, frameY)
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
                        y: .value(viLabel, pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(pt.style)
                }

                // Pixel DL fit curve (when inspecting)
                ForEach(pixelDLCurvePoints(sorted: sorted), id: \.id) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value(viLabel, pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(pt.style)
                }

                // Phenology indicator lines (tangent slopes for rsp/rau)
                ForEach(phenologyIndicatorLines(sorted: sorted), id: \.id) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value(viLabel, pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }

                // Fraction time series (when unmixing enabled)
                if !frameUnmixResults.isEmpty {
                    ForEach(validSorted) { frame in
                        if let fv = medianFraction(for: frame, param: .fveg) {
                            LineMark(
                                x: .value("Date", frame.date),
                                y: .value(viLabel, fv),
                                series: .value("Series", "fVeg")
                            )
                            .foregroundStyle(.green.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                        }
                    }
                    ForEach(validSorted) { frame in
                        if let fn = medianFraction(for: frame, param: .fnpv) {
                            LineMark(
                                x: .value("Date", frame.date),
                                y: .value(viLabel, fn),
                                series: .value("Series", "fNPV")
                            )
                            .foregroundStyle(.brown.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                        }
                    }
                    ForEach(validSorted) { frame in
                        if let fs = medianFraction(for: frame, param: .fsoil) {
                            LineMark(
                                x: .value("Date", frame.date),
                                y: .value(viLabel, fs),
                                series: .value("Series", "fSoil")
                            )
                            .foregroundStyle(.orange.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                        }
                    }
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

            // Pixel phenology parameters annotation
            if isInspectingPixel, let pp = pixelPhenology,
               inspectedPixelRow >= 0, inspectedPixelRow < pp.height,
               inspectedPixelCol >= 0, inspectedPixelCol < pp.width,
               let px = pp.pixels[inspectedPixelRow][inspectedPixelCol] {
                HStack(spacing: 8) {
                    if px.fitQuality == .good {
                        Text("SOS \(Int(px.params.sos))")
                        Text("EOS \(Int(px.params.eos))")
                        Text("amp \(String(format: "%.2f", px.params.delta))")
                        Text("rsp \(String(format: "%.3f", px.params.rsp))")
                        Text("RMSE \(String(format: "%.3f", px.params.rmse))")
                    } else {
                        Text(px.fitQuality.rawValue.capitalized)
                            .foregroundStyle(.red)
                        Text("\(px.nValidObs) obs")
                    }
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.cyan)
            }

            // Pixel unmixing fractions annotation
            if isInspectingPixel, currentFrameIndex < processor.frames.count {
                let cf = processor.frames[currentFrameIndex]
                if let ur = frameUnmixResults[cf.id],
                   inspectedPixelRow < ur.height, inspectedPixelCol < ur.width {
                    let fv = ur.fveg[inspectedPixelRow][inspectedPixelCol]
                    if !fv.isNaN {
                        let fn = ur.fnpv[inspectedPixelRow][inspectedPixelCol]
                        let fs = ur.fsoil[inspectedPixelRow][inspectedPixelCol]
                        let rm = ur.rmse[inspectedPixelRow][inspectedPixelCol]
                        HStack(spacing: 8) {
                            Text("fVeg \(String(format: "%.2f", fv))")
                                .foregroundStyle(.green)
                            Text("fNPV \(String(format: "%.2f", fn))")
                                .foregroundStyle(.brown)
                            Text("fSoil \(String(format: "%.2f", fs))")
                                .foregroundStyle(.orange)
                            Text("RMSE \(String(format: "%.4f", rm))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 9).monospacedDigit())
                    }
                }
            }
        }
    }

    // MARK: - Spectral Unmixing

    /// Extract fraction map for a given frame and parameter.
    private func fractionMap(for frame: NDVIFrame, param: PhenologyParameter) -> [[Float]]? {
        guard let result = frameUnmixResults[frame.id] else { return nil }
        switch param {
        case .fveg: return result.fveg
        case .fnpv: return result.fnpv
        case .fsoil: return result.fsoil
        case .unmixRMSE: return result.rmse
        default: return nil
        }
    }

    /// Compute median fraction value for a frame (area-level).
    private func medianFraction(for frame: NDVIFrame, param: PhenologyParameter) -> Double? {
        guard let map = fractionMap(for: frame, param: param) else { return nil }
        var vals = [Float]()
        for row in map { for v in row where !v.isNaN { vals.append(v) } }
        guard !vals.isEmpty else { return nil }
        vals.sort()
        let mid = vals.count / 2
        return Double(vals.count % 2 == 0 ? (vals[mid-1] + vals[mid]) / 2 : vals[mid])
    }

    /// Run spectral unmixing on all frames.
    private func runUnmixing() {
        isRunningUnmix = true
        let frames = processor.frames
        Task.detached {
            var results = [UUID: FrameUnmixResult]()
            for frame in frames {
                // Build band arrays from available bands (B02, B03, B04, B08)
                var bands = [[[UInt16]]]()
                var bandInfo = [(band: String, nm: Double)]()
                // Always have red (B04) and NIR (B08)
                bands.append(frame.redBand)
                bandInfo.append(("B04", 665))
                bands.append(frame.nirBand)
                bandInfo.append(("B08", 842))
                if let green = frame.greenBand {
                    bands.append(green)
                    bandInfo.append(("B03", 560))
                }
                if let blue = frame.blueBand {
                    bands.append(blue)
                    bandInfo.append(("B02", 490))
                }
                guard bands.count >= 3 else { continue }
                let result = SpectralUnmixing.unmixFrame(
                    bands: bands, bandInfo: bandInfo,
                    dnOffset: frame.dnOffset,
                    width: frame.width, height: frame.height
                )
                results[frame.id] = result
            }
            await MainActor.run {
                frameUnmixResults = results
                isRunningUnmix = false
            }
        }
    }

    // MARK: - Spectral Plot

    /// Sentinel-2 band center wavelengths (nm)
    private static let bandWavelengths: [(band: String, nm: Double)] = [
        ("B02", 490), ("B03", 560), ("B04", 665), ("B08", 842)
    ]

    /// Compute median reflectance for a single pixel (or AOI median) for each available band.
    private func spectralValues(frame: NDVIFrame, pixelRow: Int? = nil, pixelCol: Int? = nil) -> [(nm: Double, refl: Double, band: String)] {
        let ofs = frame.dnOffset
        var result = [(nm: Double, refl: Double, band: String)]()

        func singlePixel(_ band: [[UInt16]]?, row: Int, col: Int) -> Double? {
            guard let b = band, row < b.count, col < b[row].count else { return nil }
            let dn = b[row][col]
            guard dn > 0, dn < 65535 else { return nil }
            return Double((Float(dn) + ofs) / 10000.0)
        }

        if let r = pixelRow, let c = pixelCol {
            // Single pixel mode
            if let v = singlePixel(frame.redBand, row: r, col: c) { result.append((665, v, "B04")) }
            if let v = singlePixel(frame.nirBand, row: r, col: c) { result.append((842, v, "B08")) }
            if let v = singlePixel(frame.greenBand, row: r, col: c) { result.append((560, v, "B03")) }
            if let v = singlePixel(frame.blueBand, row: r, col: c) { result.append((490, v, "B02")) }
        } else {
            // AOI median mode
            result.append((665, medianReflectance(band: frame.redBand, frame: frame), "B04"))
            result.append((842, medianReflectance(band: frame.nirBand, frame: frame), "B08"))
            if frame.greenBand != nil {
                result.append((560, medianReflectance(band: frame.greenBand, frame: frame), "B03"))
            }
            if frame.blueBand != nil {
                result.append((490, medianReflectance(band: frame.blueBand, frame: frame), "B02"))
            }
        }
        return result.filter { $0.refl > 0 }.sorted(by: { $0.nm < $1.nm })
    }

    @State private var showSpectralChart = false

    private var spectralChart: some View {
        Group {
            if showSpectralChart, currentFrameIndex < processor.frames.count {
                let current = processor.frames[currentFrameIndex]
                let sorted = processor.frames.sorted(by: { $0.date < $1.date })

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        let peakFrame = sorted.max(by: { $0.medianNDVI < $1.medianNDVI })
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Spectral \u{2014} \(current.dateString)")
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                            if current.id == peakFrame?.id {
                                Text("(peak)")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.green)
                            }
                        }
                        Spacer()
                        Text("\(sorted.count) dates")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Button {
                            showSpectralChart = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    spectralChartContent(current: current, sorted: sorted)
                }
                .task {
                    // Ensure green and blue bands are loaded for the spectral plot
                    await processor.loadMissingBands(for: .rcc)
                }
            } else if !showSpectralChart && processor.frames.count > 1 {
                Button {
                    showSpectralChart = true
                } label: {
                    Label("Spectral Plot", systemImage: "waveform.path.ecg")
                        .font(.caption)
                }
            }
        }
    }

    private func spectralChartContent(current: NDVIFrame, sorted: [NDVIFrame]) -> some View {
        let usePixel = isInspectingPixel
        let currentVals = spectralValues(
            frame: current,
            pixelRow: usePixel ? inspectedPixelRow : nil,
            pixelCol: usePixel ? inspectedPixelCol : nil
        )

        let peakFrame = sorted.max(by: { $0.medianNDVI < $1.medianNDVI })
        let minFrame = sorted.min(by: { $0.medianNDVI < $1.medianNDVI })

        struct SpectralPt: Identifiable {
            let id: String
            let nm: Double
            let refl: Double
            let series: String
            let band: String
        }

        struct EnvelopePt: Identifiable {
            let id: String
            let nm: Double
            let lo: Double
            let hi: Double
        }

        // Per-band statistics across all frames (median, min, max)
        var envelopePts = [EnvelopePt]()
        var pts = [SpectralPt]()
        for bw in Self.bandWavelengths {
            var allRefl = [Double]()
            for frame in sorted {
                let sv = spectralValues(frame: frame,
                                        pixelRow: usePixel ? inspectedPixelRow : nil,
                                        pixelCol: usePixel ? inspectedPixelCol : nil)
                if let v = sv.first(where: { $0.band == bw.band }) {
                    allRefl.append(v.refl)
                }
            }
            if allRefl.count >= 2 {
                let s = allRefl.sorted()
                let mid = s.count / 2
                let median = s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
                envelopePts.append(EnvelopePt(id: "env_\(bw.band)", nm: bw.nm,
                                              lo: s.first!, hi: s.last!))
                pts.append(SpectralPt(id: "med_\(bw.band)", nm: bw.nm, refl: median,
                                      series: "Median", band: bw.band))
            }
        }

        // Current frame
        for v in currentVals {
            pts.append(SpectralPt(id: "cur_\(v.band)", nm: v.nm, refl: v.refl,
                                  series: "Current", band: v.band))
        }

        // Peak frame
        if let peak = peakFrame, peak.id != current.id {
            let pv = spectralValues(frame: peak,
                                    pixelRow: usePixel ? inspectedPixelRow : nil,
                                    pixelCol: usePixel ? inspectedPixelCol : nil)
            for v in pv {
                pts.append(SpectralPt(id: "peak_\(v.band)", nm: v.nm, refl: v.refl,
                                      series: "Peak", band: v.band))
            }
        }

        // Lowest-NDVI frame
        if let mn = minFrame, mn.id != current.id, mn.id != peakFrame?.id {
            let mv = spectralValues(frame: mn,
                                    pixelRow: usePixel ? inspectedPixelRow : nil,
                                    pixelCol: usePixel ? inspectedPixelCol : nil)
            for v in mv {
                pts.append(SpectralPt(id: "low_\(v.band)", nm: v.nm, refl: v.refl,
                                      series: "Low", band: v.band))
            }
        }

        // Predicted spectrum from unmixing
        if let unmixResult = frameUnmixResults[current.id] {
            let fracs: UnmixResult?
            if usePixel, inspectedPixelRow < unmixResult.height, inspectedPixelCol < unmixResult.width {
                let fv = unmixResult.fveg[inspectedPixelRow][inspectedPixelCol]
                let fn = unmixResult.fnpv[inspectedPixelRow][inspectedPixelCol]
                let fs = unmixResult.fsoil[inspectedPixelRow][inspectedPixelCol]
                let rm = unmixResult.rmse[inspectedPixelRow][inspectedPixelCol]
                fracs = fv.isNaN ? nil : UnmixResult(fveg: fv, fnpv: fn, fsoil: fs, rmse: rm)
            } else if let mfv = medianFraction(for: current, param: .fveg),
                      let mfn = medianFraction(for: current, param: .fnpv),
                      let mfs = medianFraction(for: current, param: .fsoil) {
                fracs = UnmixResult(fveg: Float(mfv), fnpv: Float(mfn), fsoil: Float(mfs), rmse: 0)
            } else {
                fracs = nil
            }
            if let f = fracs {
                let endmembers = EndmemberLibrary.defaults
                let availableBands: [(band: String, nm: Double)] = currentVals.map { ($0.band, $0.nm) }
                let predicted = SpectralUnmixing.predict(
                    fractions: f, endmembers: endmembers, bands: availableBands)
                for p in predicted {
                    let band = availableBands.first(where: { $0.nm == p.nm })?.band ?? ""
                    pts.append(SpectralPt(id: "pred_\(band)", nm: p.nm, refl: p.refl,
                                          series: "Predicted", band: band))
                }
            }
        }

        // Dynamic Y scale
        let maxRefl = max(0.5, (envelopePts.map(\.hi) + pts.map(\.refl)).max() ?? 0.5)
        let yTop = ceil(maxRefl * 10) / 10  // round up to nearest 0.1

        // Build color map
        var colorMap: KeyValuePairs<String, Color> {
            [
                "Current": Color.red,
                "Peak": Color.green.opacity(0.7),
                "Low": Color.blue.opacity(0.7),
                "Median": Color.gray,
                "Predicted": Color.purple.opacity(0.8)
            ]
        }

        return Chart {
            // Envelope: min/max range across all frames
            ForEach(envelopePts) { env in
                AreaMark(
                    x: .value("Wavelength (nm)", env.nm),
                    yStart: .value("lo", env.lo),
                    yEnd: .value("hi", env.hi)
                )
                .foregroundStyle(Color.gray.opacity(0.12))
                .interpolationMethod(.catmullRom)
            }

            // Line + point marks for each series
            ForEach(pts) { pt in
                LineMark(
                    x: .value("Wavelength (nm)", pt.nm),
                    y: .value("Reflectance", pt.refl),
                    series: .value("Series", pt.series)
                )
                .foregroundStyle(by: .value("Series", pt.series))
                .lineStyle(StrokeStyle(
                    lineWidth: pt.series == "Current" ? 2.5 : 1.5,
                    dash: pt.series == "Current" ? [] : [4, 2]))

                PointMark(
                    x: .value("Wavelength (nm)", pt.nm),
                    y: .value("Reflectance", pt.refl)
                )
                .foregroundStyle(by: .value("Series", pt.series))
                .symbolSize(pt.series == "Current" ? 40 : (pt.series == "Median" ? 10 : 20))
                .annotation(position: .top, spacing: 2) {
                    if pt.series == "Current" {
                        Text(pt.band)
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartForegroundStyleScale(colorMap)
        .chartXScale(domain: 400...900)
        .chartYScale(domain: 0...yTop)
        .chartXAxis {
            AxisMarks(values: [450, 500, 560, 665, 750, 842]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.2f", v))
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .chartLegend(.visible)
        .frame(height: 160)
        .overlay(alignment: .bottom) {
            Text("Wavelength (nm)")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .offset(y: -2)
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
        let refYr = cal.component(.year, from: first.date)
        // Use continuous DOY (handles year boundaries)
        let cdoyFirst = first.continuousDOY(referenceYear: refYr)
        let cdoyLast = last.continuousDOY(referenceYear: refYr)
        let nPts = 80
        let step = max(1, (cdoyLast - cdoyFirst) / nPts)
        let cdoys = stride(from: cdoyFirst, through: cdoyLast, by: step).map { $0 }

        // Convert continuous DOY back to a Date for the chart x-axis
        func dateForCDOY(_ cdoy: Int) -> Date? {
            let yr = refYr + (cdoy - 1) / 365
            let doy = ((cdoy - 1) % 365) + 1
            return cal.date(from: DateComponents(year: yr, day: doy))
        }

        var pts = [DLCurvePoint]()

        // Ensemble curves (semi-transparent, hidden when inspecting pixel)
        if !isInspectingPixel {
            for (ei, ep) in dlEnsemble.prefix(15).enumerated() where ei > 0 {
                for cdoy in cdoys {
                    if let d = dateForCDOY(cdoy) {
                        pts.append(DLCurvePoint(
                            id: "e\(ei)_\(cdoy)", date: d,
                            ndvi: ep.evaluate(t: Double(cdoy)),
                            series: "ens\(ei)",
                            color: .yellow.opacity(0.15),
                            style: StrokeStyle(lineWidth: 1)
                        ))
                    }
                }
            }
        }

        // Best fit — always show as thick green
        if let dl = dlBest {
            for cdoy in cdoys {
                if let d = dateForCDOY(cdoy) {
                    pts.append(DLCurvePoint(
                        id: "fit_\(cdoy)", date: d,
                        ndvi: dl.evaluate(t: Double(cdoy)),
                        series: "DL-fit",
                        color: .green.opacity(isInspectingPixel ? 0.3 : 0.9),
                        style: StrokeStyle(lineWidth: isInspectingPixel ? 1.5 : 3)
                    ))
                }
            }
        }

        // Slider curve
        if showDLSliders {
            for cdoy in cdoys {
                if let d = dateForCDOY(cdoy) {
                    pts.append(DLCurvePoint(
                        id: "sl_\(cdoy)", date: d,
                        ndvi: dlSliders.evaluate(t: Double(cdoy)),
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
        let refYr = cal.component(.year, from: firstDate)
        var pts = [DLCurvePoint]()

        // Convert continuous DOY to Date (handles year boundaries)
        func dateForCDOY(_ cdoy: Int) -> Date? {
            let yr = refYr + (cdoy - 1) / 365
            let doy = ((cdoy - 1) % 365) + 1
            return cal.date(from: DateComponents(year: yr, day: doy))
        }

        // rsp: tangent line at SOS showing green-up slope
        if param == .rsp || param == .sos || param == .seasonLength {
            let sosCDOY = Int(fit.sos)
            if let sosDate = dateForCDOY(sosCDOY) {
                if param == .rsp {
                    let sosNDVI = fit.evaluate(t: fit.sos)
                    let halfSpan = 20.0
                    let slope = fit.rsp * (fit.mx - fit.mn) * 0.25
                    if let date0 = dateForCDOY(sosCDOY - Int(halfSpan)),
                       let date1 = dateForCDOY(sosCDOY + Int(halfSpan)) {
                        pts.append(DLCurvePoint(id: "rsp_t0", date: date0,
                            ndvi: sosNDVI - slope * halfSpan, series: "rsp-tangent",
                            color: .orange, style: StrokeStyle(lineWidth: 2.5)))
                        pts.append(DLCurvePoint(id: "rsp_t1", date: date1,
                            ndvi: sosNDVI + slope * halfSpan, series: "rsp-tangent",
                            color: .orange, style: StrokeStyle(lineWidth: 2.5)))
                    }
                    pts.append(DLCurvePoint(id: "rsp_v0", date: sosDate, ndvi: -0.2,
                        series: "sos-rule", color: .orange.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                    pts.append(DLCurvePoint(id: "rsp_v1", date: sosDate, ndvi: 1.0,
                        series: "sos-rule", color: .orange.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                } else {
                    pts.append(DLCurvePoint(id: "sos_v0", date: sosDate, ndvi: -0.2,
                        series: "sos-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
                    pts.append(DLCurvePoint(id: "sos_v1", date: sosDate, ndvi: 1.0,
                        series: "sos-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
                }
            }
        }

        // rau: tangent line at EOS showing senescence slope
        if param == .rau || param == .seasonLength {
            let eosCDOY = Int(fit.eos)
            if let eosDate = dateForCDOY(eosCDOY) {
                if param == .rau {
                    let eosNDVI = fit.evaluate(t: fit.eos)
                    let halfSpan = 20.0
                    let slope = -fit.rau * (fit.mx - fit.mn) * 0.25
                    if let date0 = dateForCDOY(eosCDOY - Int(halfSpan)),
                       let date1 = dateForCDOY(eosCDOY + Int(halfSpan)) {
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

        // Delta (amplitude) — show horizontal lines at mn and mx
        if param == .delta, let first = sorted.first?.date, let last = sorted.last?.date {
            pts.append(DLCurvePoint(id: "delta_mn0", date: first, ndvi: fit.mn,
                series: "mn-line", color: .primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
            pts.append(DLCurvePoint(id: "delta_mn1", date: last, ndvi: fit.mn,
                series: "mn-line", color: .primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
            pts.append(DLCurvePoint(id: "delta_mx0", date: first, ndvi: fit.mx,
                series: "mx-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
            pts.append(DLCurvePoint(id: "delta_mx1", date: last, ndvi: fit.mx,
                series: "mx-line", color: .primary, style: StrokeStyle(lineWidth: 2)))
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

    // MARK: - Pixel Inspection Helpers

    private struct PixelDataPoint: Identifiable {
        let id: String
        let date: Date
        let ndvi: Double
    }

    /// Extract NxN window-averaged NDVI for the inspected pixel across all frames.
    private func pixelNDVIData(sorted: [NDVIFrame]) -> [PixelDataPoint] {
        guard isInspectingPixel else { return [] }
        return sorted.compactMap { frame in
            guard let val = pixelValue(row: inspectedPixelRow, col: inspectedPixelCol, frame: frame) else { return nil }
            return PixelDataPoint(id: frame.id.uuidString, date: frame.date, ndvi: val)
        }
    }

    /// Average NDVI over the NxN inspect window for a single frame.
    private func pixelValue(row: Int, col: Int, frame: NDVIFrame) -> Double? {
        let half = (settings.pixelInspectWindow - 1) / 2
        var values = [Float]()
        for dr in -half...half {
            for dc in -half...half {
                let r = row + dr, c = col + dc
                guard r >= 0, r < frame.height, c >= 0, c < frame.width else { continue }
                let v = frame.ndvi[r][c]
                if !v.isNaN { values.append(v) }
            }
        }
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    /// Generate DL curve points for the inspected pixel's phenology fit.
    /// Shows the curve even for poor fits (only skipped pixels have no params to plot).
    private func pixelDLCurvePoints(sorted: [NDVIFrame]) -> [DLCurvePoint] {
        guard isInspectingPixel,
              let pp = pixelPhenology,
              inspectedPixelRow >= 0, inspectedPixelRow < pp.height,
              inspectedPixelCol >= 0, inspectedPixelCol < pp.width,
              let px = pp.pixels[inspectedPixelRow][inspectedPixelCol],
              px.fitQuality != .skipped,
              let first = sorted.first, let last = sorted.last else { return [] }

        let cal = Calendar.current
        let refYr = cal.component(.year, from: first.date)
        let cdoyFirst = first.continuousDOY(referenceYear: refYr)
        let cdoyLast = last.continuousDOY(referenceYear: refYr)
        let step = max(1, (cdoyLast - cdoyFirst) / 80)

        func dateForCDOY(_ cdoy: Int) -> Date? {
            let yr = refYr + (cdoy - 1) / 365
            let doy = ((cdoy - 1) % 365) + 1
            return cal.date(from: DateComponents(year: yr, day: doy))
        }

        let pxID = "\(inspectedPixelRow)_\(inspectedPixelCol)"
        return stride(from: cdoyFirst, through: cdoyLast, by: step).compactMap { cdoy in
            guard let d = dateForCDOY(cdoy) else { return nil }
            return DLCurvePoint(
                id: "pixdl_\(pxID)_\(cdoy)", date: d,
                ndvi: px.params.evaluate(t: Double(cdoy)),
                series: "DL-pixel-\(pxID)",
                color: .cyan,
                style: StrokeStyle(lineWidth: 2.5, dash: [6, 3])
            )
        }
    }

    /// Update the inspected pixel coordinates (called from long-press gesture).
    private func updatePixelInspection(row: Int, col: Int) {
        guard let pp = pixelPhenology,
              row >= 0, row < pp.height, col >= 0, col < pp.width else { return }
        inspectedPixelRow = row
        inspectedPixelCol = col
        if !isInspectingPixel {
            isInspectingPixel = true
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }

    // MARK: - Live Menu (parameter map selector)

    private var liveMenu: some View {
        Menu {
            Button {
                phenologyDisplayParam = nil
                showBadData = false
                startPlayback()
            } label: {
                if phenologyDisplayParam == nil && !showBadData {
                    Label("Live", systemImage: "checkmark")
                } else {
                    Text("Live")
                }
            }
            Divider()
            ForEach(PhenologyParameter.phenologyCases, id: \.self) { param in
                Button {
                    phenologyDisplayParam = param
                    showBadData = false
                    stopPlayback()
                } label: {
                    if phenologyDisplayParam == param && !showBadData {
                        Label(param.rawValue, systemImage: "checkmark")
                    } else {
                        Text(param.rawValue)
                    }
                }
            }
            if !frameUnmixResults.isEmpty {
                Divider()
                ForEach(PhenologyParameter.fractionCases, id: \.self) { param in
                    Button {
                        phenologyDisplayParam = param
                        showBadData = false
                        startPlayback()
                    } label: {
                        if phenologyDisplayParam == param && !showBadData {
                            Label(param.rawValue, systemImage: "checkmark")
                        } else {
                            Text(param.rawValue)
                        }
                    }
                }
            }
            Divider()
            Button {
                showBadData = true
                phenologyDisplayParam = nil
                stopPlayback()
            } label: {
                if showBadData {
                    Label("Bad Data", systemImage: "checkmark")
                } else {
                    Text("Bad Data")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showBadData ? "exclamationmark.triangle.fill" : "map.fill")
                    .font(.system(size: 11))
                Text(showBadData ? "Bad Data" : (phenologyDisplayParam?.rawValue ?? "Live"))
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .tint(showBadData ? .red : (phenologyDisplayParam != nil ? .orange : .green))
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
                    Text("RMSE \(String(format: "%.2f", settings.pixelFitRMSEThreshold))")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.orange)
                    Text("\(String(format: "%.1f", pp.computeTimeSeconds))s")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.pixelFitRMSEThreshold, in: 0.02...0.50, step: 0.01)
                    .tint(.orange)
                    .onChange(of: settings.pixelFitRMSEThreshold) {
                        guard let base = pixelPhenologyBase ?? pixelPhenology else { return }
                        pixelPhenology = base.reclassified(rmseThreshold: settings.pixelFitRMSEThreshold)
                    }

                // Cluster filter + analysis
                HStack(spacing: 6) {
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

                    Spacer()
                }
            }

            // Best-fit parameters
            if let dl = dlBest {
                HStack(spacing: 8) {
                    dlParamLabel("mn", dl.mn, fmt: "%.2f")
                    dlParamLabel("amp", dl.delta, fmt: "%.2f")
                    dlParamLabel("sos", dl.sos, fmt: "%.0f")
                    dlParamLabel("rsp", dl.rsp, fmt: "%.3f")
                    dlParamLabel("season", dl.seasonLength, fmt: "%.0f")
                    dlParamLabel("rau", dl.rau, fmt: "%.3f")
                    dlParamLabel("mx", dl.mx, fmt: "%.2f", color: .secondary)
                    dlParamLabel("eos", dl.eos, fmt: "%.0f", color: .secondary)
                }
            }

            // Sliders
            if showDLSliders {
                VStack(spacing: 6) {
                    dlSlider("mn", Binding(
                        get: { dlSliders.mn },
                        set: { newMn in
                            let amp = dlSliders.mx - dlSliders.mn
                            dlSliders.mn = newMn
                            dlSliders.mx = newMn + amp
                        }
                    ), range: -0.2...0.5, step: 0.01)
                    dlSlider("amp", Binding(
                        get: { dlSliders.mx - dlSliders.mn },
                        set: { dlSliders.mx = dlSliders.mn + $0 }
                    ), range: 0.05...1.2, step: 0.01)
                    dlSlider("sos", Binding(
                        get: { dlSliders.sos },
                        set: { newSOS in
                            let season = dlSliders.eos - dlSliders.sos
                            dlSliders.sos = newSOS
                            dlSliders.eos = newSOS + season
                        }
                    ), range: Double(datasetDOYFirst)...Double(datasetDOYLast), step: 1)
                    dlSlider("rsp", $dlSliders.rsp, range: 0.005...0.3, step: 0.005)
                    dlSlider("season", Binding(
                        get: { dlSliders.eos - dlSliders.sos },
                        set: { dlSliders.eos = dlSliders.sos + $0 }
                    ), range: 10...365, step: 1)
                    dlSlider("rau", $dlSliders.rau, range: 0.005...0.3, step: 0.005)

                    // Live RMSE for slider values
                    let refYr = referenceYear
                    let sliderRMSE = DoubleLogistic.rmse(
                        params: dlSliders,
                        data: processor.frames.filter { $0.validPixelCount > 0 }.map {
                            DoubleLogistic.DataPoint(doy: Double($0.continuousDOY(referenceYear: refYr)), ndvi: Double($0.medianNDVI))
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

    private func dlParamLabel(_ name: String, _ value: Double, fmt: String, color: Color = .yellow.opacity(0.7)) -> some View {
        VStack(spacing: 1) {
            Text(name)
                .font(.system(size: 7).bold())
                .foregroundStyle(color)
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
        log.info("  amp: \(f3(base.delta)) (mx-mn)")
        log.info("  sos: \(f1(base.sos)) * U(\(f3(1-p)), \(f3(1+p))) → [\(f1(base.sos*(1-p))), \(f1(base.sos*(1+p)))]")
        log.info("  rsp: \(f3(base.rsp)) * U(\(f3(1-sp)), \(f3(1+sp))) → [\(f3(base.rsp*(1-sp))), \(f3(base.rsp*(1+sp)))]")
        log.info("  len: \(f1(base.seasonLength)) (eos-sos)")
        log.info("  rau: \(f3(base.rau)) * U(\(f3(1-sp)), \(f3(1+sp))) → [\(f3(base.rau*(1-sp))), \(f3(base.rau*(1+sp)))]")
    }

    private func runDLFit() {
        let refYr = referenceYear
        let useFveg = settings.dlFitTarget == .fveg && !frameUnmixResults.isEmpty
        let data = processor.frames.filter { $0.validPixelCount > 0 }.compactMap { f -> DoubleLogistic.DataPoint? in
            let val: Double
            if useFveg, let fv = medianFraction(for: f, param: .fveg) {
                val = fv
            } else {
                val = Double(f.medianNDVI)
            }
            return DoubleLogistic.DataPoint(doy: Double(f.continuousDOY(referenceYear: refYr)), ndvi: val)
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        let dlBounds: (lo: [Double], hi: [Double]) = (
            [settings.boundMnMin, settings.boundDeltaMin, settings.boundSosMin, settings.boundRspMin, max(minSL, 10), settings.boundRauMin],
            [settings.boundMnMax, settings.boundDeltaMax, settings.boundSosMax, settings.boundRspMax, min(maxSL, 350), settings.boundRauMax]
        )

        // Log the initial guess and perturbation ranges
        let filtered = DoubleLogistic.filterCycleContamination(data: data)
        let guess = DoubleLogistic.initialGuess(data: filtered)
        logDistributions(label: "Median DL fit", base: guess, p: p, sp: sp, nRuns: 50, minSL: minSL, maxSL: maxSL)

        Task.detached {
            // Stage 1: initial robust fit on all data
            let initial = DoubleLogistic.ensembleFit(data: data,
                perturbation: p, slopePerturbation: sp,
                minSeasonLength: minSL, maxSeasonLength: maxSL,
                slopeSymmetry: Double(settings.slopeSymmetry),
                bounds: dlBounds,
                secondPass: settings.enableSecondPass)

            // Stage 2: identify outlier dates using MAD of residuals
            let residuals = data.map { pt in
                pt.ndvi - initial.best.evaluate(t: pt.doy)
            }
            let sortedAbs = residuals.map { abs($0) }.sorted()
            let mad = sortedAbs[sortedAbs.count / 2]  // median absolute deviation
            let threshold = max(0.05, mad * 4.0)  // 4 MADs, floor at 0.05

            var outlierIndices = Set<Int>()
            for (i, r) in residuals.enumerated() {
                if abs(r) > threshold {
                    outlierIndices.insert(i)
                }
            }

            if !outlierIndices.isEmpty {
                // Exclude outliers from fit but DO NOT remove frames from processor
                let cleanData = data.enumerated().filter { !outlierIndices.contains($0.offset) }.map(\.element)

                await MainActor.run {
                    let outlierDates = outlierIndices.sorted().map { idx -> String in
                        let frame = processor.frames[idx]
                        let src = frame.sourceID?.rawValue.uppercased() ?? "?"
                        return "\(frame.dateString) [\(src)] (residual=\(String(format: "%.3f", residuals[idx])))"
                    }
                    log.warn("Excluded \(outlierIndices.count) outlier date(s) from fit (MAD=\(String(format: "%.3f", mad)), threshold=\(String(format: "%.3f", threshold))):")
                    for d in outlierDates { log.warn("  \(d)") }
                }

                guard cleanData.count >= 4 else {
                    await MainActor.run {
                        log.error("Too few dates remaining after outlier exclusion")
                        dlBest = initial.best
                        dlEnsemble = initial.ensemble
                        dlSliders = initial.best
                    }
                    return
                }

                // Stage 3: refit with clean data
                let result = DoubleLogistic.ensembleFit(data: cleanData,
                    perturbation: p, slopePerturbation: sp,
                    minSeasonLength: minSL, maxSeasonLength: maxSL,
                    slopeSymmetry: Double(settings.slopeSymmetry),
                    bounds: dlBounds,
                    secondPass: settings.enableSecondPass)
                await MainActor.run {
                    dlBest = result.best
                    dlEnsemble = result.ensemble
                    dlSliders = result.best
                    let rmseStr = String(format: "%.4f", result.best.rmse)
                    if result.best.rmse > 0.15 {
                        log.warn("DL fit poor (excl. \(outlierIndices.count) outlier): RMSE=\(rmseStr) — try adjusting SOS slider or widening parameter bounds")
                    } else {
                        log.success("DL fit (excl. \(outlierIndices.count) outlier): RMSE=\(rmseStr), \(result.ensemble.count) viable of 50")
                    }
                }
            } else {
                await MainActor.run {
                    dlBest = initial.best
                    dlEnsemble = initial.ensemble
                    dlSliders = initial.best
                    let rmseStr = String(format: "%.4f", initial.best.rmse)
                    if initial.best.rmse > 0.15 {
                        log.warn("DL fit poor: RMSE=\(rmseStr) — try adjusting SOS slider or widening parameter bounds")
                    } else {
                        log.success("DL fit: RMSE=\(rmseStr), \(initial.ensemble.count) viable of 50, no outliers")
                    }
                }
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
            maxSeasonLength: Double(settings.maxSeasonLength),
            slopeSymmetry: Double(settings.slopeSymmetry),
            boundMnMin: settings.boundMnMin,
            boundMnMax: settings.boundMnMax,
            boundDeltaMin: settings.boundDeltaMin,
            boundDeltaMax: settings.boundDeltaMax,
            boundSosMin: settings.boundSosMin,
            boundSosMax: settings.boundSosMax,
            boundRspMin: settings.boundRspMin,
            boundRspMax: settings.boundRspMax,
            boundRauMin: settings.boundRauMin,
            boundRauMax: settings.boundRauMax,
            secondPass: settings.enableSecondPass,
            secondPassWeightMin: settings.secondPassWeightMin,
            secondPassWeightMax: settings.secondPassWeightMax
        )

        logDistributions(label: "Per-pixel DL fit", base: medianFit, p: settings.pixelPerturbation,
                         sp: settings.pixelSlopePerturbation, nRuns: settings.pixelEnsembleRuns,
                         minSL: Double(settings.minSeasonLength), maxSL: Double(settings.maxSeasonLength))

        let enforceAOI = settings.enforceAOI
        let coverageThreshold = settings.pixelCoverageThreshold
        pixelFitTask = Task.detached {
            let result = await PixelPhenologyFitter.fitAllPixels(
                frames: frames,
                medianParams: medianFit,
                settings: fitSettings,
                polygon: polygon,
                enforceAOI: enforceAOI,
                pixelCoverageThreshold: coverageThreshold,
                onProgress: { progress in
                    Task { @MainActor in
                        pixelFitProgress = progress
                    }
                }
            )

            guard !Task.isCancelled else {
                await MainActor.run {
                    isRunningPixelFit = false
                    log.info("Per-pixel fit cancelled")
                }
                return
            }

            await MainActor.run {
                pixelPhenologyBase = result
                pixelPhenology = result.reclassified(rmseThreshold: settings.pixelFitRMSEThreshold)
                isRunningPixelFit = false
                pixelFitTask = nil
                lastPixelFitSettingsHash = pixelFitSettingsHash
                let reclassified = pixelPhenology!
                log.success("Per-pixel fit: \(reclassified.goodCount) good, \(reclassified.poorCount) poor, \(reclassified.skippedCount) skipped in \(String(format: "%.1f", result.computeTimeSeconds))s")
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
            data.append(DoubleLogistic.DataPoint(doy: Double(frame.continuousDOY(referenceYear: referenceYear)), ndvi: Double(m)))
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        let dlBounds: (lo: [Double], hi: [Double]) = (
            [settings.boundMnMin, settings.boundDeltaMin, settings.boundSosMin, settings.boundRspMin, max(minSL, 10), settings.boundRauMin],
            [settings.boundMnMax, settings.boundDeltaMax, settings.boundSosMax, settings.boundRspMax, min(maxSL, 350), settings.boundRauMax]
        )
        Task.detached {
            let result = DoubleLogistic.ensembleFit(data: data,
                perturbation: p, slopePerturbation: sp,
                minSeasonLength: minSL, maxSeasonLength: maxSL,
                slopeSymmetry: Double(settings.slopeSymmetry),
                bounds: dlBounds)
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
        let refYr = referenceYear
        let data = processor.frames.filter { $0.validPixelCount > 0 }.map { f in
            DoubleLogistic.DataPoint(doy: Double(f.continuousDOY(referenceYear: refYr)), ndvi: Double(f.medianNDVI))
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        let dlBounds: (lo: [Double], hi: [Double]) = (
            [settings.boundMnMin, settings.boundDeltaMin, settings.boundSosMin, settings.boundRspMin, max(minSL, 10), settings.boundRauMin],
            [settings.boundMnMax, settings.boundDeltaMax, settings.boundSosMax, settings.boundRspMax, min(maxSL, 350), settings.boundRauMax]
        )
        Task.detached {
            let result = DoubleLogistic.ensembleFit(data: data,
                perturbation: p, slopePerturbation: sp,
                minSeasonLength: minSL, maxSeasonLength: maxSL,
                slopeSymmetry: Double(settings.slopeSymmetry),
                bounds: dlBounds)
            await MainActor.run {
                dlBest = result.best
                dlSliders = result.best
                dlEnsemble = result.ensemble
                log.success("Refit on original median: RMSE=\(String(format: "%.4f", result.best.rmse))")
            }
        }
    }

    private func runDLFitFrom(_ start: DLParams) {
        let refYr = referenceYear
        let data = processor.frames.filter { $0.validPixelCount > 0 }.map { f in
            DoubleLogistic.DataPoint(doy: Double(f.continuousDOY(referenceYear: refYr)), ndvi: Double(f.medianNDVI))
        }
        guard data.count >= 4 else { return }
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        let dlBounds: (lo: [Double], hi: [Double]) = (
            [settings.boundMnMin, settings.boundDeltaMin, settings.boundSosMin, settings.boundRspMin, max(minSL, 10), settings.boundRauMin],
            [settings.boundMnMax, settings.boundDeltaMax, settings.boundSosMax, settings.boundRspMax, min(maxSL, 350), settings.boundRauMax]
        )
        Task.detached {
            let fitted = DoubleLogistic.fit(data: data, initial: start,
                                           minSeasonLength: minSL, maxSeasonLength: maxSL,
                slopeSymmetry: Double(settings.slopeSymmetry),
                bounds: dlBounds)
            await MainActor.run {
                dlBest = fitted
                dlSliders = fitted
                // Re-run ensemble from this better starting point
                let result = DoubleLogistic.ensembleFit(data: data,
                    perturbation: p, slopePerturbation: sp,
                    minSeasonLength: minSL, maxSeasonLength: maxSL,
                    slopeSymmetry: Double(settings.slopeSymmetry),
                    bounds: dlBounds)
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

    private func prefetchSASToken() async {
        let pcSources = settings.sources.filter { $0.assetAuthType == .sasToken && $0.isEnabled }
        guard !pcSources.isEmpty else { return }
        let sas = SASTokenManager()
        for src in pcSources {
            do {
                let token = try await sas.getToken(for: src.collection)
                // Parse expiry from token
                var expiry = ""
                for param in token.components(separatedBy: "&") {
                    if param.hasPrefix("se=") {
                        expiry = param.dropFirst(3)
                            .removingPercentEncoding ?? String(param.dropFirst(3))
                    }
                }
                log.info("SAS token [\(src.shortName)]: expires \(expiry)")
            } catch {
                log.warn("SAS token [\(src.shortName)]: \(error.localizedDescription)")
            }
        }
    }

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

        // Check cellular — warn user with estimated size
        if networkMonitor.isCellular && !settings.allowCellularDownload {
            estimatedDownloadMB = estimateDownloadSize(geometry: geometry)
            pendingGeometry = geometry
            showCellularAlert = true
            return
        }

        launchFetch(geometry: geometry)
    }

    private func launchFetch(geometry: GeoJSONGeometry) {
        Task {
            await processor.fetch(
                geometry: geometry,
                startDate: settings.startDateString,
                endDate: settings.endDateString
            )
        }
    }

    /// Estimate download size in MB from AOI dimensions and date range.
    private func estimateDownloadSize(geometry: GeoJSONGeometry) -> Double {
        let dims = geometry.bboxMeters
        let pixelsW = max(1, dims.width / 10.0)
        let pixelsH = max(1, dims.height / 10.0)
        let pixelsPerBand = pixelsW * pixelsH
        let bytesPerBand = pixelsPerBand * 2 // UInt16

        let bandCount: Double = (settings.displayMode == .ndvi || settings.displayMode == .scl) ? 3 : 5
        let months = max(1, Calendar.current.dateComponents(
            [.month], from: settings.startDate, to: settings.endDate).month ?? 1)
        let estimatedScenes = Double(months) * 6 // S2 ~5-day revisit

        let headerBytes = 128_000.0
        let compressionRatio = 2.5
        let perScene = headerBytes + (bytesPerBand * bandCount / compressionRatio)
        return (perScene * estimatedScenes) / 1_000_000
    }

    private func startComparisonFetch() {
        stopPlayback()
        log.clear()
        processor.compareSourcesMode = true
        processor.comparisonPairs = []
        startFetch()
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
        // The S2 image chip is typically larger than the AOI bbox due to pixel
        // alignment and the buffer added in NDVIProcessor. Scale the bbox to
        // match the frame's aspect ratio so the basemap aligns with the imagery.
        let aoiLatSpan = bbox.maxLat - bbox.minLat
        let aoiLonSpan = bbox.maxLon - bbox.minLon
        let frameAspect = Double(first.width) / Double(first.height)  // W/H in pixels
        let centerLat = (bbox.minLat + bbox.maxLat) / 2
        let centerLon = (bbox.minLon + bbox.maxLon) / 2

        // Expand bbox to match frame aspect ratio (the chip is always larger)
        // The processor adds ~10% buffer on each side, so add ~25% total padding
        let adjustedLatSpan = max(aoiLatSpan, aoiLonSpan / frameAspect)
        let adjustedLonSpan = max(aoiLonSpan, aoiLatSpan * frameAspect)

        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
        let span = MKCoordinateSpan(latitudeDelta: adjustedLatSpan, longitudeDelta: adjustedLonSpan)
        let region = MKCoordinateRegion(center: center, span: span)

        let opts = MKMapSnapshotter.Options()
        opts.mapType = .satellite
        opts.region = region
        let targetW = CGFloat(first.width) * 8
        let targetH = CGFloat(first.height) * 8
        opts.size = CGSize(width: targetW, height: targetH)
        opts.scale = 1

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

    // MARK: - Zoom + Pan Helpers

    /// Convert a screen-space point to image pixel coordinates, accounting for zoom + pan.
    /// The image is rendered at `fitScale` px/pixel, then scaled by `zoom` from top-leading, then offset by `pan`.
    private func screenToPixel(_ screenPt: CGPoint, zoom: CGFloat, pan: CGSize, fitScale: CGFloat, inset: CGSize = .zero) -> (col: Int, row: Int) {
        let viewX = (screenPt.x - pan.width) / zoom - inset.width
        let viewY = (screenPt.y - pan.height) / zoom - inset.height
        return (col: Int(viewX / fitScale), row: Int(viewY / fitScale))
    }

    /// Finalize a drag selection, converting screen-space rectangle to pixel coordinates via zoom+pan transform.
    private func finalizeSelectionZoomed(frame: NDVIFrame, fitScale: CGFloat, zoom: CGFloat, pan: CGSize, inset: CGSize = .zero) {
        guard let s = selectionStart, let e = selectionEnd else { return }
        let (c0, r0) = screenToPixel(CGPoint(x: min(s.x, e.x), y: min(s.y, e.y)), zoom: zoom, pan: pan, fitScale: fitScale, inset: inset)
        let (c1, r1) = screenToPixel(CGPoint(x: max(s.x, e.x), y: max(s.y, e.y)), zoom: zoom, pan: pan, fitScale: fitScale, inset: inset)
        let minCol = max(0, c0), maxCol = min(frame.width - 1, c1)
        let minRow = max(0, r0), maxRow = min(frame.height - 1, r1)

        guard maxCol > minCol && maxRow > minRow else {
            log.warn("Selection too small — drag a larger rectangle")
            selectionStart = nil; selectionEnd = nil
            return
        }

        var validCount = 0
        for row in minRow...maxRow {
            for col in minCol...maxCol {
                if !frame.ndvi[row][col].isNaN { validCount += 1 }
            }
        }
        if validCount == 0 {
            log.warn("No valid pixels in selection (\(maxCol - minCol + 1)x\(maxRow - minRow + 1) px)")
            selectionStart = nil; selectionEnd = nil
            return
        }
        selectionItem = SelectionItem(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol)
        log.info("Selected \(maxCol - minCol + 1)x\(maxRow - minRow + 1) px, \(validCount) valid")
    }

    /// Clamp pan offset so the image stays within the visible area.
    private func clampPan(_ offset: CGSize, zoom: CGFloat, geoSize: CGSize, imageH: CGFloat) -> CGSize {
        let maxPanX = max(0, geoSize.width * (zoom - 1))
        let maxPanY = max(0, imageH * zoom - geoSize.height)  // allow vertical pan if image taller than geo
        return CGSize(
            width: min(0, max(-maxPanX, offset.width)),
            height: min(0, max(-maxPanY, offset.height))
        )
    }

    @MainActor
    private func copyCurrentFrame(frame: NDVIFrame) {
        let currentPhenoMap: [[Float]]? = phenologyDisplayParam.flatMap { p in
            if p.isFraction { return fractionMap(for: frame, param: p) }
            return pixelPhenology?.parameterMap(p)
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
    enum PreviewMode: String, CaseIterable {
        case masked = "Masked"
        case raw = "Raw"
        case scl = "SCL"
    }
    @State private var previewMode: PreviewMode = .masked
    @State private var searchTrigger = 0
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
                    HStack(spacing: 8) {
                        if showingImages {
                            Menu {
                                ForEach(PreviewMode.allCases, id: \.self) { mode in
                                    Button {
                                        withAnimation { previewMode = mode }
                                    } label: {
                                        if previewMode == mode {
                                            Label(mode.rawValue, systemImage: "checkmark")
                                        } else {
                                            Text(mode.rawValue)
                                        }
                                    }
                                }
                            } label: {
                                Label(previewMode.rawValue,
                                      systemImage: previewMode == .scl ? "square.grid.3x3" :
                                                   previewMode == .raw ? "eye" : "eye.slash")
                            }
                            .buttonStyle(.glass)
                            .tint(previewMode == .masked ? .secondary : .orange)
                        } else {
                            Button {
                                searchTrigger += 1
                            } label: {
                                Label("Search", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.glass)
                        }
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
    }

    // MARK: - Image Grid

    private var imageGrid: some View {
        ScrollView {
            VStack(spacing: 8) {
                if previewMode == .scl {
                    SCLLegend()
                        .padding(.horizontal, 8)
                } else if settings.displayMode == .ndvi {
                    NDVIColorBar()
                        .padding(.horizontal, 8)
                } else if settings.displayMode == .scl {
                    SCLLegend()
                        .padding(.horizontal, 8)
                }
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(processor.frames.sorted(by: { $0.date < $1.date })) { frame in
                        VStack(spacing: 2) {
                            ZStack(alignment: .topLeading) {
                                NDVIMapView(frame: frame, scale: 2, showPolygon: true,
                                            showColorBar: false,
                                            displayMode: previewMode == .scl ? .scl : settings.displayMode,
                                            cloudMask: (previewMode != .masked || frame.validPixelCount == 0) ? false : settings.cloudMask,
                                            ndviThreshold: previewMode != .masked ? -1 : settings.ndviThreshold,
                                            sclValidClasses: previewMode != .masked ? Set(0...11) : settings.sclValidClasses,
                                            showSCLBoundaries: previewMode != .masked ? false : settings.showSCLBoundaries,
                                            enforceAOI: previewMode != .masked ? false : settings.enforceAOI,
                                            showMaskedClassColors: (previewMode != .masked || frame.validPixelCount == 0) ? true : settings.showMaskedClassColors)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                // Source label
                                if let sid = frame.sourceID {
                                    Text(sid.shortLabel)
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 2)
                                        .padding(.vertical, 1)
                                        .background(Color.black.opacity(0.5))
                                        .cornerRadius(2)
                                        .padding(2)
                                }
                                if frame.validPixelCount == 0 {
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Spacer()
                                            Text("NO DATA")
                                                .font(.system(size: 6, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 2)
                                                .padding(.vertical, 1)
                                                .background(Color.red.opacity(0.8))
                                                .cornerRadius(2)
                                                .padding(2)
                                        }
                                    }
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.red, lineWidth: 1.5)
                                }
                            }
                            Text(frame.dateString)
                                .font(.system(size: 8))
                                .foregroundStyle(frame.validPixelCount == 0 ? .red : .secondary)
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
        LogTextView(entries: log.entries, searchTrigger: searchTrigger)
    }
}

// MARK: - Log Text View (UIKit-backed, guaranteed scrollable)

struct LogTextView: UIViewRepresentable {
    let entries: [ActivityLog.LogEntry]
    var searchTrigger: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        weak var textView: UITextView?
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.showsVerticalScrollIndicator = true
        tv.alwaysBounceVertical = true
        tv.isFindInteractionEnabled = true
        context.coordinator.textView = tv
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

        // Open find navigator when search button tapped
        if searchTrigger > 0 {
            DispatchQueue.main.async {
                tv.findInteraction?.presentFindNavigator(showingReplace: false)
            }
        }
    }
}
