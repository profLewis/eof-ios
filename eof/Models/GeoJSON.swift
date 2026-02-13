import Foundation

struct GeoJSONFeatureCollection: Codable {
    let type: String
    let features: [GeoJSONFeature]
}

struct GeoJSONFeature: Codable {
    let type: String
    let geometry: GeoJSONGeometry
}

struct GeoJSONGeometry: Codable {
    let type: String
    let coordinates: [[[Double]]]

    var polygon: [(lon: Double, lat: Double)] {
        coordinates[0].map { (lon: $0[0], lat: $0[1]) }
    }

    var bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        let lons = polygon.map(\.lon)
        let lats = polygon.map(\.lat)
        return (lons.min()!, lats.min()!, lons.max()!, lats.max()!)
    }

    var centroid: (lon: Double, lat: Double) {
        let b = bbox
        return (lon: (b.minLon + b.maxLon) / 2, lat: (b.minLat + b.maxLat) / 2)
    }

    /// Encode as GeoJSON dict for STAC intersects parameter
    var asDict: [String: Any] {
        [
            "type": type,
            "coordinates": coordinates
        ]
    }
}

/// Load GeoJSON from a local file. Supports FeatureCollection, Feature, or bare Geometry.
func loadGeoJSON(from url: URL) throws -> GeoJSONGeometry {
    let data = try Data(contentsOf: url)
    return try parseGeoJSON(data: data)
}

/// Load GeoJSON from a remote URL asynchronously.
func loadGeoJSONAsync(from url: URL) async throws -> GeoJSONGeometry {
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw NSError(domain: "EOFetch", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) fetching GeoJSON"])
    }
    return try parseGeoJSON(data: data)
}

/// Parse GeoJSON data, trying FeatureCollection → Feature → bare Geometry.
private func parseGeoJSON(data: Data) throws -> GeoJSONGeometry {
    let decoder = JSONDecoder()
    // Try FeatureCollection
    if let fc = try? decoder.decode(GeoJSONFeatureCollection.self, from: data),
       let feature = fc.features.first {
        return feature.geometry
    }
    // Try single Feature
    if let feature = try? decoder.decode(GeoJSONFeature.self, from: data) {
        return feature.geometry
    }
    // Try bare Geometry
    if let geometry = try? decoder.decode(GeoJSONGeometry.self, from: data) {
        return geometry
    }
    throw NSError(domain: "EOFetch", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Could not parse GeoJSON (expected FeatureCollection, Feature, or Polygon)"])
}

// MARK: - Multi-format AOI Parsing

/// Parse AOI from data, auto-detecting format: GeoJSON, KML, WKT.
func parseAOI(data: Data) throws -> GeoJSONGeometry {
    // Try GeoJSON first
    if let geo = try? parseGeoJSON(data: data) {
        return geo
    }
    // Try as text (KML, WKT)
    if let text = String(data: data, encoding: .utf8) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // KML detection
        if trimmed.contains("<kml") || trimmed.contains("<Placemark") || trimmed.contains("<coordinates") {
            return try parseKML(text: trimmed)
        }
        // WKT detection
        if trimmed.uppercased().hasPrefix("POLYGON") || trimmed.uppercased().hasPrefix("MULTIPOLYGON") {
            return try parseWKT(text: trimmed)
        }
    }
    throw NSError(domain: "EOFetch", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Unrecognized AOI format. Supported: GeoJSON, KML, WKT."])
}

/// Parse AOI from a local file, auto-detecting format.
func loadAOI(from url: URL) throws -> GeoJSONGeometry {
    let data = try Data(contentsOf: url)
    return try parseAOI(data: data)
}

/// Load AOI from a remote URL, auto-detecting format.
func loadAOIAsync(from url: URL) async throws -> GeoJSONGeometry {
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw NSError(domain: "EOFetch", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) fetching AOI"])
    }
    return try parseAOI(data: data)
}

// MARK: - KML Parser

/// Extract first polygon from KML text.
private func parseKML(text: String) throws -> GeoJSONGeometry {
    // Simple XML extraction — find <coordinates> content
    // KML format: lon,lat[,alt] lon,lat[,alt] ...
    guard let coordStart = text.range(of: "<coordinates>", options: .caseInsensitive),
          let coordEnd = text.range(of: "</coordinates>", options: .caseInsensitive) else {
        throw NSError(domain: "EOFetch", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "KML: no <coordinates> element found"])
    }

    let coordText = String(text[coordStart.upperBound..<coordEnd.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Split by whitespace or newlines
    let pairs = coordText.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }

    var ring = [[Double]]()
    for pair in pairs {
        let parts = pair.split(separator: ",").compactMap { Double($0) }
        guard parts.count >= 2 else { continue }
        ring.append([parts[0], parts[1]]) // lon, lat
    }

    guard ring.count >= 3 else {
        throw NSError(domain: "EOFetch", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "KML: polygon needs at least 3 vertices (got \(ring.count))"])
    }

    // Close ring if not already closed
    if ring.first![0] != ring.last![0] || ring.first![1] != ring.last![1] {
        ring.append(ring.first!)
    }

    return GeoJSONGeometry(type: "Polygon", coordinates: [ring])
}

// MARK: - WKT Parser

/// Parse WKT POLYGON or MULTIPOLYGON (uses first polygon).
private func parseWKT(text: String) throws -> GeoJSONGeometry {
    let upper = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Extract content inside outer parentheses
    // POLYGON((lon lat, lon lat, ...)) or POLYGON ((lon lat, ...))
    guard let firstParen = upper.firstIndex(of: "(") else {
        throw NSError(domain: "EOFetch", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "WKT: no opening parenthesis found"])
    }

    var content = String(upper[firstParen...])
    // Strip outer parens — find the innermost ring
    // For POLYGON((x y, ...)), we need to find first (( and matching ))
    // For MULTIPOLYGON(((x y, ...))), strip one more layer
    while content.hasPrefix("(") && !content.dropFirst().hasPrefix(")") {
        content = String(content.dropFirst())
    }
    if let end = content.lastIndex(of: ")") {
        content = String(content[content.startIndex..<end])
    }
    // Remove remaining parens
    content = content.replacingOccurrences(of: "(", with: "")
        .replacingOccurrences(of: ")", with: "")

    // WKT uses commas between coordinate pairs, spaces within pairs
    // "lon lat, lon lat, lon lat" — just split on commas
    let pairs = content.split(separator: ",")
    var ring = [[Double]]()
    for pair in pairs {
        let parts = pair.trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .compactMap { Double($0) }
        guard parts.count >= 2 else { continue }
        ring.append([parts[0], parts[1]]) // lon, lat in WKT
    }

    guard ring.count >= 3 else {
        throw NSError(domain: "EOFetch", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "WKT: polygon needs at least 3 vertices (got \(ring.count))"])
    }

    // Close ring if not already closed
    if ring.first![0] != ring.last![0] || ring.first![1] != ring.last![1] {
        ring.append(ring.first!)
    }

    return GeoJSONGeometry(type: "Polygon", coordinates: [ring])
}
