import Foundation

/// Google Earth Engine REST API service for searching and fetching Sentinel-2 imagery.
struct GEEService {
    let projectID: String
    let tokenManager: GEETokenManager

    private let log = ActivityLog.shared

    /// Dedicated URLSession with no caching.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Search

    /// Search COPERNICUS/S2_SR_HARMONIZED via GEE REST API, returning adapted STACItems.
    func search(
        geometry: GeoJSONGeometry,
        startDate: String,
        endDate: String,
        maxCloudCover: Double = 80
    ) async throws -> [STACItem] {
        let headers = try await tokenManager.authHeaders()
        let collection = "COPERNICUS/S2_SR_HARMONIZED"
        let baseURL = "https://earthengine.googleapis.com/v1/projects/\(projectID)/assets/\(collection):listImages"

        // Build filter: date range + spatial intersection + cloud cover
        let centroid = geometry.centroid
        let bbox = geometry.bbox
        let filterJSON: [String: Any] = [
            "startTime": "\(startDate)T00:00:00Z",
            "endTime": "\(endDate)T23:59:59Z",
            "region": [
                "type": "Polygon",
                "coordinates": [[
                    [bbox.minLon, bbox.minLat],
                    [bbox.maxLon, bbox.minLat],
                    [bbox.maxLon, bbox.maxLat],
                    [bbox.minLon, bbox.maxLat],
                    [bbox.minLon, bbox.minLat]
                ]]
            ] as [String: Any],
            "filter": "properties.CLOUDY_PIXEL_PERCENTAGE < \(Int(maxCloudCover))"
        ]

        var allItems = [STACItem]()
        var pageToken: String? = nil

        repeat {
            var urlStr = baseURL
            var queryItems = [String]()
            if let pt = pageToken {
                queryItems.append("pageToken=\(pt)")
            }
            queryItems.append("pageSize=100")
            if !queryItems.isEmpty {
                urlStr += "?" + queryItems.joined(separator: "&")
            }

            guard let url = URL(string: urlStr) else { break }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            request.timeoutInterval = 30
            request.httpBody = try JSONSerialization.data(withJSONObject: filterJSON)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { break }

            if http.statusCode == 401 || http.statusCode == 403 {
                throw GEEError.authFailed(http.statusCode)
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw GEEError.searchFailed(http.statusCode, body)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }

            if let images = json["images"] as? [[String: Any]] {
                for img in images {
                    if let item = adaptGEEImage(img, centroid: centroid) {
                        allItems.append(item)
                    }
                }
            }

            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil

        return allItems.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    // MARK: - Pixel Fetch

    struct GEEPixelResult {
        let bands: [[UInt16]]   // One 2D row-major array per band
        let width: Int
        let height: Int
    }

    /// Fetch pixel data via computePixels endpoint.
    func fetchPixels(
        imageID: String,
        bandIds: [String],
        transform: (scaleX: Double, scaleY: Double, translateX: Double, translateY: Double),
        width: Int,
        height: Int,
        crsCode: String
    ) async throws -> GEEPixelResult {
        let headers = try await tokenManager.authHeaders()
        let url = URL(string: "https://earthengine.googleapis.com/v1/projects/\(projectID)/image:computePixels")!

        let requestBody: [String: Any] = [
            "expression": [
                "functionInvocationValue": [
                    "functionName": "Image.load",
                    "arguments": [
                        "id": ["constantValue": imageID]
                    ]
                ]
            ],
            "fileFormat": "GEO_TIFF",
            "bandIds": bandIds,
            "grid": [
                "dimensions": ["width": width, "height": height],
                "affineTransform": [
                    "scaleX": transform.scaleX,
                    "shearX": 0,
                    "translateX": transform.translateX,
                    "shearY": 0,
                    "scaleY": transform.scaleY,
                    "translateY": transform.translateY
                ],
                "crsCode": crsCode
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GEEError.pixelFetchFailed(0, "No HTTP response")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw GEEError.authFailed(http.statusCode)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GEEError.pixelFetchFailed(http.statusCode, body)
        }

        // Parse the multi-band GeoTIFF response
        let bands = try GEETiffParser.parse(data: data, expectedBands: bandIds.count)
        return GEEPixelResult(bands: bands, width: width, height: height)
    }

    // MARK: - Adapt GEE Image to STACItem

    private func adaptGEEImage(_ img: [String: Any], centroid: (lat: Double, lon: Double)) -> STACItem? {
        // Extract image name/ID
        guard let name = img["name"] as? String else { return nil }
        // name is like "projects/{project}/assets/COPERNICUS/S2_SR_HARMONIZED/20220801T093559_..."
        // Extract the image ID (everything after the collection path)
        let imageID: String
        if let range = name.range(of: "COPERNICUS/S2_SR_HARMONIZED/") {
            imageID = "COPERNICUS/S2_SR_HARMONIZED/" + name[range.upperBound...]
        } else {
            imageID = name
        }

        // Extract properties
        let properties = img["properties"] as? [String: Any] ?? [:]

        // Datetime from system:time_start (milliseconds since epoch)
        let datetime: String
        if let ts = properties["system:time_start"] as? Double {
            let date = Date(timeIntervalSince1970: ts / 1000)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            datetime = fmt.string(from: date)
        } else if let timeStart = img["startTime"] as? String {
            datetime = timeStart
        } else {
            return nil
        }

        // Cloud cover
        let cloudCover = properties["CLOUDY_PIXEL_PERCENTAGE"] as? Double
            ?? (properties["system:footprint"] as? Double)

        // Determine EPSG from centroid
        let utm = UTMProjection.zoneFor(lon: centroid.lon, lat: centroid.lat)

        // Build synthetic STACItem
        let stacProperties = STACProperties(
            datetime: datetime,
            cloudCover: cloudCover,
            projEpsg: utm.epsg,
            boaOffsetApplied: nil,
            processingBaseline: nil,
            productURI: nil
        )

        // Synthetic assets with gee:// hrefs containing the image ID
        let syntheticAsset = STACAsset(
            href: "gee://\(imageID)",
            type: "application/geo+json",
            title: "GEE Image",
            projTransform: nil,
            projShape: nil
        )

        let stacItem = STACItem(
            id: imageID,
            properties: stacProperties,
            assets: ["B4": syntheticAsset]
        )

        return stacItem
    }
}

// MARK: - GEE TIFF Parser

/// Parses multi-band GeoTIFF returned by GEE computePixels (in-memory, not COG).
enum GEETiffParser {
    enum ParseError: Error, LocalizedError {
        case invalidTIFF(String)
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .invalidTIFF(let msg): return "Invalid TIFF: \(msg)"
            case .unsupportedFormat(let msg): return "Unsupported format: \(msg)"
            }
        }
    }

    /// Parse a multi-band GeoTIFF into per-band 2D arrays of UInt16.
    /// Returns array of bands, each as a flat row-major [UInt16] array.
    static func parse(data: Data, expectedBands: Int) throws -> [[UInt16]] {
        guard data.count >= 8 else {
            throw ParseError.invalidTIFF("Data too short (\(data.count) bytes)")
        }

        let byteOrder = data[0..<2]
        let isLittleEndian = byteOrder == Data([0x49, 0x49])

        func readU16(_ offset: Int) -> UInt16 {
            guard offset + 2 <= data.count else { return 0 }
            let val = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
            return isLittleEndian ? val.littleEndian : val.bigEndian
        }
        func readU32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            let val = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            return isLittleEndian ? val.littleEndian : val.bigEndian
        }

        let magic = readU16(2)
        guard magic == 42 else {
            throw ParseError.invalidTIFF("Not a TIFF file (magic=\(magic))")
        }

        // Parse all IFDs
        var bands = [[UInt16]]()
        var ifdOffset = Int(readU32(4))

        while ifdOffset > 0 && ifdOffset < data.count {
            let numEntries = Int(readU16(ifdOffset))
            guard numEntries > 0 && numEntries < 100 else { break }

            var imageWidth = 0
            var imageHeight = 0
            var bitsPerSample = 16
            var samplesPerPixel = 1
            var compression: UInt16 = 1
            var stripOffsets = [Int]()
            var stripByteCounts = [Int]()
            var rowsPerStrip = 0

            for i in 0..<numEntries {
                let entryOffset = ifdOffset + 2 + i * 12
                guard entryOffset + 12 <= data.count else { break }

                let tag = readU16(entryOffset)
                let type = readU16(entryOffset + 2)
                let count = Int(readU32(entryOffset + 4))
                let valueOffset = entryOffset + 8

                func tagValue() -> Int {
                    switch type {
                    case 3: return Int(readU16(valueOffset))  // SHORT
                    case 4: return Int(readU32(valueOffset))  // LONG
                    default: return Int(readU16(valueOffset))
                    }
                }

                func tagValues() -> [Int] {
                    if count == 1 { return [tagValue()] }
                    let dataOffset: Int
                    if count * (type == 3 ? 2 : 4) <= 4 {
                        dataOffset = valueOffset
                    } else {
                        dataOffset = Int(readU32(valueOffset))
                    }
                    var vals = [Int]()
                    for j in 0..<count {
                        let off = dataOffset + j * (type == 3 ? 2 : 4)
                        if type == 3 { vals.append(Int(readU16(off))) }
                        else { vals.append(Int(readU32(off))) }
                    }
                    return vals
                }

                switch tag {
                case 256: imageWidth = tagValue()       // ImageWidth
                case 257: imageHeight = tagValue()      // ImageLength
                case 258: bitsPerSample = tagValue()    // BitsPerSample
                case 259: compression = UInt16(tagValue())  // Compression
                case 277: samplesPerPixel = tagValue()  // SamplesPerPixel
                case 278: rowsPerStrip = tagValue()     // RowsPerStrip
                case 273: stripOffsets = tagValues()     // StripOffsets
                case 279: stripByteCounts = tagValues()  // StripByteCounts
                default: break
                }
            }

            if imageWidth == 0 || imageHeight == 0 { break }
            if rowsPerStrip == 0 { rowsPerStrip = imageHeight }

            let bytesPerSample = max(1, bitsPerSample / 8)
            let totalPixels = imageWidth * imageHeight

            if samplesPerPixel > 1 {
                // Interleaved multi-band: parse all bands from this single IFD
                var allPixelData = [UInt8]()
                for i in 0..<stripOffsets.count {
                    let offset = stripOffsets[i]
                    let length = i < stripByteCounts.count ? stripByteCounts[i] : 0
                    guard offset + length <= data.count, length > 0 else { continue }
                    let stripData = data.subdata(in: offset..<offset+length)
                    let raw = try decompressStrip(stripData, compression: compression,
                                                  expectedSize: imageWidth * rowsPerStrip * bytesPerSample * samplesPerPixel)
                    allPixelData.append(contentsOf: raw)
                }

                // De-interleave
                for band in 0..<samplesPerPixel {
                    var pixels = [UInt16]()
                    pixels.reserveCapacity(totalPixels)
                    for px in 0..<totalPixels {
                        let idx = (px * samplesPerPixel + band) * bytesPerSample
                        if bytesPerSample == 2 && idx + 1 < allPixelData.count {
                            let val = isLittleEndian
                                ? UInt16(allPixelData[idx]) | (UInt16(allPixelData[idx+1]) << 8)
                                : (UInt16(allPixelData[idx]) << 8) | UInt16(allPixelData[idx+1])
                            pixels.append(val)
                        } else if bytesPerSample == 1 && idx < allPixelData.count {
                            pixels.append(UInt16(allPixelData[idx]))
                        }
                    }
                    bands.append(pixels)
                }
                // All bands extracted from interleaved IFD — done
                break
            } else {
                // Single band per IFD (band-sequential)
                var allStripData = [UInt8]()
                for i in 0..<stripOffsets.count {
                    let offset = stripOffsets[i]
                    let length = i < stripByteCounts.count ? stripByteCounts[i] : 0
                    guard offset + length <= data.count, length > 0 else { continue }
                    let stripData = data.subdata(in: offset..<offset+length)
                    let rows = min(rowsPerStrip, imageHeight - i * rowsPerStrip)
                    let raw = try decompressStrip(stripData, compression: compression,
                                                  expectedSize: imageWidth * rows * bytesPerSample)
                    allStripData.append(contentsOf: raw)
                }

                var pixels = [UInt16]()
                pixels.reserveCapacity(totalPixels)
                if bytesPerSample >= 2 {
                    for i in stride(from: 0, to: min(allStripData.count, totalPixels * 2), by: 2) {
                        if i + 1 < allStripData.count {
                            let val = isLittleEndian
                                ? UInt16(allStripData[i]) | (UInt16(allStripData[i+1]) << 8)
                                : (UInt16(allStripData[i]) << 8) | UInt16(allStripData[i+1])
                            pixels.append(val)
                        }
                    }
                } else {
                    for b in allStripData.prefix(totalPixels) {
                        pixels.append(UInt16(b))
                    }
                }
                bands.append(pixels)
            }

            // Next IFD
            let nextIFDOff = ifdOffset + 2 + numEntries * 12
            guard nextIFDOff + 4 <= data.count else { break }
            ifdOffset = Int(readU32(nextIFDOff))
        }

        return bands
    }

