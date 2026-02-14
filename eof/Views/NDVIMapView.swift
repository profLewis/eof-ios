import SwiftUI
import CoreGraphics

/// Renders an NDVIFrame as NDVI colormap, FCC, or True Color image.
struct NDVIMapView: View {
    let frame: NDVIFrame
    let scale: CGFloat
    let showPolygon: Bool
    let showColorBar: Bool
    let displayMode: AppSettings.DisplayMode
    let cloudMask: Bool
    let ndviThreshold: Float
    let sclValidClasses: Set<Int>
    let showSCLBoundaries: Bool
    let enforceAOI: Bool
    let showMaskedClassColors: Bool
    let basemapImage: CGImage?
    let phenologyMap: [[Float]]?
    let phenologyParam: PhenologyParameter?
    let rejectionMap: [[Float]]?

    init(frame: NDVIFrame, scale: CGFloat = 8, showPolygon: Bool = false,
         showColorBar: Bool = false, displayMode: AppSettings.DisplayMode = .ndvi,
         cloudMask: Bool = true, ndviThreshold: Float = 0.0,
         sclValidClasses: Set<Int> = [4, 5, 6, 7],
         showSCLBoundaries: Bool = true,
         enforceAOI: Bool = true,
         showMaskedClassColors: Bool = true,
         basemapImage: CGImage? = nil,
         phenologyMap: [[Float]]? = nil,
         phenologyParam: PhenologyParameter? = nil,
         rejectionMap: [[Float]]? = nil) {
        self.frame = frame
        self.scale = scale
        self.showPolygon = showPolygon
        self.showColorBar = showColorBar
        self.displayMode = displayMode
        self.cloudMask = cloudMask
        self.ndviThreshold = ndviThreshold
        self.sclValidClasses = sclValidClasses
        self.showSCLBoundaries = showSCLBoundaries
        self.enforceAOI = enforceAOI
        self.showMaskedClassColors = showMaskedClassColors
        self.basemapImage = basemapImage
        self.phenologyMap = phenologyMap
        self.phenologyParam = phenologyParam
        self.rejectionMap = rejectionMap
    }

    var body: some View {
        if let image = renderImage() {
            let imgWidth = CGFloat(frame.width) * scale
            let imgHeight = CGFloat(frame.height) * scale

            VStack(spacing: 2) {
                Image(decorative: image, scale: 1.0 / scale)
                    .interpolation(.none)
                    .background {
                        if let bm = basemapImage {
                            Image(decorative: bm, scale: CGFloat(bm.width) / imgWidth)
                                .interpolation(.high)
                        }
                    }
                    .overlay {
                        if showSCLBoundaries, let scl = frame.sclBand {
                            sclBoundaryOverlay(sclBand: scl, width: imgWidth, height: imgHeight)
                        }
                    }
                    .overlay {
                        if showPolygon && !frame.polygonNorm.isEmpty {
                            polygonOverlay(width: imgWidth, height: imgHeight)
                        }
                    }

                if showColorBar {
                    if rejectionMap != nil {
                        rejectionLegend(width: imgWidth)
                    } else if phenologyParam != nil {
                        phenologyColorBar(width: imgWidth)
                    } else if displayMode == .ndvi {
                        colorBar(width: imgWidth)
                    } else if displayMode == .scl {
                        SCLLegend()
                            .frame(width: imgWidth)
                    }
                }
            }
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                .overlay(Text("No data"))
        }
    }

    // MARK: - Rendering

    private func renderImage() -> CGImage? {
        var pixels: [UInt32]

        // Rejection map takes highest priority
        if let p = renderRejectionPixels() {
            pixels = p
        }
        // Phenology parameter map takes priority
        else if let p = renderPhenologyPixels() {
            pixels = p
        } else {
            switch displayMode {
            case .ndvi:
                guard let p = renderNDVIPixels() else { return nil }
                pixels = p
            case .fcc:
                guard let p = renderFCCPixels() else { return nil }
                pixels = p
            case .rcc:
                guard let p = renderRCCPixels() else { return nil }
                pixels = p
            case .scl:
                guard let p = renderSCLPixels() else { return nil }
                pixels = p
            case .bandRed:
                guard let p = renderBandPixels(band: frame.redBand) else { return nil }
                pixels = p
            case .bandNIR:
                guard let p = renderBandPixels(band: frame.nirBand) else { return nil }
                pixels = p
            case .bandGreen:
                guard let p = renderBandPixels(band: frame.greenBand) else { return nil }
                pixels = p
            case .bandBlue:
                guard let p = renderBandPixels(band: frame.blueBand) else { return nil }
                pixels = p
            }
        }

        return makeImage(pixels: pixels, width: frame.width, height: frame.height)
    }

