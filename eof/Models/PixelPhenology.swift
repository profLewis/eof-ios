import Foundation

/// Per-pixel double logistic fit result.
struct PixelPhenology {
    let row: Int
    let col: Int
    let params: DLParams
    let nValidObs: Int
    let fitQuality: FitQuality
    var rejectionDetail: RejectionDetail?

    enum FitQuality: String {
        case good
        case poor
        case skipped
        case outlier
    }

    /// Detail about why a pixel was rejected (nil for good-fit pixels).
    struct RejectionDetail {
        let reason: FitQuality
        let observationCount: Int
        let rmse: Double?
        let rmseThreshold: Double?
        let clusterDistance: Double?
        let clusterThreshold: Double?
        let paramZScores: [String: Double]?

        var humanReadable: String {
            switch reason {
            case .skipped:
                return "Insufficient observations (\(observationCount))"
            case .poor:
                let r = rmse.map { String(format: "%.4f", $0) } ?? "?"
                let t = rmseThreshold.map { String(format: "%.4f", $0) } ?? "?"
                return "Poor fit (RMSE \(r) > \(t))"
            case .outlier:
                let d = clusterDistance.map { String(format: "%.1f", $0) } ?? "?"
                let t = clusterThreshold.map { String(format: "%.1f", $0) } ?? "?"
                return "Outlier parameters (distance \(d) > \(t))"
            case .good:
                return "Good fit"
            }
        }
    }
}

/// Complete per-pixel phenology result grid.
struct PixelPhenologyResult {
    let width: Int
    let height: Int
    let pixels: [[PixelPhenology?]]  // [row][col], nil = outside AOI
    let medianFit: DLParams
    let computeTimeSeconds: Double

    /// Extract a 2D parameter map for a given parameter.
    func parameterMap(_ param: PhenologyParameter) -> [[Float]] {
        var map = [[Float]](repeating: [Float](repeating: .nan, count: width), count: height)
        for row in 0..<height {
            for col in 0..<width {
                guard let px = pixels[row][col],
                      px.fitQuality == .good else { continue }
                map[row][col] = Float(param.extract(from: px.params))
            }
        }
        return map
    }

