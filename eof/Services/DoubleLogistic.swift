import Foundation

/// Parameters for the Beck double logistic phenology model.
/// f(t) = mn + (mx - mn) * (1/(1+exp(-rsp*(t-sos))) + 1/(1+exp(rau*(t-eos))) - 1)
struct DLParams: Codable, Equatable {
    var mn: Double    // minimum NDVI (winter baseline)
    var mx: Double    // maximum NDVI (peak)
    var sos: Double   // start of season (DOY of green-up inflection)
    var rsp: Double   // rate of spring green-up
    var eos: Double   // end of season (DOY of senescence inflection)
    var rau: Double   // rate of autumn senescence
    var rmse: Double = 0  // fit quality

    /// Evaluate the double logistic at day-of-year t.
    func evaluate(t: Double) -> Double {
        let spring = 1.0 / (1.0 + exp(-rsp * (t - sos)))
        let autumn = 1.0 / (1.0 + exp(rau * (t - eos)))
        return mn + (mx - mn) * (spring + autumn - 1.0)
    }

    /// Evaluate at an array of DOYs.
    func curve(doys: [Double]) -> [Double] {
        doys.map { evaluate(t: $0) }
    }

    /// Amplitude (mx - mn).
    var delta: Double { mx - mn }

    /// Season length in days (eos - sos).
    var seasonLength: Double { eos - sos }

    /// Parameter labels for display (reparameterized).
    static let labels = ["mn", "amp", "sos", "rsp", "season", "rau"]

    /// As reparameterized array for optimizer: [mn, delta, sos, rsp, seasonLength, rau].
    var asOptArray: [Double] {
        [mn, mx - mn, sos, rsp, eos - sos, rau]
    }

    /// From reparameterized optimizer array.
    static func fromOpt(_ a: [Double]) -> DLParams {
        DLParams(mn: a[0], mx: a[0] + a[1], sos: a[2], rsp: a[3], eos: a[2] + a[4], rau: a[5])
    }
}

/// Double logistic fitting engine using Nelder-Mead optimization.
enum DoubleLogistic {

    struct DataPoint {
        let doy: Double
        let ndvi: Double
    }

    /// Estimate initial parameters from observed data.
    /// SOS defaults to ~1/4 through the DOY range if crossing detection fails.
    static func initialGuess(data: [DataPoint]) -> DLParams {
        guard !data.isEmpty else {
            return DLParams(mn: 0.1, mx: 0.6, sos: 120, rsp: 0.05, eos: 280, rau: 0.05)
        }
        let sorted = data.sorted { $0.ndvi < $1.ndvi }
        let n = sorted.count
        // Robust min/max from 10th/90th percentiles
        let mn = sorted[max(0, n / 10)].ndvi
        let mx = sorted[min(n - 1, n - 1 - n / 10)].ndvi

        let bySeason = data.sorted { $0.doy < $1.doy }
        let doyMin = bySeason.first!.doy
        let doyMax = bySeason.last!.doy
        let doyRange = doyMax - doyMin

        // Default SOS at 1/4 through dataset, EOS at 3/4
        var sos = doyMin + doyRange * 0.25
        var eos = doyMin + doyRange * 0.75

        // Try to find crossing points for more accurate estimate
        let mid = (mn + mx) / 2
        // Green-up: first crossing above midpoint
        for i in 1..<bySeason.count {
            if bySeason[i - 1].ndvi < mid && bySeason[i].ndvi >= mid {
                sos = bySeason[i].doy
                break
            }
        }
        // Senescence: last crossing below midpoint
        for i in stride(from: bySeason.count - 1, through: 1, by: -1) {
            if bySeason[i - 1].ndvi >= mid && bySeason[i].ndvi < mid {
                eos = bySeason[i].doy
                break
            }
        }

        // Sanity: ensure eos > sos with reasonable season
        if eos <= sos + 20 {
            eos = sos + max(60, doyRange * 0.5)
        }

        return DLParams(mn: mn, mx: mx, sos: sos, rsp: 0.05, eos: eos, rau: 0.05)
    }

    /// Compute RMSE for a parameter set against data (for quality reporting).
    static func rmse(params: DLParams, data: [DataPoint]) -> Double {
        guard !data.isEmpty else { return .infinity }
        var sumSq = 0.0
        for pt in data {
            let pred = params.evaluate(t: pt.doy)
            let diff = pred - pt.ndvi
            sumSq += diff * diff
        }
        return sqrt(sumSq / Double(data.count))
    }

