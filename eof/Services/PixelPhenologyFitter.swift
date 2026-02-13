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
        onProgress: @Sendable @escaping (Double) -> Void
    ) async -> PixelPhenologyResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let first = frames.first else {
            return PixelPhenologyResult(width: 0, height: 0, pixels: [],
                                        medianFit: medianParams, computeTimeSeconds: 0)
        }
        let width = first.width
        let height = first.height
        let doys = frames.map { Double($0.dayOfYear) }
        let poly = polygon.map { (col: $0.x, row: $0.y) }

        // Pre-extract per-pixel time series (serial, once)
        struct PixelWork: Sendable {
            let row: Int
            let col: Int
            let data: [DoubleLogistic.DataPoint]
        }

        var workItems = [PixelWork]()
        for row in 0..<height {
            for col in 0..<width {
                // Check polygon containment (normalized coords) — skip if enforceAOI is off
                if enforceAOI {
                    let x = (Double(col) + 0.5) / Double(width)
                    let y = (Double(row) + 0.5) / Double(height)
                    guard NDVIProcessor.pointInPolygon(x: x, y: y, polygon: poly) else { continue }
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

        // Fit all pixels in parallel
        var results = [[PixelPhenology?]](
            repeating: [PixelPhenology?](repeating: nil, count: width),
            count: height
        )

        // Use nonisolated sendable closure workaround
        let medParams = medianParams
        let fitSettings = settings

        let fitted: [PixelPhenology] = await withTaskGroup(of: PixelPhenology.self) { group in
            for item in workItems {
                group.addTask {
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
                        return px
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
                    return px
                }
            }

            var collected = [PixelPhenology]()
            for await result in group {
                collected.append(result)
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