    /// Summary statistics.
    var goodCount: Int {
        pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .good }.count
    }
    var poorCount: Int {
        pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .poor }.count
    }
    var skippedCount: Int {
        pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .skipped }.count
    }
    var outlierCount: Int {
        pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .outlier }.count
    }

    /// Parameter uncertainty: IQR (interquartile range) of each parameter across good-fit pixels.
    /// Returns (median, iqr) for each of the 6 DL parameters.
    func parameterUncertainty() -> [(name: String, median: Double, iqr: Double)] {
        let goodPixels = pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .good }
        guard goodPixels.count >= 3 else { return [] }

        let names = ["mn", "amp", "sos", "rsp", "season", "rau"]
        let extractors: [(DLParams) -> Double] = [
            { $0.mn }, { $0.delta }, { $0.sos }, { $0.rsp }, { $0.seasonLength }, { $0.rau }
        ]

        return zip(names, extractors).map { name, extract in
            let values = goodPixels.map { extract($0.params) }.sorted()
            let n = values.count
            guard n > 0 else { return (name: name, median: 0, iqr: 0) }
            let median = n == 1 ? values[0] : (n % 2 == 0
                ? (values[n / 2 - 1] + values[n / 2]) / 2
                : values[n / 2])
            let q1 = values[max(0, n / 4)]
            let q3 = values[min(n - 1, 3 * n / 4)]
            return (name: name, median: median, iqr: q3 - q1)
        }
    }

    /// A 2D map of rejection reason codes for rendering:
    /// 0 = good/nil, 1 = poor, 2 = outlier, 3 = skipped
    func rejectionReasonMap() -> [[Float]] {
        var map = [[Float]](repeating: [Float](repeating: Float.nan, count: width), count: height)
        for row in 0..<height {
            for col in 0..<width {
                guard let px = pixels[row][col] else { continue }
                switch px.fitQuality {
                case .good:   map[row][col] = 0
                case .poor:   map[row][col] = 1
                case .outlier: map[row][col] = 2
                case .skipped: map[row][col] = 3
                }
            }
        }
        return map
    }

    /// Compute filtered median NDVI per frame, excluding non-good pixels.
    func filteredMedianNDVI(frames: [NDVIFrame]) -> [Float] {
        frames.map { frame in
            var goodValues = [Float]()
            for row in 0..<min(height, frame.height) {
                for col in 0..<min(width, frame.width) {
                    guard let px = pixels[row][col], px.fitQuality == .good else { continue }
                    let val = frame.ndvi[row][col]
                    guard !val.isNaN else { continue }
                    goodValues.append(val)
                }
            }
            guard !goodValues.isEmpty else { return Float.nan }
            goodValues.sort()
            let n = goodValues.count
            return n % 2 == 0
                ? (goodValues[n / 2 - 1] + goodValues[n / 2]) / 2
                : goodValues[n / 2]
        }
    }

    /// Reclassify pixels based on a new RMSE threshold without re-running fits.
    /// Pixels previously classified as poor/good are reclassified by comparing their RMSE
    /// to the new threshold. Skipped/outlier pixels are left unchanged.
    func reclassified(rmseThreshold: Double) -> PixelPhenologyResult {
        var newPixels = pixels
        for row in 0..<height {
            for col in 0..<width {
                guard let px = pixels[row][col] else { continue }
                let q = px.fitQuality
                guard q == .good || q == .poor else { continue }
                let shouldBeGood = px.params.rmse < rmseThreshold
                let newQuality: PixelPhenology.FitQuality = shouldBeGood ? .good : .poor
                if newQuality != q {
                    var reclassified = PixelPhenology(
                        row: row, col: col,
                        params: px.params,
                        nValidObs: px.nValidObs,
                        fitQuality: newQuality
                    )
                    if newQuality == .poor {
                        reclassified.rejectionDetail = PixelPhenology.RejectionDetail(
                            reason: .poor,
                            observationCount: px.nValidObs,
                            rmse: px.params.rmse,
                            rmseThreshold: rmseThreshold,
                            clusterDistance: nil,
                            clusterThreshold: nil,
                            paramZScores: nil
                        )
                    }
                    newPixels[row][col] = reclassified
                }
            }
        }
        return PixelPhenologyResult(
            width: width, height: height,
            pixels: newPixels,
            medianFit: medianFit,
            computeTimeSeconds: computeTimeSeconds
        )
    }

    /// Cluster filter: identify outlier pixels using robust Mahalanobis-like distance
    /// with spatial regularization.
    ///
    /// **Algorithm:**
    /// 1. Compute median and MAD (median absolute deviation) of each DL parameter
    ///    (mn, mx, sos, rsp, eos, rau) across all good-fit pixels.
    /// 2. For each good-fit pixel, compute a normalized distance: the RMS of
    ///    per-parameter z-scores (|value - median| / MAD).
    /// 3. Pixels with distance > `threshold` are initially flagged as candidate outliers.
    /// 4. **Spatial regularization pass:** For each candidate outlier, count its
    ///    8-connected neighbors that are good-fit and *not* candidate outliers.
    ///    If the fraction of good neighbors >= `spatialRescueFraction` (default 0.5),
    ///    the pixel is "rescued" — kept as good despite its statistical distance.
    ///    This prevents isolated pixels from being incorrectly flagged when surrounded
    ///    by spatially coherent good fits.
    ///
    /// - Parameters:
    ///   - threshold: Number of MADs beyond which a pixel is a candidate outlier (default 4.0).
    ///   - spatialRescueFraction: Fraction of valid 8-neighbors that must be non-outlier
    ///     to rescue a candidate outlier (default 0.5).
    /// - Returns: A new `PixelPhenologyResult` with outlier pixels re-classified.
    func clusterFiltered(threshold: Double = 4.0, spatialRescueFraction: Double = 0.5) -> PixelPhenologyResult {
        // Collect parameter vectors from good-fit pixels
        let goodPixels = pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .good }
        guard goodPixels.count >= 5 else { return self }

        // Extract parameter arrays
        let paramKeys: [(DLParams) -> Double] = [
            { $0.mn }, { $0.mx }, { $0.sos }, { $0.rsp }, { $0.eos }, { $0.rau }
        ]
        let nParams = paramKeys.count

        // Compute median and MAD for each parameter
        var medians = [Double](repeating: 0, count: nParams)
        var mads = [Double](repeating: 0, count: nParams)

        for (i, key) in paramKeys.enumerated() {
            let values = goodPixels.map { key($0.params) }.sorted()
            let n = values.count
            medians[i] = n % 2 == 0
                ? (values[n / 2 - 1] + values[n / 2]) / 2
                : values[n / 2]
            let deviations = values.map { abs($0 - medians[i]) }.sorted()
            mads[i] = n % 2 == 0
                ? (deviations[n / 2 - 1] + deviations[n / 2]) / 2
                : deviations[n / 2]
            // Avoid zero MAD (all identical values)
            if mads[i] < 1e-10 { mads[i] = 1e-10 }
        }

        // Step 1: Compute normalized distance for each pixel → candidate outlier grid
        var distances = [[Double]](repeating: [Double](repeating: 0, count: width), count: height)
        var isCandidate = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)
        var isGood = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)

        for row in 0..<height {
            for col in 0..<width {
                guard let px = pixels[row][col], px.fitQuality == .good else { continue }
                isGood[row][col] = true

                var sumSq = 0.0
                for (i, key) in paramKeys.enumerated() {
                    let z = (key(px.params) - medians[i]) / mads[i]
                    sumSq += z * z
                }
                let dist = sqrt(sumSq / Double(nParams))
                distances[row][col] = dist
                isCandidate[row][col] = dist > threshold
            }
        }

        // Step 2: Spatial regularization — rescue candidates with mostly good neighbors
        let offsets = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
        var isOutlier = isCandidate  // start from candidates, then rescue some

        for row in 0..<height {
            for col in 0..<width {
                guard isCandidate[row][col] else { continue }

                var goodNeighbors = 0
                var totalNeighbors = 0
                for (dr, dc) in offsets {
                    let nr = row + dr, nc = col + dc
                    guard nr >= 0, nr < height, nc >= 0, nc < width else { continue }
                    guard isGood[nr][nc] else { continue }
                    totalNeighbors += 1
                    if !isCandidate[nr][nc] {
                        goodNeighbors += 1
                    }
                }
                // Rescue if enough good neighbors
                if totalNeighbors > 0 {
                    let goodFrac = Double(goodNeighbors) / Double(totalNeighbors)
                    if goodFrac >= spatialRescueFraction {
                        isOutlier[row][col] = false
                    }
                }
            }
        }

        // Step 3: Apply final outlier flags with rejection detail
        let paramNames = ["mn", "amp", "sos", "rsp", "season", "rau"]
        var newPixels = pixels
        for row in 0..<height {
            for col in 0..<width {
                guard let px = pixels[row][col], px.fitQuality == .good else { continue }
                if isOutlier[row][col] {
                    // Compute per-parameter z-scores for this pixel
                    var zScores = [String: Double]()
                    for (i, key) in paramKeys.enumerated() {
                        zScores[paramNames[i]] = abs(key(px.params) - medians[i]) / mads[i]
                    }
                    var outlierPx = PixelPhenology(
                        row: row, col: col,
                        params: px.params,
                        nValidObs: px.nValidObs,
                        fitQuality: .outlier
                    )
                    outlierPx.rejectionDetail = PixelPhenology.RejectionDetail(
                        reason: .outlier,
                        observationCount: px.nValidObs,
                        rmse: px.params.rmse,
                        rmseThreshold: nil,
                        clusterDistance: distances[row][col],
                        clusterThreshold: threshold,
                        paramZScores: zScores
                    )
                    newPixels[row][col] = outlierPx
                }
            }
        }

        return PixelPhenologyResult(
            width: width, height: height,
            pixels: newPixels,
            medianFit: medianFit,
            computeTimeSeconds: computeTimeSeconds
        )
    }
}

