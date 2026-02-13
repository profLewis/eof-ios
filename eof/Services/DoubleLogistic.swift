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

    /// Parameter labels for display.
    static let labels = ["mn", "mx", "sos", "rsp", "eos", "rau"]

    /// As array (for optimizer).
    var asArray: [Double] {
        [mn, mx, sos, rsp, eos, rau]
    }

    /// From array.
    static func from(_ a: [Double]) -> DLParams {
        DLParams(mn: a[0], mx: a[1], sos: a[2], rsp: a[3], eos: a[4], rau: a[5])
    }
}

/// Double logistic fitting engine using Nelder-Mead optimization.
enum DoubleLogistic {

    struct DataPoint {
        let doy: Double
        let ndvi: Double
    }

    /// Estimate initial parameters from observed data.
    static func initialGuess(data: [DataPoint]) -> DLParams {
        guard !data.isEmpty else {
            return DLParams(mn: 0.1, mx: 0.6, sos: 120, rsp: 0.05, eos: 280, rau: 0.05)
        }
        let sorted = data.sorted { $0.ndvi < $1.ndvi }
        let n = sorted.count
        // Robust min/max from 10th/90th percentiles
        let mn = sorted[max(0, n / 10)].ndvi
        let mx = sorted[min(n - 1, n - 1 - n / 10)].ndvi

        // Find approximate green-up: DOY where NDVI crosses midpoint rising
        let mid = (mn + mx) / 2
        let bySeason = data.sorted { $0.doy < $1.doy }
        var sos: Double = 120
        var eos: Double = 280
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

        return DLParams(mn: mn, mx: mx, sos: sos, rsp: 0.05, eos: eos, rau: 0.05)
    }

    /// Compute RMSE for a parameter set against data.
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

    /// Fit using Nelder-Mead simplex optimization.
    static func fit(
        data: [DataPoint],
        initial: DLParams,
        maxIter: Int = 2000,
        minSeasonLength: Double = 0,
        maxSeasonLength: Double = 366
    ) -> DLParams {
        let n = 6  // number of parameters
        let x0 = initial.asArray

        // Parameter bounds (for clamping)
        let lo = [-0.5, 0.0, 1.0, 0.001, 100.0, 0.001]
        let hi = [0.8, 1.2, 250.0, 0.5, 366.0, 0.5]

        func clamp(_ x: [Double]) -> [Double] {
            var c = x
            for i in 0..<n {
                c[i] = max(lo[i], min(hi[i], c[i]))
            }
            return c
        }

        func cost(_ x: [Double]) -> Double {
            let p = DLParams.from(clamp(x))
            var c = rmse(params: p, data: data)
            // Penalise season lengths outside allowed range
            let seasonLen = p.eos - p.sos
            if seasonLen < minSeasonLength {
                c += (minSeasonLength - seasonLen) * 0.01
            } else if seasonLen > maxSeasonLength {
                c += (seasonLen - maxSeasonLength) * 0.01
            }
            return c
        }

        // Initialize simplex
        var simplex = [[Double]]()
        simplex.append(x0)
        let scales = [0.1, 0.1, 20.0, 0.02, 20.0, 0.02]
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

        var best = DLParams.from(clamp(simplex[0]))
        best.rmse = fvals[0]
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

    /// Ensemble fit: run from many perturbed starting points, return all viable solutions.
    static func ensembleFit(
        data: [DataPoint],
        nRuns: Int = 50,
        minSeasonLength: Double = 0,
        maxSeasonLength: Double = 366
    ) -> (best: DLParams, ensemble: [DLParams]) {
        let filtered = filterCycleContamination(data: data)
        let guess = initialGuess(data: filtered)
        var allFits = [DLParams]()

        // Run from perturbed initial conditions
        for i in 0..<nRuns {
            var perturbed = guess
            if i > 0 {
                perturbed.mn += Double.random(in: -0.15...0.15)
                perturbed.mx += Double.random(in: -0.15...0.15)
                perturbed.sos += Double.random(in: -40...40)
                perturbed.rsp += Double.random(in: -0.03...0.03)
                perturbed.eos += Double.random(in: -40...40)
                perturbed.rau += Double.random(in: -0.03...0.03)
                // Clamp
                perturbed.mn = max(-0.5, min(0.8, perturbed.mn))
                perturbed.mx = max(0.0, min(1.2, perturbed.mx))
                perturbed.sos = max(1, min(250, perturbed.sos))
                perturbed.rsp = max(0.001, min(0.5, perturbed.rsp))
                perturbed.eos = max(100, min(366, perturbed.eos))
                perturbed.rau = max(0.001, min(0.5, perturbed.rau))
            }
            let fitted = fit(data: filtered, initial: perturbed,
                           minSeasonLength: minSeasonLength, maxSeasonLength: maxSeasonLength)
            allFits.append(fitted)
        }

        allFits.sort { $0.rmse < $1.rmse }
        let best = allFits[0]

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

        var bestFit = fit(data: filtered, initial: medianParams, maxIter: settings.maxIter,
                         minSeasonLength: settings.minSeasonLength, maxSeasonLength: settings.maxSeasonLength)

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
            // Clamp to bounds
            perturbed.mn  = max(-0.5, min(0.8, perturbed.mn))
            perturbed.mx  = max(0.0, min(1.2, perturbed.mx))
            perturbed.sos = max(1, min(250, perturbed.sos))
            perturbed.rsp = max(0.001, min(0.5, perturbed.rsp))
            perturbed.eos = max(100, min(366, perturbed.eos))
            perturbed.rau = max(0.001, min(0.5, perturbed.rau))

            let candidate = fit(data: filtered, initial: perturbed, maxIter: settings.maxIter,
                              minSeasonLength: settings.minSeasonLength, maxSeasonLength: settings.maxSeasonLength)
            if candidate.rmse < bestFit.rmse {
                bestFit = candidate
            }
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
}
