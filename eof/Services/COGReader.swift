import Foundation

/// Reads Cloud Optimized GeoTIFF (COG) files via HTTP range requests.
/// Supports TIFF and BigTIFF with DEFLATE-compressed UInt16 tiles.
actor COGReader {

    // MARK: - TIFF Constants

    private static let tiffMagic: UInt16 = 42
    private static let bigTiffMagic: UInt16 = 43

    // Tag IDs
    private static let tagImageWidth: UInt16 = 256
    private static let tagImageLength: UInt16 = 257
    private static let tagBitsPerSample: UInt16 = 258
    private static let tagCompression: UInt16 = 259
    private static let tagPredictor: UInt16 = 317
    private static let tagTileWidth: UInt16 = 322
    private static let tagTileLength: UInt16 = 323
    private static let tagTileOffsets: UInt16 = 324
    private static let tagTileByteCounts: UInt16 = 325

    // Compression types
    private static let compressionNone: UInt16 = 1
    private static let compressionDeflate: UInt16 = 8
    private static let compressionAdobeDeflate: UInt16 = 32946

    private let log = ActivityLog.shared

    // MARK: - Public API

    /// Read a rectangular region of UInt16 pixels from a COG.
    func readRegion(url: URL, pixelBounds: (minCol: Int, minRow: Int, maxCol: Int, maxRow: Int), authHeaders: [String: String] = [:]) async throws -> [[UInt16]] {
        let headerSize = 131072  // 128KB to capture IFD + tile arrays
        let headerData = try await fetchRange(url: url, offset: 0, length: headerSize, authHeaders: authHeaders)
        let ifd = try parseFirstIFD(data: headerData)

        // Log IFD info for diagnostics
        let filename = url.lastPathComponent
        log.info("COG \(filename): \(ifd.imageWidth)x\(ifd.imageLength) bps=\(ifd.bitsPerSample) comp=\(ifd.compression) pred=\(ifd.predictor) tile=\(ifd.tileWidth)x\(ifd.tileLength)")

        let tilesAcross = (ifd.imageWidth + ifd.tileWidth - 1) / ifd.tileWidth
        let minTileCol = max(0, pixelBounds.minCol / ifd.tileWidth)
        let maxTileCol = min(tilesAcross - 1, pixelBounds.maxCol / ifd.tileWidth)
        let minTileRow = max(0, pixelBounds.minRow / ifd.tileLength)
        let maxTileRow = min((ifd.imageLength + ifd.tileLength - 1) / ifd.tileLength - 1,
                             pixelBounds.maxRow / ifd.tileLength)

        let offsets = try await readTileArray(
            url: url, headerData: headerData,
            arrayOffset: ifd.tileOffsetsOffset, count: ifd.tileCount,
            valueSize: ifd.tileOffsetValueSize, isLittleEndian: ifd.isLittleEndian,
            authHeaders: authHeaders
        )
        let byteCounts = try await readTileArray(
            url: url, headerData: headerData,
            arrayOffset: ifd.tileByteCountsOffset, count: ifd.tileCount,
            valueSize: ifd.tileByteCountValueSize, isLittleEndian: ifd.isLittleEndian,
            authHeaders: authHeaders
        )

        let outWidth = pixelBounds.maxCol - pixelBounds.minCol
        let outHeight = pixelBounds.maxRow - pixelBounds.minRow
        guard outWidth > 0 && outHeight > 0 && minTileRow <= maxTileRow && minTileCol <= maxTileCol else {
            return [[UInt16]](repeating: [UInt16](repeating: 0, count: max(1, outWidth)), count: max(1, outHeight))
        }
        var result = [[UInt16]](repeating: [UInt16](repeating: 0, count: outWidth), count: outHeight)

        for tileRow in minTileRow...maxTileRow {
            for tileCol in minTileCol...maxTileCol {
                let tileIndex = tileRow * tilesAcross + tileCol
                guard tileIndex < offsets.count && tileIndex < byteCounts.count else { continue }

                let offset = offsets[tileIndex]
                let byteCount = byteCounts[tileIndex]
                guard byteCount > 0 else { continue }

                let tileData = try await fetchRange(url: url, offset: UInt64(offset), length: Int(byteCount), authHeaders: authHeaders)
                let pixels = try decompressTileU16(
                    data: tileData, ifd: ifd
                )

                let tilePixelStartCol = tileCol * ifd.tileWidth
                let tilePixelStartRow = tileRow * ifd.tileLength

                for localRow in 0..<ifd.tileLength {
                    let globalRow = tilePixelStartRow + localRow
                    guard globalRow >= pixelBounds.minRow && globalRow < pixelBounds.maxRow else { continue }
                    let outRow = globalRow - pixelBounds.minRow

                    for localCol in 0..<ifd.tileWidth {
                        let globalCol = tilePixelStartCol + localCol
                        guard globalCol >= pixelBounds.minCol && globalCol < pixelBounds.maxCol else { continue }
                        let outCol = globalCol - pixelBounds.minCol
                        let pixelIndex = localRow * ifd.tileWidth + localCol
                        if pixelIndex < pixels.count {
                            result[outRow][outCol] = pixels[pixelIndex]
                        }
                    }
                }
            }
        }

        return result
    }

    // MARK: - IFD Parsing

    private struct IFDInfo {
        let isBigTiff: Bool
        let isLittleEndian: Bool
        let imageWidth: Int
        let imageLength: Int
        let tileWidth: Int
        let tileLength: Int
        let bitsPerSample: Int
        let compression: UInt16
        let predictor: Int
        let tileOffsetsOffset: UInt64
        let tileByteCountsOffset: UInt64
        let tileCount: Int
        let tileOffsetValueSize: Int    // bytes per offset value (4 or 8)
        let tileByteCountValueSize: Int // bytes per byte count value (2, 4, or 8)
    }

    private func parseFirstIFD(data: Data) throws -> IFDInfo {
        guard data.count >= 16 else {
            throw COGError.invalidTIFF("Header too short")
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

        func readU64(_ offset: Int) -> UInt64 {
            guard offset + 8 <= data.count else { return 0 }
            let val = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) }
            return isLittleEndian ? val.littleEndian : val.bigEndian
        }

        let magic = readU16(2)
        let isBigTiff = magic == Self.bigTiffMagic

        var ifdOffset: UInt64
        if isBigTiff {
            ifdOffset = readU64(8)
        } else {
            guard magic == Self.tiffMagic else {
                throw COGError.invalidTIFF("Not a TIFF file (magic=\(magic))")
            }
            ifdOffset = UInt64(readU32(4))
        }

        guard ifdOffset < data.count else {
            throw COGError.invalidTIFF("IFD offset \(ifdOffset) beyond header data")
        }

        let off = Int(ifdOffset)
        let entryCount: Int
        var entryStart: Int
        if isBigTiff {
            entryCount = Int(readU64(off))
            entryStart = off + 8
        } else {
            entryCount = Int(readU16(off))
            entryStart = off + 2
        }

        let entrySize = isBigTiff ? 20 : 12

        var imageWidth = 0
        var imageLength = 0
        var tileWidth = 512
        var tileLength = 512
        var bitsPerSample = 16
        var compression: UInt16 = 1
        var predictor = 1  // 1 = none, 2 = horizontal differencing
        var tileOffsetsOffset: UInt64 = 0
        var tileByteCountsOffset: UInt64 = 0
        var tileCount = 0
        var tileOffsetValueSize = 4
        var tileByteCountValueSize = 4

        // TIFF type sizes: 1=BYTE(1), 2=ASCII(1), 3=SHORT(2), 4=LONG(4), 5=RATIONAL(8),
        //                  16=LONG8(8), 17=SLONG8(8)
        func typeSizeBytes(_ t: UInt16) -> Int {
            switch t {
            case 1, 2, 6, 7: return 1   // BYTE, ASCII, SBYTE, UNDEFINED
            case 3, 8: return 2          // SHORT, SSHORT
            case 4, 9, 11: return 4      // LONG, SLONG, FLOAT
            case 5, 10, 12: return 8     // RATIONAL, SRATIONAL, DOUBLE
            case 16, 17: return 8        // LONG8, SLONG8 (BigTIFF)
            default: return 4
            }
        }

        for i in 0..<entryCount {
            let pos = entryStart + i * entrySize
            guard pos + entrySize <= data.count else { break }

            let tag = readU16(pos)
            let type = readU16(pos + 2)
            let count: UInt64
            let valueOffset: Int

            if isBigTiff {
                count = readU64(pos + 4)
                valueOffset = pos + 12
            } else {
                count = UInt64(readU32(pos + 4))
                valueOffset = pos + 8
            }

            func tagValueU32() -> UInt32 {
                if isBigTiff {
                    if type == 3 { return UInt32(readU16(valueOffset)) }
                    if type == 16 || type == 17 { return UInt32(readU64(valueOffset)) }
                    return UInt32(readU32(valueOffset))
                }
                if type == 3 { return UInt32(readU16(valueOffset)) }
                return readU32(valueOffset)
            }

            func tagValueU64() -> UInt64 {
                if isBigTiff { return readU64(valueOffset) }
                return UInt64(readU32(valueOffset))
            }

            // Max inline bytes: 4 for classic TIFF, 8 for BigTIFF
            let inlineBytes = isBigTiff ? 8 : 4
            let tSize = typeSizeBytes(type)

            switch tag {
            case Self.tagImageWidth:
                imageWidth = Int(tagValueU32())
            case Self.tagImageLength:
                imageLength = Int(tagValueU32())
            case Self.tagBitsPerSample:
                bitsPerSample = Int(readU16(valueOffset))
            case Self.tagCompression:
                compression = readU16(valueOffset)
            case Self.tagPredictor:
                predictor = Int(tagValueU32())
            case Self.tagTileWidth:
                tileWidth = Int(tagValueU32())
            case Self.tagTileLength:
                tileLength = Int(tagValueU32())
            case Self.tagTileOffsets:
                tileCount = Int(count)
                tileOffsetValueSize = tSize
                if Int(count) * tSize <= inlineBytes {
                    tileOffsetsOffset = UInt64(valueOffset)
                } else {
                    tileOffsetsOffset = tagValueU64()
                }
            case Self.tagTileByteCounts:
                tileByteCountValueSize = tSize
                if Int(count) * tSize <= inlineBytes {
                    tileByteCountsOffset = UInt64(valueOffset)
                } else {
                    tileByteCountsOffset = tagValueU64()
                }
            default:
                break
            }
        }

        guard imageWidth > 0 && imageLength > 0 else {
            throw COGError.invalidTIFF("Missing image dimensions")
        }

        // Detailed COG info logged at debug level only
        // log.info("COG: \(imageWidth)x\(imageLength), tile=\(tileWidth)x\(tileLength), bps=\(bitsPerSample), compression=\(compression), predictor=\(predictor)")

        return IFDInfo(
            isBigTiff: isBigTiff,
            isLittleEndian: isLittleEndian,
            imageWidth: imageWidth,
            imageLength: imageLength,
            tileWidth: tileWidth,
            tileLength: tileLength,
            bitsPerSample: bitsPerSample,
            compression: compression,
            predictor: predictor,
            tileOffsetsOffset: tileOffsetsOffset,
            tileByteCountsOffset: tileByteCountsOffset,
            tileCount: tileCount,
            tileOffsetValueSize: tileOffsetValueSize,
            tileByteCountValueSize: tileByteCountValueSize
        )
    }

    // MARK: - Tile Array Reading

    private func readTileArray(
        url: URL, headerData: Data,
        arrayOffset: UInt64, count: Int, valueSize: Int, isLittleEndian: Bool,
        authHeaders: [String: String] = [:]
    ) async throws -> [UInt64] {
        let totalBytes = count * valueSize
        let offset = Int(arrayOffset)

        let arrayData: Data
        if offset + totalBytes <= headerData.count {
            arrayData = headerData.subdata(in: offset..<offset + totalBytes)
        } else {
            arrayData = try await fetchRange(url: url, offset: arrayOffset, length: totalBytes, authHeaders: authHeaders)
        }

        var result = [UInt64]()
        result.reserveCapacity(count)

        for i in 0..<count {
            let pos = i * valueSize
            guard pos + valueSize <= arrayData.count else { break }
            switch valueSize {
            case 2:
                let val = arrayData.subdata(in: pos..<pos+2).withUnsafeBytes { $0.load(as: UInt16.self) }
                result.append(UInt64(isLittleEndian ? val.littleEndian : val.bigEndian))
            case 8:
                let val = arrayData.subdata(in: pos..<pos+8).withUnsafeBytes { $0.load(as: UInt64.self) }
                result.append(isLittleEndian ? val.littleEndian : val.bigEndian)
            default: // 4
                let val = arrayData.subdata(in: pos..<pos+4).withUnsafeBytes { $0.load(as: UInt32.self) }
                result.append(UInt64(isLittleEndian ? val.littleEndian : val.bigEndian))
            }
        }

        return result
    }

    // MARK: - Decompression

    private func decompressTileU16(data: Data, ifd: IFDInfo) throws -> [UInt16] {
        let bytesPerPixel = max(1, ifd.bitsPerSample / 8)
        let expectedSize = ifd.tileWidth * ifd.tileLength * bytesPerPixel

        var raw = try decompressBytes(data: data, compression: ifd.compression, expectedSize: expectedSize)

        // Apply horizontal differencing predictor (TIFF predictor = 2)
        if ifd.predictor == 2 {
            if bytesPerPixel == 2 {
                applyHorizontalDiffPredictor16(&raw, width: ifd.tileWidth, height: ifd.tileLength)
            } else if bytesPerPixel == 1 {
                applyHorizontalDiffPredictor8(&raw, width: ifd.tileWidth, height: ifd.tileLength)
            }
        }

        var pixels = [UInt16]()
        pixels.reserveCapacity(ifd.tileWidth * ifd.tileLength)

        if bytesPerPixel <= 1 {
            // 8-bit data (e.g. SCL band): read each byte as a UInt16
            for i in 0..<min(raw.count, expectedSize) {
                pixels.append(UInt16(raw[i]))
            }
        } else {
            // 16-bit data: read pairs of bytes as little-endian UInt16
            for i in stride(from: 0, to: min(raw.count, expectedSize), by: 2) {
                if i + 1 < raw.count {
                    let val = UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)
                    pixels.append(val)
                }
            }
        }

        return pixels
    }

    private func decompressBytes(data: Data, compression: UInt16, expectedSize: Int) throws -> [UInt8] {
        switch compression {
        case Self.compressionNone:
            return [UInt8](data)

        case Self.compressionDeflate, Self.compressionAdobeDeflate:
            return try inflateDeflate(data: data, expectedSize: expectedSize)

        default:
            throw COGError.unsupportedCompression(Int(compression))
        }
    }

    private func inflateDeflate(data: Data, expectedSize: Int) throws -> [UInt8] {
        // Use zlib uncompress() directly — S2 COGs use zlib-wrapped DEFLATE (78 9c header)
        // Apple's COMPRESSION_ZLIB expects raw deflate without the zlib header, so it fails.
        let source = [UInt8](data)
        var destLen = uLong(expectedSize)
        var dest = [UInt8](repeating: 0, count: expectedSize)

        let ret = uncompress(&dest, &destLen, source, uLong(source.count))

        if ret == Z_OK {
            return Array(dest[0..<Int(destLen)])
        }

        // If uncompress fails, try with a larger buffer (tile might exceed expected size)
        if ret == Z_BUF_ERROR {
            let bigSize = expectedSize * 4
            var bigDest = [UInt8](repeating: 0, count: bigSize)
            var bigDestLen = uLong(bigSize)
            let ret2 = uncompress(&bigDest, &bigDestLen, source, uLong(source.count))
            if ret2 == Z_OK {
                return Array(bigDest[0..<Int(bigDestLen)])
            }
        }

        // Last resort: if data is already the right size, treat as uncompressed
        if data.count == expectedSize {
            log.warn("zlib failed but data matches expected size — treating as uncompressed")
            return source
        }

        log.error("zlib uncompress failed: ret=\(ret), input=\(data.count) bytes, expected=\(expectedSize)")
        throw COGError.decompressionFailed
    }

    /// Undo TIFF horizontal differencing predictor for 8-bit samples.
    private func applyHorizontalDiffPredictor8(_ data: inout [UInt8], width: Int, height: Int) {
        for row in 0..<height {
            let rowStart = row * width
            for col in 1..<width {
                let pos = rowStart + col
                guard pos < data.count else { break }
                data[pos] = data[pos] &+ data[pos - 1]
            }
        }
    }

    /// Undo TIFF horizontal differencing predictor for 16-bit samples.
    private func applyHorizontalDiffPredictor16(_ data: inout [UInt8], width: Int, height: Int) {
        let rowBytes = width * 2
        for row in 0..<height {
            let rowStart = row * rowBytes
            for col in 1..<width {
                let pos = rowStart + col * 2
                guard pos + 1 < data.count else { break }
                let prevPos = pos - 2
                let prev = UInt16(data[prevPos]) | (UInt16(data[prevPos + 1]) << 8)
                let curr = UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)
                let sum = prev &+ curr  // wrapping add
                data[pos] = UInt8(sum & 0xFF)
                data[pos + 1] = UInt8(sum >> 8)
            }
        }
    }

    // MARK: - HTTP Range Requests

    private func fetchRange(url: URL, offset: UInt64, length: Int, authHeaders: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30
        for (key, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw COGError.httpError(httpResponse.statusCode)
            }
        }

        return data
    }
}

// MARK: - Errors

enum COGError: Error, LocalizedError {
    case invalidTIFF(String)
    case unsupportedCompression(Int)
    case decompressionFailed
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidTIFF(let msg): return "Invalid TIFF: \(msg)"
        case .unsupportedCompression(let c): return "Unsupported compression: \(c)"
        case .decompressionFailed: return "DEFLATE decompression failed"
        case .httpError(let code): return "HTTP error \(code)"
        }
    }
}