    /// Huber loss: quadratic for |r| <= delta, linear beyond.
    /// Limits the influence of outliers on the fit.
    /// delta = 0.10 is appropriate for NDVI (residuals > 0.10 are treated as outliers).
    private static let huberDelta: Double = 0.10

    /// Compute mean Huber loss for a parameter set against data (for optimization).
    static func huberLoss(params: DLParams, data: [DataPoint], weights: [Double]? = nil) -> Double {
        guard !data.isEmpty else { return .infinity }
        let delta = huberDelta
        var sum = 0.0
        var wSum = 0.0
        for (i, pt) in data.enumerated() {
            let w = weights?[i] ?? 1.0
            let r = abs(params.evaluate(t: pt.doy) - pt.ndvi)
            if r <= delta {
                sum += w * 0.5 * r * r
            } else {
                sum += w * delta * (r - 0.5 * delta)
            }
            wSum += w
        }
        return sum / wSum
    }

    /// Fit using Nelder-Mead simplex optimization with Huber loss.
    /// The optimizer minimizes Huber loss (robust to outliers). RMSE is computed
    /// after convergence for quality reporting.
    /// Internally optimizes in reparameterized space: [mn, delta, sos, rsp, seasonLength, rau]
    /// where delta = mx - mn and seasonLength = eos - sos.
    static func fit(
        data: [DataPoint],
        initial: DLParams,
        maxIter: Int = 2000,
        minSeasonLength: Double = 0,
        maxSeasonLength: Double = 366,
        slopeSymmetry: Double = 0,
        bounds: (lo: [Double], hi: [Double])? = nil,
        weights: [Double]? = nil
    ) -> DLParams {
        let n = 6  // number of parameters
        let x0 = initial.asOptArray  // [mn, delta, sos, rsp, seasonLength, rau]

        // Bounds in reparameterized space
        let lo = bounds?.lo ?? [-0.5, 0.05, 1.0, 0.02, max(minSeasonLength, 10), 0.02]
        let hi = bounds?.hi ?? [0.8, 1.5, 365.0, 0.6, min(maxSeasonLength, 350), 0.6]

        func clamp(_ x: [Double]) -> [Double] {
            var c = x
            for i in 0..<n {
                c[i] = max(lo[i], min(hi[i], c[i]))
            }
            // Slope symmetry: constrain rau (index 5) relative to rsp (index 3)
            if slopeSymmetry > 0 {
                let frac = slopeSymmetry / 100.0
                let rsp = c[3]
                c[5] = max(rsp * (1 - frac), min(rsp * (1 + frac), c[5]))
                c[5] = max(lo[5], min(hi[5], c[5]))  // re-enforce absolute bounds
            }
            return c
        }

        func cost(_ x: [Double]) -> Double {
            let p = DLParams.fromOpt(clamp(x))
            return huberLoss(params: p, data: data, weights: weights)
        }

        // Initialize simplex
        var simplex = [[Double]]()
        simplex.append(x0)
        let scales = [0.1, 0.1, 20.0, 0.02, 20.0, 0.02]  // [mn, delta, sos, rsp, seasonLen, rau]
        for i in 0..<n {
            var pt = x0
            pt[i] += scales[i]
            simplex.append(pt)
        }
        var fvals = simplex.map { cost($0) }

        let alpha = 1.0, gamma = 2.0, rho = 0.5, sigma = 0.5
        let tol = 1e-8

        for _ in 0..<maxIter {
            // Sort
            let indices = (0...n).sorted { fvals[$0] < fvals[$1] }
            simplex = indices.map { simplex[$0] }
            fvals = indices.map { fvals[$0] }

            // Check convergence
            if fvals[n] - fvals[0] < tol { break }

            // Centroid (excluding worst)
            var centroid = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in 0..<n { centroid[j] += simplex[i][j] }
            }
            for j in 0..<n { centroid[j] /= Double(n) }

            // Reflect
            let worst = simplex[n]
            var reflected = [Double](repeating: 0, count: n)
            for j in 0..<n { reflected[j] = centroid[j] + alpha * (centroid[j] - worst[j]) }
            let fr = cost(reflected)

            if fr < fvals[0] {
                // Expand
                var expanded = [Double](repeating: 0, count: n)
                for j in 0..<n { expanded[j] = centroid[j] + gamma * (reflected[j] - centroid[j]) }
                let fe = cost(expanded)
                if fe < fr {
                    simplex[n] = expanded; fvals[n] = fe
                } else {
                    simplex[n] = reflected; fvals[n] = fr
                }
            } else if fr < fvals[n - 1] {
                simplex[n] = reflected; fvals[n] = fr
            } else {
                // Contract
                var contracted = [Double](repeating: 0, count: n)
                let best = fr < fvals[n] ? reflected : worst
                let fb = fr < fvals[n] ? fr : fvals[n]
                for j in 0..<n { contracted[j] = centroid[j] + rho * (best[j] - centroid[j]) }
                let fc = cost(contracted)
                if fc < fb {
                    simplex[n] = contracted; fvals[n] = fc
                } else {
                    // Shrink
                    for i in 1...n {
                        for j in 0..<n {
                            simplex[i][j] = simplex[0][j] + sigma * (simplex[i][j] - simplex[0][j])
                        }
                        fvals[i] = cost(simplex[i])
                    }
                }
            }
        }

