import Foundation

/// A known crop-growing location with season information.
struct CropFieldSample {
    let lat: Double
    let lon: Double
    let crop: String
    let region: String
    let plantingMonth: Int   // typical sowing month (1-12)
    let harvestMonth: Int    // typical harvest month (1-12)
}

/// Crop map sources — each provides a curated set of real agricultural locations.
enum CropMapSource: String, CaseIterable, Identifiable {
    case usaCDL = "US Cropland"
    case euCropMap = "EU Cropland"
    case southAfrica = "South Africa"
    case india = "India"
    case china = "China"
    case brazil = "Brazil"
    case australia = "Australia"
    case global = "Global (Mixed)"

    var id: String { rawValue }

    var samples: [CropFieldSample] {
        switch self {
        case .usaCDL: return Self.usa
        case .euCropMap: return Self.eu
        case .southAfrica: return Self.za
        case .india: return Self.ind
        case .china: return Self.cn
        case .brazil: return Self.br
        case .australia: return Self.au
        case .global: return Self.glob
        }
    }

    // MARK: - US Cropland (CDL regions)
    private static let usa: [CropFieldSample] = [
        CropFieldSample(lat: 42.03, lon: -93.47, crop: "Maize", region: "Iowa", plantingMonth: 4, harvestMonth: 10),
        CropFieldSample(lat: 38.78, lon: -99.32, crop: "Winter Wheat", region: "Kansas", plantingMonth: 9, harvestMonth: 6),
        CropFieldSample(lat: 41.13, lon: -100.77, crop: "Maize", region: "Nebraska", plantingMonth: 4, harvestMonth: 10),
        CropFieldSample(lat: 40.06, lon: -89.45, crop: "Soybean", region: "Illinois", plantingMonth: 5, harvestMonth: 10),
        CropFieldSample(lat: 46.88, lon: -96.79, crop: "Spring Wheat", region: "Minnesota", plantingMonth: 4, harvestMonth: 8),
        CropFieldSample(lat: 33.45, lon: -90.84, crop: "Cotton", region: "Mississippi", plantingMonth: 4, harvestMonth: 10),
        CropFieldSample(lat: 39.42, lon: -121.93, crop: "Rice", region: "California", plantingMonth: 4, harvestMonth: 9),
        CropFieldSample(lat: 46.92, lon: -98.68, crop: "Sunflower", region: "North Dakota", plantingMonth: 5, harvestMonth: 9),
        CropFieldSample(lat: 40.27, lon: -86.13, crop: "Maize", region: "Indiana", plantingMonth: 4, harvestMonth: 10),
        CropFieldSample(lat: 32.35, lon: -101.48, crop: "Cotton", region: "Texas", plantingMonth: 4, harvestMonth: 10),
        CropFieldSample(lat: 34.46, lon: -91.55, crop: "Rice", region: "Arkansas", plantingMonth: 4, harvestMonth: 9),
        CropFieldSample(lat: 47.65, lon: -109.63, crop: "Spring Wheat", region: "Montana", plantingMonth: 4, harvestMonth: 8),
    ]

    // MARK: - EU Cropland
    private static let eu: [CropFieldSample] = [
        CropFieldSample(lat: 48.13, lon: 1.68, crop: "Winter Wheat", region: "Beauce, France", plantingMonth: 10, harvestMonth: 7),
        CropFieldSample(lat: 52.42, lon: 13.08, crop: "Winter Wheat", region: "Brandenburg, Germany", plantingMonth: 10, harvestMonth: 7),
        CropFieldSample(lat: 39.47, lon: -2.93, crop: "Barley", region: "Castilla-La Mancha, Spain", plantingMonth: 11, harvestMonth: 6),
        CropFieldSample(lat: 45.05, lon: 11.08, crop: "Maize", region: "Po Valley, Italy", plantingMonth: 4, harvestMonth: 9),
        CropFieldSample(lat: 53.85, lon: 20.48, crop: "Winter Wheat", region: "Masuria, Poland", plantingMonth: 10, harvestMonth: 7),
        CropFieldSample(lat: 44.12, lon: 26.08, crop: "Winter Wheat", region: "Wallachian Plain, Romania", plantingMonth: 10, harvestMonth: 7),
        CropFieldSample(lat: 52.53, lon: 5.45, crop: "Potato", region: "Flevoland, Netherlands", plantingMonth: 3, harvestMonth: 9),
        CropFieldSample(lat: 42.43, lon: 25.63, crop: "Sunflower", region: "Thrace, Bulgaria", plantingMonth: 4, harvestMonth: 9),
        CropFieldSample(lat: 46.92, lon: 20.33, crop: "Maize", region: "Great Plain, Hungary", plantingMonth: 4, harvestMonth: 9),
        CropFieldSample(lat: 56.27, lon: 9.52, crop: "Barley", region: "Jutland, Denmark", plantingMonth: 3, harvestMonth: 8),
    ]

