import Foundation
import CoreGraphics

/// A single NDVI observation for a date.
struct NDVIFrame: Identifiable, Codable {
    let id: UUID
    let date: Date
    let dateString: String
    let ndvi: [[Float]]     // 2D array [row][col], NaN for masked pixels
    let width: Int
    let height: Int
    let cloudFraction: Double
    var medianNDVI: Float
    var validPixelCount: Int
    var polyPixelCount: Int      // total pixels inside polygon (for % valid calculation)
    /// Raw band DN values for FCC/RCC rendering
    let redBand: [[UInt16]]
    let nirBand: [[UInt16]]
    var greenBand: [[UInt16]]?
    var blueBand: [[UInt16]]?
    var sclBand: [[UInt16]]?
    /// Polygon outline in normalized image coordinates (0-1 range)
    var polygonNormX: [Double] = []
    var polygonNormY: [Double] = []
    /// Asset URLs for lazy band loading
    var greenURL: URL?
    var blueURL: URL?
    /// Pixel bounds for lazy band loading
    var pixelBoundsMinCol: Int?
    var pixelBoundsMinRow: Int?
    var pixelBoundsMaxCol: Int?
    var pixelBoundsMaxRow: Int?
    /// Which data source provided this frame
    var sourceID: SourceID?
    /// STAC item ID (scene name)
    var sceneID: String?
    /// DN offset for reflectance conversion (0 for AWS, -1000 for PC PB>=04.00)
    var dnOffset: Float = 0

    /// Tuple accessors for compatibility
    var polygonNorm: [(x: Double, y: Double)] {
        get { zip(polygonNormX, polygonNormY).map { (x: $0, y: $1) } }
        set {
            polygonNormX = newValue.map { $0.x }
            polygonNormY = newValue.map { $0.y }
        }
    }

    var pixelBounds: (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int)? {
        get {
            guard let mc = pixelBoundsMinCol, let mr = pixelBoundsMinRow,
                  let xc = pixelBoundsMaxCol, let xr = pixelBoundsMaxRow else { return nil }
            return (minCol: mc, minRow: mr, maxCol: xc, maxRow: xr)
        }
        set {
            pixelBoundsMinCol = newValue?.minCol
            pixelBoundsMinRow = newValue?.minRow
            pixelBoundsMaxCol = newValue?.maxCol
            pixelBoundsMaxRow = newValue?.maxRow
        }
    }

    /// Day of year (1-366)
    var dayOfYear: Int {
        Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0
    }

    /// Day of year with year prefix for multi-year spans
    var dayOfYearLabel: String {
        let doy = dayOfYear
        let year = Calendar.current.component(.year, from: date)
        return "\(year) DOY \(doy)"
    }

    // Custom CodingKeys to exclude computed properties
    enum CodingKeys: String, CodingKey {
        case id, date, dateString, ndvi, width, height, cloudFraction
        case medianNDVI, validPixelCount, polyPixelCount
        case redBand, nirBand, greenBand, blueBand, sclBand
        case polygonNormX, polygonNormY
        case greenURL, blueURL
        case pixelBoundsMinCol, pixelBoundsMinRow, pixelBoundsMaxCol, pixelBoundsMaxRow
        case sourceID, sceneID, dnOffset
    }