        var best = DLParams.fromOpt(clamp(simplex[0]))
        // Enforce mx > mn post-optimization
        if best.mx <= best.mn { best.mx = best.mn + 0.05 }
        best.rmse = rmse(params: best, data: data)  // true RMSE for quality reporting
        return best
    }

    /// Filter out-of-phase data from adjacent growing cycles.
    /// Strategy: identify the main peak, then trim leading/trailing points that belong
    /// to a different cycle (rising at the end or falling at the start).
    static func filterCycleContamination(data: [DataPoint]) -> [DataPoint] {
        guard data.count >= 6 else { return data }
        let sorted = data.sorted { $0.doy < $1.doy }

        // Find the DOY of peak NDVI (using a 3-point moving average to smooth)
        var peakDoy = sorted[0].doy
        var peakVal = -Double.infinity
        for i in 1..<(sorted.count - 1) {
            let avg = (sorted[i - 1].ndvi + sorted[i].ndvi + sorted[i + 1].ndvi) / 3
            if avg > peakVal {
                peakVal = avg
                peakDoy = sorted[i].doy
            }
        }

        // Compute baseline: low percentile of values away from peak
        let allVals = sorted.map { $0.ndvi }.sorted()
        let baseline = allVals[max(0, allVals.count / 5)]
        let threshold = baseline + (peakVal - baseline) * 0.4

        // Trim leading points that are above threshold and DECREASING
        // (they belong to the tail end of a previous cycle)
        var startIdx = 0
        if sorted[0].ndvi > threshold && sorted[0].doy < peakDoy - 30 {
            // Check if leading values are decreasing (previous cycle's senescence)
            for i in 0..<min(sorted.count / 3, sorted.count - 1) {
                if sorted[i].ndvi > threshold && sorted[i + 1].ndvi < sorted[i].ndvi && sorted[i].doy < peakDoy - 30 {
                    startIdx = i + 1
                } else {
                    break
                }
            }
        }

        // Trim trailing points that are above threshold and INCREASING
        // (they belong to the start of a next cycle)
        var endIdx = sorted.count - 1
        if sorted.last!.ndvi > threshold && sorted.last!.doy > peakDoy + 30 {
            for i in stride(from: sorted.count - 1, through: max(sorted.count * 2 / 3, 1), by: -1) {
                if sorted[i].ndvi > threshold && sorted[i - 1].ndvi < sorted[i].ndvi && sorted[i].doy > peakDoy + 30 {
                    endIdx = i - 1
                } else {
                    break
                }
            }
        }

        if startIdx > 0 || endIdx < sorted.count - 1 {
            return Array(sorted[startIdx...endIdx])
        }
        return sorted
    }

    /// Compute weights for second-pass fitting from a first-pass DL curve.
    /// The DL curve is rescaled to [wMin, wMax] so observations near the peak of the
    /// growing season get higher weight, while off-season observations get baseline weight.
    static func secondPassWeights(data: [DataPoint], firstPass: DLParams,
                                  wMin: Double = 1.0, wMax: Double = 2.0) -> [Double] {
        let vals = data.map { firstPass.evaluate(t: $0.doy) }
        let mn = vals.min() ?? 0
        let mx = vals.max() ?? 1
        let range = mx - mn
        guard range > 1e-6 else { return [Double](repeating: 1.0, count: data.count) }
        return vals.map { wMin + (wMax - wMin) * ($0 - mn) / range }
    }

    /// Ensemble fit: run from many perturbed starting points, return all viable solutions.
    /// Perturbation is multiplicative: param * (1 + U(-p, p)) where U is uniform.
    /// Slope parameters (rsp, rau) use a separate, tighter perturbation fraction.
    static func ensembleFit(
        data: [DataPoint],
        nRuns: Int = 50,
        perturbation: Double = 0.50,
        slopePerturbation: Double = 0.10,
        minSeasonLength: Double = 0,
        maxSeasonLength: Double = 366,
        slopeSymmetry: Double = 0,
        bounds: (lo: [Double], hi: [Double])? = nil,
        secondPass: Bool = false
    ) -> (best: DLParams, ensemble: [DLParams]) {
        let filtered = filterCycleContamination(data: data)
        let guess = initialGuess(data: filtered)
        var allFits = [DLParams]()

        let p = perturbation
        let sp = slopePerturbation
        // Use provided bounds or defaults for clamping
        let blo = bounds?.lo ?? [-0.5, 0.05, 1.0, 0.02, max(minSeasonLength, 10), 0.02]
        let bhi = bounds?.hi ?? [0.8, 1.5, 365.0, 0.6, min(maxSeasonLength, 350), 0.6]

        // Run from perturbed initial conditions
        for i in 0..<nRuns {
            var perturbed = guess
            if i > 0 {
                // Multiplicative uniform perturbation: param * (1 + U(-p, p))
                perturbed.mn  += guess.mn  * Double.random(in: -p...p)
                perturbed.mx  += guess.mx  * Double.random(in: -p...p)
                perturbed.sos += guess.sos * Double.random(in: -p...p)
                perturbed.rsp += guess.rsp * Double.random(in: -sp...sp)
                perturbed.eos += guess.eos * Double.random(in: -p...p)
                perturbed.rau += guess.rau * Double.random(in: -sp...sp)
                // Clamp to physical bounds from settings
                perturbed.mn = max(blo[0], min(bhi[0], perturbed.mn))
                perturbed.mx = max(perturbed.mn + blo[1], min(perturbed.mn + bhi[1], perturbed.mx))
                perturbed.sos = max(blo[2], min(bhi[2], perturbed.sos))
                perturbed.rsp = max(blo[3], min(bhi[3], perturbed.rsp))
                perturbed.eos = max(perturbed.sos + minSeasonLength, min(perturbed.sos + maxSeasonLength, perturbed.eos))
                perturbed.rau = max(blo[5], min(bhi[5], perturbed.rau))
                // Enforce mx > mn
                if perturbed.mx <= perturbed.mn {
                    perturbed.mx = perturbed.mn + 0.1
                }
            }
            let fitted = fit(data: filtered, initial: perturbed,
                           minSeasonLength: minSeasonLength, maxSeasonLength: maxSeasonLength,
                           slopeSymmetry: slopeSymmetry, bounds: (blo, bhi))
            allFits.append(fitted)
        }

        allFits.sort { $0.rmse < $1.rmse }
        var best = allFits[0]

        // Second pass: refit with DL-derived weights
        if secondPass {
            let w = secondPassWeights(data: filtered, firstPass: best)
            best = fit(data: filtered, initial: best,
                      minSeasonLength: minSeasonLength, maxSeasonLength: maxSeasonLength,
                      slopeSymmetry: slopeSymmetry, bounds: (blo, bhi), weights: w)
        }

        // Keep solutions within 1.5x best RMSE as "viable"
        let threshold = best.rmse * 1.5
        let viable = allFits.filter { $0.rmse <= threshold }

        return (best: best, ensemble: viable)
    }

    /// Fit a single pixel's time series using the median fit as a strong prior.
    /// Applies cycle contamination filtering. Returns best fit from small ensemble.
    static func pixelFit(
        data: [DataPoint],
        medianParams: DLParams,
        settings: PhenologyFitSettings
    ) -> DLParams {
        let filtered = filterCycleContamination(data: data)
        guard filtered.count >= settings.minObservations else {
            var skip = medianParams
            skip.rmse = .infinity
            return skip
        }

        let b = settings.boundsArrays
        var bestFit = fit(data: filtered, initial: medianParams, maxIter: settings.maxIter,
                         minSeasonLength: settings.minSeasonLength, maxSeasonLength: settings.maxSeasonLength,
                         slopeSymmetry: settings.slopeSymmetry, bounds: b)

        for _ in 1..<settings.ensembleRuns {
            var perturbed = medianParams
            let p = settings.perturbation
            let sp = settings.slopePerturbation
            perturbed.mn  += medianParams.mn  * Double.random(in: -p...p)
            perturbed.mx  += medianParams.mx  * Double.random(in: -p...p)
            perturbed.sos += medianParams.sos * Double.random(in: -p...p)
            perturbed.rsp += medianParams.rsp * Double.random(in: -sp...sp)
            perturbed.eos += medianParams.eos * Double.random(in: -p...p)
            perturbed.rau += medianParams.rau * Double.random(in: -sp...sp)
            // Clamp to physical bounds from settings
            perturbed.mn  = max(b.lo[0], min(b.hi[0], perturbed.mn))
            perturbed.mx  = max(perturbed.mn + b.lo[1], min(perturbed.mn + b.hi[1], perturbed.mx))
            perturbed.sos = max(b.lo[2], min(b.hi[2], perturbed.sos))
            perturbed.rsp = max(b.lo[3], min(b.hi[3], perturbed.rsp))
            perturbed.eos = max(perturbed.sos + settings.minSeasonLength, min(perturbed.sos + settings.maxSeasonLength, perturbed.eos))
            perturbed.rau = max(b.lo[5], min(b.hi[5], perturbed.rau))
            // Enforce mx > mn
            if perturbed.mx <= perturbed.mn {
                perturbed.mx = perturbed.mn + 0.1
            }

            let candidate = fit(data: filtered, initial: perturbed, maxIter: settings.maxIter,
                              minSeasonLength: settings.minSeasonLength, maxSeasonLength: settings.maxSeasonLength,
                              slopeSymmetry: settings.slopeSymmetry, bounds: b)
            if candidate.rmse < bestFit.rmse {
                bestFit = candidate
            }
        }

        // Second pass: refit with DL-derived weights from first pass
        if settings.secondPass {
            let w = secondPassWeights(data: filtered, firstPass: bestFit,
                                      wMin: settings.secondPassWeightMin, wMax: settings.secondPassWeightMax)
            bestFit = fit(data: filtered, initial: bestFit, maxIter: settings.maxIter,
                         minSeasonLength: settings.minSeasonLength, maxSeasonLength: settings.maxSeasonLength,
                         slopeSymmetry: settings.slopeSymmetry, bounds: b, weights: w)
        }

        return bestFit
    }
}