    // MARK: - South Africa
    private static let za: [CropFieldSample] = [
        CropFieldSample(lat: -28.73, lon: 26.22, crop: "Winter Wheat", region: "Free State", plantingMonth: 5, harvestMonth: 11),
        CropFieldSample(lat: -25.47, lon: 29.22, crop: "Maize", region: "Mpumalanga", plantingMonth: 10, harvestMonth: 4),
        CropFieldSample(lat: -29.62, lon: 30.38, crop: "Sugarcane", region: "KwaZulu-Natal", plantingMonth: 9, harvestMonth: 6),
        CropFieldSample(lat: -33.58, lon: 18.88, crop: "Winter Wheat", region: "Western Cape", plantingMonth: 5, harvestMonth: 11),
        CropFieldSample(lat: -23.90, lon: 29.45, crop: "Sorghum", region: "Limpopo", plantingMonth: 10, harvestMonth: 4),
        CropFieldSample(lat: -26.68, lon: 25.28, crop: "Sunflower", region: "North West", plantingMonth: 11, harvestMonth: 5),
    ]

    // MARK: - India
    private static let ind: [CropFieldSample] = [
        CropFieldSample(lat: 30.90, lon: 75.85, crop: "Winter Wheat", region: "Punjab", plantingMonth: 11, harvestMonth: 4),
        CropFieldSample(lat: 29.96, lon: 76.88, crop: "Rice", region: "Haryana", plantingMonth: 6, harvestMonth: 10),
        CropFieldSample(lat: 26.85, lon: 80.91, crop: "Sugarcane", region: "Uttar Pradesh", plantingMonth: 2, harvestMonth: 12),
        CropFieldSample(lat: 20.93, lon: 76.70, crop: "Cotton", region: "Maharashtra", plantingMonth: 6, harvestMonth: 11),
        CropFieldSample(lat: 23.25, lon: 77.41, crop: "Soybean", region: "Madhya Pradesh", plantingMonth: 6, harvestMonth: 10),
        CropFieldSample(lat: 26.92, lon: 70.90, crop: "Mustard", region: "Rajasthan", plantingMonth: 10, harvestMonth: 2),
        CropFieldSample(lat: 15.83, lon: 80.43, crop: "Rice", region: "Andhra Pradesh", plantingMonth: 6, harvestMonth: 11),
        CropFieldSample(lat: 22.30, lon: 70.78, crop: "Groundnut", region: "Gujarat", plantingMonth: 6, harvestMonth: 10),
    ]

    // MARK: - China
    private static let cn: [CropFieldSample] = [
        CropFieldSample(lat: 46.63, lon: 126.63, crop: "Soybean", region: "Heilongjiang", plantingMonth: 5, harvestMonth: 9),
        CropFieldSample(lat: 34.76, lon: 113.65, crop: "Winter Wheat", region: "Henan", plantingMonth: 10, harvestMonth: 6),
        CropFieldSample(lat: 36.68, lon: 117.00, crop: "Maize", region: "Shandong", plantingMonth: 6, harvestMonth: 9),
        CropFieldSample(lat: 33.28, lon: 120.16, crop: "Rice", region: "Jiangsu", plantingMonth: 5, harvestMonth: 10),
        CropFieldSample(lat: 30.59, lon: 114.31, crop: "Rice", region: "Hubei", plantingMonth: 4, harvestMonth: 9),
        CropFieldSample(lat: 30.57, lon: 104.07, crop: "Rice", region: "Sichuan", plantingMonth: 4, harvestMonth: 9),
        CropFieldSample(lat: 39.47, lon: 75.99, crop: "Cotton", region: "Xinjiang", plantingMonth: 4, harvestMonth: 10),
        CropFieldSample(lat: 43.65, lon: 116.05, crop: "Spring Wheat", region: "Inner Mongolia", plantingMonth: 4, harvestMonth: 8),
    ]

