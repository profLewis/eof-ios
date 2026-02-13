import Foundation

/// Generates GeoJSON polygon geometries from center coordinates and extent.
enum AOIGeometry {

    /// Generate a GeoJSON Polygon from a center point and diameter.
    /// - Parameters:
    ///   - lat: Center latitude in degrees
    ///   - lon: Center longitude in degrees
    ///   - diameter: Diameter in meters
    ///   - shape: .circle or .square
    /// - Returns: A valid GeoJSON Polygon (counter-clockwise, closed ring)
    static func generate(lat: Double, lon: Double, diameter: Double, shape: AppSettings.ManualShape) -> GeoJSONGeometry {
        let radius = diameter / 2.0

        // Degrees per meter at this latitude (WGS84 spherical approximation)
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(lat * .pi / 180.0)

        let dLat = radius / metersPerDegLat
        let dLon = radius / metersPerDegLon

        let ring: [[Double]]

        switch shape {
        case .circle:
            // 64-point polygon approximation, counter-clockwise
            let n = 64
            ring = (0...n).map { i in
                let angle = Double(i) * 2.0 * .pi / Double(n)
                let pLon = lon + dLon * cos(angle)
                let pLat = lat + dLat * sin(angle)
                return [pLon, pLat]
            }

        case .square:
            // Counter-clockwise: SW → SE → NE → NW → SW (closed)
            ring = [
                [lon - dLon, lat - dLat],
                [lon + dLon, lat - dLat],
                [lon + dLon, lat + dLat],
                [lon - dLon, lat + dLat],
                [lon - dLon, lat - dLat],
            ]
        }

        return GeoJSONGeometry(type: "Polygon", coordinates: [ring])
    }

    /// Generate a GeoJSON rectangle from bounding box coordinates.
    static func generateRect(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> GeoJSONGeometry {
        let ring: [[Double]] = [
            [minLon, minLat],
            [maxLon, minLat],
            [maxLon, maxLat],
            [minLon, maxLat],
            [minLon, minLat],
        ]
        return GeoJSONGeometry(type: "Polygon", coordinates: [ring])
    }
}