    // Custom encode/decode to handle Float.nan in ndvi array (JSON doesn't support NaN)
    private static let nanSentinel: Float = -9999.0

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(dateString, forKey: .dateString)
        // Replace NaN with sentinel for JSON compatibility
        let safeNDVI = ndvi.map { row in row.map { $0.isNaN ? Self.nanSentinel : $0 } }
        try container.encode(safeNDVI, forKey: .ndvi)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(cloudFraction, forKey: .cloudFraction)
        try container.encode(medianNDVI, forKey: .medianNDVI)
        try container.encode(validPixelCount, forKey: .validPixelCount)
        try container.encode(polyPixelCount, forKey: .polyPixelCount)
        try container.encode(redBand, forKey: .redBand)
        try container.encode(nirBand, forKey: .nirBand)
        try container.encodeIfPresent(greenBand, forKey: .greenBand)
        try container.encodeIfPresent(blueBand, forKey: .blueBand)
        try container.encodeIfPresent(sclBand, forKey: .sclBand)
        try container.encode(polygonNormX, forKey: .polygonNormX)
        try container.encode(polygonNormY, forKey: .polygonNormY)
        try container.encodeIfPresent(greenURL, forKey: .greenURL)
        try container.encodeIfPresent(blueURL, forKey: .blueURL)
        try container.encodeIfPresent(pixelBoundsMinCol, forKey: .pixelBoundsMinCol)
        try container.encodeIfPresent(pixelBoundsMinRow, forKey: .pixelBoundsMinRow)
        try container.encodeIfPresent(pixelBoundsMaxCol, forKey: .pixelBoundsMaxCol)
        try container.encodeIfPresent(pixelBoundsMaxRow, forKey: .pixelBoundsMaxRow)
        try container.encodeIfPresent(sourceID, forKey: .sourceID)
        try container.encodeIfPresent(sceneID, forKey: .sceneID)
        try container.encode(dnOffset, forKey: .dnOffset)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        dateString = try container.decode(String.self, forKey: .dateString)
        // Restore NaN from sentinel
        let rawNDVI = try container.decode([[Float]].self, forKey: .ndvi)
        ndvi = rawNDVI.map { row in row.map { $0 == Self.nanSentinel ? .nan : $0 } }
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        cloudFraction = try container.decode(Double.self, forKey: .cloudFraction)
        medianNDVI = try container.decode(Float.self, forKey: .medianNDVI)
        validPixelCount = try container.decode(Int.self, forKey: .validPixelCount)
        polyPixelCount = try container.decode(Int.self, forKey: .polyPixelCount)
        redBand = try container.decode([[UInt16]].self, forKey: .redBand)
        nirBand = try container.decode([[UInt16]].self, forKey: .nirBand)
        greenBand = try container.decodeIfPresent([[UInt16]].self, forKey: .greenBand)
        blueBand = try container.decodeIfPresent([[UInt16]].self, forKey: .blueBand)
        sclBand = try container.decodeIfPresent([[UInt16]].self, forKey: .sclBand)
        polygonNormX = try container.decode([Double].self, forKey: .polygonNormX)
        polygonNormY = try container.decode([Double].self, forKey: .polygonNormY)
        greenURL = try container.decodeIfPresent(URL.self, forKey: .greenURL)
        blueURL = try container.decodeIfPresent(URL.self, forKey: .blueURL)
        pixelBoundsMinCol = try container.decodeIfPresent(Int.self, forKey: .pixelBoundsMinCol)
        pixelBoundsMinRow = try container.decodeIfPresent(Int.self, forKey: .pixelBoundsMinRow)
        pixelBoundsMaxCol = try container.decodeIfPresent(Int.self, forKey: .pixelBoundsMaxCol)
        pixelBoundsMaxRow = try container.decodeIfPresent(Int.self, forKey: .pixelBoundsMaxRow)
        sourceID = try container.decodeIfPresent(SourceID.self, forKey: .sourceID)
        sceneID = try container.decodeIfPresent(String.self, forKey: .sceneID)
        dnOffset = (try? container.decode(Float.self, forKey: .dnOffset)) ?? 0
    }

    /// Convenience init matching the old tuple-based API
    init(date: Date, dateString: String, ndvi: [[Float]], width: Int, height: Int,
         cloudFraction: Double, medianNDVI: Float, validPixelCount: Int, polyPixelCount: Int,
         redBand: [[UInt16]], nirBand: [[UInt16]],
         greenBand: [[UInt16]]? = nil, blueBand: [[UInt16]]? = nil, sclBand: [[UInt16]]? = nil,
         polygonNorm: [(x: Double, y: Double)] = [],
         greenURL: URL? = nil, blueURL: URL? = nil,
         pixelBounds: (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int)? = nil,
         sourceID: SourceID? = nil, sceneID: String? = nil, dnOffset: Float = 0) {
        self.id = UUID()
        self.date = date
        self.dateString = dateString
        self.ndvi = ndvi
        self.width = width
        self.height = height
        self.cloudFraction = cloudFraction
        self.medianNDVI = medianNDVI
        self.validPixelCount = validPixelCount
        self.polyPixelCount = polyPixelCount
        self.redBand = redBand
        self.nirBand = nirBand
        self.greenBand = greenBand
        self.blueBand = blueBand
        self.sclBand = sclBand
        self.polygonNormX = polygonNorm.map { $0.x }
        self.polygonNormY = polygonNorm.map { $0.y }
        self.greenURL = greenURL
        self.blueURL = blueURL
        self.pixelBoundsMinCol = pixelBounds?.minCol
        self.pixelBoundsMinRow = pixelBounds?.minRow
        self.pixelBoundsMaxCol = pixelBounds?.maxCol
        self.pixelBoundsMaxRow = pixelBounds?.maxRow
        self.sourceID = sourceID
        self.sceneID = sceneID
        self.dnOffset = dnOffset
    }
}