    // MARK: - Brazil
    private static let br: [CropFieldSample] = [
        CropFieldSample(lat: -12.68, lon: -55.78, crop: "Soybean", region: "Mato Grosso", plantingMonth: 10, harvestMonth: 2),
        CropFieldSample(lat: -24.05, lon: -51.55, crop: "Maize", region: "Parana", plantingMonth: 9, harvestMonth: 2),
        CropFieldSample(lat: -29.92, lon: -52.43, crop: "Rice", region: "Rio Grande do Sul", plantingMonth: 10, harvestMonth: 3),
        CropFieldSample(lat: -15.93, lon: -49.25, crop: "Soybean", region: "Goias", plantingMonth: 10, harvestMonth: 2),
        CropFieldSample(lat: -12.13, lon: -44.99, crop: "Cotton", region: "Bahia", plantingMonth: 11, harvestMonth: 5),
        CropFieldSample(lat: -21.17, lon: -45.00, crop: "Coffee", region: "Minas Gerais", plantingMonth: 9, harvestMonth: 8),
    ]

    // MARK: - Australia
    private static let au: [CropFieldSample] = [
        CropFieldSample(lat: -33.87, lon: 147.22, crop: "Winter Wheat", region: "NSW", plantingMonth: 5, harvestMonth: 11),
        CropFieldSample(lat: -31.95, lon: 117.86, crop: "Winter Wheat", region: "Western Australia", plantingMonth: 5, harvestMonth: 11),
        CropFieldSample(lat: -19.59, lon: 147.14, crop: "Sugarcane", region: "Queensland", plantingMonth: 8, harvestMonth: 6),
        CropFieldSample(lat: -34.28, lon: 138.63, crop: "Barley", region: "South Australia", plantingMonth: 5, harvestMonth: 11),
        CropFieldSample(lat: -36.36, lon: 143.79, crop: "Canola", region: "Victoria", plantingMonth: 4, harvestMonth: 11),
        CropFieldSample(lat: -41.45, lon: 146.18, crop: "Potato", region: "Tasmania", plantingMonth: 10, harvestMonth: 3),
    ]

    // MARK: - Global (Mixed)
    private static let glob: [CropFieldSample] = [
        CropFieldSample(lat: 30.78, lon: 31.00, crop: "Rice", region: "Nile Delta, Egypt", plantingMonth: 5, harvestMonth: 10),
        CropFieldSample(lat: -0.28, lon: 36.07, crop: "Maize", region: "Rift Valley, Kenya", plantingMonth: 3, harvestMonth: 8),
        CropFieldSample(lat: 11.59, lon: 37.39, crop: "Teff", region: "Amhara, Ethiopia", plantingMonth: 6, harvestMonth: 11),
        CropFieldSample(lat: -34.60, lon: -61.28, crop: "Soybean", region: "Pampas, Argentina", plantingMonth: 11, harvestMonth: 4),
        CropFieldSample(lat: 49.44, lon: 32.06, crop: "Winter Wheat", region: "Cherkasy, Ukraine", plantingMonth: 9, harvestMonth: 7),
        CropFieldSample(lat: 37.87, lon: 32.49, crop: "Winter Wheat", region: "Konya, Turkey", plantingMonth: 10, harvestMonth: 7),
        CropFieldSample(lat: 31.52, lon: 73.08, crop: "Winter Wheat", region: "Punjab, Pakistan", plantingMonth: 11, harvestMonth: 4),
        CropFieldSample(lat: 14.35, lon: 100.57, crop: "Rice", region: "Central Plain, Thailand", plantingMonth: 5, harvestMonth: 11),
    ]

