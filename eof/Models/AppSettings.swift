import Foundation
import Observation

@Observable
class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let prefix = "eof_"

    enum DisplayMode: String, CaseIterable {
        case ndvi = "NDVI"
        case fcc = "False Color (NIR-R-G)"
        case rcc = "True Color (R-G-B)"
        case scl = "Scene Classification"
        case bandRed = "Red (B04)"
        case bandNIR = "NIR (B08)"
        case bandGreen = "Green (B03)"
        case bandBlue = "Blue (B02)"
    }

    enum AOISource: Equatable {
        case bundled
        case url(String)
        case file(URL)
        case manual(lat: Double, lon: Double, diameter: Double, shape: ManualShape)
        case mapRect(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)
        case location(lat: Double, lon: Double, diameter: Double)
    }

    enum ManualShape: String, CaseIterable {
        case circle = "Circle"
        case square = "Square"
    }

    enum VegetationIndex: String, CaseIterable {
        case ndvi = "NDVI"
        case dvi = "DVI"

        var label: String { rawValue }
        var description: String {
            switch self {
            case .ndvi: return "(NIR \u{2212} Red) / (NIR + Red)"
            case .dvi: return "NIR \u{2212} Red"
            }
        }
    }

    var displayMode: DisplayMode = .fcc { didSet { save() } }
    var cloudMask: Bool = true { didSet { save() } }
    var cloudThreshold: Double = 100 { didSet { save() } }
    var ndviThreshold: Float = 0.2 { didSet { save() } }
    var showHelp: Bool = false
    var maxConcurrent: Int = 8 { didSet { save() } }
    var showSCLBoundaries: Bool = true { didSet { save() } }
    var showSaturationMarkers: Bool = false { didSet { save() } }
    var playbackSpeed: Double = 1.0 { didSet { save() } }
    var enforceAOI: Bool = true { didSet { save() } }
    var showMaskedClassColors: Bool = false { didSet { save() } }
    var showBasemap: Bool = true { didSet { save() } }
    var vegetationIndex: VegetationIndex = .ndvi { didSet { save() } }

    // Per-pixel phenology settings
    var pixelEnsembleRuns: Int = 5 { didSet { save() } }
    var pixelPerturbation: Double = 0.50 { didSet { save() } }
    var pixelFitRMSEThreshold: Double = 0.10 { didSet { save() } }
    var pixelMinObservations: Int = 4 { didSet { save() } }
    var pixelSlopePerturbation: Double = 0.10 { didSet { save() } }
    var clusterFilterThreshold: Double = 4.0 { didSet { save() } }
    var minSeasonLength: Int = 50 { didSet { save() } }
    var maxSeasonLength: Int = 150 { didSet { save() } }

    /// SCL classes to treat as VALID (not masked). User can toggle each.
    var sclValidClasses: Set<Int> = [4, 5] { didSet { save() } }

    /// All SCL class definitions
    static let sclClassNames: [(value: Int, name: String)] = [
        (0, "No Data"),
        (1, "Saturated / Defective"),
        (2, "Dark Area Pixels"),
        (3, "Cloud Shadows"),
        (4, "Vegetation"),
        (5, "Not Vegetated"),
        (6, "Water"),
        (7, "Unclassified"),
        (8, "Cloud Medium Prob."),
        (9, "Cloud High Prob."),
        (10, "Thin Cirrus"),
        (11, "Snow / Ice"),
    ]

    // Data Sources (order = trust priority)
    var sources: [STACSourceConfig] = [.planetaryDefault(), .awsDefault(), .cdseDefault(), .earthdataDefault()]
    var benchmarkResults: [SourceBenchmark] = []
    var smartAllocation: Bool = true

    var enabledSources: [STACSourceConfig] {
        sources.filter { $0.isEnabled }
    }

    // Area of Interest
    var aoiSource: AOISource = .bundled
    var aoiGeometry: GeoJSONGeometry? = nil
    var aoiHistory: [AOIHistoryEntry] = []
    private let maxHistory = 10

    struct AOIHistoryEntry: Identifiable {
        let id = UUID()
        let source: AOISource
        let geometry: GeoJSONGeometry
        let label: String
    }

    func recordAOI() {
        guard let geo = aoiGeometry else { return }
        let label = aoiSourceLabel
        // Don't duplicate if same as most recent
        if let last = aoiHistory.first, last.label == label { return }
        let entry = AOIHistoryEntry(source: aoiSource, geometry: geo, label: label)
        aoiHistory.insert(entry, at: 0)
        if aoiHistory.count > maxHistory {
            aoiHistory = Array(aoiHistory.prefix(maxHistory))
        }
    }

    func restoreAOI(_ entry: AOIHistoryEntry) {
        aoiSource = entry.source
        aoiGeometry = entry.geometry
    }

    var aoiSourceLabel: String {
        switch aoiSource {
        case .bundled:
            return "SA wheat field (bundled)"
        case .url(let u):
            let short = u.count > 40 ? String(u.prefix(40)) + "..." : u
            return "URL: \(short)"
        case .file(let u):
            return "File: \(u.lastPathComponent)"
        case .manual(let lat, let lon, let d, let shape):
            return "\(shape.rawValue) \(Int(d))m at \(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))"
        case .mapRect(let minLat, _, let maxLat, _):
            return "Map rect \(String(format: "%.3f", minLat))\u{2013}\(String(format: "%.3f", maxLat))"
        case .location(let lat, let lon, let d):
            return "My location \(Int(d))m at \(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))"
        }
    }

    var aoiSummary: String {
        guard let geo = aoiGeometry else { return "Not set" }
        let c = geo.centroid
        let b = geo.bbox
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(c.lat * .pi / 180)
        let widthM = (b.maxLon - b.minLon) * metersPerDegLon
        let heightM = (b.maxLat - b.minLat) * metersPerDegLat
        return String(format: "%.4f, %.4f (~%.0f x %.0f m)", c.lat, c.lon, widthM, heightM)
    }
    var startDate: Date = {
        var c = DateComponents()
        c.year = 2022; c.month = 6; c.day = 15
        return Calendar.current.date(from: c) ?? Date()
    }() { didSet { save() } }
    var endDate: Date = {
        var c = DateComponents()
        c.year = 2022; c.month = 12; c.day = 31
        return Calendar.current.date(from: c) ?? Date()
    }() { didSet { save() } }

    private init() { load() }

    // MARK: - Persistence

    private func save() {
        defaults.set(displayMode.rawValue, forKey: prefix + "displayMode")
        defaults.set(cloudMask, forKey: prefix + "cloudMask")
        defaults.set(cloudThreshold, forKey: prefix + "cloudThreshold")
        defaults.set(ndviThreshold, forKey: prefix + "ndviThreshold")
        defaults.set(maxConcurrent, forKey: prefix + "maxConcurrent")
        defaults.set(showSCLBoundaries, forKey: prefix + "showSCLBoundaries")
        defaults.set(showSaturationMarkers, forKey: prefix + "showSaturationMarkers")
        defaults.set(playbackSpeed, forKey: prefix + "playbackSpeed")
        defaults.set(enforceAOI, forKey: prefix + "enforceAOI")
        defaults.set(showMaskedClassColors, forKey: prefix + "showMaskedClassColors")
        defaults.set(showBasemap, forKey: prefix + "showBasemap")
        defaults.set(Array(sclValidClasses), forKey: prefix + "sclValidClasses")
        defaults.set(startDate.timeIntervalSince1970, forKey: prefix + "startDate")
        defaults.set(endDate.timeIntervalSince1970, forKey: prefix + "endDate")
        defaults.set(pixelEnsembleRuns, forKey: prefix + "pixelEnsembleRuns")
        defaults.set(pixelPerturbation, forKey: prefix + "pixelPerturbation")
        defaults.set(pixelFitRMSEThreshold, forKey: prefix + "pixelFitRMSEThreshold")
        defaults.set(pixelMinObservations, forKey: prefix + "pixelMinObservations")
        defaults.set(pixelSlopePerturbation, forKey: prefix + "pixelSlopePerturbation")
        defaults.set(clusterFilterThreshold, forKey: prefix + "clusterFilterThreshold")
        defaults.set(minSeasonLength, forKey: prefix + "minSeasonLength")
        defaults.set(maxSeasonLength, forKey: prefix + "maxSeasonLength")
        defaults.set(vegetationIndex.rawValue, forKey: prefix + "vegetationIndex")
    }

    private func load() {
        guard defaults.object(forKey: prefix + "displayMode") != nil else { return }

        if let raw = defaults.string(forKey: prefix + "displayMode"),
           let mode = DisplayMode(rawValue: raw) {
            displayMode = mode
        }
        cloudMask = defaults.bool(forKey: prefix + "cloudMask")
        cloudThreshold = defaults.double(forKey: prefix + "cloudThreshold")
        if cloudThreshold == 0 { cloudThreshold = 100 }  // default
        ndviThreshold = Float(defaults.double(forKey: prefix + "ndviThreshold"))
        let mc = defaults.integer(forKey: prefix + "maxConcurrent")
        maxConcurrent = mc > 0 ? mc : 8
        showSCLBoundaries = defaults.bool(forKey: prefix + "showSCLBoundaries")
        showSaturationMarkers = defaults.bool(forKey: prefix + "showSaturationMarkers")
        let speed = defaults.double(forKey: prefix + "playbackSpeed")
        playbackSpeed = speed > 0 ? speed : 1.0
        // enforceAOI defaults to true; only override if key exists
        if defaults.object(forKey: prefix + "enforceAOI") != nil {
            enforceAOI = defaults.bool(forKey: prefix + "enforceAOI")
        }
        if defaults.object(forKey: prefix + "showMaskedClassColors") != nil {
            showMaskedClassColors = defaults.bool(forKey: prefix + "showMaskedClassColors")
        }
        showBasemap = defaults.bool(forKey: prefix + "showBasemap")
        if let arr = defaults.array(forKey: prefix + "sclValidClasses") as? [Int] {
            sclValidClasses = Set(arr)
        }
        let sd = defaults.double(forKey: prefix + "startDate")
        if sd > 0 { startDate = Date(timeIntervalSince1970: sd) }
        let ed = defaults.double(forKey: prefix + "endDate")
        if ed > 0 { endDate = Date(timeIntervalSince1970: ed) }
        let per = defaults.integer(forKey: prefix + "pixelEnsembleRuns")
        if per > 0 { pixelEnsembleRuns = per }
        let pp = defaults.double(forKey: prefix + "pixelPerturbation")
        if pp > 0 { pixelPerturbation = pp }
        let prt = defaults.double(forKey: prefix + "pixelFitRMSEThreshold")
        if prt > 0 { pixelFitRMSEThreshold = prt }
        let pmo = defaults.integer(forKey: prefix + "pixelMinObservations")
        if pmo > 0 { pixelMinObservations = pmo }
        let psp = defaults.double(forKey: prefix + "pixelSlopePerturbation")
        if psp > 0 { pixelSlopePerturbation = psp }
        let cft = defaults.double(forKey: prefix + "clusterFilterThreshold")
        if cft > 0 { clusterFilterThreshold = cft }
        let msl = defaults.integer(forKey: prefix + "minSeasonLength")
        if msl > 0 { minSeasonLength = msl }
        let mxl = defaults.integer(forKey: prefix + "maxSeasonLength")
        if mxl > 0 { maxSeasonLength = mxl }
        if let viRaw = defaults.string(forKey: prefix + "vegetationIndex"),
           let vi = VegetationIndex(rawValue: viRaw) {
            vegetationIndex = vi
        }
    }

    var startDateString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: startDate)
    }

    var endDateString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: endDate)
    }
}
