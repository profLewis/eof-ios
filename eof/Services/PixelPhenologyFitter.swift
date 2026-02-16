import Foundation

/// Orchestrates parallel per-pixel double logistic fitting.
enum PixelPhenologyFitter {

    /// Run per-pixel DL fitting across all valid pixels.
    static func fitAllPixels(
        frames: [NDVIFrame],
        medianParams: DLParams,
        settings: PhenologyFitSettings,
        polygon: [(x: Double, y: Double)],
        enforceAOI: Bool = true,
        pixelCoverageThreshold: Double = 0.01,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async -> PixelPhenologyResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let first = frames.first else {
            return PixelPhenologyResult(width: 0, height: 0, pixels: [],
                                        medianFit: medianParams, computeTimeSeconds: 0)
        }
        let width = first.width
        let height = first.height
        // Use continuous DOY to handle year-boundary data
        let refYear = Calendar.current.component(.year, from: first.date)
        let doys = frames.map { Double($0.continuousDOY(referenceYear: refYear)) }
        let poly = polygon.map { (col: $0.x, row: $0.y) }
        // Scale normalized polygon to pixel coordinates for coverage check
        let polyPx = poly.map { (col: $0.col * Double(width), row: $0.row * Double(height)) }

        // Pre-extract per-pixel time series (serial, once)
        struct PixelWork: Sendable {
            let row: Int
            let col: Int
            let data: [DoubleLogistic.DataPoint]
        }

        var workItems = [PixelWork]()
        for row in 0..<height {
            for col in 0..<width {
                // Check polygon containment — skip if enforceAOI is off
                if enforceAOI {
                    guard NDVIProcessor.pixelInAOI(
                        col: col, row: row,
                        polygon: polyPx,
                        threshold: pixelCoverageThreshold
                    ) else { continue }
                }

                // Extract time series for this pixel
                var series = [DoubleLogistic.DataPoint]()
                for (fi, frame) in frames.enumerated() {
                    guard row < frame.height, col < frame.width else { continue }
                    let val = frame.ndvi[row][col]
                    guard !val.isNaN else { continue }
                    series.append(DoubleLogistic.DataPoint(doy: doys[fi], ndvi: Double(val)))
                }
                workItems.append(PixelWork(row: row, col: col, data: series))
            }
        }

        let totalWork = workItems.count
        let progressActor = ProgressActor(total: totalWork, onProgress: onProgress)

        // Fit pixels with limited concurrency to avoid freezing the UI
        var results = [[PixelPhenology?]](
            repeating: [PixelPhenology?](repeating: nil, count: width),
            count: height
        )

        let medParams = medianParams
        let fitSettings = settings
        // Limit parallel workers to half the cores (leave headroom for UI)
        let maxWorkers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        // Process in chunks — each worker handles a batch of pixels serially
        let chunkSize = max(1, (totalWork + maxWorkers - 1) / maxWorkers)
        let chunks = stride(from: 0, to: totalWork, by: chunkSize).map { start in
            Array(workItems[start..<min(start + chunkSize, totalWork)])
        }

        let fitted: [PixelPhenology] = await withTaskGroup(of: [PixelPhenology].self) { group in
            for chunk in chunks {
                group.addTask {
                    var batch = [PixelPhenology]()
                    for item in chunk {
                        if Task.isCancelled { break }
                        let row = item.row, col = item.col, data = item.data

                        if data.count < fitSettings.minObservations {
                            await progressActor.increment()
                            var px = PixelPhenology(
                                row: row, col: col,
                                params: medParams,
                                nValidObs: data.count,
                                fitQuality: .skipped
                            )
                            px.rejectionDetail = PixelPhenology.RejectionDetail(
                                reason: .skipped,
                                observationCount: data.count,
                                rmse: nil,
                                rmseThreshold: Double(fitSettings.minObservations),
                                clusterDistance: nil,
                                clusterThreshold: nil,
                                paramZScores: nil
                            )
                            batch.append(px)
                            continue
                        }

                        let fitted = DoubleLogistic.pixelFit(
                            data: data,
                            medianParams: medParams,
                            settings: fitSettings
                        )

                        let quality: PixelPhenology.FitQuality =
                            fitted.rmse < fitSettings.rmseThreshold ? .good : .poor

                        await progressActor.increment()
                        var px = PixelPhenology(
                            row: row, col: col,
                            params: fitted,
                            nValidObs: data.count,
                            fitQuality: quality
                        )
                        if quality == .poor {
                            px.rejectionDetail = PixelPhenology.RejectionDetail(
                                reason: .poor,
                                observationCount: data.count,
                                rmse: fitted.rmse,
                                rmseThreshold: fitSettings.rmseThreshold,
                                clusterDistance: nil,
                                clusterThreshold: nil,
                                paramZScores: nil
                            )
                        }
                        batch.append(px)
                    }
                    return batch
                }
            }

            var collected = [PixelPhenology]()
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            return collected
        }

        for px in fitted {
            results[px.row][px.col] = px
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        return PixelPhenologyResult(
            width: width, height: height,
            pixels: results,
            medianFit: medianParams,
            computeTimeSeconds: elapsed
        )
    }
}

/// Thread-safe progress counter.
private actor ProgressActor {
    let total: Int
    let onProgress: @Sendable (Double) -> Void
    var completed: Int = 0

    init(total: Int, onProgress: @Sendable @escaping (Double) -> Void) {
        self.total = total
        self.onProgress = onProgress
    }

    func increment() {
        completed += 1
        if completed % 50 == 0 || completed == total {
            onProgress(Double(completed) / Double(total))
        }
    }
}