    /// Unique crop names available in this region.
    var availableCrops: [String] {
        Array(Set(samples.map { $0.crop })).sorted()
    }

    /// Typical field width (meters) for this region. Varies with agricultural practice.
    var typicalFieldWidth: Double {
        switch self {
        case .usaCDL: return 500       // large US pivot/row-crop fields
        case .brazil: return 600       // large mechanised farms
        case .australia: return 500
        case .euCropMap: return 300    // smaller European parcels
        case .southAfrica: return 400
        case .india: return 200        // small-holder dominated
        case .china: return 250
        case .global: return 350
        }
    }

    /// Pick a random field from this source, optionally filtered by crop.
    func randomField(crop: String? = nil) -> CropFieldSample {
        let pool = crop == nil ? samples : samples.filter { $0.crop == crop }
        let base = pool.randomElement() ?? samples.randomElement() ?? samples[0]
        let jitterLat = Double.random(in: -0.005...0.005)
        let jitterLon = Double.random(in: -0.005...0.005)
        return CropFieldSample(
            lat: base.lat + jitterLat,
            lon: base.lon + jitterLon,
            crop: base.crop,
            region: base.region,
            plantingMonth: base.plantingMonth,
            harvestMonth: base.harvestMonth
        )
    }

    /// Generate a field polygon (rectangular, slightly rotated) for a sample.
    func fieldPolygon(for sample: CropFieldSample) -> [(lat: Double, lon: Double)] {
        let w = typicalFieldWidth
        let aspect = Double.random(in: 1.2...2.0) // fields are usually longer than wide
        let halfW = w / 2.0
        let halfH = (w * aspect) / 2.0
        let rotation = Double.random(in: -30...30) * .pi / 180 // slight rotation

        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(sample.lat * .pi / 180.0)

        // Corner offsets in meters, then rotate
        let corners: [(dx: Double, dy: Double)] = [
            (-halfW, -halfH), (halfW, -halfH), (halfW, halfH), (-halfW, halfH)
        ]
        return corners.map { c in
            let rx = c.dx * cos(rotation) - c.dy * sin(rotation)
            let ry = c.dx * sin(rotation) + c.dy * cos(rotation)
            return (lat: sample.lat + ry / metersPerDegLat, lon: sample.lon + rx / metersPerDegLon)
        }
    }

    /// Find the nearest crop field sample within a given radius (km) of a coordinate.
    static func nearestField(lat: Double, lon: Double, radiusKm: Double = 50) -> (sample: CropFieldSample, source: CropMapSource, distKm: Double)? {
        var best: (sample: CropFieldSample, source: CropMapSource, distKm: Double)?
        for source in CropMapSource.allCases {
            for sample in source.samples {
                let dLat = (sample.lat - lat) * 111.32
                let dLon = (sample.lon - lon) * 111.32 * cos(lat * .pi / 180)
                let dist = sqrt(dLat * dLat + dLon * dLon)
                if dist <= radiusKm {
                    if best == nil || dist < best!.distKm {
                        best = (sample, source, dist)
                    }
                }
            }
        }
        return best
    }

    /// Compute date range covering the growing season with 1-month padding.
    static func dateRange(plantingMonth: Int, harvestMonth: Int, year: Int? = nil) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let yr = year ?? (cal.component(.year, from: Date()) - 1)

        let startMonth = plantingMonth > 1 ? plantingMonth - 1 : 12
        let startYear = plantingMonth > 1 ? yr : yr - 1

        let endMonth = harvestMonth < 12 ? harvestMonth + 1 : 1
        let crossesYearBoundary = harvestMonth < plantingMonth
        let endYear = crossesYearBoundary ? yr + 1 : yr
        let adjustedEndYear = harvestMonth < 12 ? endYear : endYear + 1

        let start = cal.date(from: DateComponents(year: startYear, month: startMonth, day: 1))
            ?? Date(timeIntervalSince1970: 0)
        let end = cal.date(from: DateComponents(year: adjustedEndYear, month: endMonth, day: 28))
            ?? Date()
        return (start, end)
    }
}