    // MARK: - Decompression

    private static func decompressStrip(_ data: Data, compression: UInt16, expectedSize: Int) throws -> [UInt8] {
        switch compression {
        case 1: // No compression
            return [UInt8](data)

        case 8, 32946: // DEFLATE / Adobe DEFLATE
            let source = [UInt8](data)
            var destLen = uLong(expectedSize)
            var dest = [UInt8](repeating: 0, count: expectedSize)
            let ret = uncompress(&dest, &destLen, source, uLong(source.count))
            if ret == Z_OK {
                return Array(dest[0..<Int(destLen)])
            }
            // Try larger buffer
            if ret == Z_BUF_ERROR {
                let bigSize = expectedSize * 4
                var bigDest = [UInt8](repeating: 0, count: bigSize)
                var bigDestLen = uLong(bigSize)
                let ret2 = uncompress(&bigDest, &bigDestLen, source, uLong(source.count))
                if ret2 == Z_OK {
                    return Array(bigDest[0..<Int(bigDestLen)])
                }
            }
            // If data is already the right size, treat as uncompressed
            if data.count == expectedSize {
                return source
            }
            throw ParseError.unsupportedFormat("DEFLATE decompression failed (zlib ret=\(ret))")

        case 5: // LZW
            return try decompressLZW(data)

        default:
            throw ParseError.unsupportedFormat("Unsupported compression type: \(compression)")
        }
    }

