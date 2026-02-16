import Foundation
import UIKit

// MARK: - CDL Crop Type Lookup

/// USDA Cropland Data Layer crop type codes (30m, US only).
enum CDLCropType: UInt8, CaseIterable {
    case corn = 1, cotton = 2, rice = 3, sorghum = 4, soybeans = 5
    case sunflower = 6, peanuts = 10, tobacco = 11
    case barley = 21, durum = 22, springWheat = 23, winterWheat = 24
    case otherSmallGrains = 25, canola = 31, flaxseed = 32
    case safflower = 33, rapeseed = 34, mustard = 35
    case alfalfa = 36, otherHay = 37, sugarbeets = 41
    case dryBeans = 42, potatoes = 43, otherCrops = 44
    case sugarcane = 45, sweetPotatoes = 46
    case oats = 28
    case grassland = 176

    var name: String {
        switch self {
        case .corn: return "Corn"
        case .cotton: return "Cotton"
        case .rice: return "Rice"
        case .sorghum: return "Sorghum"
        case .soybeans: return "Soybeans"
        case .sunflower: return "Sunflower"
        case .peanuts: return "Peanuts"
        case .tobacco: return "Tobacco"
        case .barley: return "Barley"
        case .durum: return "Durum Wheat"
        case .springWheat: return "Spring Wheat"
        case .winterWheat: return "Winter Wheat"
        case .otherSmallGrains: return "Other Small Grains"
        case .canola: return "Canola"
        case .flaxseed: return "Flaxseed"
        case .safflower: return "Safflower"
        case .rapeseed: return "Rapeseed"
        case .mustard: return "Mustard"
        case .alfalfa: return "Alfalfa"
        case .otherHay: return "Other Hay"
        case .sugarbeets: return "Sugarbeets"
        case .dryBeans: return "Dry Beans"
        case .potatoes: return "Potatoes"
        case .otherCrops: return "Other Crops"
        case .sugarcane: return "Sugarcane"
        case .sweetPotatoes: return "Sweet Potatoes"
        case .oats: return "Oats"
        case .grassland: return "Grassland"
        }
    }

    /// RGB color for map overlay (matches USDA CDL color table).
    var color: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .corn: return (255, 211, 0)
        case .cotton: return (255, 37, 37)
        case .rice: return (0, 168, 226)
        case .sorghum: return (255, 158, 9)
        case .soybeans: return (38, 115, 0)
        case .sunflower: return (255, 255, 0)
        case .peanuts: return (112, 165, 0)
        case .tobacco: return (0, 175, 73)
        case .barley: return (226, 0, 124)
        case .durum: return (166, 112, 0)
        case .springWheat: return (168, 112, 0)
        case .winterWheat: return (166, 0, 0)
        case .otherSmallGrains: return (171, 113, 40)
        case .canola: return (215, 255, 0)
        case .flaxseed: return (112, 168, 0)
        case .safflower: return (255, 166, 226)
        case .rapeseed: return (255, 211, 0)
        case .mustard: return (230, 230, 0)
        case .alfalfa: return (255, 166, 0)
        case .otherHay: return (227, 227, 194)
        case .sugarbeets: return (168, 0, 226)
        case .dryBeans: return (166, 113, 0)
        case .potatoes: return (115, 76, 0)
        case .otherCrops: return (0, 175, 73)
        case .sugarcane: return (135, 115, 255)
        case .sweetPotatoes: return (145, 53, 145)
        case .oats: return (145, 145, 0)
        case .grassland: return (218, 211, 162)
        }
    }
}

// MARK: - ESA WorldCover Classes

/// ESA WorldCover 10m land cover classes.
enum WorldCoverClass: UInt8, CaseIterable {
    case tree = 10
    case shrubland = 20
    case grassland = 30
    case cropland = 40
    case builtUp = 50
    case bareSparse = 60
    case snowIce = 70
    case water = 80
    case wetland = 90
    case mangroves = 95
    case mossLichen = 100

