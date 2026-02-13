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
    private let baselineOffset: Float = 0.0  // AWS/PC S2 L2A data: DN/10000 = reflectance (no offset)

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
                            let stac = STACService(config: src)
                            let items = try await stac.search(
                                geometry: geometry, startDate: startDate, endDate: endDate
                            )
                            let searchMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)

                            var sasMs: Int? = nil
                            if src.assetAuthType == .sasToken {
                                let t1 = CFAbsoluteTimeGetCurrent()
                                let sas = SASTokenManager()
                                _ = try await sas.getToken()
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

            // Deduplicate by (dateString, mgrsTile), then distribute across sources round-robin
            struct TaggedItem {
                let item: STACItem
                let config: STACSourceConfig
                let key: String  // dedup key for fallback lookup
            }

            // Build a lookup: for each unique date/tile key, collect available (item, config) pairs
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

            // Assign scenes to sources — weighted by benchmark speed if available
            var taggedItems = [TaggedItem]()
            var sourceAssignCounts = [SourceID: Int]()

            // Compute target allocation weights from benchmarks (faster = more scenes)
            let benchmarks = settings.benchmarkResults
            let useWeighted = settings.smartAllocation && !benchmarks.isEmpty
            var sourceWeights = [SourceID: Double]()
            if useWeighted {
                let streamAlloc = SourceBenchmarkService.allocateStreams(
                    benchmarks: benchmarks, totalStreams: orderedKeys.count
                )
                let totalAlloc = Double(streamAlloc.values.reduce(0, +))
                for (sid, count) in streamAlloc {
                    sourceWeights[sid] = totalAlloc > 0 ? Double(count) / totalAlloc : 0
                }
                log.info("Weighted allocation: \(streamAlloc.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", "))")
            }

            // Weighted round-robin: track deficit per source, assign to most under-represented
            var sourceDeficit = [SourceID: Double]()  // positive = under-allocated
            for src in enabledSources {
                sourceDeficit[src.sourceID] = 0
            }
            var totalAssigned = 0

            for key in orderedKeys {
                guard let candidates = candidatesByKey[key] else { continue }
                totalAssigned += 1

                if useWeighted {
                    // Pick the source with the highest deficit that has a candidate
                    // Update deficits: each source "deserves" weight * totalAssigned scenes
                    for src in enabledSources {
                        let w = sourceWeights[src.sourceID] ?? (1.0 / Double(enabledSources.count))
                        let deserved = w * Double(totalAssigned)
                        let got = Double(sourceAssignCounts[src.sourceID] ?? 0)
                        sourceDeficit[src.sourceID] = deserved - got
                    }
                    // Sort candidates by deficit (highest first)
                    let ranked = candidates.sorted { a, b in
                        (sourceDeficit[a.1.sourceID] ?? 0) > (sourceDeficit[b.1.sourceID] ?? 0)
                    }
                    let pick = ranked.first!
                    taggedItems.append(TaggedItem(item: pick.0, config: pick.1, key: key))
                    sourceAssignCounts[pick.1.sourceID, default: 0] += 1
                } else {
                    // Simple round-robin fallback
                    let srcCount = enabledSources.count
                    var assigned = false
                    let rrIndex = totalAssigned % srcCount
                    for offset in 0..<srcCount {
                        let tryIdx = (rrIndex + offset) % srcCount
                        let tryID = enabledSources[tryIdx].sourceID
                        if let match = candidates.first(where: { $0.1.sourceID == tryID }) {
                            taggedItems.append(TaggedItem(item: match.0, config: match.1, key: key))
                            sourceAssignCounts[tryID, default: 0] += 1
                            assigned = true
                            break
                        }
                    }
                    if !assigned, let fallback = candidates.first {
                        taggedItems.append(TaggedItem(item: fallback.0, config: fallback.1, key: key))
                        sourceAssignCounts[fallback.1.sourceID, default: 0] += 1
                    }
                }
            }

            for src in enabledSources {
                let count = sourceAssignCounts[src.sourceID] ?? 0
                sourceSearchStatus[src.sourceID] = "\(count) assigned"
                log.info("\(src.shortName): \(count) scenes assigned")
            }

            var totalItems = taggedItems.count
            guard totalItems > 0 else {
                log.error("No Sentinel-2 items found for date range")
                throw STACError.noItems
            }

            if let first = taggedItems.first?.item, let tile = first.mgrsTile {
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
            let cogReader = COGReader()
            var processedCount = 0
            var newFrames = [NDVIFrame]()
            let maxConc = settings.maxConcurrent
            let cloudThreshold = settings.cloudThreshold

            // Create auth managers per source
            var sasManagers = [SourceID: SASTokenManager]()
            var bearerManagers = [SourceID: BearerTokenManager]()
            for src in enabledSources {
                switch src.assetAuthType {
                case .sasToken: sasManagers[src.sourceID] = SASTokenManager()
                case .bearerToken: bearerManagers[src.sourceID] = BearerTokenManager(sourceID: src.sourceID)
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

            // Process with limited concurrency, tracking stream slots and HTTP fallback
            enum ProcessResult {
                case success(NDVIFrame?, Int)  // frame (nil=skipped), slot
                case httpFailed(String, SourceID, Int, Int)  // dateKey, failedSourceID, httpCode, slot
            }

            var httpErrorCount = 0
            var retryQueue = [(item: STACItem, config: STACSourceConfig, key: String)]()
            var currentMaxConc = maxConc

            await withTaskGroup(of: ProcessResult.self) { group in
                var running = 0
                var nextSlot = 0
                var freeSlots = [Int]()

                // Helper to handle one result
                func handleResult(_ result: ProcessResult) {
                    switch result {
                    case .success(let frame, let slot):
                        if let f = frame { newFrames.append(f) }
                        processedCount += 1
                        progress = Double(processedCount) / Double(totalItems)
                        progressMessage = "Reading imagery \(processedCount)/\(totalItems)..."
                        if slot < sourceProgresses.count {
                            sourceProgresses[slot].completedItems += 1
                        }
                        freeSlots.append(slot)

                    case .httpFailed(let dateKey, let failedSrc, let code, let slot):
                        processedCount += 1
                        progress = Double(processedCount) / Double(totalItems)
                        if slot < sourceProgresses.count {
                            sourceProgresses[slot].completedItems += 1
                        }
                        freeSlots.append(slot)

                        httpErrorCount += 1
                        // On 403, try alternate source
                        if let alts = candidatesByKey[dateKey] {
                            if let alt = alts.first(where: { $0.1.sourceID != failedSrc }) {
                                log.warn("\(alt.0.dateString): \(failedSrc.rawValue.uppercased()) HTTP \(code), retrying from \(alt.1.shortName)")
                                retryQueue.append((item: alt.0, config: alt.1, key: dateKey))
                                totalItems += 1  // adjust total for the retry
                            }
                        }
                        // If many 403s, reduce concurrency
                        if code == 403 && httpErrorCount == 5 {
                            currentMaxConc = max(2, currentMaxConc / 2)
                            log.warn("Rate limiting detected (\(httpErrorCount) x 403) — reducing concurrency to \(currentMaxConc)")
                        }
                    }
                    running -= 1
                }

                for tagged in taggedItems {
                    if self.isCancelled { group.cancelAll(); break }

                    // Wait while paused
                    while self.isPaused && !self.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if self.isCancelled { group.cancelAll(); break }

                    while running >= currentMaxConc {
                        if let result = await group.next() {
                            handleResult(result)
                        }
                    }

                    let cfg = tagged.config
                    let dateKey = tagged.key
                    let slot = freeSlots.isEmpty ? nextSlot : freeSlots.removeFirst()
                    if freeSlots.isEmpty && nextSlot < maxConc { nextSlot += 1 }
                    if slot < sourceProgresses.count {
                        sourceProgresses[slot].currentSource = cfg.shortName
                    }

                    group.addTask {
                        do {
                            let frame = try await self.processItem(
                                item: tagged.item, geometry: geometry,
                                utm: utm, bbox: bbox, cogReader: cogReader,
                                cloudThreshold: cloudThreshold,
                                bandMapping: cfg.bandMapping,
                                sasTokenManager: sasManagers[cfg.sourceID],
                                bearerTokenManager: bearerManagers[cfg.sourceID],
                                sourceID: cfg.sourceID
                            )
                            return .success(frame, slot)
                        } catch let err as COGError {
                            if case .httpError(let code) = err {
                                return .httpFailed(dateKey, cfg.sourceID, code, slot)
                            }
                            return .success(nil, slot)
                        } catch {
                            return .success(nil, slot)
                        }
                    }
                    running += 1
                }

                // Process retries (items that failed from primary source)
                while !retryQueue.isEmpty {
                    if self.isCancelled { group.cancelAll(); break }

                    while self.isPaused && !self.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if self.isCancelled { group.cancelAll(); break }

                    while running >= currentMaxConc {
                        if let result = await group.next() {
                            handleResult(result)
                        }
                    }

                    let retry = retryQueue.removeFirst()
                    let cfg = retry.config
                    let slot = freeSlots.isEmpty ? nextSlot : freeSlots.removeFirst()
                    if freeSlots.isEmpty && nextSlot < maxConc { nextSlot += 1 }
                    if slot < sourceProgresses.count {
                        sourceProgresses[slot].currentSource = "\(cfg.shortName) retry"
                    }

                    group.addTask {
                        do {
                            let frame = try await self.processItem(
                                item: retry.item, geometry: geometry,
                                utm: utm, bbox: bbox, cogReader: cogReader,
                                cloudThreshold: cloudThreshold,
                                bandMapping: cfg.bandMapping,
                                sasTokenManager: sasManagers[cfg.sourceID],
                                bearerTokenManager: bearerManagers[cfg.sourceID],
                                sourceID: cfg.sourceID
                            )
                            return .success(frame, slot)
                        } catch {
                            return .success(nil, slot)  // don't retry twice
                        }
                    }
                    running += 1
                }

                // Collect remaining
                for await result in group {
                    handleResult(result)
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
        let stacService = STACService(config: sourceConfig)
        let bandMapping = sourceConfig.bandMapping
        let sasManager: SASTokenManager? = sourceConfig.assetAuthType == .sasToken ? SASTokenManager() : nil
        let utm = UTMProjection.zoneFor(lon: centroid.lon, lat: centroid.lat)
        let bbox = geometry.bbox
        let cogReader = COGReader()
        let maxConc = settings.maxConcurrent
        let cloudThreshold = settings.cloudThreshold

        var allNewItems = [STACItem]()
        for range in fetchRanges {
            log.info("Searching \(range.start) to \(range.end)...")
            if let items = try? await stacService.search(
                geometry: geometry, startDate: range.start, endDate: range.end
            ) {
                // Skip items we already have
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
                    try? await self.processItem(
                        item: item, geometry: geometry,
                        utm: utm, bbox: bbox, cogReader: cogReader,
                        cloudThreshold: cloudThreshold,
                        bandMapping: bandMapping,
                        sasTokenManager: sasManager,
                        sourceID: sourceConfig.sourceID
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
        cogReader: COGReader,
        cloudThreshold: Double,
        bandMapping: BandMapping = BandMapping(red: "red", nir: "nir", green: "green", blue: "blue", scl: "scl", projTransformKey: "red"),
        sasTokenManager: SASTokenManager? = nil,
        bearerTokenManager: BearerTokenManager? = nil,
        sourceID: SourceID? = nil
    ) async throws -> NDVIFrame? {
        let dateStr = item.dateString
        let srcName = sourceID?.rawValue.uppercased() ?? "?"
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
                redURL = (try? await sas.signURL(redURL)) ?? redURL
                nirURL = (try? await sas.signURL(nirURL)) ?? nirURL
                if let u = greenURL { greenURL = try? await sas.signURL(u) }
                if let u = blueURL { blueURL = try? await sas.signURL(u) }
                if let u = sclURL { sclURL = try? await sas.signURL(u) }
            }

            // Build auth headers for bearer token sources (CDSE, Earthdata)
            var authHeaders = [String: String]()
            if let bearer = bearerTokenManager {
                authHeaders = (try? await bearer.authHeaders()) ?? [:]
            }

            // Get projection info from asset
            guard let transform = item.projTransform(using: bandMapping),
                  transform.count >= 6 else {
                log.warn("\(dateStr) [\(srcName)]: missing proj:transform — skipping")
                return nil
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
            async let redData = cogReader.readRegion(url: redURL, pixelBounds: pixelBounds, authHeaders: authHeaders)
            async let nirData = cogReader.readRegion(url: nirURL, pixelBounds: pixelBounds, authHeaders: authHeaders)

            let red = try await redData
            let nir = try await nirData

            // Only download extra bands if needed for current display mode
            let mode = settings.displayMode
            var green: [[UInt16]]?
            var blue: [[UInt16]]?
            if mode == .fcc || mode == .rcc, let gURL = greenURL {
                green = try? await cogReader.readRegion(url: gURL, pixelBounds: pixelBounds, authHeaders: authHeaders)
            }
            if mode == .rcc, let bURL = blueURL {
                blue = try? await cogReader.readRegion(url: bURL, pixelBounds: pixelBounds, authHeaders: authHeaders)
            }

            // Read SCL/Fmask band for cloud masking
            let sclValidValues: Set<UInt16> = Set(settings.sclValidClasses.map { UInt16($0) })
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
                if let sclData = try? await cogReader.readRegion(url: sURL, pixelBounds: sclBounds, authHeaders: authHeaders) {
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

            // Compute NDVI — only SCL mask applied (no DN/reflectance filtering)
            var ndvi = [[Float]](repeating: [Float](repeating: .nan, count: width), count: height)
            var validCount = 0
            var validValues = [Float]()
            var polyPixelCount = 0
            for row in 0..<height {
                for col in 0..<width {
                    // Check polygon containment
                    guard Self.pointInPolygon(
                        x: Double(col) + 0.5, y: Double(row) + 0.5,
                        polygon: polyPixels
                    ) else { continue }
                    polyPixelCount += 1

                    // SCL mask is the ONLY mask applied
                    if settings.cloudMask, let mask = sclMask, mask[row][col] { continue }

                    let redDN = Float(red[row][col])
                    let nirDN = Float(nir[row][col])

                    // DN to reflectance
                    let redRefl = (redDN + baselineOffset) / quantificationValue
                    let nirRefl = (nirDN + baselineOffset) / quantificationValue

                    // Compute NDVI (allow all values including negative)
                    let sum = nirRefl + redRefl
                    if sum != 0 {
                        let val = (nirRefl - redRefl) / sum
                        ndvi[row][col] = min(1, max(-1, val))
                        validValues.append(ndvi[row][col])
                        validCount += 1
                    }
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

            // Drop frames with no valid data after masking
            if validCount == 0 {
                log.warn("\(dateStr) [\(srcName)]: no valid pixels after masking — dropped")
                return nil
            }

            log.success("\(dateStr) [\(srcName)]: \(validCount)/\(polyPixelCount) valid, median=\(String(format: "%.3f", medianNDVI)), cloud=\(Int(cloudPercent))%")

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
                sourceID: sourceID
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

    /// Lazy-load missing bands for display mode change.
    @MainActor
    func loadMissingBands(for mode: AppSettings.DisplayMode) async {
        let cogReader = COGReader()
        var updated = false

        for i in 0..<frames.count {
            let frame = frames[i]
            guard let bounds = frame.pixelBounds else { continue }

            // FCC needs green
            if (mode == .fcc || mode == .rcc) && frame.greenBand == nil,
               let url = frame.greenURL {
                if let data = try? await cogReader.readRegion(url: url, pixelBounds: bounds) {
                    frames[i].greenBand = data
                    updated = true
                }
            }

            // RCC needs blue
            if mode == .rcc && frame.blueBand == nil,
               let url = frame.blueURL {
                if let data = try? await cogReader.readRegion(url: url, pixelBounds: bounds) {
                    frames[i].blueBand = data
                    updated = true
                }
            }
        }

        if updated {
            let bandNames = switch mode {
            case .ndvi: "Red, NIR"
            case .fcc: "Red, NIR, Green"
            case .rcc: "Red, Green, Blue"
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