    /// Basic LZW decompression for TIFF.
    private static func decompressLZW(_ data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 3)

        var table = [[UInt8]]()
        let clearCode = 256
        let eoiCode = 257
        var nextCode = 258
        var codeSize = 9

        // Initialize table
        func resetTable() {
            table = (0..<256).map { [UInt8($0)] }
            table.append([])  // clearCode placeholder
            table.append([])  // eoiCode placeholder
            nextCode = 258
            codeSize = 9
        }
        resetTable()

        var bitPos = 0
        func readCode() -> Int? {
            guard bitPos + codeSize <= bytes.count * 8 else { return nil }
            var code = 0
            for i in 0..<codeSize {
                let byteIdx = (bitPos + i) / 8
                let bitIdx = (bitPos + i) % 8
                guard byteIdx < bytes.count else { return nil }
                if bytes[byteIdx] & (1 << (7 - bitIdx)) != 0 {
                    code |= 1 << (codeSize - 1 - i)
                }
            }
            bitPos += codeSize
            return code
        }

        guard let firstCode = readCode(), firstCode == clearCode else {
            throw ParseError.unsupportedFormat("LZW: expected clear code")
        }

        guard var code = readCode(), code != eoiCode else {
            return output
        }
        guard code < table.count else {
            throw ParseError.unsupportedFormat("LZW: invalid first code")
        }
        var oldEntry = table[code]
        output.append(contentsOf: oldEntry)

