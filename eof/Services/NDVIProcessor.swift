import Foundation
import Observation

/// Orchestrates the STAC search → COG read → NDVI computation pipeline.
@Observable
class NDVIProcessor {

    // Published state
    var status: ProcessorStatus = .idle
    var progress: Double = 0
    var progressMessage: String = ""
    var frames: [NDVIFrame] = []
    var errorMessage: String?
    var sourceProgresses: [SourceProgress] = []
    var isCancelled = false
    var isPaused = false

    private var lastGeometryCentroid: (lon: Double, lat: Double)?
    private var fetchTask: Task<Void, Never>?

    // Constants
    private let quantificationValue: Float = 10000.0

    private let log = ActivityLog.shared
    private let settings = AppSettings.shared

    enum ProcessorStatus {
        case idle, searching, processing, done, error
    }

    /// Run the full pipeline.
    @MainActor
    func fetch(geometry: GeoJSONGeometry, startDate: String, endDate: String) async {
        status = .searching
        progress = 0
        progressMessage = "Searching STAC catalog..."
        frames = []
        errorMessage = nil
        sourceProgresses = []
        isPaused = false
        isCancelled = false

        log.info("Starting fetch: \(startDate) to \(endDate)")

        do {
            // 0. Validate enabled sources — quick probe, disable failures
            var validatedSources = settings.enabledSources
            guard !validatedSources.isEmpty else {
                throw STACError.noItems
            }

            progressMessage = "Testing \(validatedSources.count) source(s)..."

            struct ProbeResult {
                let sourceID: SourceID
                let ok: Bool
                let error: String?
                let searchMs: Int
                let sasMs: Int?
            }

            let probeResults = await withTaskGroup(of: ProbeResult.self) { group -> [ProbeResult] in
                for src in validatedSources {
                    group.addTask {
                        do {
                            let t0 = CFAbsoluteTimeGetCurrent()
                            if src.sourceID == .gee {
                                // GEE probe: verify token and basic API access
                                let gee = GEETokenManager()
                                _ = try await gee.getToken()
                                let searchMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                                return ProbeResult(sourceID: src.sourceID, ok: true, error: nil,
                                                   searchMs: searchMs, sasMs: nil)
                            }
                            let stac = STACService(config: src)
                            let items = try await stac.search(
                                geometry: geometry, startDate: startDate, endDate: endDate
                            )
                            let searchMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)

                            var sasMs: Int? = nil
                            if src.assetAuthType == .sasToken {
                                let t1 = CFAbsoluteTimeGetCurrent()
                                let sas = SASTokenManager()
                                _ = try await sas.getToken(for: src.collection)
                                sasMs = Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)
                            } else if src.assetAuthType == .bearerToken {
                                let t1 = CFAbsoluteTimeGetCurrent()
                                let bearer = BearerTokenManager(sourceID: src.sourceID)
                                _ = try await bearer.getToken()
                                sasMs = Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)
                            }
                            return ProbeResult(sourceID: src.sourceID, ok: true, error: nil,
                                               searchMs: searchMs, sasMs: sasMs)
                        } catch {
                            return ProbeResult(sourceID: src.sourceID, ok: false,
                                               error: error.localizedDescription, searchMs: 0, sasMs: nil)
                        }
                    }
                }
                var results = [ProbeResult]()
                for await r in group { results.append(r) }
                return results
            }

            // Disable failed sources, log timing
            for probe in probeResults where !probe.ok {
                if let idx = validatedSources.firstIndex(where: { $0.sourceID == probe.sourceID }) {
                    let name = validatedSources[idx].displayName
                    validatedSources.remove(at: idx)
                    let msg = "\(name) unavailable — disabled for this fetch"
                    log.warn(msg + (probe.error.map { " (\($0))" } ?? ""))
                    if let si = settings.sources.firstIndex(where: { $0.sourceID == probe.sourceID }) {
                        settings.sources[si].isEnabled = false
                    }
                    progressMessage = msg
                }
            }
            for probe in probeResults where probe.ok {
                let name = validatedSources.first(where: { $0.sourceID == probe.sourceID })?.shortName ?? probe.sourceID.rawValue
                var timing = "search \(probe.searchMs)ms"
                if let sas = probe.sasMs { timing += ", SAS \(sas)ms" }
                log.success("\(name): \(timing) \u{2713}")
            }

            guard !validatedSources.isEmpty else {
                throw STACError.noItems
            }

            let enabledSources = validatedSources

            // 1. Search all enabled sources in parallel
            progressMessage = "Searching \(enabledSources.count) source(s)..."

            // Per-source search status (temporary)
            var sourceSearchStatus = [SourceID: String]()

            // Search all sources in parallel
            struct SourceSearchResult {
                let config: STACSourceConfig
                let items: [STACItem]
            }

            var searchResults = [SourceSearchResult]()
            await withTaskGroup(of: SourceSearchResult?.self) { group in
                for src in enabledSources {
                    group.addTask {
                        if src.sourceID == .gee {
                            let projectID = KeychainService.retrieve(key: "gee.project") ?? ""
                            guard !projectID.isEmpty else { return nil }
                            let gee = GEEService(projectID: projectID, tokenManager: GEETokenManager())
                            if let items = try? await gee.search(
                                geometry: geometry, startDate: startDate, endDate: endDate
                            ), !items.isEmpty {
                                return SourceSearchResult(config: src, items: items)
                            }
                            return nil
                        }
                        let stac = STACService(config: src)
                        if let items = try? await stac.search(
                            geometry: geometry, startDate: startDate, endDate: endDate
                        ), !items.isEmpty {
                            return SourceSearchResult(config: src, items: items)
                        }
                        return nil
                    }
                }
                for await result in group {
                    if let r = result {
                        searchResults.append(r)
                    }
                }
            }

            // Deduplicate by (dateString, mgrsTile), collect available sources per scene
            var candidatesByKey = [String: [(STACItem, STACSourceConfig)]]()
            var orderedKeys = [String]()
            for src in enabledSources {
                guard let result = searchResults.first(where: { $0.config.sourceID == src.sourceID }) else {
                    sourceSearchStatus[src.sourceID] = "skipped"
                    continue
                }
                for item in result.items {
                    let key = "\(item.dateString)_\(item.mgrsTile ?? "")"
                    if candidatesByKey[key] == nil {
                        orderedKeys.append(key)
                    }
                    candidatesByKey[key, default: []].append((item, src))
                }
            }

            for src in enabledSources {
                let count = orderedKeys.filter { candidatesByKey[$0]?.contains(where: { $0.1.sourceID == src.sourceID }) ?? false }.count
                sourceSearchStatus[src.sourceID] = "\(count) available"
                log.info("\(src.shortName): \(count) scenes available")
            }

            var totalItems = orderedKeys.count
            guard totalItems > 0 else {
                log.error("No Sentinel-2 items found for date range")
                throw STACError.noItems
            }

            if let firstKey = orderedKeys.first,
               let firstItem = candidatesByKey[firstKey]?.first?.0,
               let tile = firstItem.mgrsTile {
                log.info("MGRS tile: \(tile)")
            }
            progressMessage = "Found \(totalItems) scenes — reading imagery..."
            status = .processing

            // 2. Determine UTM zone from geometry centroid
            let centroid = geometry.centroid
            let utm = UTMProjection.zoneFor(lon: centroid.lon, lat: centroid.lat)
            let bbox = geometry.bbox
            log.info("UTM zone: \(utm.zone)\(utm.isNorth ? "N" : "S") (EPSG:\(utm.epsg))")

            // 3. Process items concurrently with per-source tracking
            // Capture settings snapshot to avoid reading shared mutable state from concurrent tasks
            let capturedDisplayMode = settings.displayMode
            let capturedCloudMask = settings.cloudMask
            let capturedSCLValidClasses = settings.sclValidClasses
            let capturedVegetationIndex = settings.vegetationIndex
            var processedCount = 0
            var newFrames = [NDVIFrame]()
            let maxConc = settings.maxConcurrent
            let cloudThreshold = settings.cloudThreshold

            // Create auth managers per source
            var sasManagers = [SourceID: SASTokenManager]()
            var bearerManagers = [SourceID: BearerTokenManager]()
            var geeTokenManager: GEETokenManager?
            for src in enabledSources {
                switch src.assetAuthType {
                case .sasToken: sasManagers[src.sourceID] = SASTokenManager()
                case .bearerToken: bearerManagers[src.sourceID] = BearerTokenManager(sourceID: src.sourceID)
                case .geeOAuth: geeTokenManager = GEETokenManager()
                case .none: break
                }
            }

            // Create per-stream progress bars (one per concurrent slot)
            let itemsPerStream = totalItems / maxConc
            let remainder = totalItems % maxConc
            for i in 0..<maxConc {
                let sp = SourceProgress(sourceID: enabledSources.first?.sourceID ?? .aws, displayName: "\(i + 1)")
                sp.totalItems = itemsPerStream + (i < remainder ? 1 : 0)
                sp.status = .downloading
                sourceProgresses.append(sp)
            }

            log.info("Downloading & processing \(totalItems) scenes (\(maxConc) streams, cloud \u{2264}\(Int(cloudThreshold))%)...")

            // Dynamic source selection: track per-source latency, pick fastest at dispatch time
            enum ProcessResult {
                case success(NDVIFrame?, Int, SourceID, Double)  // frame, slot, sourceID, seconds
                case httpFailed(String, SourceID, Int, Int, Double)  // key, sourceID, httpCode, slot, seconds
            }

            var httpErrorCount = 0
            var retryQueue = [(key: String, excludeSource: SourceID)]()
            var currentMaxConc = maxConc
            // Latency tracking (all on MainActor — safe)
            var sourceLatencies = [SourceID: [Double]]()
            var sourceInFlight = [SourceID: Int]()
            var sourceCompleteCounts = [SourceID: Int]()

            func avgLatency(_ sid: SourceID) -> Double {
                guard let lats = sourceLatencies[sid], !lats.isEmpty else { return 1.0 }
                let recent = lats.suffix(10)
                return recent.reduce(0, +) / Double(recent.count)
            }

            func pickBestSource(from candidates: [(STACItem, STACSourceConfig)]) -> (STACItem, STACSourceConfig) {
                guard candidates.count > 1 else { return candidates[0] }
                // Score each candidate; pick randomly among those within 20% of the best
                let scored = candidates.map { c in
                    (c, avgLatency(c.1.sourceID) + Double(sourceInFlight[c.1.sourceID] ?? 0) * 0.5)
                }
                let bestScore = scored.map(\.1).min()!
                let threshold = bestScore * 1.2 + 0.1  // 20% tolerance + small absolute margin
                let eligible = scored.filter { $0.1 <= threshold }.map(\.0)
                return eligible.randomElement()!
            }

            await withTaskGroup(of: ProcessResult.self) { group in
                var running = 0
                var nextSlot = 0
                var freeSlots = [Int]()
                var keyIndex = 0

                func handleResult(_ result: ProcessResult) {
                    switch result {
                    case .success(let frame, let slot, let sourceID, let seconds):
                        if let f = frame { newFrames.append(f) }
                        processedCount += 1
                        progress = Double(processedCount) / Double(totalItems)
                        progressMessage = "Reading imagery \(processedCount)/\(totalItems)..."
                        if slot < sourceProgresses.count {
                            sourceProgresses[slot].completedItems += 1
                        }
                        freeSlots.append(slot)
                        sourceLatencies[sourceID, default: []].append(seconds)
                        sourceInFlight[sourceID, default: 0] -= 1
                        sourceCompleteCounts[sourceID, default: 0] += 1

                    case .httpFailed(let dateKey, let failedSrc, let code, let slot, let seconds):
                        processedCount += 1
                        progress = Double(processedCount) / Double(totalItems)
                        if slot < sourceProgresses.count {
                            sourceProgresses[slot].completedItems += 1
                        }
                        freeSlots.append(slot)
                        sourceLatencies[failedSrc, default: []].append(seconds)
                        sourceInFlight[failedSrc, default: 0] -= 1

                        httpErrorCount += 1
                        if let alts = candidatesByKey[dateKey],
                           alts.contains(where: { $0.1.sourceID != failedSrc }) {
                            log.warn("\(dateKey): \(failedSrc.rawValue.uppercased()) HTTP \(code), will retry from alternate")
                            retryQueue.append((key: dateKey, excludeSource: failedSrc))
                            totalItems += 1
                        }
                        if code == 403 {
                            if httpErrorCount == 1 {
                                if failedSrc == .earthdata {
                                    log.warn("Earthdata 403: check credentials and EULA at https://urs.earthdata.nasa.gov/profile")
                                } else {
                                    log.warn("\(failedSrc.rawValue.uppercased()) 403: access denied — check credentials")
                                }
                            }
                            if httpErrorCount == 5 {
                                currentMaxConc = max(2, currentMaxConc / 2)
                                log.warn("Rate limiting (\(httpErrorCount) x 403) — reducing to \(currentMaxConc) streams")
                            }
                        }
                    }
                    running -= 1
                }

                // Main work queue — dynamic source selection per scene
                while keyIndex < orderedKeys.count {
                    if self.isCancelled { group.cancelAll(); break }
                    while self.isPaused && !self.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if self.isCancelled { group.cancelAll(); break }

                    while running >= currentMaxConc {
                        if let result = await group.next() { handleResult(result) }
                    }

                    let key = orderedKeys[keyIndex]
                    keyIndex += 1
                    guard let candidates = candidatesByKey[key] else { continue }

                    let (item, cfg) = pickBestSource(from: candidates)
                    sourceInFlight[cfg.sourceID, default: 0] += 1
                    let dateKey = key
                    let slot = freeSlots.isEmpty ? nextSlot : freeSlots.removeFirst()
                    if freeSlots.isEmpty && nextSlot < maxConc { nextSlot += 1 }
                    if slot < sourceProgresses.count {
                        sourceProgresses[slot].currentSource = cfg.shortName
                    }

                    group.addTask {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        do {
                            let frame: NDVIFrame?
                            if cfg.sourceID == .gee {
                                frame = try await self.processGEEItem(
                                    item: item, geometry: geometry,
                                    utm: utm, bbox: bbox,
                                    cloudThreshold: cloudThreshold,
                                    geeTokenManager: geeTokenManager!,
                                    displayMode: capturedDisplayMode,
                                    cloudMask: capturedCloudMask,
                                    sclValidClasses: capturedSCLValidClasses,
                                    vegetationIndex: capturedVegetationIndex
                                )
                            } else {
                                frame = try await self.processItem(
                                    item: item, geometry: geometry,
                                    utm: utm, bbox: bbox,
                                    cloudThreshold: cloudThreshold,
                                    bandMapping: cfg.bandMapping,
                                    sasTokenManager: sasManagers[cfg.sourceID],
                                    bearerTokenManager: bearerManagers[cfg.sourceID],
                                    sourceID: cfg.sourceID,
                                    collection: cfg.collection,
                                    displayMode: capturedDisplayMode,
                                    cloudMask: capturedCloudMask,
                                    sclValidClasses: capturedSCLValidClasses,
                                    vegetationIndex: capturedVegetationIndex
                                )
                            }
                            return .success(frame, slot, cfg.sourceID, CFAbsoluteTimeGetCurrent() - t0)
                        } catch let err as COGError {
                            let elapsed = CFAbsoluteTimeGetCurrent() - t0
                            switch err {
                            case .httpError(let code):
                                return .httpFailed(dateKey, cfg.sourceID, code, slot, elapsed)
                            case .missingTransform:
                                return .httpFailed(dateKey, cfg.sourceID, 0, slot, elapsed)
                            default:
                                return .success(nil, slot, cfg.sourceID, elapsed)
                            }
                        } catch {
                            return .success(nil, slot, cfg.sourceID, CFAbsoluteTimeGetCurrent() - t0)
                        }
                    }
                    running += 1
                }

                // Retries — pick from alternate sources, excluding the one that failed
                while !retryQueue.isEmpty {
                    if self.isCancelled { group.cancelAll(); break }
                    while self.isPaused && !self.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if self.isCancelled { group.cancelAll(); break }

                    while running >= currentMaxConc {
                        if let result = await group.next() { handleResult(result) }
                    }

                    let retry = retryQueue.removeFirst()
                    guard let candidates = candidatesByKey[retry.key]?.filter({ $0.1.sourceID != retry.excludeSource }),
                          !candidates.isEmpty else {
                        processedCount += 1
                        progress = Double(processedCount) / Double(totalItems)
                        continue
                    }

                    let (item, cfg) = pickBestSource(from: candidates)
                    sourceInFlight[cfg.sourceID, default: 0] += 1
                    let slot = freeSlots.isEmpty ? nextSlot : freeSlots.removeFirst()
                    if freeSlots.isEmpty && nextSlot < maxConc { nextSlot += 1 }
                    if slot < sourceProgresses.count {
                        sourceProgresses[slot].currentSource = "\(cfg.shortName)\u{21BA}"
                    }

                    group.addTask {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        do {
                            let frame: NDVIFrame?
                            if cfg.sourceID == .gee {
                                frame = try await self.processGEEItem(
                                    item: item, geometry: geometry,
                                    utm: utm, bbox: bbox,
                                    cloudThreshold: cloudThreshold,
                                    geeTokenManager: geeTokenManager!,
                                    displayMode: capturedDisplayMode,
                                    cloudMask: capturedCloudMask,
                                    sclValidClasses: capturedSCLValidClasses,
                                    vegetationIndex: capturedVegetationIndex
                                )
                            } else {
                                frame = try await self.processItem(
                                    item: item, geometry: geometry,
                                    utm: utm, bbox: bbox,
                                    cloudThreshold: cloudThreshold,
                                    bandMapping: cfg.bandMapping,
                                    sasTokenManager: sasManagers[cfg.sourceID],
                                    bearerTokenManager: bearerManagers[cfg.sourceID],
                                    sourceID: cfg.sourceID,
                                    collection: cfg.collection,
                                    displayMode: capturedDisplayMode,
                                    cloudMask: capturedCloudMask,
                                    sclValidClasses: capturedSCLValidClasses,
                                    vegetationIndex: capturedVegetationIndex
                                )
                            }
                            return .success(frame, slot, cfg.sourceID, CFAbsoluteTimeGetCurrent() - t0)
                        } catch {
                            return .success(nil, slot, cfg.sourceID, CFAbsoluteTimeGetCurrent() - t0)
                        }
                    }
                    running += 1
                }

                for await result in group { handleResult(result) }
            }

            // Log per-source performance summary
            for src in enabledSources {
                let count = sourceCompleteCounts[src.sourceID] ?? 0
                let avg = avgLatency(src.sourceID)
                if count > 0 {
                    log.info("\(src.shortName): \(count) scenes, avg \(String(format: "%.1f", avg))s/scene")
                }
            }

            if httpErrorCount > 0 {
                log.warn("HTTP errors: \(httpErrorCount) total")
            }

            // Mark all streams as done
            for sp in sourceProgresses {
                sp.status = isCancelled ? .failed : .done
            }

            // Sort by date — keep whatever frames we have (even if cancelled)
            frames = newFrames.sorted { $0.date < $1.date }
            lastGeometryCentroid = (lon: centroid.lon, lat: centroid.lat)

            if isCancelled {
                isCancelled = false
                progress = Double(processedCount) / Double(totalItems)
                progressMessage = "Stopped — \(frames.count) scenes loaded"
                status = .done
                log.warn("Fetch stopped by user after \(processedCount)/\(totalItems) scenes (\(frames.count) frames kept)")
            } else {
                progress = 1.0
                let skipped = totalItems - frames.count
                progressMessage = "Done! \(frames.count) scenes loaded"
                status = .done

                log.success("Pipeline complete: \(frames.count) frames from \(totalItems) scenes")
                if skipped > 0 {
                    log.info("Dropped \(skipped) scenes (cloud/no valid data/error)")
                }
                if let first = frames.first, let last = frames.last {
                    log.info("Date range: \(first.dateString) to \(last.dateString)")
                    if let peak = frames.map({ $0.medianNDVI }).max() {
                        log.info("Peak median NDVI: \(String(format: "%.3f", peak))")
                    }
                }

                // Scene summary table
                log.info("--- Scene Summary ---")
                for f in frames {
                    let src = f.sourceID?.rawValue.uppercased() ?? "?"
                    let scene = f.sceneID ?? f.dateString
                    let doy = String(format: "%03d", f.dayOfYear)
                    let med = String(format: "%.3f", f.medianNDVI)
                    log.info("\(scene) \(f.dateString) DOY=\(doy) nValid=\(f.validPixelCount)/\(f.polyPixelCount) medNDVI=\(med) [\(src)]")
                }

            }

        } catch {
            errorMessage = error.localizedDescription
            status = .error
            progressMessage = "Error: \(error.localizedDescription)"
            log.error("Pipeline failed: \(error.localizedDescription)")
        }
    }

    /// Incrementally update for a new date range: keep in-range frames, fetch only new dates.
    @MainActor
    func updateDateRange(geometry: GeoJSONGeometry, startDate: String, endDate: String) async {
        // Check if AOI moved — if so, do full fetch
        let centroid = geometry.centroid
        if let prev = lastGeometryCentroid,
           abs(prev.lon - centroid.lon) > 0.001 || abs(prev.lat - centroid.lat) > 0.001 {
            log.info("AOI changed spatially — full re-fetch")
            await fetch(geometry: geometry, startDate: startDate, endDate: endDate)
            return
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let newStart = fmt.date(from: startDate),
              let newEnd = fmt.date(from: endDate) else {
            await fetch(geometry: geometry, startDate: startDate, endDate: endDate)
            return
        }

        // Keep only in-range frames, discard the rest
        var kept = frames.filter { $0.date >= newStart && $0.date <= newEnd.addingTimeInterval(86400) }
        let dropped = frames.count - kept.count
        let existingDates = Set(kept.map { $0.dateString })

        log.info("Date update: keeping \(kept.count) frames, dropped \(dropped)")

        // Determine which date sub-ranges need fetching
        // Find the previous date range from existing frames
        let existingStart = frames.compactMap({ $0.date }).min()
        let existingEnd = frames.compactMap({ $0.date }).max()

        struct DateRange {
            let start: String
            let end: String
        }
        var fetchRanges = [DateRange]()

        if let eStart = existingStart, let eEnd = existingEnd {
            // Fetch new dates before previous start
            if newStart < eStart {
                fetchRanges.append(DateRange(
                    start: startDate,
                    end: fmt.string(from: eStart.addingTimeInterval(-86400))
                ))
            }
            // Fetch new dates after previous end
            if newEnd > eEnd {
                fetchRanges.append(DateRange(
                    start: fmt.string(from: eEnd.addingTimeInterval(86400)),
                    end: endDate
                ))
            }
        } else {
            // No existing frames, fetch entire range
            fetchRanges.append(DateRange(start: startDate, end: endDate))
        }

        if fetchRanges.isEmpty {
            // Just reorganize existing frames
            frames = kept.sorted { $0.date < $1.date }
            progress = 1.0
            let msg = "Date range updated: \(frames.count) frames"
            progressMessage = msg
            status = .done
            log.success(msg)
            return
        }

        // Fetch new sub-ranges
        status = .processing
        progressMessage = "Fetching new dates..."
        progress = 0

        let sourceConfig = settings.enabledSources.first ?? .awsDefault()
        let isGEE = sourceConfig.sourceID == .gee
        let stacService = isGEE ? nil : STACService(config: sourceConfig)
        let geeService: GEEService? = isGEE ? {
            let pid = KeychainService.retrieve(key: "gee.project") ?? ""
            return GEEService(projectID: pid, tokenManager: GEETokenManager())
        }() : nil
        let geeToken: GEETokenManager? = isGEE ? GEETokenManager() : nil
        let bandMapping = sourceConfig.bandMapping
        let sasManager: SASTokenManager? = sourceConfig.assetAuthType == .sasToken ? SASTokenManager() : nil
        let utm = UTMProjection.zoneFor(lon: centroid.lon, lat: centroid.lat)
        let bbox = geometry.bbox
        let maxConc = settings.maxConcurrent
        let cloudThreshold = settings.cloudThreshold
        let capturedDisplayMode = settings.displayMode
        let capturedCloudMask = settings.cloudMask
        let capturedSCLValidClasses = settings.sclValidClasses
        let capturedVegetationIndex = settings.vegetationIndex

        var allNewItems = [STACItem]()
        for range in fetchRanges {
            log.info("Searching \(range.start) to \(range.end)...")
            let items: [STACItem]?
            if isGEE, let gee = geeService {
                items = try? await gee.search(geometry: geometry, startDate: range.start, endDate: range.end)
            } else if let stac = stacService {
                items = try? await stac.search(geometry: geometry, startDate: range.start, endDate: range.end)
            } else {
                items = nil
            }
            if let items {
                let newItems = items.filter { !existingDates.contains($0.dateString) }
                allNewItems.append(contentsOf: newItems)
                log.info("Found \(items.count) scenes (\(newItems.count) new)")
            }
        }

        if allNewItems.isEmpty {
            frames = kept.sorted { $0.date < $1.date }
            progress = 1.0
            let msg = "Updated: \(frames.count) frames (no new scenes)"
            progressMessage = msg
            status = .done
            log.success(msg)
            return
        }

        // Process new items
        let totalNew = allNewItems.count
        var processedCount = 0
        var newFrames = [NDVIFrame]()

        log.info("Processing \(totalNew) new scenes...")

        await withTaskGroup(of: NDVIFrame?.self) { group in
            var running = 0
            for item in allNewItems {
                if running >= maxConc {
                    if let frame = await group.next() {
                        if let f = frame { newFrames.append(f) }
                        processedCount += 1
                        progress = Double(processedCount) / Double(totalNew)
                        progressMessage = "Reading new imagery \(processedCount)/\(totalNew)..."
                        running -= 1
                    }
                }
                group.addTask {
                    if isGEE, let gt = geeToken {
                        return try? await self.processGEEItem(
                            item: item, geometry: geometry,
                            utm: utm, bbox: bbox,
                            cloudThreshold: cloudThreshold,
                            geeTokenManager: gt,
                            displayMode: capturedDisplayMode,
                            cloudMask: capturedCloudMask,
                            sclValidClasses: capturedSCLValidClasses,
                            vegetationIndex: capturedVegetationIndex
                        )
                    }
                    return try? await self.processItem(
                        item: item, geometry: geometry,
                        utm: utm, bbox: bbox,
                        cloudThreshold: cloudThreshold,
                        bandMapping: bandMapping,
                        sasTokenManager: sasManager,
                        sourceID: sourceConfig.sourceID,
                        collection: sourceConfig.collection,
                        displayMode: capturedDisplayMode,
                        cloudMask: capturedCloudMask,
                        sclValidClasses: capturedSCLValidClasses,
                        vegetationIndex: capturedVegetationIndex
                    )
                }
                running += 1
            }
            for await frame in group {
                if let f = frame { newFrames.append(f) }
                processedCount += 1
                progress = Double(processedCount) / Double(totalNew)
                progressMessage = "Reading new imagery \(processedCount)/\(totalNew)..."
            }
        }

        // Merge kept + new
        kept.append(contentsOf: newFrames)
        frames = kept.sorted { $0.date < $1.date }
        lastGeometryCentroid = (lon: centroid.lon, lat: centroid.lat)
        progress = 1.0
        let msg = "Updated: \(frames.count) frames (\(newFrames.count) new, \(dropped) dropped)"
        progressMessage = msg
        status = .done
        log.success(msg)
    }

    /// Stop an in-progress fetch — keeps frames collected so far.
    @MainActor
    func cancelFetch() {
        guard status == .searching || status == .processing else { return }
        isCancelled = true
        isPaused = false
        log.info("Stopping fetch...")
    }

    /// Pause an in-progress fetch — running tasks finish but no new ones start.
    @MainActor
    func pauseFetch() {
        guard status == .processing && !isPaused else { return }
        isPaused = true
        log.info("Fetch paused")
    }

    /// Resume a paused fetch.
    @MainActor
    func resumeFetch() {
        guard isPaused else { return }
        isPaused = false
        log.info("Fetch resumed")
    }

    /// Reset state (call when AOI changes spatially).
    func resetGeometry() {
        lastGeometryCentroid = nil
    }

    /// Process a single STAC item → NDVIFrame (or nil if too cloudy / no data).
    /// Throws COGError.httpError on HTTP failures so caller can retry from alternate source.
    private func processItem(
        item: STACItem,
        geometry: GeoJSONGeometry,
        utm: UTMProjection,
        bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        cloudThreshold: Double,
        bandMapping: BandMapping = BandMapping(red: "red", nir: "nir", green: "green", blue: "blue", scl: "scl", projTransformKey: "red"),
        sasTokenManager: SASTokenManager? = nil,
        bearerTokenManager: BearerTokenManager? = nil,
        sourceID: SourceID? = nil,
        collection: String = "sentinel-2-l2a",
        displayMode: AppSettings.DisplayMode = .fcc,
        cloudMask: Bool = true,
        sclValidClasses: Set<Int> = [4, 5],
        vegetationIndex: AppSettings.VegetationIndex = .ndvi
    ) async throws -> NDVIFrame? {
        let dateStr = item.dateString
        let srcName = sourceID?.rawValue.uppercased() ?? "?"
        // Each processItem gets its own COGReader for complete source isolation
        let cogReader = COGReader()
        do {
            // Get asset URLs using source-specific band keys
            guard let redAsset = item.assets[bandMapping.red],
                  let nirAsset = item.assets[bandMapping.nir] else {
                log.warn("\(dateStr) [\(srcName)]: missing \(bandMapping.red)/\(bandMapping.nir) assets — skipping")
                return nil
            }

            guard var redURL = URL(string: redAsset.href),
                  var nirURL = URL(string: nirAsset.href) else {
                log.warn("\(dateStr) [\(srcName)]: invalid asset URLs — skipping")
                return nil
            }

            // Optional green/blue/scl bands
            var greenURL = item.assets[bandMapping.green].flatMap { URL(string: $0.href) }
            var blueURL = item.assets[bandMapping.blue].flatMap { URL(string: $0.href) }
            var sclURL = item.assets[bandMapping.scl].flatMap { URL(string: $0.href) }

            // CDSE: translate S3 hrefs to HTTPS
            if sourceID == .cdse {
                redURL = Self.translateCDSEURL(redURL)
                nirURL = Self.translateCDSEURL(nirURL)
                greenURL = greenURL.map { Self.translateCDSEURL($0) }
                blueURL = blueURL.map { Self.translateCDSEURL($0) }
                sclURL = sclURL.map { Self.translateCDSEURL($0) }
            }

            // Sign URLs for Planetary Computer
            if let sas = sasTokenManager {
                redURL = (try? await sas.signURL(redURL, collection: collection)) ?? redURL
                nirURL = (try? await sas.signURL(nirURL, collection: collection)) ?? nirURL
                if let u = greenURL { greenURL = try? await sas.signURL(u, collection: collection) }
                if let u = blueURL { blueURL = try? await sas.signURL(u, collection: collection) }
                if let u = sclURL { sclURL = try? await sas.signURL(u, collection: collection) }
            }

            // Build auth headers for bearer token sources (CDSE, Earthdata)
            // For CDSE with S3 credentials, use SigV4 signing instead of bearer token
            var authHeaders = [String: String]()
            var requestSigner: RequestSigner?
            if sourceID == .cdse,
               let ak = KeychainService.retrieve(key: "cdse.accesskey"),
               let sk = KeychainService.retrieve(key: "cdse.secretkey"),
               !ak.isEmpty, !sk.isEmpty {
                let signer = SigV4Signer(accessKey: ak, secretKey: sk, region: "default", service: "s3")
                requestSigner = { request in signer.sign(&request) }
            } else if let bearer = bearerTokenManager {
                do {
                    authHeaders = try await bearer.authHeaders()
                } catch {
                    log.warn("\(dateStr) [\(srcName)]: bearer token failed — \(error.localizedDescription)")
                    return nil
                }
            }

            // Get projection info from asset (fallback to COG header if STAC metadata lacks it)
            let transform: [Double]
            if let stacTransform = item.projTransform(using: bandMapping), stacTransform.count >= 6 {
                transform = stacTransform
            } else {
                do {
                    if let cogTransform = try await cogReader.readGeoTransform(url: redURL, authHeaders: authHeaders, requestSigner: requestSigner),
                       cogTransform.count >= 6 {
                        transform = cogTransform
                        log.info("\(dateStr) [\(srcName)]: using COG header geo-transform (STAC metadata lacked proj:transform)")
                    } else {
                        log.warn("\(dateStr) [\(srcName)]: missing proj:transform in STAC and COG header — will retry from alternate")
                        throw COGError.missingTransform
                    }
                } catch let cogErr as COGError {
                    throw cogErr
                } catch {
                    log.warn("\(dateStr) [\(srcName)]: COG header geo-transform read failed (\(error.localizedDescription)) — will retry from alternate")
                    throw COGError.missingTransform
                }
            }

            // Calculate pixel bounds
            let pixels = utm.bboxToPixels(bbox: bbox, transform: transform)
            let pixelBounds = (
                minCol: max(0, pixels.minCol),
                minRow: max(0, pixels.minRow),
                maxCol: pixels.maxCol,
                maxRow: pixels.maxRow
            )

            let width = pixelBounds.maxCol - pixelBounds.minCol
            let height = pixelBounds.maxRow - pixelBounds.minRow
            guard width > 0 && height > 0 else {
                log.warn("\(dateStr) [\(srcName)]: zero-size crop region — skipping")
                return nil
            }

            // Cloud check using STAC metadata (eo:cloud_cover)
            let cloudPercent = item.properties.cloudCover ?? 0
            if cloudPercent > cloudThreshold {
                log.warn("\(dateStr) [\(srcName)]: \(Int(cloudPercent))% cloud — skipping")
                return nil
            }

            // Read all available bands concurrently
            async let redData = cogReader.readRegion(url: redURL, pixelBounds: pixelBounds, authHeaders: authHeaders, requestSigner: requestSigner)
            async let nirData = cogReader.readRegion(url: nirURL, pixelBounds: pixelBounds, authHeaders: authHeaders, requestSigner: requestSigner)

            let red = try await redData
            let nir = try await nirData

            // Data integrity check: verify band dimensions match expected crop size
            let redH = red.count
            let nirH = nir.count
            let redW = redH > 0 ? red[0].count : 0
            let nirW = nirH > 0 ? nir[0].count : 0
            if redH != height || redW != width || nirH != height || nirW != width {
                log.error("\(dateStr) [\(srcName)]: band size mismatch — red=\(redW)x\(redH) nir=\(nirW)x\(nirH) expected=\(width)x\(height) — SKIPPED")
                return nil
            }

            // Data integrity check: detect all-zero bands (failed download / nodata)
            var redAllZero = true, nirAllZero = true
            outerCheck: for row in stride(from: 0, to: height, by: max(1, height / 10)) {
                for col in stride(from: 0, to: width, by: max(1, width / 10)) {
                    if red[row][col] != 0 { redAllZero = false }
                    if nir[row][col] != 0 { nirAllZero = false }
                    if !redAllZero && !nirAllZero { break outerCheck }
                }
            }
            if redAllZero || nirAllZero {
                log.error("\(dateStr) [\(srcName)]: \(redAllZero ? "RED" : "") \(nirAllZero ? "NIR" : "") band all zeros — corrupt/nodata — SKIPPED")
                return nil
            }

            // Only download extra bands if needed for current display mode
            let mode = displayMode
            var green: [[UInt16]]?
            var blue: [[UInt16]]?
            if mode == .fcc || mode == .rcc || mode == .bandGreen, let gURL = greenURL {
                green = try? await cogReader.readRegion(url: gURL, pixelBounds: pixelBounds, authHeaders: authHeaders, requestSigner: requestSigner)
            }
            if mode == .rcc || mode == .bandBlue, let bURL = blueURL {
                blue = try? await cogReader.readRegion(url: bURL, pixelBounds: pixelBounds, authHeaders: authHeaders, requestSigner: requestSigner)
            }

            // Read SCL/Fmask band for cloud masking
            let sclValidValues: Set<UInt16> = Set(sclValidClasses.map { UInt16($0) })
            let isHLS = sourceID == .earthdata
            var sclMask: [[Bool]]? // true = invalid
            var sclUpsampled: [[UInt16]]? // upsampled SCL values for display
            if let sURL = sclURL {
                // S2 SCL is 20m (half resolution); HLS Fmask is same resolution as bands (30m)
                let sclBounds: (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int)
                if isHLS {
                    sclBounds = pixelBounds  // HLS: all bands at same resolution
                } else {
                    sclBounds = (
                        minCol: pixelBounds.minCol / 2,
                        minRow: pixelBounds.minRow / 2,
                        maxCol: (pixelBounds.maxCol + 1) / 2,
                        maxRow: (pixelBounds.maxRow + 1) / 2
                    )
                }
                if let sclData = try? await cogReader.readRegion(url: sURL, pixelBounds: sclBounds, authHeaders: authHeaders, requestSigner: requestSigner) {
                    // Upsample SCL mask to 10m pixel grid (nearest neighbor)
                    var mask = [[Bool]](repeating: [Bool](repeating: true, count: width), count: height)
                    var sclUp = [[UInt16]](repeating: [UInt16](repeating: 0, count: width), count: height)
                    let sclH = sclData.count
                    let sclW = sclH > 0 ? sclData[0].count : 0
                    let sclMinRow = sclBounds.minRow
                    let sclMinCol = sclBounds.minCol
                    for row in 0..<height {
                        for col in 0..<width {
                            let sclRow: Int
                            let sclCol: Int
                            if isHLS {
                                // HLS: same resolution, direct mapping
                                sclRow = min(row, sclH - 1)
                                sclCol = min(col, sclW - 1)
                            } else {
                                // S2: map 10m global pixel to 20m local SCL index
                                sclRow = min((pixelBounds.minRow + row) / 2 - sclMinRow, sclH - 1)
                                sclCol = min((pixelBounds.minCol + col) / 2 - sclMinCol, sclW - 1)
                            }
                            if sclRow >= 0 && sclRow < sclH && sclCol >= 0 && sclCol < sclW {
                                let val = sclData[sclRow][sclCol]
                                sclUp[row][col] = val
                                if isHLS {
                                    // HLS Fmask: bitmask — bit 1 = cloud, bit 2 = cloud shadow
                                    let cloudBits = (val >> 1) & 0x03
                                    mask[row][col] = cloudBits != 0
                                } else {
                                    mask[row][col] = !sclValidValues.contains(val)
                                }
                            }
                        }
                    }
                    sclMask = mask
                    sclUpsampled = sclUp
                    let maskedCount = mask.flatMap { $0 }.filter { $0 }.count
                    // Log SCL value distribution for diagnostics
                    var sclCounts = [UInt16: Int]()
                    for r in sclData { for v in r { sclCounts[v, default: 0] += 1 } }
                    let dist = sclCounts.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }.joined(separator: " ")
                    log.info("\(dateStr) [\(srcName)]: SCL \(dist)")
                    log.info("\(dateStr) [\(srcName)]: SCL mask: \(maskedCount)/\(width*height) px masked")
                }
            }

            // Build polygon mask (true = inside polygon)
            var polyPixels = [(col: Double, row: Double)]()
            let scaleX = transform[0]
            let originX = transform[2]
            let scaleY = transform[4]
            let originY = transform[5]
            for vertex in geometry.polygon {
                let utmPt = utm.forward(lon: vertex.lon, lat: vertex.lat)
                let pixCol = (utmPt.easting - originX) / scaleX - Double(pixelBounds.minCol)
                let pixRow = (utmPt.northing - originY) / scaleY - Double(pixelBounds.minRow)
                polyPixels.append((col: pixCol, row: pixRow))
            }

            // Compute VI — only SCL mask applied (no DN/reflectance filtering)
            // Per-item DN offset: AWS applies BOA offset to pixels (dnOffset=0),
            // PC serves raw ESA DNs where PB >= 04.00 has +1000 (dnOffset=-1000)
            let dnOffset = item.dnOffset
            if dnOffset != 0 {
                log.info("\(dateStr) [\(srcName)]: applying DN offset \(Int(dnOffset)) (PB=\(item.properties.processingBaseline ?? "?"))")
            }
            let viMode = vegetationIndex
            var ndvi = [[Float]](repeating: [Float](repeating: .nan, count: width), count: height)
            var validCount = 0
            var validValues = [Float]()
            var polyPixelCount = 0
            // DN diagnostics
            var redDNMin: UInt16 = .max, redDNMax: UInt16 = 0
            var nirDNMin: UInt16 = .max, nirDNMax: UInt16 = 0
            var zeroDNCount = 0
            for row in 0..<height {
                for col in 0..<width {
                    // Check polygon containment
                    guard Self.pointInPolygon(
                        x: Double(col) + 0.5, y: Double(row) + 0.5,
                        polygon: polyPixels
                    ) else { continue }
                    polyPixelCount += 1

                    // SCL mask is the ONLY mask applied
                    if cloudMask, let mask = sclMask, mask[row][col] { continue }

                    let rawRed = red[row][col]
                    let rawNir = nir[row][col]

                    // DN=0 is nodata, DN=65535 is saturated — skip both
                    if rawRed == 0 || rawNir == 0 { zeroDNCount += 1; continue }
                    if rawRed == 65535 || rawNir == 65535 { continue }

                    redDNMin = min(redDNMin, rawRed); redDNMax = max(redDNMax, rawRed)
                    nirDNMin = min(nirDNMin, rawNir); nirDNMax = max(nirDNMax, rawNir)

                    let redDN = Float(rawRed)
                    let nirDN = Float(rawNir)

                    // DN to reflectance (per-item offset for cross-source harmonization)
                    let redRefl = (redDN + dnOffset) / quantificationValue
                    let nirRefl = (nirDN + dnOffset) / quantificationValue

                    // Skip if reflectance is non-physical (negative after offset, or > 1.5)
                    if redRefl < 0 || nirRefl < 0 || redRefl > 1.5 || nirRefl > 1.5 { continue }

                    // Compute selected vegetation index
                    let val: Float
                    switch viMode {
                    case .ndvi:
                        let sum = nirRefl + redRefl
                        guard sum > 0 else { continue }
                        val = (nirRefl - redRefl) / sum
                    case .dvi:
                        val = nirRefl - redRefl
                    }
                    ndvi[row][col] = val
                    validValues.append(val)
                    validCount += 1
                }
            }

            // Log DN range for diagnostics
            if polyPixelCount > 0 {
                let unmasked = polyPixelCount - (cloudMask && sclMask != nil ? sclMask!.flatMap{$0}.filter{$0}.count : 0)
                log.info("\(dateStr) [\(srcName)] ID=\(item.id): DN red=\(redDNMin)-\(redDNMax) nir=\(nirDNMin)-\(nirDNMax) zero=\(zeroDNCount)/\(unmasked)")
            }

            let medianNDVI: Float
            if validValues.isEmpty {
                medianNDVI = 0
            } else {
                let sorted = validValues.sorted()
                let mid = sorted.count / 2
                medianNDVI = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            }

            // Drop frames with no valid data after masking
            if validCount == 0 {
                log.warn("\(dateStr) [\(srcName)]: no valid pixels after masking — dropped")
                return nil
            }

            log.success("\(dateStr) [\(srcName)]: \(validCount)/\(polyPixelCount) valid, median \(viMode.rawValue)=\(String(format: "%.3f", medianNDVI)), cloud=\(Int(cloudPercent))%")

            let date = item.date ?? Date()

            // Normalized polygon coordinates (reuse polyPixels computed above)
            let polyNorm = polyPixels.map { (x: $0.col / Double(width), y: $0.row / Double(height)) }

            return NDVIFrame(
                date: date,
                dateString: item.dateString,
                ndvi: ndvi,
                width: width,
                height: height,
                cloudFraction: cloudPercent / 100.0,
                medianNDVI: medianNDVI,
                validPixelCount: validCount,
                polyPixelCount: polyPixelCount,
                redBand: red,
                nirBand: nir,
                greenBand: green,
                blueBand: blue,
                sclBand: sclUpsampled,
                polygonNorm: polyNorm,
                greenURL: greenURL,
                blueURL: blueURL,
                pixelBounds: pixelBounds,
                sourceID: sourceID,
                sceneID: item.id,
                dnOffset: dnOffset
            )
        } catch let cogErr as COGError {
            // Rethrow HTTP errors so caller can retry from alternate source
            log.error("\(dateStr) [\(srcName)]: \(cogErr.localizedDescription)")
            throw cogErr
        } catch {
            log.error("\(dateStr) [\(srcName)]: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - GEE Processing

    /// Process a single GEE scene via the computePixels REST API.
    private func processGEEItem(
        item: STACItem,
        geometry: GeoJSONGeometry,
        utm: UTMProjection,
        bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        cloudThreshold: Double,
        geeTokenManager: GEETokenManager,
        displayMode: AppSettings.DisplayMode = .fcc,
        cloudMask: Bool = true,
        sclValidClasses: Set<Int> = [4, 5],
        vegetationIndex: AppSettings.VegetationIndex = .ndvi
    ) async throws -> NDVIFrame? {
        let dateStr = item.dateString
        let srcName = "GEE"

        // Extract GEE image ID from synthetic asset href
        let imageID: String
        if let asset = item.assets.values.first, asset.href.hasPrefix("gee://") {
            imageID = String(asset.href.dropFirst(6))
        } else {
            imageID = item.id
        }

        // Cloud check
        let cloudPercent = item.properties.cloudCover ?? 0
        if cloudPercent > cloudThreshold {
            log.warn("\(dateStr) [\(srcName)]: \(Int(cloudPercent))% cloud — skipping")
            return nil
        }

        // Calculate UTM pixel bounds and dimensions
        let corners = [
            utm.forward(lon: bbox.minLon, lat: bbox.minLat),
            utm.forward(lon: bbox.maxLon, lat: bbox.minLat),
            utm.forward(lon: bbox.minLon, lat: bbox.maxLat),
            utm.forward(lon: bbox.maxLon, lat: bbox.maxLat),
        ]
        let eastings = corners.map(\.easting)
        let northings = corners.map(\.northing)
        let minE = eastings.min()!
        let maxE = eastings.max()!
        let minN = northings.min()!
        let maxN = northings.max()!

        let resolution = 10.0
        let width = Int(ceil((maxE - minE) / resolution))
        let height = Int(ceil((maxN - minN) / resolution))
        guard width > 0 && height > 0 && width < 5000 && height < 5000 else {
            log.warn("\(dateStr) [\(srcName)]: invalid region size \(width)x\(height) — skipping")
            return nil
        }

        // GEE grid transform: top-left corner, north-up (negative scaleY)
        let gridTransform = (scaleX: resolution, scaleY: -resolution, translateX: minE, translateY: maxN)
        let crsCode = "EPSG:\(utm.epsg)"
        let projectID = KeychainService.retrieve(key: "gee.project") ?? ""
        guard !projectID.isEmpty else {
            throw GEEError.noProjectID
        }

        let geeService = GEEService(projectID: projectID, tokenManager: geeTokenManager)

        // Determine which bands to request
        var bandIds = ["B4", "B8"]  // red, nir always needed
        let mode = displayMode
        if mode == .fcc || mode == .rcc || mode == .bandGreen { bandIds.append("B3") }
        if mode == .rcc || mode == .bandBlue { bandIds.append("B2") }
        bandIds.append("SCL")

        // Fetch all bands in one computePixels call
        let result = try await geeService.fetchPixels(
            imageID: imageID,
            bandIds: bandIds,
            transform: gridTransform,
            width: width,
            height: height,
            crsCode: crsCode
        )

        guard result.bands.count == bandIds.count else {
            log.error("\(dateStr) [\(srcName)]: expected \(bandIds.count) bands, got \(result.bands.count) — skipping")
            return nil
        }

        // Map bands by name
        var bandData = [String: [UInt16]]()
        for (i, name) in bandIds.enumerated() {
            bandData[name] = result.bands[i]
        }

        guard let redFlat = bandData["B4"], let nirFlat = bandData["B8"] else {
            log.error("\(dateStr) [\(srcName)]: missing red/nir bands — skipping")
            return nil
        }

        // Convert flat arrays to 2D
        func to2D(_ flat: [UInt16]) -> [[UInt16]] {
            var arr = [[UInt16]]()
            arr.reserveCapacity(height)
            for row in 0..<height {
                let start = row * width
                let end = min(start + width, flat.count)
                if start < flat.count {
                    arr.append(Array(flat[start..<end]))
                } else {
                    arr.append([UInt16](repeating: 0, count: width))
                }
            }
            return arr
        }

        let red = to2D(redFlat)
        let nir = to2D(nirFlat)
        let green: [[UInt16]]? = bandData["B3"].map { to2D($0) }
        let blue: [[UInt16]]? = bandData["B2"].map { to2D($0) }
        let sclData: [[UInt16]]? = bandData["SCL"].map { to2D($0) }

        // Data integrity: check for all-zero bands
        var redAllZero = true, nirAllZero = true
        outerCheck: for row in stride(from: 0, to: height, by: max(1, height / 10)) {
            for col in stride(from: 0, to: width, by: max(1, width / 10)) {
                if red[row][col] != 0 { redAllZero = false }
                if nir[row][col] != 0 { nirAllZero = false }
                if !redAllZero && !nirAllZero { break outerCheck }
            }
        }
        if redAllZero || nirAllZero {
            log.error("\(dateStr) [\(srcName)]: \(redAllZero ? "RED" : "") \(nirAllZero ? "NIR" : "") band all zeros — SKIPPED")
            return nil
        }

        // Build SCL mask
        let sclValidValues: Set<UInt16> = Set(sclValidClasses.map { UInt16($0) })
        var sclMask: [[Bool]]?
        if let scl = sclData {
            var mask = [[Bool]](repeating: [Bool](repeating: true, count: width), count: height)
            for row in 0..<height {
                for col in 0..<width {
                    if row < scl.count && col < scl[row].count {
                        mask[row][col] = !sclValidValues.contains(scl[row][col])
                    }
                }
            }
            sclMask = mask
        }

        // Build polygon mask
        let scaleX = resolution
        let originX = minE
        let scaleY = -resolution
        let originY = maxN
        var polyPixels = [(col: Double, row: Double)]()
        for vertex in geometry.polygon {
            let utmPt = utm.forward(lon: vertex.lon, lat: vertex.lat)
            let pixCol = (utmPt.easting - originX) / scaleX
            let pixRow = (utmPt.northing - originY) / scaleY
            polyPixels.append((col: pixCol, row: pixRow))
        }

        // Compute VI — GEE S2_SR_HARMONIZED: DN/10000 = reflectance (no offset)
        let viMode = vegetationIndex
        var ndvi = [[Float]](repeating: [Float](repeating: .nan, count: width), count: height)
        var validCount = 0
        var validValues = [Float]()
        var polyPixelCount = 0
        var zeroDNCount = 0

        for row in 0..<height {
            for col in 0..<width {
                guard Self.pointInPolygon(
                    x: Double(col) + 0.5, y: Double(row) + 0.5,
                    polygon: polyPixels
                ) else { continue }
                polyPixelCount += 1

                if cloudMask, let mask = sclMask, mask[row][col] { continue }

                let rawRed = red[row][col]
                let rawNir = nir[row][col]

                // DN=0 is nodata, DN=65535 is saturated
                if rawRed == 0 || rawNir == 0 { zeroDNCount += 1; continue }
                if rawRed == 65535 || rawNir == 65535 { continue }

                // GEE S2_SR_HARMONIZED: reflectance = DN / 10000 (no offset)
                let redRefl = Float(rawRed) / quantificationValue
                let nirRefl = Float(rawNir) / quantificationValue

                if redRefl < 0 || nirRefl < 0 || redRefl > 1.5 || nirRefl > 1.5 { continue }

                let val: Float
                switch viMode {
                case .ndvi:
                    let sum = nirRefl + redRefl
                    guard sum > 0 else { continue }
                    val = (nirRefl - redRefl) / sum
                case .dvi:
                    val = nirRefl - redRefl
                }
                ndvi[row][col] = val
                validValues.append(val)
                validCount += 1
            }
        }

        let medianNDVI: Float
        if validValues.isEmpty {
            medianNDVI = 0
        } else {
            let sorted = validValues.sorted()
            let mid = sorted.count / 2
            medianNDVI = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }

        if validCount == 0 {
            log.warn("\(dateStr) [\(srcName)]: no valid pixels after masking — dropped")
            return nil
        }

        log.success("\(dateStr) [\(srcName)]: \(validCount)/\(polyPixelCount) valid, median \(viMode.rawValue)=\(String(format: "%.3f", medianNDVI)), cloud=\(Int(cloudPercent))%")

        let date = item.date ?? Date()
        let polyNorm = polyPixels.map { (x: $0.col / Double(width), y: $0.row / Double(height)) }

        return NDVIFrame(
            date: date,
            dateString: item.dateString,
            ndvi: ndvi,
            width: width,
            height: height,
            cloudFraction: cloudPercent / 100.0,
            medianNDVI: medianNDVI,
            validPixelCount: validCount,
            polyPixelCount: polyPixelCount,
            redBand: red,
            nirBand: nir,
            greenBand: green,
            blueBand: blue,
            sclBand: sclData,
            polygonNorm: polyNorm,
            sourceID: .gee,
            sceneID: item.id,
            dnOffset: 0
        )
    }

    /// Lazy-load missing bands for display mode change.
    @MainActor
    func loadMissingBands(for mode: AppSettings.DisplayMode) async {
        let cogReader = COGReader()
        var updated = false

        for i in 0..<frames.count {
            let frame = frames[i]
            guard let bounds = frame.pixelBounds else { continue }

            // FCC/RCC/bandGreen needs green
            if (mode == .fcc || mode == .rcc || mode == .bandGreen) && frame.greenBand == nil,
               let url = frame.greenURL {
                if let data = try? await cogReader.readRegion(url: url, pixelBounds: bounds) {
                    frames[i].greenBand = data
                    updated = true
                }
            }

            // RCC/bandBlue needs blue
            if (mode == .rcc || mode == .bandBlue) && frame.blueBand == nil,
               let url = frame.blueURL {
                if let data = try? await cogReader.readRegion(url: url, pixelBounds: bounds) {
                    frames[i].blueBand = data
                    updated = true
                }
            }
        }

        if updated {
            let bandNames = switch mode {
            case .ndvi, .bandRed, .bandNIR: "Red, NIR"
            case .fcc, .bandGreen: "Red, NIR, Green"
            case .rcc, .bandBlue: "Red, Green, Blue"
            case .scl: "SCL"
            }
            log.success("Loaded additional bands for \(mode.rawValue) (\(bandNames))")
        }
    }

    /// Recompute valid pixel stats for all frames based on current SCL settings.
    @MainActor
    func recomputeStats() {
        let sclValid = Set(settings.sclValidClasses.map { UInt16($0) })
        let useCloudMask = settings.cloudMask
        let useAOI = settings.enforceAOI
        var updated = 0

        for i in 0..<frames.count {
            let frame = frames[i]
            let w = frame.width, h = frame.height
            let poly = frame.polygonNorm.map { (col: $0.x * Double(w), row: $0.y * Double(h)) }

            var validCount = 0
            var polyCount = 0
            var validValues = [Float]()

            for row in 0..<h {
                for col in 0..<w {
                    // AOI polygon check (skip if enforceAOI is off)
                    if useAOI {
                        guard Self.pointInPolygon(x: Double(col) + 0.5, y: Double(row) + 0.5, polygon: poly) else { continue }
                    }
                    polyCount += 1

                    // SCL-only mask
                    if useCloudMask, let scl = frame.sclBand, row < scl.count, col < scl[row].count {
                        if !sclValid.contains(scl[row][col]) { continue }
                    }

                    let val = frame.ndvi[row][col]
                    guard !val.isNaN else { continue }
                    validValues.append(val)
                    validCount += 1
                }
            }

            let median: Float
            if validValues.isEmpty {
                median = 0
            } else {
                let sorted = validValues.sorted()
                let mid = sorted.count / 2
                median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            }

            if frames[i].validPixelCount != validCount || frames[i].medianNDVI != median {
                frames[i].validPixelCount = validCount
                frames[i].polyPixelCount = polyCount
                frames[i].medianNDVI = median
                updated += 1
            }
        }

        if updated > 0 {
            log.info("Recomputed stats for \(updated) frames (SCL valid=\(settings.sclValidClasses.sorted()), cloudMask=\(useCloudMask))")
        }
    }

    /// Recompute VI values for all frames (e.g., when switching NDVI↔DVI).
    @MainActor
    func recomputeVI() {
        let viMode = settings.vegetationIndex
        let useCloudMask = settings.cloudMask
        let useAOI = settings.enforceAOI
        let sclValid = Set(settings.sclValidClasses.map { UInt16($0) })

        for i in 0..<frames.count {
            let frame = frames[i]
            let w = frame.width, h = frame.height
            let poly = frame.polygonNorm.map { (col: $0.x * Double(w), row: $0.y * Double(h)) }

            var ndvi = [[Float]](repeating: [Float](repeating: .nan, count: w), count: h)
            var validCount = 0
            var validValues = [Float]()
            var polyCount = 0

            for row in 0..<h {
                for col in 0..<w {
                    if useAOI {
                        guard Self.pointInPolygon(x: Double(col) + 0.5, y: Double(row) + 0.5, polygon: poly) else { continue }
                    }
                    polyCount += 1

                    if useCloudMask, let scl = frame.sclBand, row < scl.count, col < scl[row].count {
                        if !sclValid.contains(scl[row][col]) { continue }
                    }

                    let rawRed = frame.redBand[row][col]
                    let rawNir = frame.nirBand[row][col]

                    // DN=0 is nodata, DN=65535 is saturated
                    if rawRed == 0 || rawNir == 0 || rawRed == 65535 || rawNir == 65535 { continue }

                    let redDN = Float(rawRed)
                    let nirDN = Float(rawNir)
                    let redRefl = (redDN + frame.dnOffset) / quantificationValue
                    let nirRefl = (nirDN + frame.dnOffset) / quantificationValue

                    if redRefl < 0 || nirRefl < 0 || redRefl > 1.5 || nirRefl > 1.5 { continue }

                    let val: Float
                    switch viMode {
                    case .ndvi:
                        let sum = nirRefl + redRefl
                        guard sum > 0 else { continue }
                        val = (nirRefl - redRefl) / sum
                    case .dvi:
                        val = nirRefl - redRefl
                    }
                    ndvi[row][col] = val
                    validValues.append(val)
                    validCount += 1
                }
            }

            let median: Float
            if validValues.isEmpty { median = 0 }
            else {
                let sorted = validValues.sorted()
                let mid = sorted.count / 2
                median = sorted.count % 2 == 0 ? (sorted[mid-1] + sorted[mid]) / 2 : sorted[mid]
            }

            frames[i] = NDVIFrame(
                date: frame.date, dateString: frame.dateString, ndvi: ndvi,
                width: w, height: h, cloudFraction: frame.cloudFraction,
                medianNDVI: median, validPixelCount: validCount, polyPixelCount: polyCount,
                redBand: frame.redBand, nirBand: frame.nirBand,
                greenBand: frame.greenBand, blueBand: frame.blueBand, sclBand: frame.sclBand,
                polygonNorm: frame.polygonNorm,
                greenURL: frame.greenURL, blueURL: frame.blueURL,
                pixelBounds: frame.pixelBounds, sourceID: frame.sourceID,
                dnOffset: frame.dnOffset
            )
        }
        log.info("Recomputed \(viMode.rawValue) for \(frames.count) frames")
    }

    /// Translate CDSE S3 hrefs to HTTPS URLs.
    private static func translateCDSEURL(_ url: URL) -> URL {
        let str = url.absoluteString
        if str.hasPrefix("s3://eodata/") {
            let https = str.replacingOccurrences(of: "s3://eodata/", with: "https://eodata.dataspace.copernicus.eu/")
            return URL(string: https) ?? url
        }
        return url
    }

    /// Ray-casting point-in-polygon test.
    static func pointInPolygon(x: Double, y: Double, polygon: [(col: Double, row: Double)]) -> Bool {
        let n = polygon.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let yi = polygon[i].row, xi = polygon[i].col
            let yj = polygon[j].row, xj = polygon[j].col
            if ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

}