    var name: String {
        switch self {
        case .tree: return "Tree Cover"
        case .shrubland: return "Shrubland"
        case .grassland: return "Grassland"
        case .cropland: return "Cropland"
        case .builtUp: return "Built-up"
        case .bareSparse: return "Bare/Sparse"
        case .snowIce: return "Snow/Ice"
        case .water: return "Permanent Water"
        case .wetland: return "Herbaceous Wetland"
        case .mangroves: return "Mangroves"
        case .mossLichen: return "Moss/Lichen"
        }
    }

    var color: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .tree: return (0, 100, 0)
        case .shrubland: return (255, 187, 34)
        case .grassland: return (255, 255, 76)
        case .cropland: return (240, 150, 255)
        case .builtUp: return (250, 0, 0)
        case .bareSparse: return (180, 180, 180)
        case .snowIce: return (240, 240, 255)
        case .water: return (0, 100, 200)
        case .wetland: return (0, 150, 160)
        case .mangroves: return (0, 207, 117)
        case .mossLichen: return (250, 230, 160)
        }
    }
}

// MARK: - Crop Map Raster

/// A downloaded crop map raster with pixel values and geo-referencing.
struct CropMapRaster {
    let width: Int
    let height: Int
    let data: [UInt8]
    let bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)
    let source: CropMapDataSource

    /// Pixel size in degrees.
    var pixelWidth: Double { width > 0 ? (bbox.maxLon - bbox.minLon) / Double(width) : 0 }
    var pixelHeight: Double { height > 0 ? (bbox.maxLat - bbox.minLat) / Double(height) : 0 }

    /// Get pixel value at geographic coordinate.
    func value(at lon: Double, lat: Double) -> UInt8? {
        guard width > 0 && height > 0 else { return nil }
        let col = Int((lon - bbox.minLon) / pixelWidth)
        let row = Int((bbox.maxLat - lat) / pixelHeight) // north-up
        guard col >= 0 && col < width && row >= 0 && row < height else { return nil }
        return data[row * width + col]
    }

    /// Create RGBA image for map overlay.
    func renderOverlay(highlightCode: UInt8? = nil, opacity: UInt8 = 140) -> UIImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let code = data[i]
            guard code > 0 else { continue }
            let idx = i * 4

            switch source {
            case .cdl:
                if let crop = CDLCropType(rawValue: code) {
                    let c = crop.color
                    let alpha: UInt8 = (highlightCode == nil || highlightCode == code) ? opacity : 40
                    rgba[idx] = c.r; rgba[idx+1] = c.g; rgba[idx+2] = c.b; rgba[idx+3] = alpha
                }
            case .worldCover:
                if let lc = WorldCoverClass(rawValue: code) {
                    let c = lc.color
                    let alpha: UInt8 = (highlightCode == nil || highlightCode == code) ? opacity : 40
                    rgba[idx] = c.r; rgba[idx+1] = c.g; rgba[idx+2] = c.b; rgba[idx+3] = alpha
                }
            }
        }
        let cfData = CFDataCreate(nil, rgba, rgba.count)!
        let provider = CGDataProvider(data: cfData)!
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Count pixels per crop code.
    func histogram() -> [(code: UInt8, count: Int, name: String)] {
        var counts = [UInt8: Int]()
        for code in data where code > 0 {
            counts[code, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.compactMap { (code, count) in
            let name: String
            switch source {
            case .cdl: name = CDLCropType(rawValue: code)?.name ?? "Code \(code)"
            case .worldCover: name = WorldCoverClass(rawValue: code)?.name ?? "Code \(code)"
            }
            return (code, count, name)
        }
    }
}

/// Source type for a crop map raster.
enum CropMapDataSource {
    case cdl
    case worldCover
}

// MARK: - Extracted Field

/// A contiguous field polygon extracted from crop map raster.
struct ExtractedField: Identifiable {
    let id = UUID()
    let cropCode: UInt8
    let cropName: String
    let pixelCount: Int
    let areaSqM: Double
    let centroid: (lat: Double, lon: Double)
    let bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)

    /// Create polygon vertices from bbox (rectangular approximation).
    var vertices: [(lat: Double, lon: Double)] {
        [
            (bbox.minLat, bbox.minLon),
            (bbox.minLat, bbox.maxLon),
            (bbox.maxLat, bbox.maxLon),
            (bbox.maxLat, bbox.minLon),
        ]
    }
}

