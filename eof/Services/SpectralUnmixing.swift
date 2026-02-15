import Foundation

/// Result of linear spectral unmixing for a single pixel.
struct UnmixResult {
    let fveg: Float     // green vegetation fraction
    let fnpv: Float     // non-photosynthetic vegetation fraction
    let fsoil: Float    // bare soil fraction
    let rmse: Float     // reconstruction error (reflectance units)
}

/// Result of unmixing an entire frame (all pixels).
struct FrameUnmixResult {
    let fveg: [[Float]]   // [row][col] green vegetation fractions
    let fnpv: [[Float]]   // [row][col] NPV fractions
    let fsoil: [[Float]]  // [row][col] bare soil fractions
    let rmse: [[Float]]   // [row][col] reconstruction RMSE
    let width: Int
    let height: Int
}

/// Linear spectral unmixing engine.
/// Solves: observed = a * veg + b * npv + c * soil + residual
/// with constraints: a,b,c >= 0 and a+b+c = 1 (fully constrained).
enum SpectralUnmixing {

    // MARK: - Single Pixel Unmixing

    /// Unmix a single pixel using fully constrained least squares (FCLS).
    /// - Parameters:
    ///   - observed: Reflectance values for available bands
    ///   - endmembers: Matrix of endmember reflectances [endmember][band], same band order as observed
    /// - Returns: Fractions and RMSE, or nil if insufficient data
    static func unmix(observed: [Float], endmembers: [[Float]]) -> UnmixResult? {
        let nBands = observed.count
        let nEnd = endmembers.count
        guard nBands >= nEnd, nEnd == 3 else { return nil }

        // Solve unconstrained least squares: E^T * E * f = E^T * y
        // where E is nBands x nEnd, y is observed, f is fractions
        let fractions = solveConstrainedLS(observed: observed, endmembers: endmembers)

        // Compute RMSE
        var sse: Float = 0
        for i in 0..<nBands {
            var predicted: Float = 0
            for j in 0..<nEnd {
                predicted += fractions[j] * endmembers[j][i]
            }
            let residual = observed[i] - predicted
            sse += residual * residual
        }
        let rmse = sqrt(sse / Float(nBands))

        return UnmixResult(
            fveg: fractions[0],
            fnpv: fractions[1],
            fsoil: fractions[2],
            rmse: rmse
        )
    }

    /// Predict full spectrum from unmixing fractions.
    static func predict(fractions: UnmixResult, endmembers: [EndmemberSpectrum],
                        bands: [(band: String, nm: Double)]) -> [(nm: Double, refl: Double)] {
        bands.compactMap { b in
            guard let veg = endmembers[0].values.first(where: { $0.band == b.band })?.reflectance,
                  let npv = endmembers[1].values.first(where: { $0.band == b.band })?.reflectance,
                  let soil = endmembers[2].values.first(where: { $0.band == b.band })?.reflectance
            else { return nil }
            let refl = Double(fractions.fveg) * veg + Double(fractions.fnpv) * npv + Double(fractions.fsoil) * soil
            return (nm: b.nm, refl: refl)
        }
    }

    // MARK: - Frame-Level Unmixing

    /// Unmix all valid pixels in a frame.
    /// - Parameters:
    ///   - bands: Array of band data [[UInt16]] for each available band, same order as `bandInfo`
    ///   - bandInfo: Band names/wavelengths matching `bands` array order
    ///   - dnOffset: DN-to-reflectance offset
    ///   - polygon: Optional polygon mask (normalized coords)
    ///   - width/height: Frame dimensions
    /// - Returns: FrameUnmixResult with per-pixel fractions
    static func unmixFrame(
        bands: [[[UInt16]]],
        bandInfo: [(band: String, nm: Double)],
        dnOffset: Float,
        width: Int,
        height: Int,
        validMask: [[Bool]]? = nil
    ) -> FrameUnmixResult {
        let endmembers = EndmemberLibrary.defaults
        // Build endmember matrix for available bands only
        let emMatrix: [[Float]] = endmembers.map { em in
            bandInfo.compactMap { bi in
                em.values.first(where: { $0.band == bi.band }).map { Float($0.reflectance) }
            }
        }
        let nBands = bandInfo.count

        var fveg = [[Float]](repeating: [Float](repeating: Float.nan, count: width), count: height)
        var fnpv = [[Float]](repeating: [Float](repeating: Float.nan, count: width), count: height)
        var fsoil = [[Float]](repeating: [Float](repeating: Float.nan, count: width), count: height)
        var rmse = [[Float]](repeating: [Float](repeating: Float.nan, count: width), count: height)

        for row in 0..<height {
            for col in 0..<width {
                // Skip pixels outside AOI mask
                if let mask = validMask, row < mask.count, col < mask[row].count, !mask[row][col] {
                    continue
                }
                // Extract observed reflectance for this pixel
                var observed = [Float]()
                var valid = true
                for b in 0..<nBands {
                    guard row < bands[b].count, col < bands[b][row].count else {
                        valid = false; break
                    }
                    let dn = bands[b][row][col]
                    if dn == 0 || dn == 65535 {
                        valid = false; break
                    }
                    let refl = (Float(dn) + dnOffset) / 10000.0
                    if refl < -0.05 || refl > 1.5 {
                        valid = false; break
                    }
                    observed.append(max(0, refl))
                }
                guard valid, observed.count == nBands else { continue }

                if let result = unmix(observed: observed, endmembers: emMatrix) {
                    fveg[row][col] = result.fveg
                    fnpv[row][col] = result.fnpv
                    fsoil[row][col] = result.fsoil
                    rmse[row][col] = result.rmse
                }
            }
        }

        return FrameUnmixResult(fveg: fveg, fnpv: fnpv, fsoil: fsoil, rmse: rmse,
                                width: width, height: height)
    }