/// Phenology parameters that can be mapped spatially.
enum PhenologyParameter: String, CaseIterable {
    case sos = "SOS"
    case seasonLength = "Season"
    case delta = "Amp"
    case mn = "Min"
    case rsp = "Green-up"
    case rau = "Senescence"
    case rmse = "RMSE"
    // Spectral unmixing fraction maps (per-frame, animated)
    case fveg = "FVC"
    case fnpv = "NPV"
    case fsoil = "Soil"
    case unmixRMSE = "Unmix RMSE"

    /// True for phenology params derived from DL fit (static per-pixel maps).
    var isPhenology: Bool {
        switch self {
        case .sos, .seasonLength, .delta, .mn, .rsp, .rau, .rmse: return true
        case .fveg, .fnpv, .fsoil, .unmixRMSE: return false
        }
    }

    /// True for spectral unmixing fraction params (per-frame animated maps).
    var isFraction: Bool { !isPhenology }

    /// Phenology cases only (for DL fit parameter display).
    static var phenologyCases: [PhenologyParameter] {
        allCases.filter { $0.isPhenology }
    }

    /// Fraction cases only (for spectral unmixing display).
    static var fractionCases: [PhenologyParameter] {
        allCases.filter { $0.isFraction }
    }

    func extract(from p: DLParams) -> Double {
        switch self {
        case .sos: return p.sos
        case .seasonLength: return p.eos - p.sos
        case .delta: return p.mx - p.mn
        case .mn: return p.mn
        case .rsp: return p.rsp
        case .rau: return p.rau
        case .rmse: return p.rmse
        case .fveg, .fnpv, .fsoil, .unmixRMSE: return 0 // not applicable
        }
    }
}
