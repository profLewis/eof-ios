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
        case digitized
        case cropSample(crop: String, region: String)
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
    var pixelFitRMSEThreshold: Double = 0.15 { didSet { save() } }
    var pixelMinObservations: Int = 4 { didSet { save() } }
    var pixelSlopePerturbation: Double = 0.10 { didSet { save() } }
    var clusterFilterThreshold: Double = 4.0 { didSet { save() } }
    var minSeasonLength: Int = 30 { didSet { save() } }
    var maxSeasonLength: Int = 150 { didSet { save() } }
    /// Max % difference between green-up (rsp) and senescence (rau) rates. 0 = no constraint.
    var slopeSymmetry: Int = 20 { didSet { save() } }
    /// Second pass: refit with weights from first-pass DL curve.
    var enableSecondPass: Bool = false { didSet { save() } }
    /// Second pass weight range: min weight (off-season) and max weight (peak season).
    var secondPassWeightMin: Double = 1.0 { didSet { save() } }
    var secondPassWeightMax: Double = 2.0 { didSet { save() } }

    // DL parameter bounds (physical constraints)
    var boundMnMin: Double = -0.5 { didSet { save() } }
    var boundMnMax: Double = 0.8 { didSet { save() } }
    var boundDeltaMin: Double = 0.05 { didSet { save() } }
    var boundDeltaMax: Double = 1.5 { didSet { save() } }
    var boundSosMin: Double = 1 { didSet { save() } }
    var boundSosMax: Double = 365 { didSet { save() } }
    var boundRspMin: Double = 0.02 { didSet { save() } }
    var boundRspMax: Double = 0.6 { didSet { save() } }
    var boundRauMin: Double = 0.02 { didSet { save() } }
    var boundRauMax: Double = 0.6 { didSet { save() } }

    // Crop calendar
    var selectedCrop: String = "" { didSet { save() } }

    // Pixel inspection
    var pixelInspectWindow: Int = 1 { didSet { save() } }

    /// Minimum fractional pixel coverage within AOI to include (0.01 = 1%)
    var pixelCoverageThreshold: Double = 0.01 { didSet { save() } }

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
    var sources: [STACSourceConfig] = [.planetaryDefault(), .awsDefault(), .cdseDefault(), .earthdataDefault(), .geeDefault()] {
        didSet { saveSources() }
    }
    var benchmarkResults: [SourceBenchmark] = []
    var smartAllocation: Bool = true { didSet { save() } }

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
        case .digitized:
            return "Digitized polygon"
        case .cropSample(let crop, let region):
            return "\(crop), \(region)"
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
        defaults.set(slopeSymmetry, forKey: prefix + "slopeSymmetry")
        defaults.set(enableSecondPass, forKey: prefix + "enableSecondPass")
        defaults.set(secondPassWeightMin, forKey: prefix + "secondPassWeightMin")
        defaults.set(secondPassWeightMax, forKey: prefix + "secondPassWeightMax")
        defaults.set(vegetationIndex.rawValue, forKey: prefix + "vegetationIndex")
        defaults.set(smartAllocation, forKey: prefix + "smartAllocation")
        defaults.set(boundMnMin, forKey: prefix + "boundMnMin")
        defaults.set(boundMnMax, forKey: prefix + "boundMnMax")
        defaults.set(boundDeltaMin, forKey: prefix + "boundDeltaMin")
        defaults.set(boundDeltaMax, forKey: prefix + "boundDeltaMax")
        defaults.set(boundSosMin, forKey: prefix + "boundSosMin")
        defaults.set(boundSosMax, forKey: prefix + "boundSosMax")
        defaults.set(boundRspMin, forKey: prefix + "boundRspMin")
        defaults.set(boundRspMax, forKey: prefix + "boundRspMax")
        defaults.set(boundRauMin, forKey: prefix + "boundRauMin")
        defaults.set(boundRauMax, forKey: prefix + "boundRauMax")
        defaults.set(selectedCrop, forKey: prefix + "selectedCrop")
        defaults.set(pixelInspectWindow, forKey: prefix + "pixelInspectWindow")
        defaults.set(pixelCoverageThreshold, forKey: prefix + "pixelCoverageThreshold")
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: prefix + "sources")
        }
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
        let ss = defaults.integer(forKey: prefix + "slopeSymmetry")
        if ss > 0 { slopeSymmetry = ss }
        if defaults.object(forKey: prefix + "enableSecondPass") != nil {
            enableSecondPass = defaults.bool(forKey: prefix + "enableSecondPass")
        }
        let spwMin = defaults.double(forKey: prefix + "secondPassWeightMin")
        if spwMin > 0 { secondPassWeightMin = spwMin }
        let spwMax = defaults.double(forKey: prefix + "secondPassWeightMax")
        if spwMax > 0 { secondPassWeightMax = spwMax }
        if let viRaw = defaults.string(forKey: prefix + "vegetationIndex"),
           let vi = VegetationIndex(rawValue: viRaw) {
            vegetationIndex = vi
        }
        if defaults.object(forKey: prefix + "smartAllocation") != nil {
            smartAllocation = defaults.bool(forKey: prefix + "smartAllocation")
        }
        // Parameter bounds
        if defaults.object(forKey: prefix + "boundMnMin") != nil {
            boundMnMin = defaults.double(forKey: prefix + "boundMnMin")
            boundMnMax = defaults.double(forKey: prefix + "boundMnMax")
            boundDeltaMin = defaults.double(forKey: prefix + "boundDeltaMin")
            boundDeltaMax = defaults.double(forKey: prefix + "boundDeltaMax")
            boundSosMin = defaults.double(forKey: prefix + "boundSosMin")
            boundSosMax = defaults.double(forKey: prefix + "boundSosMax")
            boundRspMin = defaults.double(forKey: prefix + "boundRspMin")
            boundRspMax = defaults.double(forKey: prefix + "boundRspMax")
            boundRauMin = defaults.double(forKey: prefix + "boundRauMin")
            boundRauMax = defaults.double(forKey: prefix + "boundRauMax")
        }
        if let crop = defaults.string(forKey: prefix + "selectedCrop") {
            selectedCrop = crop
        }
        let piw = defaults.integer(forKey: prefix + "pixelInspectWindow")
        if piw > 0 { pixelInspectWindow = piw }
        if defaults.object(forKey: prefix + "pixelCoverageThreshold") != nil {
            pixelCoverageThreshold = defaults.double(forKey: prefix + "pixelCoverageThreshold")
        }
        // Restore data source selections and order
        if let data = defaults.data(forKey: prefix + "sources"),
           let saved = try? JSONDecoder().decode([STACSourceConfig].self, from: data) {
            // Merge: use saved state for known sources, append any new defaults not in saved
            let allDefaults: [STACSourceConfig] = [.planetaryDefault(), .awsDefault(), .cdseDefault(), .earthdataDefault(), .geeDefault()]
            var merged = saved
            // Update code-controlled fields (URLs, band mappings) from defaults while preserving user preferences (isEnabled, order)
            for def in allDefaults {
                if let idx = merged.firstIndex(where: { $0.sourceID == def.sourceID }) {
                    merged[idx].searchURL = def.searchURL
                    merged[idx].collection = def.collection
                    merged[idx].bandMapping = def.bandMapping
                    merged[idx].assetAuthType = def.assetAuthType
                } else {
                    merged.append(def)
                }
            }
            sources = merged
        }

        // Auto-enable sources that have credentials stored but are still disabled
        for i in 0..<sources.count {
            if !sources[i].isEnabled {
                switch sources[i].sourceID {
                case .earthdata:
                    if let u = KeychainService.retrieve(key: "earthdata.username"),
                       let p = KeychainService.retrieve(key: "earthdata.password"),
                       !u.isEmpty, !p.isEmpty {
                        sources[i].isEnabled = true
                    }
                case .cdse:
                    if let u = KeychainService.retrieve(key: "cdse.username"),
                       let p = KeychainService.retrieve(key: "cdse.password"),
                       !u.isEmpty, !p.isEmpty {
                        sources[i].isEnabled = true
                    }
                case .gee:
                    if KeychainService.retrieve(key: "gee.refresh_token") != nil,
                       let pid = KeychainService.retrieve(key: "gee.project"),
                       !pid.isEmpty {
                        sources[i].isEnabled = true
                    }
                default: break
                }
            }
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