// MARK: - Map Block (for rendering on SwiftUI Map)

/// A colored rectangle block representing a group of crop map pixels.
struct CropMapBlock: Identifiable {
    let id: Int
    let code: UInt8
    let minLat: Double
    let minLon: Double
    let maxLat: Double
    let maxLon: Double
    let r: UInt8, g: UInt8, b: UInt8
}

// MARK: - CropMapService

/// Downloads and processes crop map rasters from USDA CDL and ESA WorldCover.
actor CropMapService {
    private let log = ActivityLog.shared
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - USDA CDL Download

    /// Download USDA Cropland Data Layer for a bounding box (US only).
    /// Returns a CropMapRaster with uint8 crop type codes.
    func downloadCDL(
        bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        year: Int = 2023
    ) async throws -> CropMapRaster {
        // CDL resolution is 30m; at equator ~0.00027° per pixel
        let resx = 0.0003
        let resy = 0.0003
        let coverageID = year >= 1997 ? "cdl_\(year)" : "cdl_2023"

        var components = URLComponents(string: "https://nassgeodata.gmu.edu/CropScapeService/wms_cdlall.cgi")!
        components.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WCS"),
            URLQueryItem(name: "VERSION", value: "1.0.0"),
            URLQueryItem(name: "REQUEST", value: "GetCoverage"),
            URLQueryItem(name: "COVERAGE", value: coverageID),
            URLQueryItem(name: "CRS", value: "EPSG:4326"),
            URLQueryItem(name: "BBOX", value: "\(bbox.minLon),\(bbox.minLat),\(bbox.maxLon),\(bbox.maxLat)"),
            URLQueryItem(name: "RESX", value: String(resx)),
            URLQueryItem(name: "RESY", value: String(resy)),
            URLQueryItem(name: "FORMAT", value: "GTiff"),
        ]

        guard let url = components.url else {
            throw CropMapError.invalidURL
        }

        await log.info("CDL: downloading crop map (\(coverageID))...")
        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CropMapError.httpError(code)
        }

        // Check for XML error response
        if data.count < 100, let text = String(data: data, encoding: .utf8), text.contains("Error") {
            throw CropMapError.serverError(text)
        }

        // Parse uncompressed GeoTIFF (reads actual geotransform for correct registration)
        let raster = try parseSimpleGeoTIFF(data: data, requestedBbox: bbox, source: .cdl)
        await log.success("CDL: \(raster.width)x\(raster.height) crop map loaded")
        return raster
    }

    // MARK: - ESA WorldCover Download

    /// Download ESA WorldCover for a bounding box (global, 10m).
    /// Uses the existing COGReader to read from S3 COG tiles.
    func downloadWorldCover(
        bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)
    ) async throws -> CropMapRaster {
        // Determine the 3-degree tile(s) needed
        let tileLat = Int(floor(bbox.minLat / 3.0)) * 3
        let tileLon = Int(floor(bbox.minLon / 3.0)) * 3

        let latStr = tileLat >= 0 ? "N\(String(format: "%02d", tileLat))" : "S\(String(format: "%02d", abs(tileLat)))"
        let lonStr = tileLon >= 0 ? "E\(String(format: "%03d", tileLon))" : "W\(String(format: "%03d", abs(tileLon)))"

        let tileURL = URL(string: "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_\(latStr)\(lonStr)_Map.tif")!

        await log.info("WorldCover: downloading \(latStr)\(lonStr) tile...")

        // Use COGReader to read the relevant portion
        let cogReader = COGReader()

        // First get the geotransform
        guard let geoTransform = try await cogReader.readGeoTransform(url: tileURL) else {
            throw CropMapError.missingTransform
        }

        // WorldCover is in EPSG:4326, so pixel bounds are straightforward
        let scaleX = geoTransform[0]  // ~0.0000833 (~10m at equator)
        let originX = geoTransform[2]
        let scaleY = geoTransform[4]  // negative
        let originY = geoTransform[5]

        let minCol = Int(floor((bbox.minLon - originX) / scaleX))
        let maxCol = Int(ceil((bbox.maxLon - originX) / scaleX))
        let minRow = Int(floor((bbox.maxLat - originY) / scaleY))
        let maxRow = Int(ceil((bbox.minLat - originY) / scaleY))

        let pixelBounds = (
            minCol: max(0, min(minCol, maxCol)),
            minRow: max(0, min(minRow, maxRow)),
            maxCol: max(minCol, maxCol),
            maxRow: max(minRow, maxRow)
        )

        // Read UInt16 data from COG, convert to UInt8 (values are 10-100)
        let uint16Data = try await cogReader.readRegion(url: tileURL, pixelBounds: pixelBounds)
        let height = uint16Data.count
        let width = uint16Data.first?.count ?? 0
        guard width > 0 && height > 0 else { throw CropMapError.invalidDimensions }

        var uint8Data = [UInt8](repeating: 0, count: width * height)
        for r in 0..<height {
            for c in 0..<width {
                uint8Data[r * width + c] = UInt8(min(255, uint16Data[r][c]))
            }
        }

        await log.success("WorldCover: \(width)x\(height) land cover loaded")
        return CropMapRaster(width: width, height: height, data: uint8Data, bbox: bbox, source: .worldCover)
    }

    // MARK: - Field Extraction

    /// Extract contiguous fields of a given crop type using connected-component labeling.
    func extractFields(
        from raster: CropMapRaster,
        cropCode: UInt8,
        minPixels: Int = 10
    ) -> [ExtractedField] {
        let w = raster.width, h = raster.height
        guard w > 0 && h > 0 else { return [] }
        guard w * h <= 2_000_000 else { return [] } // cap to avoid memory issues
        var labels = [Int](repeating: 0, count: w * h)
        var nextLabel = 1
        let maxFieldPixels = 50_000 // cap BFS to avoid memory blow-up

        // Simple flood-fill connected component labeling (4-connected)
        for r in 0..<h {
            for c in 0..<w {
                let idx = r * w + c
                guard raster.data[idx] == cropCode && labels[idx] == 0 else { continue }

                // BFS flood fill
                let label = nextLabel
                nextLabel += 1
                var queue = [(r, c)]
                labels[idx] = label
                var head = 0

                while head < queue.count {
                    if queue.count > maxFieldPixels { break }
                    let (cr, cc) = queue[head]; head += 1
                    let neighbors = [(cr-1,cc), (cr+1,cc), (cr,cc-1), (cr,cc+1)]
                    for (nr, nc) in neighbors {
                        guard nr >= 0 && nr < h && nc >= 0 && nc < w else { continue }
                        let ni = nr * w + nc
                        guard raster.data[ni] == cropCode && labels[ni] == 0 else { continue }
                        labels[ni] = label
                        queue.append((nr, nc))
                    }
                }
            }
        }

        // Collect field stats
        struct FieldStats {
            var pixelCount = 0
            var minRow = Int.max, maxRow = 0, minCol = Int.max, maxCol = 0
            var sumRow = 0.0, sumCol = 0.0
        }
        var stats = [Int: FieldStats]()
        for r in 0..<h {
            for c in 0..<w {
                let l = labels[r * w + c]
                guard l > 0 else { continue }
                var s = stats[l] ?? FieldStats()
                s.pixelCount += 1
                s.minRow = min(s.minRow, r); s.maxRow = max(s.maxRow, r)
                s.minCol = min(s.minCol, c); s.maxCol = max(s.maxCol, c)
                s.sumRow += Double(r); s.sumCol += Double(c)
                stats[l] = s
            }
        }

        let cropName: String
        switch raster.source {
        case .cdl: cropName = CDLCropType(rawValue: cropCode)?.name ?? "Crop \(cropCode)"
        case .worldCover: cropName = WorldCoverClass(rawValue: cropCode)?.name ?? "Class \(cropCode)"
        }

        let pxW = raster.pixelWidth
        let pxH = raster.pixelHeight
        // Approximate pixel area in sq meters
        let midLat = (raster.bbox.minLat + raster.bbox.maxLat) / 2
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(midLat * .pi / 180)
        let pixelAreaSqM = (pxW * mPerDegLon) * (pxH * mPerDegLat)

        return stats.compactMap { (_, s) in
            guard s.pixelCount >= minPixels else { return nil }
            let centLon = raster.bbox.minLon + (s.sumCol / Double(s.pixelCount) + 0.5) * pxW
            let centLat = raster.bbox.maxLat - (s.sumRow / Double(s.pixelCount) + 0.5) * pxH
            let fieldBbox = (
                minLon: raster.bbox.minLon + Double(s.minCol) * pxW,
                minLat: raster.bbox.maxLat - Double(s.maxRow + 1) * pxH,
                maxLon: raster.bbox.minLon + Double(s.maxCol + 1) * pxW,
                maxLat: raster.bbox.maxLat - Double(s.minRow) * pxH
            )
            return ExtractedField(
                cropCode: cropCode,
                cropName: cropName,
                pixelCount: s.pixelCount,
                areaSqM: Double(s.pixelCount) * pixelAreaSqM,
                centroid: (lat: centLat, lon: centLon),
                bbox: fieldBbox
            )
        }
        .sorted { $0.areaSqM > $1.areaSqM } // largest first
    }

    // MARK: - Block Rendering

    /// Generate colored map blocks from a raster. Groups pixels into blocks for efficient MapPolygon rendering.
    func generateBlocks(
        from raster: CropMapRaster,
        enabledCodes: Set<UInt8>,
        blockSize: Int = 3
    ) -> [CropMapBlock] {
        let w = raster.width, h = raster.height
        guard w > 0 && h > 0 else { return [] }
        let pxW = raster.pixelWidth, pxH = raster.pixelHeight
        var blocks = [CropMapBlock]()
        var blockId = 0

        let blocksX = (w + blockSize - 1) / blockSize
        let blocksY = (h + blockSize - 1) / blockSize

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                // Find dominant class in this block
                var counts = [UInt8: Int]()
                let startRow = by * blockSize, startCol = bx * blockSize
                let endRow = min(startRow + blockSize, h)
                let endCol = min(startCol + blockSize, w)
                for r in startRow..<endRow {
                    for c in startCol..<endCol {
                        let code = raster.data[r * w + c]
                        if code > 0 && enabledCodes.contains(code) {
                            counts[code, default: 0] += 1
                        }
                    }
                }
                guard let (dominant, _) = counts.max(by: { $0.value < $1.value }) else { continue }

                let color: (r: UInt8, g: UInt8, b: UInt8)
                switch raster.source {
                case .cdl: color = CDLCropType(rawValue: dominant)?.color ?? (128, 128, 128)
                case .worldCover: color = WorldCoverClass(rawValue: dominant)?.color ?? (128, 128, 128)
                }

                let minLon = raster.bbox.minLon + Double(startCol) * pxW
                let maxLon = raster.bbox.minLon + Double(endCol) * pxW
                let maxLat = raster.bbox.maxLat - Double(startRow) * pxH
                let minLat = raster.bbox.maxLat - Double(endRow) * pxH

                blocks.append(CropMapBlock(
                    id: blockId, code: dominant,
                    minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
                    r: color.r, g: color.g, b: color.b
                ))
                blockId += 1
            }
        }
        return blocks
    }

    // MARK: - Simple GeoTIFF Parser

    /// Parse a simple uncompressed 8-bit GeoTIFF (as returned by CDL WCS).
    private func parseSimpleGeoTIFF(
        data: Data,
        requestedBbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        source: CropMapDataSource
    ) throws -> CropMapRaster {
        guard data.count >= 8 else { throw CropMapError.invalidTIFF }

        // Check TIFF magic — use unaligned load for safety
        let byteOrder: UInt16 = data.withUnsafeBytes { buf in
            var v: UInt16 = 0
            memcpy(&v, buf.baseAddress!, 2)
            return v
        }
        let isLittleEndian = byteOrder == 0x4949
        guard isLittleEndian || byteOrder == 0x4D4D else { throw CropMapError.invalidTIFF }

        func readU16(_ offset: Int) -> UInt16 {
            guard offset >= 0, offset + 2 <= data.count else { return 0 }
            var v: UInt16 = 0
            data.withUnsafeBytes { memcpy(&v, $0.baseAddress! + offset, 2) }
            return isLittleEndian ? v : v.byteSwapped
        }
        func readU32(_ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            var v: UInt32 = 0
            data.withUnsafeBytes { memcpy(&v, $0.baseAddress! + offset, 4) }
            return isLittleEndian ? v : v.byteSwapped
        }
        func readF64(_ offset: Int) -> Double {
            guard offset >= 0, offset + 8 <= data.count else { return 0 }
            var v: UInt64 = 0
            data.withUnsafeBytes { memcpy(&v, $0.baseAddress! + offset, 8) }
            let ordered = isLittleEndian ? v : v.byteSwapped
            return Double(bitPattern: ordered)
        }

        let magic = readU16(2)
        guard magic == 42 else { throw CropMapError.invalidTIFF }

        let ifdOffset = Int(readU32(4))
        guard ifdOffset > 0, ifdOffset + 2 < data.count else { throw CropMapError.invalidTIFF }

        let numEntries = Int(readU16(ifdOffset))
        var imageWidth = 0, imageHeight = 0
        var stripOffsets = [Int](), stripByteCounts = [Int]()
        var rowsPerStrip = 0
        var bitsPerSample: UInt16 = 8

        // GeoTIFF tags
        var pixelScaleOffset: Int?
        var pixelScaleCount = 0
        var tiepointOffset: Int?
        var tiepointCount = 0

        for i in 0..<numEntries {
            let entryOffset = ifdOffset + 2 + i * 12
            guard entryOffset + 12 <= data.count else { break }
            let tag = readU16(entryOffset)
            let type = readU16(entryOffset + 2)
            let count = Int(readU32(entryOffset + 4))
            let valueOffset = entryOffset + 8

            switch tag {
            case 256: // ImageWidth
                imageWidth = type == 3 ? Int(readU16(valueOffset)) : Int(readU32(valueOffset))
            case 257: // ImageLength
                imageHeight = type == 3 ? Int(readU16(valueOffset)) : Int(readU32(valueOffset))
            case 258: // BitsPerSample
                bitsPerSample = readU16(valueOffset)
            case 278: // RowsPerStrip
                rowsPerStrip = type == 3 ? Int(readU16(valueOffset)) : Int(readU32(valueOffset))
            case 273: // StripOffsets
                if count == 1 {
                    stripOffsets = [type == 3 ? Int(readU16(valueOffset)) : Int(readU32(valueOffset))]
                } else {
                    let ptr = Int(readU32(valueOffset))
                    for j in 0..<count {
                        guard ptr + j * 4 + 4 <= data.count else { break }
                        stripOffsets.append(Int(readU32(ptr + j * 4)))
                    }
                }
            case 279: // StripByteCounts
                if count == 1 {
                    stripByteCounts = [type == 3 ? Int(readU16(valueOffset)) : Int(readU32(valueOffset))]
                } else {
                    let ptr = Int(readU32(valueOffset))
                    for j in 0..<count {
                        guard ptr + j * 4 + 4 <= data.count else { break }
                        stripByteCounts.append(Int(readU32(ptr + j * 4)))
                    }
                }
            case 33550: // ModelPixelScale (scaleX, scaleY, scaleZ) — DOUBLE values
                pixelScaleCount = count
                // Doubles are 8 bytes each; if total > 4 bytes, value field is an offset pointer
                let psBytes = count * 8
                pixelScaleOffset = psBytes <= 4 ? valueOffset : Int(readU32(valueOffset))
            case 33922: // ModelTiepoint (I, J, K, X, Y, Z) — DOUBLE values
                tiepointCount = count
                tiepointOffset = Int(readU32(valueOffset))
            default: break
            }
        }

        guard imageWidth > 0, imageHeight > 0 else { throw CropMapError.invalidDimensions }
        guard bitsPerSample == 8 else { throw CropMapError.unsupportedFormat("BitsPerSample=\(bitsPerSample)") }

        // Compute actual bbox from GeoTIFF tiepoint + pixel scale
        var actualBbox = requestedBbox
        if let psOff = pixelScaleOffset, pixelScaleCount >= 2,
           let tpOff = tiepointOffset, tiepointCount >= 6,
           psOff + 16 <= data.count, tpOff + 40 <= data.count {
            let scaleX = readF64(psOff)         // degrees per pixel (longitude)
            let scaleY = readF64(psOff + 8)     // degrees per pixel (latitude)
            let tpI = readF64(tpOff)            // pixel column of tiepoint
            let tpJ = readF64(tpOff + 8)        // pixel row of tiepoint
            // tpOff+16 = K (always 0)
            let tpX = readF64(tpOff + 24)       // longitude of tiepoint
            let tpY = readF64(tpOff + 32)       // latitude of tiepoint

            if scaleX > 0 && scaleY > 0 {
                // Origin (top-left corner): X - I*scaleX, Y + J*scaleY
                let originLon = tpX - tpI * scaleX
                let originLat = tpY + tpJ * scaleY
                actualBbox = (
                    minLon: originLon,
                    minLat: originLat - Double(imageHeight) * scaleY,
                    maxLon: originLon + Double(imageWidth) * scaleX,
                    maxLat: originLat
                )
                // Geotransform successfully parsed from TIFF tags
            }
        }

        // Read pixel data from strips
        var pixels = [UInt8](repeating: 0, count: imageWidth * imageHeight)
        if !stripOffsets.isEmpty {
            var pixelIdx = 0
            for (si, offset) in stripOffsets.enumerated() {
                let byteCount = si < stripByteCounts.count ? stripByteCounts[si] : (imageWidth * (si < stripOffsets.count - 1 ? rowsPerStrip : (imageHeight - si * rowsPerStrip)))
                let end = min(offset + byteCount, data.count)
                guard offset >= 0, offset < data.count else { continue }
                for b in offset..<end {
                    if pixelIdx < pixels.count {
                        pixels[pixelIdx] = data[b]
                        pixelIdx += 1
                    }
                }
            }
        }

        return CropMapRaster(width: imageWidth, height: imageHeight, data: pixels, bbox: actualBbox, source: source)
    }
}