    /// A pixel is masked if outside AOI polygon (when enforced) or its SCL class is invalid.
    private func isInvalid(row: Int, col: Int) -> Bool {
        // AOI polygon enforcement
        if enforceAOI && !frame.polygonNorm.isEmpty {
            let x = (Double(col) + 0.5) / Double(frame.width)
            let y = (Double(row) + 0.5) / Double(frame.height)
            let poly = frame.polygonNorm.map { (col: $0.x, row: $0.y) }
            if !NDVIProcessor.pointInPolygon(x: x, y: y, polygon: poly) {
                return true
            }
        }
        // SCL class mask
        if let scl = frame.sclBand, row < scl.count, col < scl[row].count {
            return !sclValidClasses.contains(Int(scl[row][col]))
        }
        return false
    }

    /// Render a masked pixel — always transparent so basemap shows through.
    /// Falls back to SCL class color or dark gray only when class colors enabled and no basemap.
    private func maskedPixelColor(row: Int, col: Int) -> UInt32 {
        // Always transparent — lets basemap or background show through
        if basemapImage != nil {
            return packRGBA(r: 0, g: 0, b: 0, a: 0)
        }
        if showMaskedClassColors,
           let scl = frame.sclBand, row < scl.count, col < scl[row].count {
            let (r, g, b) = Self.sclColor(scl[row][col])
            return packRGBA(r: r, g: g, b: b, a: 200)
        }
        return packRGBA(r: 0, g: 0, b: 0, a: 0)
    }

    // MARK: - SCL Class Boundary Overlay (Canvas)

