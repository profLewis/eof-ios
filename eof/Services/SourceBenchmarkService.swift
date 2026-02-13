import Foundation

/// Benchmarks STAC source response times.
struct SourceBenchmarkService {
    private let log = ActivityLog.shared

    /// Benchmark all enabled sources in parallel. Returns sorted by score (best first).
    func benchmarkAll(sources: [STACSourceConfig]) async -> [SourceBenchmark] {
        await withTaskGroup(of: SourceBenchmark.self) { group in
            for source in sources where source.isEnabled {
                group.addTask { await benchmark(source: source) }
            }
            var results = [SourceBenchmark]()
            for await result in group { results.append(result) }
            return results.sorted { ($0.score ?? .infinity) < ($1.score ?? .infinity) }
        }
    }

    /// Benchmark a single source: time a STAC search and a COG header fetch.
    private func benchmark(source: STACSourceConfig) async -> SourceBenchmark {
        let stac = STACService(config: source)

        // 1. Time a minimal STAC search (known location, limit 1)
        let searchLatency = await timeSearch(stac: stac)

        // 2. Time a COG header range request (first 32KB)
        var cogLatency: Double? = nil
        if let items = try? await stac.search(
            geometry: testGeometry(), startDate: "2022-08-01", endDate: "2022-08-15", maxCloudCover: 80
        ), let item = items.first {
            let mapping = source.bandMapping
            if let asset = item.assets[mapping.red], let url = URL(string: asset.href) {
                cogLatency = await timeCOGHeader(url: url, source: source)
            }
        }

        let reachable = searchLatency != nil
        log.info("Benchmark \(source.shortName): search=\(searchLatency.map { "\(Int($0))ms" } ?? "fail") cog=\(cogLatency.map { "\(Int($0))ms" } ?? "n/a")")

        return SourceBenchmark(
            sourceID: source.sourceID,
            searchLatencyMs: searchLatency,
            cogHeaderLatencyMs: cogLatency,
            isReachable: reachable,
            timestamp: Date()
        )
    }

    /// Time a STAC search (limit 1).
    private func timeSearch(stac: STACService) async -> Double? {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await stac.search(
                geometry: testGeometry(),
                startDate: "2022-08-01",
                endDate: "2022-08-15",
                maxCloudCover: 80
            )
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        } catch {
            return nil
        }
    }

    /// Time fetching first 32KB of a COG (header + IFD).
    private func timeCOGHeader(url: URL, source: STACSourceConfig) async -> Double? {
        var fetchURL = url
        // Sign URL for Planetary Computer
        if source.assetAuthType == .sasToken {
            let manager = SASTokenManager()
            fetchURL = (try? await manager.signURL(url)) ?? url
        }

        var request = URLRequest(url: fetchURL)
        request.setValue("bytes=0-32767", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15

        // Add bearer token for CDSE/Earthdata
        if source.assetAuthType == .bearerToken {
            let manager = BearerTokenManager(sourceID: source.sourceID)
            if let token = try? await manager.getToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        } catch {
            return nil
        }
    }

    /// Small test geometry (South Africa wheat field area — bundled AOI centroid).
    private func testGeometry() -> GeoJSONGeometry {
        // Simple small bbox around the default test field
        let ring: [[Double]] = [
            [28.74, -26.97],
            [28.75, -26.97],
            [28.75, -26.96],
            [28.74, -26.96],
            [28.74, -26.97],
        ]
        return GeoJSONGeometry(type: "Polygon", coordinates: [ring])
    }

    // MARK: - Stream Allocation

    /// Allocate concurrent streams proportionally to source speed (inverse latency).
    static func allocateStreams(benchmarks: [SourceBenchmark], totalStreams: Int) -> [SourceID: Int] {
        let reachable = benchmarks.filter { $0.isReachable }
        guard !reachable.isEmpty else { return [:] }

        let speeds: [(SourceID, Double)] = reachable.compactMap { b in
            guard let score = b.score, score > 0 else { return nil }
            return (b.sourceID, 1.0 / score)
        }
        guard !speeds.isEmpty else { return [:] }

        let totalSpeed = speeds.reduce(0.0) { $0 + $1.1 }
        var allocation = [SourceID: Int]()
        var allocated = 0

        for (sourceID, speed) in speeds {
            let share = max(1, Int(round(Double(totalStreams) * speed / totalSpeed)))
            allocation[sourceID] = share
            allocated += share
        }

        // Adjust if over-allocated
        while allocated > totalStreams, let maxKey = allocation.max(by: { $0.value < $1.value })?.key,
              (allocation[maxKey] ?? 0) > 1 {
            allocation[maxKey]! -= 1
            allocated -= 1
        }

        return allocation
    }
}