        while let code = readCode() {
            if code == eoiCode { break }
            if code == clearCode {
                resetTable()
                guard let c = readCode(), c != eoiCode else { break }
                guard c < table.count else { break }
                oldEntry = table[c]
                output.append(contentsOf: oldEntry)
                continue
            }

            let entry: [UInt8]
            if code < nextCode {
                entry = table[code]
            } else if code == nextCode {
                entry = oldEntry + [oldEntry[0]]
            } else {
                break
            }

            output.append(contentsOf: entry)
            if nextCode < 4096 {
                table.append(oldEntry + [entry[0]])
                nextCode += 1
                if nextCode > (1 << codeSize) && codeSize < 12 {
                    codeSize += 1
                }
            }
            oldEntry = entry
        }

        return output
    }
}

// MARK: - GEE Errors

enum GEEError: Error, LocalizedError {
    case authFailed(Int)
    case searchFailed(Int, String)
    case pixelFetchFailed(Int, String)
    case noProjectID
    case invalidImageID

    var errorDescription: String? {
        switch self {
        case .authFailed(let code): return "GEE auth failed (HTTP \(code))"
        case .searchFailed(let code, let msg): return "GEE search failed (HTTP \(code)): \(msg.prefix(200))"
        case .pixelFetchFailed(let code, let msg): return "GEE pixel fetch failed (HTTP \(code)): \(msg.prefix(200))"
        case .noProjectID: return "GEE project ID not configured"
        case .invalidImageID: return "Invalid GEE image ID"
        }
    }
}
