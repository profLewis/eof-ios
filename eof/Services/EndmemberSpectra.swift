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
}