// MARK: - Errors

enum CropMapError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case serverError(String)
    case invalidTIFF
    case invalidDimensions
    case unsupportedFormat(String)
    case missingTransform
    case noDataAvailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid crop map URL"
        case .httpError(let code): return "HTTP error \(code)"
        case .serverError(let msg): return "Server error: \(msg)"
        case .invalidTIFF: return "Invalid GeoTIFF data"
        case .invalidDimensions: return "Invalid image dimensions"
        case .unsupportedFormat(let f): return "Unsupported format: \(f)"
        case .missingTransform: return "Missing geo-transform"
        case .noDataAvailable: return "No crop map data available for this location"
        }
    }
}

// MARK: - CDL code lookup from crop name

extension CDLCropType {
    /// Find CDL crop code(s) matching a crop name (case-insensitive partial match).
    static func codes(forCrop name: String) -> [UInt8] {
        let lower = name.lowercased()
        // Direct mappings from CropRegionDatabase crop names to CDL codes
        let mapping: [String: [UInt8]] = [
            "maize": [1], "corn": [1],
            "cotton": [2],
            "rice": [3],
            "sorghum": [4],
            "soybean": [5], "soybeans": [5],
            "sunflower": [6],
            "barley": [21],
            "spring wheat": [23],
            "winter wheat": [24],
            "wheat": [23, 24],
            "alfalfa": [36],
            "sugarbeets": [41],
            "potato": [43], "potatoes": [43],
            "sugarcane": [45],
            "oats": [28],
            "peanuts": [10],
        ]
        // Exact match first
        if let codes = mapping[lower] { return codes }
        // Partial match
        for (key, codes) in mapping {
            if lower.contains(key) || key.contains(lower) { return codes }
        }
        return []
    }
}
