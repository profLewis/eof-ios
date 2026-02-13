import Foundation

/// Pure Swift WGS84 → UTM forward projection (Transverse Mercator).
struct UTMProjection {
    // WGS84 ellipsoid
    private static let a: Double = 6378137.0              // semi-major axis (m)
    private static let f: Double = 1.0 / 298.257223563    // flattening
    private static let b: Double = a * (1 - f)            // semi-minor axis
    private static let e2: Double = 2 * f - f * f         // first eccentricity squared
    private static let ep2: Double = e2 / (1 - e2)        // second eccentricity squared
    private static let k0: Double = 0.9996                // scale factor

    let zone: Int
    let isNorth: Bool

    var epsg: Int {
        isNorth ? 32600 + zone : 32700 + zone
    }

    /// Determine UTM zone from longitude/latitude.
    static func zoneFor(lon: Double, lat: Double) -> UTMProjection {
        var z = Int((lon + 180) / 6) + 1
        // Special zones for Norway/Svalbard
        if lat >= 56 && lat < 64 && lon >= 3 && lon < 12 { z = 32 }
        if lat >= 72 && lat < 84 {
            if lon >= 0 && lon < 9 { z = 31 }
            else if lon >= 9 && lon < 21 { z = 33 }
            else if lon >= 21 && lon < 33 { z = 35 }
            else if lon >= 33 && lon < 42 { z = 37 }
        }
        return UTMProjection(zone: z, isNorth: lat >= 0)
    }

    /// Central meridian for this UTM zone.
    var centralMeridian: Double {
        Double((zone - 1) * 6 - 180 + 3)
    }

    /// Convert WGS84 (lon, lat) in degrees to UTM (easting, northing) in meters.
    func forward(lon: Double, lat: Double) -> (easting: Double, northing: Double) {
        let a = Self.a
        let e2 = Self.e2
        let ep2 = Self.ep2
        let k0 = Self.k0

        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        let lon0Rad = centralMeridian * .pi / 180.0

        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let tanLat = tan(latRad)

        let N = a / sqrt(1 - e2 * sinLat * sinLat)
        let T = tanLat * tanLat
        let C = ep2 * cosLat * cosLat
        let A = cosLat * (lonRad - lon0Rad)

        // Meridional arc length
        let e4 = e2 * e2
        let e6 = e4 * e2
        let M = a * (
            (1 - e2/4 - 3*e4/64 - 5*e6/256) * latRad
            - (3*e2/8 + 3*e4/32 + 45*e6/1024) * sin(2*latRad)
            + (15*e4/256 + 45*e6/1024) * sin(4*latRad)
            - (35*e6/3072) * sin(6*latRad)
        )

        let A2 = A * A
        let A3 = A2 * A
        let A4 = A3 * A
        let A5 = A4 * A
        let A6 = A5 * A

        let easting = k0 * N * (
            A
            + (1 - T + C) * A3 / 6
            + (5 - 18*T + T*T + 72*C - 58*ep2) * A5 / 120
        ) + 500000.0

        var northing = k0 * (
            M
            + N * tanLat * (
                A2 / 2
                + (5 - T + 9*C + 4*C*C) * A4 / 24
                + (61 - 58*T + T*T + 600*C - 330*ep2) * A6 / 720
            )
        )

        if !isNorth {
            northing += 10000000.0
        }

        return (easting, northing)
    }

    /// Convert a bounding box from WGS84 to UTM pixel coordinates given a geotransform.
    /// geotransform: [scaleX, shearX, originX, shearY, scaleY, originY]
    /// (STAC proj:transform format, same as GDAL but reordered)
    func bboxToPixels(
        bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        transform: [Double]
    ) -> (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int) {
        // Convert all 4 corners to UTM
        let corners = [
            forward(lon: bbox.minLon, lat: bbox.minLat),
            forward(lon: bbox.maxLon, lat: bbox.minLat),
            forward(lon: bbox.minLon, lat: bbox.maxLat),
            forward(lon: bbox.maxLon, lat: bbox.maxLat),
        ]

        let eastings = corners.map(\.easting)
        let northings = corners.map(\.northing)
        let minE = eastings.min()!
        let maxE = eastings.max()!
        let minN = northings.min()!
        let maxN = northings.max()!

        // STAC proj:transform: [scaleX, shearX, originX, shearY, scaleY, originY]
        let scaleX = transform[0]
        let originX = transform[2]
        let scaleY = transform[4]   // negative for north-up
        let originY = transform[5]

        // Pixel = (UTM - origin) / scale
        let col1 = Int(floor((minE - originX) / scaleX))
        let col2 = Int(ceil((maxE - originX) / scaleX))
        let row1 = Int(floor((maxN - originY) / scaleY))  // maxN → min row (scaleY is negative)
        let row2 = Int(ceil((minN - originY) / scaleY))

        return (min(col1, col2), min(row1, row2), max(col1, col2), max(row1, row2))
    }
}
