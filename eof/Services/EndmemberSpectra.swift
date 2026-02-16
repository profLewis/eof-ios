import Foundation

/// Reference endmember spectra convolved to Sentinel-2 band response functions.
/// Sources: 6S radiative transfer code (green vegetation, dry sand), USGS Spectral Library (NPV).
/// Values are hemispherical-directional reflectance factors at each S2 band center wavelength.
struct EndmemberSpectrum {
    let name: String
    /// Reflectance values keyed by S2 band name, ordered by wavelength.
    let values: [(band: String, nm: Double, reflectance: Double)]

    /// Get reflectance for available bands only.
    func reflectance(forBands bands: [(band: String, nm: Double)]) -> [Double] {
        bands.compactMap { b in values.first(where: { $0.band == b.band })?.reflectance }
    }
}

/// Full-resolution (1nm) spectrum loaded from USGS Spectral Library CSV.
struct FullResolutionSpectrum {
    let name: String
    /// Wavelength (nm) and reflectance pairs, sorted by wavelength.
    let points: [(nm: Double, reflectance: Double)]

    /// Linear interpolation at arbitrary wavelength.
    func interpolated(at nm: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if nm < first.nm || nm > last.nm { return nil }
        // Binary search for bracketing interval
        var lo = 0, hi = points.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if points[mid].nm <= nm { lo = mid } else { hi = mid }
        }
        let p0 = points[lo], p1 = points[hi]
        if p1.nm == p0.nm { return p0.reflectance }
        let t = (nm - p0.nm) / (p1.nm - p0.nm)
        return p0.reflectance + t * (p1.reflectance - p0.reflectance)
    }

    /// Subsample to given step size (nm) for efficient plotting.
    func subsampled(step: Double = 5) -> [(nm: Double, reflectance: Double)] {
        guard let first = points.first, let last = points.last else { return [] }
        var result = [(nm: Double, reflectance: Double)]()
        var nm = first.nm
        while nm <= last.nm {
            if let r = interpolated(at: nm) {
                result.append((nm, r))
            }
            nm += step
        }
        return result
    }
}

/// Library of standard endmember spectra for linear spectral unmixing.
enum EndmemberLibrary {

    // MARK: - Green Vegetation (6S GroundReflectance.GreenVegetation)
    // Typical green leaf canopy (LAI ~3-4): low visible, red edge, high NIR plateau, SWIR water absorption
    static let greenVegetation = EndmemberSpectrum(
        name: "Green Vegetation",
        values: [
            ("B02", 490, 0.05),
            ("B03", 560, 0.09),
            ("B04", 665, 0.04),
            ("B05", 705, 0.06),
            ("B06", 740, 0.30),
            ("B07", 783, 0.40),
            ("B08", 842, 0.45),
            ("B8A", 865, 0.45),
            ("B11", 1610, 0.20),
            ("B12", 2190, 0.10),
        ]
    )

    // MARK: - Non-Photosynthetic Vegetation (USGS Spectral Library — dry grass/crop residue)
    // Moderate visible, no red edge, lower NIR than green veg, higher SWIR (cellulose/lignin)
    static let npv = EndmemberSpectrum(
        name: "NPV (Dry Vegetation)",
        values: [
            ("B02", 490, 0.05),
            ("B03", 560, 0.08),
            ("B04", 665, 0.10),
            ("B05", 705, 0.14),
            ("B06", 740, 0.20),
            ("B07", 783, 0.24),
            ("B08", 842, 0.26),
            ("B8A", 865, 0.26),
            ("B11", 1610, 0.30),
            ("B12", 2190, 0.22),
        ]
    )

    // MARK: - Bare Soil (6S GroundReflectance.Sand / PROSAIL)
    // Monotonically increasing from visible to SWIR, no red edge
    static let bareSoil = EndmemberSpectrum(
        name: "Bare Soil",
        values: [
            ("B02", 490, 0.12),
            ("B03", 560, 0.17),
            ("B04", 665, 0.22),
            ("B05", 705, 0.24),
            ("B06", 740, 0.26),
            ("B07", 783, 0.27),
            ("B08", 842, 0.28),
            ("B8A", 865, 0.29),
            ("B11", 1610, 0.35),
            ("B12", 2190, 0.30),
        ]
    )

    /// All default endmembers for 3-endmember unmixing.
    static let defaults: [EndmemberSpectrum] = [greenVegetation, npv, bareSoil]

    /// Available bands (subset of S2 bands that have endmember data).
    static let allBands: [(band: String, nm: Double)] = [
        ("B02", 490), ("B03", 560), ("B04", 665), ("B05", 705),
        ("B06", 740), ("B07", 783), ("B08", 842), ("B8A", 865),
        ("B11", 1610), ("B12", 2190),
    ]

    // MARK: - Full-resolution USGS spectra (for plotting)
    // Source: USGS Spectral Library Version 7 (splib07a), ASD FieldSpec, 1nm sampling.
    // Kokaly et al. 2017, USGS Data Series 1035, https://doi.org/10.3133/ds1035
    // CSV files stored in eof/Resources/Spectra/

    /// Load a full-resolution spectrum from a bundled CSV file.
    private static func loadCSV(_ resource: String) -> FullResolutionSpectrum? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "csv") else { return nil }
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var points = [(nm: Double, reflectance: Double)]()
        for line in data.split(separator: "\n").dropFirst() { // skip header
            let cols = line.split(separator: ",")
            guard cols.count >= 2,
                  let nm = Double(cols[0]),
                  let refl = Double(cols[1]),
                  refl >= 0, refl <= 1 else { continue }
            points.append((nm, refl))
        }
        return points.isEmpty ? nil : FullResolutionSpectrum(name: resource, points: points)
    }

    /// Full-resolution green vegetation (Aspen green leaf top, USGS splib07a).
    static let fullGreenVegetation: FullResolutionSpectrum? = loadCSV("green_vegetation")

    /// Full-resolution NPV (Golden dry grass GDS480, USGS splib07a).
    static let fullNPV: FullResolutionSpectrum? = loadCSV("npv_dry_grass")

    /// Full-resolution bare soil (Clean sand DWO-3-DEL2a, USGS splib07a).
    static let fullBareSoil: FullResolutionSpectrum? = loadCSV("bare_soil_sand")

    /// All full-resolution spectra, matching order of `defaults`.
    static let fullResolution: [FullResolutionSpectrum?] = [fullGreenVegetation, fullNPV, fullBareSoil]
}
