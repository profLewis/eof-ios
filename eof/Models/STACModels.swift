import Foundation

// MARK: - STAC Search Response

struct STACSearchResponse: Codable {
    let type: String
    let features: [STACItem]
    let links: [STACLink]?
    let context: STACContext?
}

struct STACContext: Codable {
    let returned: Int?
    let matched: Int?
}

struct STACItem: Codable {
    let id: String
    let properties: STACProperties
    let assets: [String: STACAsset]

    var dateString: String {
        String(properties.datetime.prefix(10))
    }

    var date: Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        // Try with fractional seconds
        if let d = fmt.date(from: String(properties.datetime.prefix(19))) { return d }
        // Try with Z suffix
        let s = properties.datetime.replacingOccurrences(of: "Z", with: "")
        return fmt.date(from: String(s.prefix(19)))
    }

    /// Extract MGRS tile ID from item ID.
    /// AWS:  "S2B_35JPM_20220801_0_L2A"                          → parts[1] = "35JPM"
    /// PC:   "S2B_MSIL2A_20220801T093559_R136_T35JPM_20220801…"  → "T35JPM" prefix
    /// HLS:  "HLS.S30.T35JPM.2022201T093559.v2.0"                → dot-split "T35JPM"
    var mgrsTile: String? {
        // Try dot-separated format first (HLS)
        let dotParts = id.split(separator: ".")
        for part in dotParts {
            let s = String(part)
            if s.count == 6 && s.hasPrefix("T") { return String(s.dropFirst()) }
        }
        // Underscore-separated (AWS / PC)
        let parts = id.split(separator: "_")
        for part in parts {
            let s = String(part)
            if s.count == 5 && s.first?.isNumber == true { return s }           // "35JPM"
            if s.count == 6 && s.hasPrefix("T") { return String(s.dropFirst()) } // "T35JPM"
        }
        return nil
    }

    /// DN offset for reflectance conversion.
    /// AWS earth-search applies the BOA offset to pixel values, so DN/10000 = reflectance.
    /// Planetary Computer serves raw ESA DNs. For PB >= 04.00: reflectance = (DN - 1000) / 10000.
    var dnOffset: Float {
        // AWS: if boa_offset_applied is true, offset already baked into pixels → no correction needed
        if properties.boaOffsetApplied == true { return 0 }
        // Check processing baseline: PB >= 04.00 has +1000 in DN values
        if let pb = properties.processingBaseline, let v = Double(pb), v >= 4.0 { return -1000 }
        return 0
    }

    /// Get proj:transform using source-specific band key.
    func projTransform(using mapping: BandMapping) -> [Double]? {
        assets[mapping.projTransformKey]?.projTransform
    }

    /// Legacy accessor (AWS default).
    var projTransform: [Double]? {
        assets["red"]?.projTransform
    }
}

struct STACProperties: Codable {
    let datetime: String
    let cloudCover: Double?
    let projEpsg: Int?
    /// AWS earth-search: true if BOA offset (-1000) already applied to pixel values
    let boaOffsetApplied: Bool?
    /// S2 processing baseline (e.g. "04.00"). PB >= 04.00 has BOA_ADD_OFFSET = -1000
    let processingBaseline: String?

    enum CodingKeys: String, CodingKey {
        case datetime
        case cloudCover = "eo:cloud_cover"
        case projEpsg = "proj:epsg"
        case boaOffsetApplied = "earthsearch:boa_offset_applied"
        case processingBaseline = "s2:processing_baseline"
    }
}

struct STACAsset: Codable {
    let href: String
    let type: String?
    let title: String?
    let projTransform: [Double]?
    let projShape: [Int]?

    enum CodingKeys: String, CodingKey {
        case href, type, title
        case projTransform = "proj:transform"
        case projShape = "proj:shape"
    }
}

struct STACLink: Codable {
    let rel: String
    let href: String
}