    /// Draw colored lines at SCL class boundaries — TWO lines per border,
    /// one for each side's class color, placed well inside their respective pixels.
    private func sclBoundaryOverlay(sclBand: [[UInt16]], width: CGFloat, height: CGFloat) -> some View {
        return Canvas { context, size in
            let w = frame.width
            let h = frame.height
            let pixW = size.width / CGFloat(w)
            let pixH = size.height / CGFloat(h)

            // Collect line segments grouped by SCL class for batch drawing
            var segmentsByClass = [UInt16: [(CGPoint, CGPoint)]]()

            for row in 0..<h {
                for col in 0..<w {
                    let myClass = sclBand[row][col]

                    // Right boundary: myClass | neighbor
                    if col < w - 1 {
                        let neighbor = sclBand[row][col + 1]
                        if neighbor != myClass {
                            let yTop = CGFloat(row) * pixH
                            let yBot = CGFloat(row + 1) * pixH
                            // My line at 75% inside my pixel
                            let xMy = (CGFloat(col) + 0.75) * pixW
                            segmentsByClass[myClass, default: []].append(
                                (CGPoint(x: xMy, y: yTop), CGPoint(x: xMy, y: yBot)))
                            // Neighbor line at 25% inside neighbor pixel
                            let xNb = (CGFloat(col + 1) + 0.25) * pixW
                            segmentsByClass[neighbor, default: []].append(
                                (CGPoint(x: xNb, y: yTop), CGPoint(x: xNb, y: yBot)))
                        }
                    }

                    // Bottom boundary: myClass / neighbor
                    if row < h - 1 {
                        let neighbor = sclBand[row + 1][col]
                        if neighbor != myClass {
                            let xLeft = CGFloat(col) * pixW
                            let xRight = CGFloat(col + 1) * pixW
                            // My line at 75% inside my pixel
                            let yMy = (CGFloat(row) + 0.75) * pixH
                            segmentsByClass[myClass, default: []].append(
                                (CGPoint(x: xLeft, y: yMy), CGPoint(x: xRight, y: yMy)))
                            // Neighbor line at 25% inside neighbor pixel
                            let yNb = (CGFloat(row + 1) + 0.25) * pixH
                            segmentsByClass[neighbor, default: []].append(
                                (CGPoint(x: xLeft, y: yNb), CGPoint(x: xRight, y: yNb)))
                        }
                    }
                }
            }

            // Draw each class's boundaries as a single batched path
            let lineW: CGFloat = max(1, pixW * 0.12)
            for (cls, segments) in segmentsByClass {
                var path = Path()
                for (from, to) in segments {
                    path.move(to: from)
                    path.addLine(to: to)
                }
                let (r, g, b) = NDVIMapView.sclColor(cls)
                let color = Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
                context.stroke(path, with: .color(color), lineWidth: lineW)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Phenology Map Renderer

    private func renderPhenologyPixels() -> [UInt32]? {
        guard let map = phenologyMap, let param = phenologyParam else { return nil }
        let width = frame.width, height = frame.height
        guard width > 0, height > 0, map.count == height else { return nil }

        // Compute data range from non-NaN values
        var minV: Float = .infinity, maxV: Float = -.infinity
        for row in map {
            for v in row where !v.isNaN {
                if v < minV { minV = v }
                if v > maxV { maxV = v }
            }
        }
        guard minV < maxV else { return nil }

        // Clamp peak NDVI and min NDVI display ranges
        if param == .delta { maxV = min(maxV, 1.0); minV = max(minV, 0.0) }
        if param == .mn { maxV = min(maxV, 1.0); minV = max(minV, -0.5) }

        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let val = map[row][col]
                if val.isNaN {
                    pixels[row * width + col] = packRGBA(r: 0, g: 0, b: 0, a: 0)
                } else {
                    let (r, g, b) = phenologyColor(param: param, value: val, minV: minV, maxV: maxV)
                    pixels[row * width + col] = packRGBA(r: r, g: g, b: b, a: 255)
                }
            }
        }
        return pixels
    }

    /// Map phenology parameter value to color.
    private func phenologyColor(param: PhenologyParameter, value: Float,
                                minV: Float, maxV: Float) -> (UInt8, UInt8, UInt8) {
        let t = max(0, min(1, (value - minV) / (maxV - minV)))
        switch param {
        case .sos, .seasonLength:
            // Blue → White → Red (diverging)
            if t < 0.5 {
                let s = t * 2
                return (UInt8(s * 255), UInt8(s * 255), 255)
            } else {
                let s = (t - 0.5) * 2
                return (255, UInt8((1 - s) * 255), UInt8((1 - s) * 255))
            }
        case .delta, .mn:
            // Standard NDVI-like green ramp
            return ndviToRGB(t * 0.8 + 0.1)
        case .rsp, .rau:
            // Yellow → Red
            return (255, UInt8((1 - t) * 220), UInt8((1 - t) * 50))
        case .rmse:
            // Green → Yellow → Red (good to poor)
            if t < 0.5 {
                let s = t * 2
                return (UInt8(s * 255), UInt8(200 + s * 55), 0)
            } else {
                let s = (t - 0.5) * 2
                return (255, UInt8((1 - s) * 255), 0)
            }
        }
    }

    // MARK: - Rejection Map Renderer

    private func renderRejectionPixels() -> [UInt32]? {
        guard let map = rejectionMap else { return nil }
        let width = frame.width, height = frame.height
        guard width > 0, height > 0, map.count == height else { return nil }

        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let val = map[row][col]
                if val.isNaN {
                    // Outside AOI — transparent
                    pixels[row * width + col] = packRGBA(r: 0, g: 0, b: 0, a: 0)
                } else {
                    let code = Int(val)
                    let (r, g, b, a) = rejectionColor(code)
                    pixels[row * width + col] = packRGBA(r: r, g: g, b: b, a: a)
                }
            }
        }
        return pixels
    }

    /// Map rejection reason code to color.
    /// 0=good (green, semi-transparent), 1=poor (red), 2=outlier (purple), 3=skipped (gray)
    private func rejectionColor(_ code: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        switch code {
        case 0:  return (0, 180, 0, 60)        // Good — faint green
        case 1:  return (220, 40, 40, 200)      // Poor RMSE — red
        case 2:  return (160, 40, 200, 200)     // Outlier — purple
        case 3:  return (120, 120, 120, 180)    // Skipped — gray
        default: return (0, 0, 0, 0)
        }
    }

    // MARK: - Pixel Renderers

    private func renderNDVIPixels() -> [UInt32]? {
        let width = frame.width
        let height = frame.height
        guard width > 0 && height > 0 else { return nil }

        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                if isInvalid(row: row, col: col) {
                    pixels[row * width + col] = maskedPixelColor(row: row, col: col)
                    continue
                }

                let redDN = Float(frame.redBand[row][col])
                let nirDN = Float(frame.nirBand[row][col])
                let redR = (redDN + frame.dnOffset) / 10000
                let nirR = (nirDN + frame.dnOffset) / 10000
                let sum = nirR + redR
                var val: Float
                if sum != 0 {
                    val = min(1, max(-1, (nirR - redR) / sum))
                } else {
                    pixels[row * width + col] = packRGBA(r: 30, g: 30, b: 30, a: 255)
                    continue
                }

                if ndviThreshold != 0 && val < ndviThreshold {
                    let (r, g, b) = ndviToRGB(val)
                    let gray: UInt8 = 60
                    let mr = UInt8((Float(r) * 0.3 + Float(gray) * 0.7))
                    let mg = UInt8((Float(g) * 0.3 + Float(gray) * 0.7))
                    let mb = UInt8((Float(b) * 0.3 + Float(gray) * 0.7))
                    pixels[row * width + col] = packRGBA(r: mr, g: mg, b: mb, a: 255)
                } else {
                    pixels[row * width + col] = ndviToColor(val)
                }
            }
        }
        return pixels
    }

    /// False Color Composite: R=NIR, G=Red, B=Green
    private func renderFCCPixels() -> [UInt32]? {
        let width = frame.width
        let height = frame.height
        guard width > 0 && height > 0 else { return nil }
        guard let greenBand = frame.greenBand else { return renderNDVIPixels() }

        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                if isInvalid(row: row, col: col) {
                    pixels[row * width + col] = maskedPixelColor(row: row, col: col)
                } else {
                    let r = dnToDisplay(frame.nirBand[row][col])
                    let g = dnToDisplay(frame.redBand[row][col])
                    let b = dnToDisplay(greenBand[row][col])
                    pixels[row * width + col] = packRGBA(r: r, g: g, b: b, a: 255)
                }
            }
        }
        return pixels
    }

    /// True Color Composite: R=Red, G=Green, B=Blue
    private func renderRCCPixels() -> [UInt32]? {
        let width = frame.width
        let height = frame.height
        guard width > 0 && height > 0 else { return nil }
        guard let greenBand = frame.greenBand, let blueBand = frame.blueBand else {
            return renderNDVIPixels()
        }

        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                if isInvalid(row: row, col: col) {
                    pixels[row * width + col] = maskedPixelColor(row: row, col: col)
                } else {
                    let r = dnToDisplay(frame.redBand[row][col])
                    let g = dnToDisplay(greenBand[row][col])
                    let b = dnToDisplay(blueBand[row][col])
                    pixels[row * width + col] = packRGBA(r: r, g: g, b: b, a: 255)
                }
            }
        }
        return pixels
    }

    /// Scene Classification Layer with standard colors.
    private func renderSCLPixels() -> [UInt32]? {
        let width = frame.width
        let height = frame.height
        guard width > 0 && height > 0 else { return nil }
        guard let sclBand = frame.sclBand else { return renderNDVIPixels() }

        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let val = sclBand[row][col]
                let (r, g, b) = Self.sclColor(val)
                // Dim masked classes slightly so valid classes stand out
                if !sclValidClasses.contains(Int(val)) {
                    pixels[row * width + col] = packRGBA(
                        r: UInt8(Double(r) * 0.5),
                        g: UInt8(Double(g) * 0.5),
                        b: UInt8(Double(b) * 0.5),
                        a: 200
                    )
                } else {
                    pixels[row * width + col] = packRGBA(r: r, g: g, b: b, a: 255)
                }
            }
        }
        return pixels
    }

    /// Standard SCL color mapping (Sentinel Hub).
    static func sclColor(_ value: UInt16) -> (UInt8, UInt8, UInt8) {
        switch value {
        case 0:  return (0, 0, 0)          // No Data
        case 1:  return (255, 0, 0)        // Saturated / Defective
        case 2:  return (100, 100, 100)    // Dark Area / Shadows
        case 3:  return (100, 50, 0)       // Cloud Shadows
        case 4:  return (0, 160, 0)        // Vegetation
        case 5:  return (255, 230, 90)     // Not Vegetated
        case 6:  return (0, 0, 255)        // Water
        case 7:  return (128, 128, 128)    // Unclassified
        case 8:  return (192, 192, 192)    // Cloud Medium Probability
        case 9:  return (255, 255, 255)    // Cloud High Probability
        case 10: return (100, 200, 255)    // Thin Cirrus
        case 11: return (255, 150, 255)    // Snow / Ice
        default: return (0, 0, 0)
        }
    }

    /// Render a single band as greyscale.
    private func renderBandPixels(band: [[UInt16]]?) -> [UInt32]? {
        let width = frame.width
        let height = frame.height
        guard width > 0 && height > 0 else { return nil }
        guard let band = band else { return renderNDVIPixels() }  // fallback

        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                if cloudMask && isInvalid(row: row, col: col) {
                    pixels[row * width + col] = maskedPixelColor(row: row, col: col)
                    continue
                }
                guard row < band.count, col < band[row].count else { continue }
                let g = dnToDisplay(band[row][col])
                pixels[row * width + col] = packRGBA(r: g, g: g, b: g, a: 255)
            }
        }
        return pixels
    }

    /// Convert S2 L2A DN to display byte (0-255) with stretch.
    /// Applies per-frame DN offset for correct reflectance across all sources.
    private func dnToDisplay(_ dn: UInt16) -> UInt8 {
        let refl = (Float(dn) + frame.dnOffset) / 10000.0
        let stretched = max(0, min(1, refl / 0.3))
        return UInt8(stretched * 255)
    }

    private func makeImage(pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        var mutable = pixels
        let data = mutable.withUnsafeMutableBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Polygon Overlay

    private func polygonOverlay(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            guard frame.polygonNorm.count >= 3 else { return }
            var path = Path()
            let first = frame.polygonNorm[0]
            path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
            for i in 1..<frame.polygonNorm.count {
                let pt = frame.polygonNorm[i]
                path.addLine(to: CGPoint(x: pt.x * size.width, y: pt.y * size.height))
            }
            path.closeSubpath()
            context.stroke(path, with: .color(.white), lineWidth: max(1, scale * 0.2))
        }
        .allowsHitTesting(false)
    }

    // MARK: - Phenology Color Bar

    private func phenologyColorBar(width: CGFloat) -> some View {
        guard let param = phenologyParam, let map = phenologyMap else {
            return AnyView(EmptyView())
        }
        // Compute data range
        var minV: Float = .infinity, maxV: Float = -.infinity
        for row in map {
            for v in row where !v.isNaN {
                if v < minV { minV = v }
                if v > maxV { maxV = v }
            }
        }
        guard minV < maxV else { return AnyView(EmptyView()) }

        // Clamp color bar ranges for NDVI-derived parameters
        if param == .delta { maxV = min(maxV, 1.0); minV = max(minV, 0.0) }
        if param == .mn { maxV = min(maxV, 1.0); minV = max(minV, -0.5) }

        let barH: CGFloat = max(8, scale * 0.8)
        let fontSize: CGFloat = max(7, scale * 0.7)
        let label = param.rawValue
        let nTicks = 5
        let tickVals = (0..<nTicks).map { i in
            minV + Float(i) / Float(nTicks - 1) * (maxV - minV)
        }

        return AnyView(VStack(spacing: 1) {
            Text(label)
                .font(.system(size: fontSize).bold())
                .foregroundStyle(.secondary)
            Canvas { context, size in
                let w = size.width
                for i in 0..<Int(w) {
                    let t = Float(i) / Float(w)
                    let val = minV + t * (maxV - minV)
                    let (r, g, b) = phenologyColor(param: param, value: val, minV: minV, maxV: maxV)
                    let rect = CGRect(x: CGFloat(i), y: 0, width: 1, height: barH)
                    context.fill(Path(rect), with: .color(
                        Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)))
                }
                for tv in tickVals {
                    let x = CGFloat((tv - minV) / (maxV - minV)) * w
                    context.fill(Path(CGRect(x: x - 0.5, y: barH - 3, width: 1, height: 3)),
                                 with: .color(.white.opacity(0.8)))
                    let fmt = (maxV - minV) > 10 ? "%.0f" : "%.2f"
                    let text = Text(String(format: fmt, tv))
                        .font(.system(size: fontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                    let resolved = context.resolve(text)
                    let labelW = resolved.measure(in: size).width
                    let clampedX = max(labelW / 2, min(w - labelW / 2, x))
                    context.draw(resolved, at: CGPoint(x: clampedX, y: barH + 7))
                }
            }
            .frame(width: width, height: barH + 14)
            .clipShape(Rectangle())
        })
    }

    // MARK: - Rejection Legend

    private func rejectionLegend(width: CGFloat) -> some View {
        let items: [(code: Int, label: String)] = [
            (0, "Good"), (1, "Poor RMSE"), (2, "Outlier"), (3, "Skipped")
        ]
        let fontSize: CGFloat = max(7, scale * 0.7)
        return HStack(spacing: 8) {
            ForEach(items, id: \.code) { item in
                HStack(spacing: 3) {
                    let (r, g, b, _) = rejectionColor(item.code)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
                        .frame(width: 10, height: 10)
                    Text(item.label)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width)
    }

    // MARK: - Color Bar

    private func colorBar(width: CGFloat) -> some View {
        let barH: CGFloat = max(8, scale * 0.8)
        let fontSize: CGFloat = max(7, scale * 0.7)
        let ticks: [(val: Float, label: String)] = [
            (-0.2, "-.2"), (0, "0"), (0.2, ".2"), (0.4, ".4"), (0.6, ".6"), (0.8, ".8"), (1.0, "1")
        ]

        return VStack(spacing: 1) {
            Canvas { context, size in
                let w = size.width
                // Draw gradient
                for i in 0..<Int(w) {
                    let frac = Float(i) / Float(w)
                    let v = frac * 1.2 - 0.2
                    let (r, g, b) = ndviToRGB(v)
                    let rect = CGRect(x: CGFloat(i), y: 0, width: 1, height: barH)
                    context.fill(Path(rect), with: .color(
                        Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)))
                }
                // Tick marks
                for tick in ticks {
                    let x = CGFloat((tick.val + 0.2) / 1.2) * w
                    context.fill(Path(CGRect(x: x - 0.5, y: barH - 3, width: 1, height: 3)),
                                 with: .color(.white.opacity(0.8)))
                }
                // Tick labels inside canvas
                for tick in ticks {
                    let x = CGFloat((tick.val + 0.2) / 1.2) * w
                    let text = Text(tick.label)
                        .font(.system(size: fontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                    let resolved = context.resolve(text)
                    let labelW = resolved.measure(in: size).width
                    let clampedX = max(labelW / 2, min(w - labelW / 2, x))
                    context.draw(resolved, at: CGPoint(x: clampedX, y: barH + 7))
                }
            }
            .frame(width: width, height: barH + 14)
            .clipShape(Rectangle())
        }
    }

    // MARK: - NDVI Color Mapping

    private func ndviToColor(_ value: Float) -> UInt32 {
        guard !value.isNaN else {
            return packRGBA(r: 0, g: 0, b: 0, a: 0)
        }
        let (r, g, b) = ndviToRGB(value)
        return packRGBA(r: r, g: g, b: b, a: 255)
    }

    private func ndviToRGB(_ value: Float) -> (UInt8, UInt8, UInt8) {
        let v = max(-1, min(1, value))
        if v < 0 {
            let t = Float((v + 1) / 1.0)
            return (UInt8(20 + t * 30), UInt8(20 + t * 50), UInt8(100 + t * 80))
        } else if v < 0.15 {
            let t = v / 0.15
            return (UInt8(160 + t * 40), UInt8(120 + t * 40), UInt8(60 + t * 20))
        } else if v < 0.3 {
            let t = (v - 0.15) / 0.15
            return (UInt8(200 - t * 80), UInt8(160 + t * 40), UInt8(80 - t * 40))
        } else if v < 0.5 {
            let t = (v - 0.3) / 0.2
            return (UInt8(120 - t * 80), UInt8(200 - t * 20), UInt8(40 + t * 10))
        } else if v < 0.7 {
            let t = (v - 0.5) / 0.2
            return (UInt8(40 - t * 20), UInt8(180 - t * 30), UInt8(50 - t * 20))
        } else {
            let t = min(1, (v - 0.7) / 0.3)
            return (UInt8(20 - t * 10), UInt8(150 - t * 40), UInt8(30 - t * 10))
        }
    }

    private func packRGBA(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> UInt32 {
        UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
    }
}

// MARK: - SCL Legend

struct SCLLegend: View {
    private let classes: [(value: UInt16, name: String)] = [
        (0, "No Data"), (1, "Saturated"), (2, "Dark/Shadows"),
        (3, "Cloud Shadow"), (4, "Vegetation"), (5, "Not Vegetated"),
        (6, "Water"), (7, "Unclassified"), (8, "Cloud (Med)"),
        (9, "Cloud (High)"), (10, "Cirrus"), (11, "Snow/Ice"),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], spacing: 2) {
            ForEach(classes, id: \.value) { cls in
                HStack(spacing: 4) {
                    let (r, g, b) = NDVIMapView.sclColor(cls.value)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
                        .frame(width: 12, height: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                    Text("\(cls.value): \(cls.name)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Standalone Color Bar

struct NDVIColorBar: View {
    var body: some View {
        let ticks: [(val: Float, label: String)] = [
            (-0.2, "-.2"), (0, "0"), (0.2, ".2"), (0.4, ".4"), (0.6, ".6"), (0.8, ".8"), (1.0, "1")
        ]

        Canvas { context, size in
            let barH: CGFloat = 10
            let w = size.width
            // Gradient bar
            for i in 0..<Int(w) {
                let frac = Float(i) / Float(w)
                let v = frac * 1.2 - 0.2
                let (r, g, b) = ndviToRGBStatic(v)
                let rect = CGRect(x: CGFloat(i), y: 0, width: 1, height: barH)
                context.fill(Path(rect), with: .color(
                    Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)))
            }
            // Tick marks + labels
            for tick in ticks {
                let x = CGFloat((tick.val + 0.2) / 1.2) * w
                context.fill(Path(CGRect(x: x - 0.5, y: barH - 3, width: 1, height: 3)),
                             with: .color(.white.opacity(0.8)))
                let text = Text(tick.label)
                    .font(.system(size: 7).monospacedDigit())
                    .foregroundStyle(.secondary)
                let resolved = context.resolve(text)
                let labelW = resolved.measure(in: size).width
                let clampedX = max(labelW / 2, min(w - labelW / 2, x))
                context.draw(resolved, at: CGPoint(x: clampedX, y: barH + 7))
            }
        }
        .frame(height: 24)
    }

    private func ndviToRGBStatic(_ value: Float) -> (UInt8, UInt8, UInt8) {
        let v = max(-1, min(1, value))
        if v < 0 {
            let t = Float((v + 1) / 1.0)
            return (UInt8(20 + t * 30), UInt8(20 + t * 50), UInt8(100 + t * 80))
        } else if v < 0.15 {
            let t = v / 0.15
            return (UInt8(160 + t * 40), UInt8(120 + t * 40), UInt8(60 + t * 20))
        } else if v < 0.3 {
            let t = (v - 0.15) / 0.15
            return (UInt8(200 - t * 80), UInt8(160 + t * 40), UInt8(80 - t * 40))
        } else if v < 0.5 {
            let t = (v - 0.3) / 0.2
            return (UInt8(120 - t * 80), UInt8(200 - t * 20), UInt8(40 + t * 10))
        } else if v < 0.7 {
            let t = (v - 0.5) / 0.2
            return (UInt8(40 - t * 20), UInt8(180 - t * 30), UInt8(50 - t * 20))
        } else {
            let t = min(1, (v - 0.7) / 0.3)
            return (UInt8(20 - t * 10), UInt8(150 - t * 40), UInt8(30 - t * 10))
        }
    }
}