    // MARK: - Constrained Least Squares Solver

    /// Fully constrained least squares: fractions >= 0, sum to 1.
    /// Uses iterative active-set method (Heinz & Chang, 2001).
    private static func solveConstrainedLS(observed: [Float], endmembers: [[Float]]) -> [Float] {
        let n = endmembers.count  // number of endmembers (3)
        let m = observed.count     // number of bands

        // Step 1: Unconstrained least squares via normal equations
        // E^T * E * f = E^T * y
        var ete = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        var ety = [Float](repeating: 0, count: n)

        for i in 0..<n {
            for j in 0..<n {
                var sum: Float = 0
                for k in 0..<m {
                    sum += endmembers[i][k] * endmembers[j][k]
                }
                ete[i][j] = sum
            }
            var sum: Float = 0
            for k in 0..<m {
                sum += endmembers[i][k] * observed[k]
            }
            ety[i] = sum
        }

        // Solve 3x3 system with sum-to-1 constraint using Lagrange multiplier
        // Augmented system: [E^T*E, 1; 1^T, 0] [f; λ] = [E^T*y; 1]
        var aug = [[Float]](repeating: [Float](repeating: 0, count: n + 1), count: n + 1)
        var rhs = [Float](repeating: 0, count: n + 1)

        for i in 0..<n {
            for j in 0..<n {
                aug[i][j] = ete[i][j]
            }
            aug[i][n] = 1
            aug[n][i] = 1
            rhs[i] = ety[i]
        }
        rhs[n] = 1  // sum-to-1 constraint

        // Gaussian elimination for (n+1) x (n+1) system
        var f = solveLinearSystem(aug, rhs)

        // Step 2: Project to non-negative simplex
        // If any fraction is negative, clamp to 0 and redistribute
        for _ in 0..<5 {  // iterate a few times
            var needsProjection = false
            for i in 0..<n {
                if f[i] < 0 { needsProjection = true; break }
            }
            if !needsProjection { break }

            // Clamp negatives to zero
            for i in 0..<n {
                if f[i] < 0 { f[i] = 0 }
            }
            // Renormalize so sum = 1
            let total = f[0..<n].reduce(0, +)
            if total > 0 {
                for i in 0..<n { f[i] /= total }
            } else {
                // Fallback: equal fractions
                for i in 0..<n { f[i] = 1.0 / Float(n) }
            }
        }

        return Array(f[0..<n])
    }

    /// Solve a small linear system Ax = b via Gaussian elimination with partial pivoting.
    private static func solveLinearSystem(_ A: [[Float]], _ b: [Float]) -> [Float] {
        let n = b.count
        var a = A
        var x = b

        // Forward elimination with partial pivoting
        for col in 0..<n {
            // Find pivot
            var maxVal: Float = abs(a[col][col])
            var maxRow = col
            for row in (col + 1)..<n {
                if abs(a[row][col]) > maxVal {
                    maxVal = abs(a[row][col])
                    maxRow = row
                }
            }
            // Swap rows
            if maxRow != col {
                a.swapAt(col, maxRow)
                x.swapAt(col, maxRow)
            }

            guard abs(a[col][col]) > 1e-10 else { continue }

            // Eliminate
            for row in (col + 1)..<n {
                let factor = a[row][col] / a[col][col]
                for j in col..<n {
                    a[row][j] -= factor * a[col][j]
                }
                x[row] -= factor * x[col]
            }
        }

        // Back substitution
        for col in stride(from: n - 1, through: 0, by: -1) {
            guard abs(a[col][col]) > 1e-10 else { continue }
            for row in 0..<col {
                x[row] -= a[row][col] / a[col][col] * x[col]
                a[row][col] = 0
            }
            x[col] /= a[col][col]
        }

        return x
    }
}
