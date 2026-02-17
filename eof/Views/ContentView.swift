import SwiftUI
import Charts
import MapKit

/// Darker brown for soil fraction lines (distinct from orange UI elements and yellow NPV).
private let soilBrown = Color(red: 0.55, green: 0.3, blue: 0.1)

struct ContentView: View {
    @State private var processor = NDVIProcessor()
    @State private var settings = AppSettings.shared
    @State private var currentFrameIndex = 0
    @State private var isPlaying = false
    @State private var timer: Timer?
    // settings.playbackSpeed now in settings
    @State private var showingLog = false
    @State private var showingSettings = false
    @State private var showingAOI = false
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
    // Per-fraction DL fits (auto-fitted after unmixing)
    @State private var fractionDLFits: [PhenologyParameter: DLParams] = [:]
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
    // Collapsible panels
    @State private var showMovie = true
    @State private var showChart = true
    @State private var showColorbar = true
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
    @State private var fetchTask: Task<Void, Never>?
    @State private var pixelFitTask: Task<Void, Never>?
    @State private var unmixTask: Task<Void, Never>?
    // Spectral unmixing
    @State private var frameUnmixResults: [UUID: FrameUnmixResult] = [:]
    @State private var isRunningUnmix = false
    @State private var unmixProgress: Double = 0
    @State private var lastUnmixHash: Int = 0
    // showColorBar removed — always show
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
                .padding(.top, 0)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4) {
                        if processor.status == .searching || processor.status == .processing || isRunningUnmix || isRunningPixelFit {
                            Image(systemName: "leaf.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(isRunningUnmix ? .purple : isRunningPixelFit ? .orange : statusTitleColor)
                                .rotationEffect(.degrees(leafRotation))
                                .onAppear {
                                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                                        leafRotation = 360
                                    }
                                }
                                .onDisappear { leafRotation = 0 }
                        }
                        Text("EOF")
                            .font(.headline.bold())
                            .foregroundStyle(isRunningUnmix ? .purple : isRunningPixelFit ? .orange : statusTitleColor)
                            .opacity(statusTitleOpacity)
                            .animation(statusTitleAnimation, value: processor.status == .idle || processor.status == .done)
                    }
                    .onTapGesture {
                        if processor.status == .error || processor.errorMessage != nil {
                            showingLog = true
                        }
                    }
                }
            }
            .onAppear {
                if processor.status == .idle && processor.frames.isEmpty {
                    // Show AOI tool on startup for user to confirm area
                    showingAOI = true
                }
            }
            .task { await prefetchSASToken() }
            .onChange(of: processor.status) {
                // Pulse animation for status indicator
                if processor.status == .searching || processor.status == .processing || processor.status == .error {
                    statusPulse = true
                } else {
                    statusPulse = false
                }
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
                    // Run unmixing if not already done for these frames
                    let currentUnmixHash = unmixConditionsHash()
                    if frameUnmixResults.isEmpty || lastUnmixHash != currentUnmixHash {
                        runUnmixing()
                    } else {
                        log.success("fVeg/fNPV/fSoil already computed (\(frameUnmixResults.count) frames) — press Unmix\u{2713} to force")
                    }
                    // Always run DL fit immediately (uses NDVI as fallback if FVC pending)
                    // Unmixing completion will refit to FVC when ready
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
            .onChange(of: settings.enableSpectralUnmixing) {
                if settings.enableSpectralUnmixing && frameUnmixResults.isEmpty && !processor.frames.isEmpty {
                    runUnmixing()
                }
            }
            .onChange(of: settings.vegetationIndex) {
                guard !processor.frames.isEmpty else { return }
                // Recompute VI values from raw bands when switching NDVI↔DVI
                processor.recomputeVI()
                if settings.vegetationIndex == .fvc && frameUnmixResults.isEmpty {
                    runUnmixing() // Will refit DL when unmix completes
                } else if dlBest != nil {
                    runDLFit()
                }
            }
            .onChange(of: settings.displayMode) {
                if !processor.frames.isEmpty {
                    Task {
                        await processor.loadMissingBands(for: settings.displayMode)
                    }
                }
            }
            .onChange(of: phenologyDisplayParam) {
                // Refit DL when Live menu switches to/from a fraction display
                if dlBest != nil && !frameUnmixResults.isEmpty {
                    runDLFit()
                }
            }
            .onChange(of: settings.aoiGeneration) {
                resetForNewAOI()
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
                    HStack(spacing: 8) {
                        Button {
                            showingAOI = true
                        } label: {
                            Label("Edit", systemImage: "map")
                        }
                        .buttonStyle(.glass)
                        Button {
                            showingLog = true
                        } label: {
                            Label("Log", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .sheet(isPresented: $showingAOI, onDismiss: onAOIDismiss) {
                AOIView(isPresented: $showingAOI)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingLog) {
                LogView(isPresented: $showingLog, processor: processor)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
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
                    medianFit: dlBest,
                    unmixResults: frameUnmixResults,
                    useFVC: settings.vegetationIndex == .fvc
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
            Text("S2 \(settings.displayMode.rawValue) | \(settings.startDateDisplay)–\(settings.endDateDisplay) | \(settings.enabledSources.map { $0.shortName }.joined(separator: "+"))")
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

    @State private var statusPulse = false
    @State private var leafRotation: Double = 0

    /// Estimated total data size across all loaded frames.
    private var totalDataSizeString: String {
        guard let f = processor.frames.first else { return "" }
        let px = f.width * f.height
        // Each frame: ndvi(4B) + red(2B) + nir(2B) + optional green(2B) + blue(2B) + scl(2B)
        var bytesPerPixel = 8 // ndvi + red + nir
        if f.greenBand != nil { bytesPerPixel += 2 }
        if f.blueBand != nil { bytesPerPixel += 2 }
        if f.sclBand != nil { bytesPerPixel += 2 }
        let totalBytes = px * bytesPerPixel * processor.frames.count
        let mb = Double(totalBytes) / 1_000_000
        if mb < 1 { return "<1 MB" }
        return "\(Int(mb)) MB"
    }

    private var statusTitleColor: Color {
        switch processor.status {
        case .idle, .done:
            return .green
        case .searching:
            return .yellow
        case .processing:
            return .orange
        case .error:
            return .red
        }
    }

    private var statusTitleOpacity: Double {
        switch processor.status {
        case .idle, .done:
            return 1.0
        case .searching, .processing:
            return statusPulse ? 0.3 : 1.0
        case .error:
            return statusPulse ? 0.2 : 1.0
        }
    }

    private var statusTitleAnimation: Animation? {
        switch processor.status {
        case .idle, .done:
            return nil
        case .searching, .processing:
            return .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
        case .error:
            return .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
        }
    }

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
                    Button(settings.vegetationIndex == .fvc && !frameUnmixResults.isEmpty ? "Fit FVC" : "Fit") {
                        runDLFit()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                    Button(isRunningUnmix ? "Stop" : (frameUnmixResults.isEmpty ? "Unmix" : "Unmix \u{2713}")) {
                        if isRunningUnmix {
                            unmixTask?.cancel()
                            unmixTask = nil
                            isRunningUnmix = false
                            startPlayback()
                        } else if !frameUnmixResults.isEmpty {
                            log.info("Unmix: forcing re-run (\(frameUnmixResults.count) frames already done)")
                            lastUnmixHash = 0  // force
                            runUnmixing()
                        } else {
                            runUnmixing()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(isRunningUnmix ? .red : (frameUnmixResults.isEmpty ? .purple : .purple.opacity(0.5)))
                    if isRunningUnmix {
                        ProgressView(value: unmixProgress)
                            .frame(width: 60)
                            .tint(.purple)
                    }
                    Button(isRunningPixelFit ? "Stop" : "Pheno") {
                        if isRunningPixelFit {
                            pixelFitTask?.cancel()
                            pixelFitTask = nil
                            isRunningPixelFit = false
                            startPlayback()
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
                    liveMenu
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
                        Text("\(frame.width)\u{00D7}\(frame.height)")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(totalDataSizeString)
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showMovie.toggle() }
                        } label: {
                            Image(systemName: showMovie ? "chevron.up" : "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let currentPhenoMap: [[Float]]? = phenologyDisplayParam.flatMap { param in
                        if param.isFraction {
                            return fractionMap(for: frame, param: param)
                        }
                        return pixelPhenology?.parameterMap(param)
                    }
                    let currentRejectionMap: [[Float]]? = showBadData ? pixelPhenology?.rejectionReasonMap() : nil

                    if showMovie {
                    GeometryReader { geo in
                        let widthScale = geo.size.width / CGFloat(frame.width)
                        let heightScale = geo.size.height / CGFloat(frame.height)
                        let fitScale = min(widthScale, heightScale)  // aspect-fit, fill screen
                        let maxZoom = max(8.0, fitScale * 4)  // allow 4x beyond initial fit
                        let currentZoom = min(maxZoom, max(1.0, zoomScale * gestureZoom))
                        let imageH = CGFloat(frame.height) * fitScale
                        let imageW = CGFloat(frame.width) * fitScale
                        let xInset = max(0, (geo.size.width - imageW) / 2)
                        let yInset = max(0, (geo.size.height - imageH) / 2)

                        ZStack(alignment: .topLeading) {
                            // Image layer (transformed, centered)
                            NDVIMapView(frame: frame, scale: fitScale, showPolygon: true, showColorBar: false,
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
                                        .onChanged { _ in
                                            if isPlaying { stopPlayback() }
                                        }
                                        .onEnded { value in
                                            let newZoom = min(maxZoom, max(1.0, zoomScale * value.magnification))
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
                                                // Pan when zoomed — pause to save resources
                                                if isPlaying { stopPlayback() }
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
                                    HStack(spacing: 3) {
                                        Image(systemName: isSelectMode ? "rectangle.dashed" : "selection.pin.in.out")
                                            .font(.caption)
                                        if isSelectMode {
                                            Text("Area")
                                                .font(.system(size: 9, weight: .semibold))
                                        }
                                    }
                                    .padding(.horizontal, isSelectMode ? 8 : 6)
                                    .padding(.vertical, 6)
                                    .background(isSelectMode ? AnyShapeStyle(.yellow.opacity(0.4)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                                    .overlay(isSelectMode ? Capsule().stroke(.yellow, lineWidth: 1.5) : nil)
                                }
                            }
                            .padding(6)
                            .opacity(0.7)
                        }
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 4) {
                                // Label showing what the image is currently displaying (below control buttons)
                                Text(imageDisplayLabel)
                                    .font(.system(size: 9).bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.5), in: Capsule())
                                if isSelectMode {
                                    Label("Drag to select area", systemImage: "rectangle.dashed")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.yellow.opacity(0.85), in: Capsule())
                                }
                            }
                            .padding(.leading, 6)
                            .padding(.top, 38)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if zoomScale > 1.05 || gestureZoom != 1.0 {
                                let z = min(maxZoom, max(1.0, zoomScale * gestureZoom))
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
                        .overlay(alignment: .bottomLeading) {
                            // Scale bar — S2 pixels are 10m
                            let metersPerScreenPt = 10.0 / (fitScale * currentZoom)
                            let scaleBarView = ScaleBarView(metersPerPoint: metersPerScreenPt)
                            scaleBarView
                                .padding(6)
                                .opacity(0.85)
                        }
                        .onAppear { dragStartIndex = currentFrameIndex }
                        .onChange(of: currentFrameIndex) { dragStartIndex = currentFrameIndex }
                    }
                    .frame(height: min(
                        CGFloat(frame.height) * (UIScreen.main.bounds.width / CGFloat(frame.width)),
                        UIScreen.main.bounds.height * 0.5  // cap at 50% screen height
                    ))
                    .overlay(alignment: .bottom) {
                        // Static colorbar (not affected by zoom/pan) — tap to toggle
                        if showColorbar && !showBadData {
                            if let param = phenologyDisplayParam, param.isFraction {
                                FractionColorBar(label: param.rawValue)
                                    .padding(.horizontal, 4)
                                    .padding(.bottom, 2)
                                    .onTapGesture { showColorbar = false }
                            } else if phenologyDisplayParam == nil {
                                switch settings.displayMode {
                                case .ndvi:
                                    NDVIColorBarCompact()
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 2)
                                        .onTapGesture { showColorbar = false }
                                case .bandRed, .bandNIR, .bandGreen, .bandBlue:
                                    BandColorBar(label: chartLabel)
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 2)
                                        .onTapGesture { showColorbar = false }
                                default:
                                    EmptyView()
                                }
                            }
                        } else if !showColorbar {
                            Button {
                                showColorbar = true
                            } label: {
                                Image(systemName: "paintpalette")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(6)
                            }
                        }
                    }

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
                                    .foregroundStyle(.yellow)
                            }
                            if let fs = medianFraction(for: frame, param: .fsoil) {
                                Text("fSoil \(String(format: "%.2f", fs))")
                                    .foregroundStyle(soilBrown)
                            }
                        }
                        .font(.system(size: 9).monospacedDigit())
                    }
                    } // end if showMovie
                }
            }

            // NDVI time series chart — synced with animation
            if processor.frames.count > 1 {
                if showChart {
                    ndviChart
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showChart = true }
                    } label: {
                        Label("Time Series", systemImage: "chart.xyaxis.line")
                            .font(.caption)
                    }
                }
                spectralChart
                phenologySection
            }

            // Frame counter + compact SCL class key
            HStack {
                Text("\(currentFrameIndex + 1)/\(processor.frames.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    // Cycle: 1x → 2x → 4x → 0.5x → 1x
                    switch settings.playbackSpeed {
                    case ..<1.5: settings.playbackSpeed = 2.0
                    case ..<3.0: settings.playbackSpeed = 4.0
                    case ..<5.0: settings.playbackSpeed = 0.5
                    default: settings.playbackSpeed = 1.0
                    }
                    // Restart timer at new speed if playing
                    if isPlaying { startPlayback() }
                } label: {
                    Text("\(String(format: settings.playbackSpeed == 0.5 ? "%.1f" : "%.0f", settings.playbackSpeed))x")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if settings.showSCLBoundaries {
                compactSCLKey
            }
        }
    }

    // MARK: - NDVI Time Series Chart

    /// Whether FVC is requested but unmixing hasn't completed yet — show NDVI as fallback.
    private var fvcPending: Bool {
        settings.vegetationIndex == .fvc && frameUnmixResults.isEmpty
    }

    private var viLabel: String {
        if let target = chartFractionTarget {
            switch target {
            case .fveg: return "fVeg"
            case .fnpv: return "fNPV"
            case .fsoil: return "fSoil"
            default: return target.rawValue
            }
        }
        // When FVC is requested but unmix not ready, show NDVI as fallback
        if fvcPending { return "NDVI" }
        return settings.vegetationIndex.rawValue
    }

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

    /// Chart y-axis label — always shows selected VI or fraction, never raw reflectance.
    private var chartLabel: String {
        if isInspectingPixel {
            let w = settings.pixelInspectWindow
            let label = "Pixel (\(inspectedPixelCol), \(inspectedPixelRow))"
            return w > 1 ? "\(label) [\(w)\u{00D7}\(w)]" : label
        }
        if let target = chartFractionTarget { return "Median \(target.rawValue)" }
        return "Median \(viLabel)"
    }

    /// Which fraction the chart is targeting (nil = VI or band reflectance).
    /// Follows: Live menu fraction selection > vegetationIndex=FVC > nil.
    private var chartFractionTarget: PhenologyParameter? {
        if let param = phenologyDisplayParam, param.isFraction, param != .unmixRMSE, !frameUnmixResults.isEmpty {
            return param
        }
        if settings.vegetationIndex == .fvc && !frameUnmixResults.isEmpty {
            return .fveg
        }
        return nil
    }

    /// Whether the chart should display fVeg values (when VI is FVC and unmix results exist).
    private var chartShowsFveg: Bool { chartFractionTarget != nil }

    /// Dynamic y-axis domain — always VI or fraction range (chart never shows raw reflectance).
    private var chartYDomain: ClosedRange<Double> {
        chartShowsFveg ? 0.0...1.05 : -0.25...1.05
    }

    /// Dynamic y-axis tick values.
    private var chartYAxisValues: [Double] {
        chartShowsFveg ? [0, 0.25, 0.5, 0.75, 1.0] : [-0.2, 0, 0.25, 0.5, 0.75, 1.0]
    }

    /// Get the chart y-value for a frame — always uses selected VI or fraction, never raw reflectance.
    private func chartValue(for frame: NDVIFrame) -> Double {
        if let target = chartFractionTarget, let fv = medianFraction(for: frame, param: target) {
            return fv
        }
        // Always chart the selected vegetation index regardless of display mode
        // (band display modes only affect imagery, not the median plot)
        return Double(frame.medianNDVI)
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
                guard row < frame.ndvi.count, col < frame.ndvi[row].count else { continue }
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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showChart = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
            }

            let sorted = processor.frames.sorted(by: { $0.date < $1.date })
            let validSorted = sorted.filter { $0.validPixelCount > 0 }

            // Pre-compute chart values once (avoid re-calling per ForEach item)
            let chartVals = Dictionary(uniqueKeysWithValues: validSorted.map { ($0.id, chartValue(for: $0)) })
            let pixData: [PixelDataPoint] = isInspectingPixel ? pixelNDVIData(sorted: sorted) : []
            let fvegPixData: [PixelDataPoint] = isInspectingPixel && !frameUnmixResults.isEmpty ? pixelFvegData(sorted: sorted) : []
            // Pre-compute DL curves once
            let dlCurve = dlCurvePoints(sorted: sorted)
            let pixelCurve = pixelDLCurvePoints(sorted: sorted)
            let indicatorPts = phenologyIndicatorLines(sorted: sorted)
            // Pre-compute fraction medians once (avoid 6 x N median sorts per render)
            let fracVeg: [(id: UUID, date: Date, val: Double)] = !frameUnmixResults.isEmpty
                ? validSorted.compactMap { f in medianFraction(for: f, param: .fveg).map { (f.id, f.date, $0) } } : []
            let fracNPV: [(id: UUID, date: Date, val: Double)] = !frameUnmixResults.isEmpty
                ? validSorted.compactMap { f in medianFraction(for: f, param: .fnpv).map { (f.id, f.date, $0) } } : []
            let fracSoil: [(id: UUID, date: Date, val: Double)] = !frameUnmixResults.isEmpty
                ? validSorted.compactMap { f in medianFraction(for: f, param: .fsoil).map { (f.id, f.date, $0) } } : []

            Chart {
                // NDVI line (dimmed when inspecting pixel)
                ForEach(validSorted) { frame in
                    LineMark(
                        x: .value("Date", frame.date),
                        y: .value(viLabel, chartVals[frame.id] ?? 0),
                        series: .value("Series", viLabel)
                    )
                    .foregroundStyle(.green.opacity(isInspectingPixel ? 0.15 : 0.6))
                    .lineStyle(StrokeStyle(lineWidth: isInspectingPixel ? 1 : 1.5,
                                           dash: [4, 3]))
                }

                // Per-pixel time series (when inspecting)
                if isInspectingPixel {
                    if settings.vegetationIndex == .fvc && !frameUnmixResults.isEmpty {
                        ForEach(fvegPixData) { pt in
                            LineMark(
                                x: .value("Date", pt.date),
                                y: .value(viLabel, pt.ndvi),
                                series: .value("Series", "PixelFveg")
                            )
                            .foregroundStyle(.green.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    } else {
                        ForEach(pixData) { pt in
                            LineMark(
                                x: .value("Date", pt.date),
                                y: .value(viLabel, pt.ndvi),
                                series: .value("Series", "Pixel")
                            )
                            .foregroundStyle(.orange.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        if !fvegPixData.isEmpty {
                            ForEach(fvegPixData) { pt in
                                LineMark(
                                    x: .value("Date", pt.date),
                                    y: .value(viLabel, pt.ndvi),
                                    series: .value("Series", "PixelFveg")
                                )
                                .foregroundStyle(.green.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                            }
                        }
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
                        y: .value(viLabel, chartVals[frame.id] ?? 0)
                    )
                    .foregroundStyle(.green.opacity(isInspectingPixel ? 0.15 : 1.0))
                    .symbolSize(isInspectingPixel ? 8 : 15)
                }

                // Per-pixel NDVI dots
                if isInspectingPixel {
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

                // Double logistic curves (pre-computed)
                ForEach(dlCurve, id: \.id) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value(viLabel, pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(pt.style)
                }

                // Pixel DL fit curve (pre-computed)
                ForEach(pixelCurve, id: \.id) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value(viLabel, pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(pt.style)
                }

                // Phenology indicator lines (pre-computed)
                ForEach(indicatorPts, id: \.id) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value(viLabel, pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }

                // Fraction time series (pre-computed)
                if !fracVeg.isEmpty || !fracNPV.isEmpty || !fracSoil.isEmpty {
                    if settings.vegetationIndex != .fvc {
                        ForEach(fracVeg, id: \.id) { pt in
                            LineMark(x: .value("Date", pt.date), y: .value(viLabel, pt.val), series: .value("Series", "fVeg"))
                                .foregroundStyle(.green.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                        }
                    }
                    ForEach(fracNPV, id: \.id) { pt in
                        LineMark(x: .value("Date", pt.date), y: .value(viLabel, pt.val), series: .value("Series", "fNPV"))
                            .foregroundStyle(.yellow.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    }
                    ForEach(fracSoil, id: \.id) { pt in
                        LineMark(x: .value("Date", pt.date), y: .value(viLabel, pt.val), series: .value("Series", "fSoil"))
                            .foregroundStyle(soilBrown.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    }
                    // Fraction data point dots
                    ForEach(fracVeg, id: \.id) { pt in
                        PointMark(x: .value("Date", pt.date), y: .value(viLabel, pt.val))
                            .foregroundStyle(.green.opacity(0.7)).symbolSize(12)
                    }
                    ForEach(fracNPV, id: \.id) { pt in
                        PointMark(x: .value("Date", pt.date), y: .value(viLabel, pt.val))
                            .foregroundStyle(.yellow.opacity(0.7)).symbolSize(12)
                    }
                    ForEach(fracSoil, id: \.id) { pt in
                        PointMark(x: .value("Date", pt.date), y: .value(viLabel, pt.val))
                            .foregroundStyle(soilBrown.opacity(0.7)).symbolSize(12)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: chartYAxisValues)
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
            .chartYScale(domain: chartYDomain)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
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
                   inspectedPixelRow >= 0, inspectedPixelCol >= 0,
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
                                .foregroundStyle(.yellow)
                            Text("fSoil \(String(format: "%.2f", fs))")
                                .foregroundStyle(soilBrown)
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
    /// Hash of conditions that affect unmixing — frame IDs + enforceAOI setting.
    private func unmixConditionsHash() -> Int {
        var hasher = Hasher()
        for f in processor.frames { hasher.combine(f.id) }
        hasher.combine(settings.enforceAOI)
        return hasher.finalize()
    }

    private func runUnmixing() {
        isRunningUnmix = true
        unmixProgress = 0
        stopPlayback()
        // Check if we need to download green/blue bands first
        let needsBands = processor.frames.contains { $0.greenBand == nil || $0.blueBand == nil }
        if needsBands {
            log.info("Downloading green/blue bands for unmixing...")
        }
        unmixTask = Task {
            if needsBands {
                await processor.loadMissingBands(for: .rcc)  // RCC loads green + blue
            }
            guard !Task.isCancelled else { isRunningUnmix = false; return }
            let frames = processor.frames
            log.info("Unmixing \(frames.count) frames (\(frames.first?.greenBand != nil ? "4" : "2") bands)...")
            // Capture frame data for background processing (with AOI mask from ndvi)
            let enforceAOI = settings.enforceAOI
            struct FrameData: Sendable {
                let id: UUID
                let redBand: [[UInt16]]
                let nirBand: [[UInt16]]
                let greenBand: [[UInt16]]?
                let blueBand: [[UInt16]]?
                let dnOffset: Float
                let width: Int
                let height: Int
                let validMask: [[Bool]]  // true = inside AOI and valid
            }
            let frameData = frames.map { f in
                let mask: [[Bool]] = enforceAOI
                    ? f.ndvi.map { row in row.map { !$0.isNaN } }
                    : [[Bool]](repeating: [Bool](repeating: true, count: f.width), count: f.height)
                return FrameData(id: f.id, redBand: f.redBand, nirBand: f.nirBand,
                          greenBand: f.greenBand, blueBand: f.blueBand,
                          dnOffset: f.dnOffset, width: f.width, height: f.height,
                          validMask: mask)
            }
            let results = await Task.detached(priority: .background) { () -> [UUID: FrameUnmixResult] in
                var results = [UUID: FrameUnmixResult]()
                let total = Double(frameData.count)
                for (i, fd) in frameData.enumerated() {
                    if Task.isCancelled { break }
                    var bands = [[[UInt16]]]()
                    var bandInfo = [(band: String, nm: Double)]()
                    bands.append(fd.redBand)
                    bandInfo.append(("B04", 665))
                    bands.append(fd.nirBand)
                    bandInfo.append(("B08", 842))
                    if let green = fd.greenBand {
                        bands.append(green)
                        bandInfo.append(("B03", 560))
                    }
                    if let blue = fd.blueBand {
                        bands.append(blue)
                        bandInfo.append(("B02", 490))
                    }
                    guard bands.count >= 3 else { continue }
                    let result = SpectralUnmixing.unmixFrame(
                        bands: bands, bandInfo: bandInfo,
                        dnOffset: fd.dnOffset,
                        width: fd.width, height: fd.height,
                        validMask: fd.validMask
                    )
                    results[fd.id] = result
                    let progress = Double(i + 1) / total
                    await MainActor.run { unmixProgress = progress }
                }
                return results
            }.value
            guard !Task.isCancelled else {
                isRunningUnmix = false
                log.info("Unmixing cancelled")
                return
            }
            frameUnmixResults = results
            lastUnmixHash = unmixConditionsHash()
            isRunningUnmix = false
            unmixTask = nil
            log.success("Unmixing done: \(results.count) frames, fVeg/fNPV/fSoil/RMSE maps available in Live menu")
            // Auto-fit DL to all fraction time series
            fitAllFractions()
            // If FVC was pending, refit the median DL curve to FVC now
            if settings.vegetationIndex == .fvc && processor.frames.count >= 4 {
                log.info("FVC ready — switching chart from NDVI to FVC")
                runDLFit()
            }
            if !isRunningPixelFit { startPlayback() }
        }
    }

    /// Fit DL curves to FVC, NPV, and Soil median time series after unmixing.
    /// For FVC: try fixed (mn=0,mx=1) and free magnitude, pick better.
    /// For NPV/Soil: try free magnitude DL (allows inverted curves).
    private func fitAllFractions() {
        let refYr = referenceYear
        let fracs: [PhenologyParameter] = [.fveg, .fnpv, .fsoil]
        let minSL = Double(settings.minSeasonLength)
        let maxSL = Double(settings.maxSeasonLength)
        let p = settings.pixelPerturbation
        let sp = settings.pixelSlopePerturbation
        let dlBounds: (lo: [Double], hi: [Double]) = (
            [settings.boundMnMin, settings.boundDeltaMin, settings.boundSosMin, settings.boundRspMin, max(minSL, 10), settings.boundRauMin],
            [settings.boundMnMax, settings.boundDeltaMax, settings.boundSosMax, settings.boundRspMax, min(maxSL, 350), settings.boundRauMax]
        )

        // Build data arrays for each fraction
        var fracData: [PhenologyParameter: [DoubleLogistic.DataPoint]] = [:]
        for param in fracs {
            let data = processor.frames.filter { $0.validPixelCount > 0 }.compactMap { f -> DoubleLogistic.DataPoint? in
                guard let val = medianFraction(for: f, param: param) else { return nil }
                return DoubleLogistic.DataPoint(doy: Double(f.continuousDOY(referenceYear: refYr)), ndvi: val)
            }
            if data.count >= 4 { fracData[param] = data }
        }

        guard !fracData.isEmpty else { return }
        log.info("Fitting DL to fraction time series: \(fracData.keys.map(\.rawValue).joined(separator: ", "))")

        let fsoilShape = settings.fsoilFitShape
        let fnpvShape = settings.fnpvFitShape
        let coupling = settings.fractionSOSCoupling
        let secondPass = settings.enableSecondPass

        Task.detached(priority: .utility) {
            var fits: [PhenologyParameter: DLParams] = [:]

            // Fit fVeg first so SOS/EOS are available as reference
            let fitOrder: [PhenologyParameter] = [.fveg, .fsoil, .fnpv]
            for param in fitOrder {
                guard let data = fracData[param] else { continue }

                let shape: AppSettings.FractionFitShape
                let isInverted: Bool
                switch param {
                case .fsoil:
                    shape = fsoilShape
                    isInverted = true
                case .fnpv:
                    shape = fnpvShape
                    isInverted = true
                default:
                    shape = .doubleLogistic
                    isInverted = false
                }

                let refSOS = fits[.fveg]?.sos
                let refEOS = fits[.fveg]?.eos

                let best = DoubleLogistic.ensembleFitConstrained(
                    data: data, shape: shape,
                    referenceSOS: refSOS, referenceEOS: refEOS,
                    sosCoupling: param == .fveg ? 0 : coupling,
                    nRuns: 30, perturbation: p, slopePerturbation: sp,
                    minSeasonLength: minSL, maxSeasonLength: maxSL,
                    slopeSymmetry: Double(settings.slopeSymmetry),
                    bounds: dlBounds, secondPass: secondPass,
                    invertWeights: isInverted
                )
                fits[param] = best

                await MainActor.run {
                    let rmseStr = String(format: "%.4f", best.rmse)
                    let shapeStr = shape.rawValue
                    if best.rmse > 0.15 {
                        log.warn("  \(param.rawValue) DL [\(shapeStr)]: RMSE=\(rmseStr) — poor fit")
                    } else {
                        log.success("  \(param.rawValue) DL [\(shapeStr)]: RMSE=\(rmseStr)")
                    }
                }
            }

            await MainActor.run {
                fractionDLFits = fits
                // If currently viewing FVC, use its fit as dlBest
                if let fvcFit = fits[.fveg] {
                    dlBest = fvcFit
                    dlEnsemble = []
                    dlSliders = fvcFit
                }
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
            guard let b = band, row >= 0, col >= 0, row < b.count, col < b[row].count else { return nil }
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
                        if let fv = medianFraction(for: current, param: .fveg),
                           let fn = medianFraction(for: current, param: .fnpv),
                           let fs = medianFraction(for: current, param: .fsoil) {
                            Text("GV:\(String(format: "%.0f", fv*100))% NPV:\(String(format: "%.0f", fn*100))% Soil:\(String(format: "%.0f", fs*100))%")
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("\(sorted.count) dates")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Button {
                            showSpectralChart = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
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
                                              lo: s[0], hi: s[s.count - 1]))
                pts.append(SpectralPt(id: "med_\(bw.band)", nm: bw.nm, refl: median,
                                      series: "Median", band: bw.band))
            }
        }

        // Current frame
        for v in currentVals {
            pts.append(SpectralPt(id: "cur_\(v.band)", nm: v.nm, refl: v.refl,
                                  series: "Current", band: v.band))
        }

        // Envelope + median provide all the context; no Peak/Min lines needed

        // Predicted spectrum and endmember spectra from unmixing
        var hasUnmix = false
        if let unmixResult = frameUnmixResults[current.id] {
            let fracs: UnmixResult?
            if usePixel, inspectedPixelRow >= 0, inspectedPixelCol >= 0,
               inspectedPixelRow < unmixResult.height, inspectedPixelCol < unmixResult.width {
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
            hasUnmix = true
            let endmembers = EndmemberLibrary.defaults

            if let f = fracs {
                let fractionValues: [Float] = [f.fveg, f.fnpv, f.fsoil]
                let seriesNames = ["GV scaled", "NPV scaled", "Soil scaled"]
                let fullSpecs = EndmemberLibrary.fullResolution

                // Plot scaled endmember spectra using full-resolution USGS data
                for (ei, _) in endmembers.enumerated() {
                    let frac = Double(fractionValues[ei])
                    guard frac > 0.01 else { continue }
                    if let full = fullSpecs[ei] {
                        // Full-resolution (5nm step) from USGS library
                        for pt in full.subsampled(step: 5) {
                            let refl = pt.reflectance * frac
                            guard !refl.isNaN && !refl.isInfinite else { continue }
                            pts.append(SpectralPt(id: "\(seriesNames[ei])_\(Int(pt.nm))", nm: pt.nm,
                                                  refl: refl,
                                                  series: seriesNames[ei], band: ""))
                        }
                    } else {
                        // Fallback: interpolate from S2 band values
                        let emVals = endmembers[ei].values.sorted(by: { $0.nm < $1.nm })
                        guard !emVals.isEmpty else { continue }
                        let nms = emVals.map(\.nm); let refls = emVals.map(\.reflectance)
                        var nm = nms[0]
                        while nm <= nms[nms.count - 1] {
                            let refl = linearInterpolate(x: nm, xs: nms, ys: refls) * frac
                            if !refl.isNaN && !refl.isInfinite {
                                pts.append(SpectralPt(id: "\(seriesNames[ei])_\(Int(nm))", nm: nm,
                                                      refl: refl, series: seriesNames[ei], band: ""))
                            }
                            nm += 5
                        }
                    }
                }
                // Predicted total spectrum at 5nm using full-resolution data
                let nmMin = fullSpecs.compactMap { $0?.points.first?.nm }.max() ?? 400
                let nmMax = fullSpecs.compactMap { $0?.points.last?.nm }.min() ?? 2400
                var nm = nmMin
                while nm <= nmMax {
                    var total = 0.0
                    for (ei, _) in endmembers.enumerated() {
                        if let full = fullSpecs[ei], let r = full.interpolated(at: nm) {
                            total += Double(fractionValues[ei]) * r
                        } else {
                            let emVals = endmembers[ei].values.sorted(by: { $0.nm < $1.nm })
                            total += Double(fractionValues[ei]) * linearInterpolate(x: nm, xs: emVals.map(\.nm), ys: emVals.map(\.reflectance))
                        }
                    }
                    if !total.isNaN && !total.isInfinite {
                        pts.append(SpectralPt(id: "pred_\(Int(nm))", nm: nm, refl: total,
                                              series: "Predicted", band: ""))
                    }
                    nm += 5
                }
            }
        }

        // Always show unscaled reference endmember spectra (full-res USGS) as faint background
        let hasFullSpec = EndmemberLibrary.fullResolution.compactMap({ $0 }).count > 0
        if hasFullSpec && !hasUnmix {
            let refNames = ["GV ref", "NPV ref", "Soil ref"]
            for (ei, full) in EndmemberLibrary.fullResolution.enumerated() {
                guard let f = full else { continue }
                for pt in f.subsampled(step: 10) {
                    pts.append(SpectralPt(id: "\(refNames[ei])_\(Int(pt.nm))", nm: pt.nm,
                                          refl: pt.reflectance,
                                          series: refNames[ei], band: ""))
                }
            }
        }

        // Dynamic Y/X scale
        let maxRefl = max(0.5, (envelopePts.map(\.hi) + pts.map(\.refl)).max() ?? 0.5)
        let yTop = ceil(maxRefl * 10) / 10  // round up to nearest 0.1
        let xMax: Double = (hasUnmix || hasFullSpec) ? 2500 : 900

        // Build color map
        var colorMap: KeyValuePairs<String, Color> {
            [
                "Current": Color.red,
                "Predicted": Color.purple.opacity(0.8),
                "GV scaled": Color.green.opacity(0.7),
                "NPV scaled": Color.yellow.opacity(0.7),
                "Soil scaled": soilBrown.opacity(0.7),
                "GV ref": Color.green.opacity(0.3),
                "NPV ref": Color.yellow.opacity(0.3),
                "Soil ref": soilBrown.opacity(0.3)
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
            let isModelCurve = { (s: String) in s == "GV scaled" || s == "NPV scaled" || s == "Soil scaled" || s == "GV ref" || s == "NPV ref" || s == "Soil ref" }
            ForEach(pts) { pt in
                LineMark(
                    x: .value("Wavelength (nm)", pt.nm),
                    y: .value("Reflectance", pt.refl),
                    series: .value("Series", pt.series)
                )
                .foregroundStyle(by: .value("Series", pt.series))
                .lineStyle(StrokeStyle(
                    lineWidth: pt.series == "Current" ? 2.5 : (isModelCurve(pt.series) ? (pt.series.hasSuffix("ref") ? 1.0 : 2.0) : (pt.series == "Predicted" ? 1.2 : 1.5)),
                    dash: pt.series == "Current" ? [] : (isModelCurve(pt.series) ? [3, 1] : (pt.series == "Predicted" ? [3, 2] : [4, 2]))))
                .interpolationMethod(.catmullRom)
            }
            // Point marks (only for actual data series, not model curves)
            ForEach(pts.filter { !isModelCurve($0.series) && $0.series != "Predicted" }) { pt in
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
        .chartXScale(domain: 400...xMax)
        .chartYScale(domain: 0...yTop)
        .chartXAxis {
            AxisMarks(values: (hasUnmix || hasFullSpec) ? [490, 665, 842, 1200, 1610, 2190] : [450, 500, 560, 665, 750, 842]) { value in
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
        .chartLegend(.hidden)
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .clipped()
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                // Compact 2-line legend
                let legendItems: [(String, Color)] = [
                    ("Current", .red), ("Envelope", .gray.opacity(0.3))
                ] + (hasUnmix ? [
                    ("Predicted", .purple), ("GV", .green), ("NPV", .yellow), ("Soil", soilBrown)
                ] : (hasFullSpec ? [
                    ("GV ref", .green), ("NPV ref", .yellow), ("Soil ref", soilBrown)
                ] : []))
                let half = (legendItems.count + 1) / 2
                HStack(spacing: 6) {
                    ForEach(legendItems.prefix(half), id: \.0) { name, color in
                        HStack(spacing: 2) {
                            Circle().fill(color).frame(width: 5, height: 5)
                            Text(name).font(.system(size: 7)).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(legendItems.dropFirst(half).map { $0 }, id: \.0) { name, color in
                        HStack(spacing: 2) {
                            Circle().fill(color).frame(width: 5, height: 5)
                            Text(name).font(.system(size: 7)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Wavelength (nm)")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
            }
            .offset(y: -2)
        }
    }

    /// Linear interpolation in a sorted array of (x, y) pairs.
    private func linearInterpolate(x: Double, xs: [Double], ys: [Double]) -> Double {
        guard xs.count == ys.count, !xs.isEmpty else { return 0 }
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        for i in 1..<xs.count {
            if x <= xs[i] {
                let denom = xs[i] - xs[i-1]
                guard denom != 0 else { continue }
                let t = (x - xs[i-1]) / denom
                return ys[i-1] + t * (ys[i] - ys[i-1])
            }
        }
        return ys[ys.count - 1]
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

        // Fraction model curves: use per-fraction DL fits if available,
        // otherwise fall back to single-logistic approximation from FVC params.
        if !frameUnmixResults.isEmpty {
            let ghost = isInspectingPixel
            if let soilFit = fractionDLFits[.fsoil] {
                for cdoy in cdoys {
                    if let d = dateForCDOY(cdoy) {
                        pts.append(DLCurvePoint(
                            id: "fsoil_\(cdoy)", date: d,
                            ndvi: soilFit.evaluate(t: Double(cdoy)),
                            series: "fSoil-fit",
                            color: soilBrown.opacity(ghost ? 0.3 : 0.7),
                            style: StrokeStyle(lineWidth: ghost ? 1 : 2)
                        ))
                    }
                }
            } else if let dl = dlBest {
                for cdoy in cdoys {
                    if let d = dateForCDOY(cdoy) {
                        pts.append(DLCurvePoint(
                            id: "fsoil_\(cdoy)", date: d,
                            ndvi: dl.evaluateSoilFraction(t: Double(cdoy)),
                            series: "fSoil-fit",
                            color: soilBrown.opacity(ghost ? 0.3 : 0.7),
                            style: StrokeStyle(lineWidth: ghost ? 1 : 2)
                        ))
                    }
                }
            }
            if let npvFit = fractionDLFits[.fnpv] {
                for cdoy in cdoys {
                    if let d = dateForCDOY(cdoy) {
                        pts.append(DLCurvePoint(
                            id: "fnpv_\(cdoy)", date: d,
                            ndvi: npvFit.evaluate(t: Double(cdoy)),
                            series: "fNPV-fit",
                            color: .yellow.opacity(ghost ? 0.3 : 0.7),
                            style: StrokeStyle(lineWidth: ghost ? 1 : 2)
                        ))
                    }
                }
            } else if let dl = dlBest {
                for cdoy in cdoys {
                    if let d = dateForCDOY(cdoy) {
                        pts.append(DLCurvePoint(
                            id: "fnpv_\(cdoy)", date: d,
                            ndvi: dl.evaluateNPVFraction(t: Double(cdoy)),
                            series: "fNPV-fit",
                            color: .yellow.opacity(ghost ? 0.3 : 0.7),
                            style: StrokeStyle(lineWidth: ghost ? 1 : 2)
                        ))
                    }
                }
            }
        }

        return pts
    }

    /// Label showing what the image is currently displaying.
    private var imageDisplayLabel: String {
        if showBadData {
            return "Rejection Map"
        }
        if let param = phenologyDisplayParam {
            return param.rawValue
        }
        if settings.displayMode == .ndvi {
            return fvcPending ? "NDVI" : settings.vegetationIndex.rawValue
        }
        return settings.displayMode.rawValue
    }

    /// Short name for the "Live" menu item — shows what the movie is displaying.
    private var liveDisplayName: String {
        if settings.displayMode == .ndvi {
            return fvcPending ? "NDVI" : settings.vegetationIndex.rawValue
        }
        return settings.displayMode.rawValue
    }

    // MARK: - Phenology Indicator Lines (precomputed for chart)

    /// Precompute tangent/slope lines for rsp/rau, or vertical/horizontal indicators
    /// for other phenology parameters. Returns DLCurvePoint array to render as LineMarks.
    private func phenologyIndicatorLines(sorted: [NDVIFrame]) -> [DLCurvePoint] {
        guard let param = phenologyDisplayParam, let medianFit = dlBest,
              let firstDate = sorted.first?.date else { return [] }
        let cal = Calendar.current
        let refYr = cal.component(.year, from: firstDate)
        var pts = [DLCurvePoint]()

        // Use pixel-specific params when inspecting, otherwise median
        let pixelFit: DLParams? = {
            guard isInspectingPixel, let pp = pixelPhenology,
                  inspectedPixelRow >= 0, inspectedPixelRow < pp.height,
                  inspectedPixelCol >= 0, inspectedPixelCol < pp.width,
                  let px = pp.pixels[inspectedPixelRow][inspectedPixelCol],
                  px.fitQuality != .skipped else { return nil }
            return px.params
        }()
        let fit = pixelFit ?? medianFit

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

        // Dimmed median reference lines when inspecting a pixel
        if pixelFit != nil, (param == .sos || param == .seasonLength || param == .rsp || param == .rau) {
            let mSOS = Int(medianFit.sos)
            let mEOS = Int(medianFit.eos)
            if let sosD = dateForCDOY(mSOS) {
                pts.append(DLCurvePoint(id: "ref_sos0", date: sosD, ndvi: -0.2,
                    series: "ref-sos", color: .primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                pts.append(DLCurvePoint(id: "ref_sos1", date: sosD, ndvi: 1.0,
                    series: "ref-sos", color: .primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            if let eosD = dateForCDOY(mEOS) {
                pts.append(DLCurvePoint(id: "ref_eos0", date: eosD, ndvi: -0.2,
                    series: "ref-eos", color: .primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                pts.append(DLCurvePoint(id: "ref_eos1", date: eosD, ndvi: 1.0,
                    series: "ref-eos", color: .primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
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

    /// Average value over the NxN inspect window for a single frame, matching current display mode.
    private func pixelValue(row: Int, col: Int, frame: NDVIFrame) -> Double? {
        let half = (settings.pixelInspectWindow - 1) / 2
        // For fraction modes, read from unmix results
        if let target = chartFractionTarget, let ur = frameUnmixResults[frame.id] {
            let fracMap: [[Float]]
            switch target {
            case .fveg: fracMap = ur.fveg
            case .fnpv: fracMap = ur.fnpv
            case .fsoil: fracMap = ur.fsoil
            default: fracMap = ur.fveg
            }
            var values = [Float]()
            for dr in -half...half {
                for dc in -half...half {
                    let r = row + dr, c = col + dc
                    guard r >= 0, r < ur.height, c >= 0, c < ur.width else { continue }
                    let v = fracMap[r][c]
                    if !v.isNaN { values.append(v) }
                }
            }
            guard !values.isEmpty else { return nil }
            return Double(values.reduce(0, +)) / Double(values.count)
        }
        // For band modes, read raw reflectance
        let bandData: [[UInt16]]?
        switch settings.displayMode {
        case .bandRed: bandData = frame.redBand
        case .bandNIR: bandData = frame.nirBand
        case .bandGreen: bandData = frame.greenBand
        case .bandBlue: bandData = frame.blueBand
        default: bandData = nil
        }
        if let band = bandData {
            let ofs = frame.dnOffset
            var values = [Float]()
            for dr in -half...half {
                for dc in -half...half {
                    let r = row + dr, c = col + dc
                    guard r >= 0, r < frame.height, c >= 0, c < frame.width,
                          r < band.count, c < band[r].count else { continue }
                    let dn = band[r][c]
                    guard dn > 0, dn < 65535 else { continue }
                    values.append((Float(dn) + ofs) / 10000.0)
                }
            }
            guard !values.isEmpty else { return nil }
            return Double(values.reduce(0, +)) / Double(values.count)
        }
        // Default: NDVI
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

    /// Extract per-pixel fVeg time series from unmix results.
    private func pixelFvegData(sorted: [NDVIFrame]) -> [PixelDataPoint] {
        guard isInspectingPixel else { return [] }
        return sorted.compactMap { frame in
            guard let result = frameUnmixResults[frame.id],
                  inspectedPixelRow >= 0, inspectedPixelCol >= 0,
                  inspectedPixelRow < result.height, inspectedPixelCol < result.width else { return nil }
            let fv = result.fveg[inspectedPixelRow][inspectedPixelCol]
            guard !fv.isNaN else { return nil }
            return PixelDataPoint(id: "fv_\(frame.id.uuidString)", date: frame.date, ndvi: Double(fv))
        }
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
            stopPlayback()
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }

    // MARK: - Live Menu (parameter map selector)

    private var liveMenu: some View {
        Menu {
            // Imagery display modes
            liveMenuItem("NDVI", mode: .ndvi, icon: "leaf")
            liveMenuItem("FCC (NIR-R-G)", mode: .fcc, icon: "camera.filters")
            liveMenuItem("True Color (R-G-B)", mode: .rcc, icon: "photo")
            liveMenuItem("SCL", mode: .scl, icon: "square.grid.3x3")
            Menu("Bands") {
                liveMenuItem("Red (B04)", mode: .bandRed, icon: "circle.fill")
                liveMenuItem("NIR (B08)", mode: .bandNIR, icon: "circle.fill")
                liveMenuItem("Green (B03)", mode: .bandGreen, icon: "circle.fill")
                liveMenuItem("Blue (B02)", mode: .bandBlue, icon: "circle.fill")
            }
            // Phenology parameter maps (when fitted)
            if pixelPhenology != nil {
                Menu("Phenology") {
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
                }
            }
            // Fraction maps (when unmixed)
            if !frameUnmixResults.isEmpty {
                Menu("Fractions") {
                    ForEach(PhenologyParameter.fractionCases, id: \.self) { param in
                        Button {
                            phenologyDisplayParam = param
                            showBadData = false
                            // Use per-fraction DL fit if available
                            if let fit = fractionDLFits[param] {
                                dlBest = fit
                                dlSliders = fit
                            }
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
                Text(showBadData ? "Bad Data" : (phenologyDisplayParam?.rawValue ?? liveDisplayName))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .tint(showBadData ? .red : (phenologyDisplayParam != nil ? .orange : .green))
    }

    @ViewBuilder
    private func liveMenuItem(_ title: String, mode: AppSettings.DisplayMode, icon: String) -> some View {
        Button {
            phenologyDisplayParam = nil
            showBadData = false
            settings.displayMode = mode
            startPlayback()
        } label: {
            if settings.displayMode == mode && phenologyDisplayParam == nil && !showBadData {
                Label(title, systemImage: "checkmark")
            } else {
                Label(title, systemImage: icon)
            }
        }
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
        let fracTarget = chartFractionTarget
        let useFraction = fracTarget != nil
        let data = processor.frames.filter { $0.validPixelCount > 0 }.compactMap { f -> DoubleLogistic.DataPoint? in
            let val: Double
            if let target = fracTarget, let fv = medianFraction(for: f, param: target) {
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
        // Fraction mode: mn=0, mx=1 fixed — for all fraction targets (0→1 normalised)
        let fracMode = useFraction
        // For fNPV/fSoil, invert second-pass weights (weight off-season more, not peak)
        let invertWt = fracTarget == .fnpv || fracTarget == .fsoil
        let targetLabel = fracTarget?.rawValue ?? "VI"

        let filtered = DoubleLogistic.filterCycleContamination(data: data)
        let guess = DoubleLogistic.initialGuess(data: filtered)
        logDistributions(label: "Median DL fit (\(targetLabel))", base: guess, p: p, sp: sp, nRuns: 50, minSL: minSL, maxSL: maxSL)
        if fracMode {
            log.info("  Fraction mode: mn=0, mx=1 fixed (4-param fit)")
        }

        Task.detached(priority: .utility) {
            let initial = DoubleLogistic.ensembleFit(data: data,
                perturbation: p, slopePerturbation: sp,
                minSeasonLength: minSL, maxSeasonLength: maxSL,
                slopeSymmetry: Double(settings.slopeSymmetry),
                bounds: dlBounds,
                secondPass: settings.enableSecondPass,
                fractionMode: fracMode,
                invertWeights: invertWt)

            // Identify outlier dates using MAD of residuals
            let residuals = data.map { pt in
                pt.ndvi - initial.best.evaluate(t: pt.doy)
            }
            let sortedAbs = residuals.map { abs($0) }.sorted()
            let mad = sortedAbs[sortedAbs.count / 2]
            let threshold = max(useFraction ? 0.03 : 0.05, mad * 4.0)

            var outlierIndices = Set<Int>()
            for (i, r) in residuals.enumerated() {
                if abs(r) > threshold {
                    outlierIndices.insert(i)
                }
            }

            if !outlierIndices.isEmpty {
                let cleanData = data.enumerated().filter { !outlierIndices.contains($0.offset) }.map(\.element)

                await MainActor.run {
                    let outlierDates = outlierIndices.sorted().map { idx -> String in
                        let frame = processor.frames[idx]
                        let src = frame.sourceID?.rawValue.uppercased() ?? "?"
                        return "\(frame.dateString) [\(src)] (residual=\(String(format: "%.3f", residuals[idx])))"
                    }
                    log.warn("Excluded \(outlierIndices.count) outlier date(s) from \(targetLabel) fit:")
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

                let result = DoubleLogistic.ensembleFit(data: cleanData,
                    perturbation: p, slopePerturbation: sp,
                    minSeasonLength: minSL, maxSeasonLength: maxSL,
                    slopeSymmetry: Double(settings.slopeSymmetry),
                    bounds: dlBounds,
                    secondPass: settings.enableSecondPass,
                    fractionMode: fracMode,
                    invertWeights: invertWt)
                await MainActor.run {
                    dlBest = result.best
                    dlEnsemble = result.ensemble
                    dlSliders = result.best
                    let rmseStr = String(format: "%.4f", result.best.rmse)
                    if result.best.rmse > 0.15 {
                        log.warn("DL fit to \(targetLabel) poor (excl. \(outlierIndices.count) outlier): RMSE=\(rmseStr)")
                    } else {
                        log.success("DL fit to \(targetLabel) (excl. \(outlierIndices.count) outlier): RMSE=\(rmseStr)\(fracMode ? " [4-param]" : "")")
                    }
                }
            } else {
                await MainActor.run {
                    dlBest = initial.best
                    dlEnsemble = initial.ensemble
                    dlSliders = initial.best
                    let rmseStr = String(format: "%.4f", initial.best.rmse)
                    if initial.best.rmse > 0.15 {
                        log.warn("DL fit to \(targetLabel) poor: RMSE=\(rmseStr)")
                    } else {
                        log.success("DL fit to \(targetLabel): RMSE=\(rmseStr)\(fracMode ? " [4-param]" : ""), \(initial.ensemble.count) viable of 50")
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
        stopPlayback()
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
            secondPassWeightMax: settings.secondPassWeightMax,
            invertWeights: chartFractionTarget == .fnpv || chartFractionTarget == .fsoil
        )

        logDistributions(label: "Per-pixel DL fit", base: medianFit, p: settings.pixelPerturbation,
                         sp: settings.pixelSlopePerturbation, nRuns: settings.pixelEnsembleRuns,
                         minSL: Double(settings.minSeasonLength), maxSL: Double(settings.maxSeasonLength))

        let enforceAOI = settings.enforceAOI
        let coverageThreshold = settings.pixelCoverageThreshold
        pixelFitTask = Task.detached(priority: .utility) {
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
                startPlayback()
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
        Task.detached(priority: .utility) {
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
        Task.detached(priority: .utility) {
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
        Task.detached(priority: .utility) {
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

    /// When AOI sheet dismisses, start fetch if no data loaded yet.
    /// If no AOI geometry exists, startFetch will generate a random crop field.
    private func onAOIDismiss() {
        if processor.frames.isEmpty && processor.status == .idle {
            startFetch()
        }
    }

    /// Reset all state for a new AOI — cancel in-flight work, free memory, then restart.
    private func resetForNewAOI() {
        // Cancel all in-progress work first
        fetchTask?.cancel()
        fetchTask = nil
        processor.cancelFetch()
        pixelFitTask?.cancel()
        pixelFitTask = nil
        unmixTask?.cancel()
        unmixTask = nil
        stopPlayback()

        // Reset frame index
        currentFrameIndex = 0

        // Free large data structures immediately
        frameUnmixResults = [:]
        processor.resetGeometry()
        processor.frames = []
        processor.progress = 0
        processor.progressMessage = ""
        processor.errorMessage = nil
        basemapImage = nil

        // Clear phenology
        dlBest = nil
        dlEnsemble = []
        fractionDLFits = [:]
        dlSliders = DLParams(mn: 0.1, mx: 0.7, sos: 120, rsp: 0.05, eos: 280, rau: 0.05)
        pixelPhenology = nil
        pixelPhenologyBase = nil
        unfilteredPhenology = nil
        pixelFitProgress = 0
        isRunningPixelFit = false
        isClusterFiltered = false
        phenologyDisplayParam = nil
        showBadData = false
        isRunningUnmix = false
        unmixProgress = 0
        lastUnmixHash = 0

        // Clear pixel inspection + selection
        isInspectingPixel = false
        isSelectMode = false
        selectionItem = nil
        zoomScale = 1.0
        panOffset = .zero

        // Restart immediately — set searching status to prevent onAOIDismiss race
        processor.status = .searching
        processor.progressMessage = "Restarting..."
        startFetch()
    }

    private func startFetch() {
        log.clear()

        // Re-enable sources that may have been disabled by a previous probe failure
        for i in settings.sources.indices {
            if !settings.sources[i].isEnabled && [.planetary, .aws].contains(settings.sources[i].sourceID) {
                settings.sources[i].isEnabled = true
            }
        }

        // Use existing AOI geometry, or pick a random crop field on first launch
        let geometry: GeoJSONGeometry
        if let existing = settings.aoiGeometry {
            geometry = existing
            log.info("Using AOI: \(settings.aoiSourceLabel)")
        } else {
            // Pick a random crop field from any region
            let source = CropMapSource.allCases.randomElement() ?? CropMapSource.usaCDL
            let sample = source.randomField()
            let verts = source.fieldPolygon(for: sample)
            geometry = AOIGeometry.fromVertices(verts)
            settings.aoiSource = .cropSample(crop: sample.crop, region: sample.region, sowMonth: sample.plantingMonth, harvMonth: sample.harvestMonth)
            settings.aoiGeometry = geometry
            settings.recordAOI()
            // Set dates from crop calendar
            let dates = CropMapSource.dateRange(
                plantingMonth: sample.plantingMonth,
                harvestMonth: sample.harvestMonth,
                year: Calendar.current.component(.year, from: Date()) - 1
            )
            settings.startDate = dates.start
            settings.endDate = dates.end
            let monthNames = Calendar.current.shortMonthSymbols
            log.info("Random field: \(sample.crop), \(sample.region) (\(monthNames[sample.plantingMonth - 1])\u{2013}\(monthNames[sample.harvestMonth - 1]))")
        }

        log.success("AOI loaded: \(geometry.polygon.count) vertices")
        let c = geometry.centroid
        let b = geometry.bbox
        log.info("Centroid: \(String(format: "%.4f", c.lon))E, \(String(format: "%.4f", c.lat))N")
        log.info("Dates: \(settings.startDateString) → \(settings.endDateString)")
        log.info("Bbox: \(String(format: "%.4f", b.minLon))–\(String(format: "%.4f", b.maxLon))E, \(String(format: "%.4f", b.minLat))–\(String(format: "%.4f", b.maxLat))N")
        let srcNames = settings.enabledSources.map(\.shortName).joined(separator: ", ")
        log.info("Sources: \(srcNames.isEmpty ? "NONE" : srcNames)")

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
        fetchTask?.cancel()
        fetchTask = Task {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Compact NDVI colorbar overlay (not affected by zoom/pan).
struct NDVIColorBarCompact: View {
    var body: some View {
        Canvas { context, size in
            for i in 0..<Int(size.width) {
                let frac = Float(i) / Float(size.width)
                let v = frac * 1.2 - 0.2  // -0.2 to 1.0
                let (r, g, b) = ndviRGB(v)
                context.fill(Path(CGRect(x: CGFloat(i), y: 0, width: 1, height: size.height)),
                             with: .color(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)))
            }
            // Tick labels
            let ticks: [(Float, String)] = [(-0.2, "-.2"), (0, "0"), (0.2, ".2"), (0.4, ".4"), (0.6, ".6"), (0.8, ".8")]
            for (val, label) in ticks {
                let x = CGFloat((val + 0.2) / 1.2) * size.width
                let text = Text(label).font(.system(size: 7).monospacedDigit()).foregroundStyle(.white)
                let r = context.resolve(text)
                context.draw(r, at: CGPoint(x: x, y: size.height / 2))
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .opacity(0.85)
        .padding(.horizontal, 4)
    }

    private func ndviRGB(_ v: Float) -> (UInt8, UInt8, UInt8) {
        let v = max(-1, min(1, v))
        if v < 0 {
            let t = (v + 1)
            return (UInt8(20 + t * 30), UInt8(20 + t * 50), UInt8(100 + t * 80))
        } else if v < 0.15 {
            let t = v / 0.15
            return (UInt8(160 + t * 40), UInt8(120 + t * 40), UInt8(60 + t * 20))
        } else if v < 0.3 {
            let t = (v - 0.15) / 0.15
            return (UInt8(200 - t * 80), UInt8(160 + t * 40), UInt8(80 - t * 40))
        } else if v < 0.5 {
            let t = (v - 0.3) / 0.2
            return (UInt8(120 - t * 80), UInt8(200 - t * 20), UInt8(40 + t * 10))
        } else if v < 0.7 {
            let t = (v - 0.5) / 0.2
            return (UInt8(40 - t * 20), UInt8(180 - t * 30), UInt8(50 - t * 20))
        } else {
            let t = min(1, (v - 0.7) / 0.3)
            return (UInt8(20 - t * 10), UInt8(150 - t * 40), UInt8(30 - t * 10))
        }
    }
}

/// Simple 0–1 fraction colorbar (green gradient for FVC, yellow for NPV, orange for Soil).
struct FractionColorBar: View {
    let label: String
    var body: some View {
        Canvas { context, size in
            let color: (Float) -> (UInt8, UInt8, UInt8) = { f in
                let t = max(0, min(1, f))
                switch label {
                case "FVC":  return (UInt8(30 + (1-t) * 90), UInt8(80 + t * 175), UInt8(30 + (1-t) * 40))
                case "NPV":  return (UInt8(40 + t * 215), UInt8(40 + t * 215), UInt8(20))
                case "Soil": return (UInt8(25 + t * 115), UInt8(20 + t * 57), UInt8(5 + t * 20))
                case "Unmix RMSE":
                    // Pseudocolour: Green → Yellow → Red (matches spatial map)
                    if t < 0.5 {
                        let s = t * 2
                        return (UInt8(s * 255), UInt8(200 + s * 55), 0)
                    } else {
                        let s = (t - 0.5) * 2
                        return (255, UInt8((1 - s) * 255), 0)
                    }
                default:     return (UInt8(40 + t * 215), UInt8(40 + t * 215), UInt8(40 + t * 215))
                }
            }
            for i in 0..<Int(size.width) {
                let frac = Float(i) / Float(size.width)
                let (r, g, b) = color(frac)
                context.fill(Path(CGRect(x: CGFloat(i), y: 0, width: 1, height: size.height)),
                             with: .color(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)))
            }
            let ticks: [(Float, String)] = label == "Unmix RMSE"
                ? [(0, "low"), (0.5, "RMSE"), (1.0, "high")]
                : [(0, "0"), (0.25, ".25"), (0.5, ".5"), (0.75, ".75"), (1.0, "1")]
            for (val, lbl) in ticks {
                let x = CGFloat(val) * size.width
                let text = Text(lbl).font(.system(size: 7).monospacedDigit()).foregroundStyle(.white)
                let r = context.resolve(text)
                context.draw(r, at: CGPoint(x: x, y: size.height / 2))
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .opacity(0.85)
        .padding(.horizontal, 4)
    }
}

/// Grayscale colorbar for single-band reflectance display (0–0.5).
struct BandColorBar: View {
    let label: String
    var body: some View {
        Canvas { context, size in
            for i in 0..<Int(size.width) {
                let frac = Float(i) / Float(size.width)
                let v = UInt8(min(255, frac * 510))  // 0 to 0.5 → 0 to 255
                context.fill(Path(CGRect(x: CGFloat(i), y: 0, width: 1, height: size.height)),
                             with: .color(Color(red: Double(v)/255, green: Double(v)/255, blue: Double(v)/255)))
            }
            let ticks: [(Float, String)] = [(0, "0"), (0.1, ".1"), (0.2, ".2"), (0.3, ".3"), (0.4, ".4"), (0.5, ".5")]
            for (val, lbl) in ticks {
                let x = CGFloat(val / 0.5) * size.width
                let text = Text(lbl).font(.system(size: 7).monospacedDigit()).foregroundStyle(.cyan)
                let r = context.resolve(text)
                context.draw(r, at: CGPoint(x: x, y: size.height / 2))
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .opacity(0.85)
        .padding(.horizontal, 4)
    }
}

/// Scale bar that adapts to current zoom. Shows a round-number distance.
struct ScaleBarView: View {
    let metersPerPoint: Double  // physical meters per screen point

    var body: some View {
        let (barPts, label) = scaleBarParams()
        VStack(alignment: .leading, spacing: 1) {
            Rectangle()
                .fill(.white)
                .frame(width: barPts, height: 2)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white).frame(width: 1, height: 6)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.white).frame(width: 1, height: 6)
                }
            Text(label)
                .font(.system(size: 8).bold().monospacedDigit())
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
    }

    private func scaleBarParams() -> (CGFloat, String) {
        let niceMeters: [Double] = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]
        for m in niceMeters {
            let pts = m / metersPerPoint
            if pts >= 40 && pts <= 120 {
                let label = m >= 1000 ? "\(Int(m / 1000)) km" : "\(Int(m)) m"
                return (CGFloat(pts), label)
            }
        }
        let pts = 100.0 / metersPerPoint
        return (CGFloat(max(20, min(150, pts))), "100 m")
    }
}