/// Settings for per-pixel phenology fitting.
struct PhenologyFitSettings: Sendable {
    let ensembleRuns: Int
    let perturbation: Double
    let slopePerturbation: Double  // separate (tighter) perturbation for rsp/rau
    let maxIter: Int
    let rmseThreshold: Double
    let minObservations: Int
    let minSeasonLength: Double  // minimum eos - sos (days)
    let maxSeasonLength: Double  // maximum eos - sos (days)
    let slopeSymmetry: Double    // max % difference between rsp and rau (0 = unconstrained)
    // Physical parameter bounds
    let boundMnMin: Double
    let boundMnMax: Double
    let boundDeltaMin: Double
    let boundDeltaMax: Double
    let boundSosMin: Double
    let boundSosMax: Double
    let boundRspMin: Double
    let boundRspMax: Double
    let boundRauMin: Double
    let boundRauMax: Double
    let secondPass: Bool
    let secondPassWeightMin: Double
    let secondPassWeightMax: Double

    /// Build lo/hi arrays for optimizer in reparameterized space [mn, delta, sos, rsp, seasonLength, rau]
    var boundsArrays: (lo: [Double], hi: [Double]) {
        let lo = [boundMnMin, boundDeltaMin, boundSosMin, boundRspMin, max(minSeasonLength, 10), boundRauMin]
        let hi = [boundMnMax, boundDeltaMax, boundSosMax, boundRspMax, min(maxSeasonLength, 350), boundRauMax]
        return (lo, hi)
    }
}
