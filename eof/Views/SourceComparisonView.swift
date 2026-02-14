import SwiftUI
import Charts
import CoreGraphics

/// Comparison view showing per-pixel scatter plots and statistics
/// between the same scenes fetched from different data sources.
struct SourceComparisonView: View {
    let pairs: [ComparisonPair]

    struct ComparisonPair: Identifiable {
        let id = UUID()
        let dateString: String
        let frameA: NDVIFrame
        let frameB: NDVIFrame
        var stats: PairStats { Self.computeStats(frameA, frameB) }
    }

    struct BandPairs {
        let red: [(a: Float, b: Float)]
        let nir: [(a: Float, b: Float)]
        let green: [(a: Float, b: Float)]
        let blue: [(a: Float, b: Float)]
    }

    struct PairStats {
        let n: Int
        let ndviBias: Float
        let ndviRMSE: Float
        let ndviR2: Float
        let ndviPairs: [(a: Float, b: Float)]
        let bandRefl: BandPairs
        let redReflBias: Float
        let nirReflBias: Float
        let greenReflBias: Float
        let blueReflBias: Float
    }

    enum PlotType: String, CaseIterable {
        case ndvi = "NDVI"
        case red = "Red"
        case nir = "NIR"
        case green = "Green"
        case blue = "Blue"

        var color: Color {
            switch self {
            case .ndvi: return .blue
            case .red: return .red
            case .nir: return .brown
            case .green: return .green
            case .blue: return .blue
            }
        }

        /// Default axis range for each type
        var axisRange: ClosedRange<Double> {
            switch self {
            case .ndvi: return -0.2...1.0
            case .nir: return 0...0.6
            case .red, .green, .blue: return 0...0.35
            }
        }

        var axisLabel: String {
            switch self {
            case .ndvi: return "NDVI"
            case .red: return "Red \u{03C1}"
            case .nir: return "NIR \u{03C1}"
            case .green: return "Green \u{03C1}"
            case .blue: return "Blue \u{03C1}"
            }
        }

        func pairs(from stats: PairStats) -> [(a: Float, b: Float)] {
            switch self {
            case .ndvi: return stats.ndviPairs
            case .red: return stats.bandRefl.red
            case .nir: return stats.bandRefl.nir
            case .green: return stats.bandRefl.green
            case .blue: return stats.bandRefl.blue
            }
        }

        func bias(from stats: PairStats) -> Float {
            switch self {
            case .ndvi: return stats.ndviBias
            case .red: return stats.redReflBias
            case .nir: return stats.nirReflBias
            case .green: return stats.greenReflBias
            case .blue: return stats.blueReflBias
            }
        }
    }

    /// Group pairs by source combination
    private var groupedPairs: [(key: String, srcA: String, srcB: String, pairs: [ComparisonPair])] {
        var groups = [String: [ComparisonPair]]()
        for p in pairs {
            let a = p.frameA.sourceID?.rawValue.uppercased() ?? "A"
            let b = p.frameB.sourceID?.rawValue.uppercased() ?? "B"
            let key = "\(a) vs \(b)"
            groups[key, default: []].append(p)
        }
        return groups.sorted(by: { $0.key < $1.key }).map { (key, pairs) in
            let a = pairs.first?.frameA.sourceID?.rawValue.uppercased() ?? "A"
            let b = pairs.first?.frameB.sourceID?.rawValue.uppercased() ?? "B"
            return (key: key, srcA: a, srcB: b, pairs: pairs)
        }
    }

    @State private var selectedGroup = 0
    @State private var plotType: PlotType = .ndvi
    @State private var expandedDateID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if groupedPairs.count > 1 {
                        Picker("Sources", selection: $selectedGroup) {
                            ForEach(0..<groupedPairs.count, id: \.self) { i in
                                Text(groupedPairs[i].key).tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                    }

                    if selectedGroup < groupedPairs.count {
                        let group = groupedPairs[selectedGroup]
                        comparisonSection(srcA: group.srcA, srcB: group.srcB, pairs: group.pairs)
                    }
                }
                .padding(.top, 4)
            }
            .navigationTitle("Source Comparison")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Comparison section for one source pair

    @ViewBuilder
    private func comparisonSection(srcA: String, srcB: String, pairs: [ComparisonPair]) -> some View {
        let allStats = aggregateStats(pairs: pairs)

        VStack(alignment: .leading, spacing: 8) {
            // Header
            Text("\(srcA) vs \(srcB): \(pairs.count) dates, \(allStats.n) pixels")
                .font(.headline)
                .padding(.horizontal)

            // DN offset summary per source
            offsetSummary(srcA: srcA, srcB: srcB, pairs: pairs)

            // Aggregate band bias stats
            HStack(spacing: 8) {
                bandStatBox("Red", allStats.redReflBias, color: .red)
                bandStatBox("NIR", allStats.nirReflBias, color: .brown)
                bandStatBox("Green", allStats.greenReflBias, color: .green)
                bandStatBox("Blue", allStats.blueReflBias, color: .blue)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                statBox("NDVI Bias", String(format: "%+.4f", allStats.ndviBias))
                statBox("NDVI RMSE", String(format: "%.4f", allStats.ndviRMSE))
                statBox("NDVI R\u{00B2}", String(format: "%.4f", allStats.ndviR2))
            }
            .padding(.horizontal)

            // Time series
            Text("Median NDVI Time Series")
                .font(.caption.bold())
                .padding(.horizontal)

            Chart {
                ForEach(Array(pairs.enumerated()), id: \.element.id) { _, pair in
                    PointMark(
                        x: .value("DOY", pair.frameA.dayOfYear),
                        y: .value("NDVI", Double(pair.frameA.medianNDVI))
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(30)
                    PointMark(
                        x: .value("DOY", pair.frameB.dayOfYear),
                        y: .value("NDVI", Double(pair.frameB.medianNDVI))
                    )
                    .foregroundStyle(.orange)
                    .symbolSize(30)
                }
            }
            .chartXAxisLabel("Day of Year")
            .chartYAxisLabel("Median NDVI")
            .chartForegroundStyleScale([srcA: Color.blue, srcB: Color.orange])
            .frame(height: 160)
            .padding(.horizontal)

            // Per-date table
            perDateTable(srcA: srcA, srcB: srcB, pairs: pairs)

            // Plot type selector + per-date scatter grid
            perDateScatterGrid(srcA: srcA, srcB: srcB, pairs: pairs)
        }
        .padding(.vertical)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Per-date table

    @ViewBuilder
    private func perDateTable(srcA: String, srcB: String, pairs: [ComparisonPair]) -> some View {
        Text("Per-date: NDVI, processing version")
            .font(.caption.bold())
            .padding(.horizontal)

        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text("Date").font(.caption2.bold()).frame(width: 70, alignment: .leading)
                Text(srcA).font(.caption2.bold()).frame(width: 38, alignment: .trailing)
                Text(srcB).font(.caption2.bold()).frame(width: 38, alignment: .trailing)
                Text("\u{0394}").font(.caption2.bold()).frame(width: 34, alignment: .trailing)
                Text("PB-A").font(.caption2.bold()).frame(width: 34, alignment: .trailing)
                Text("PB-B").font(.caption2.bold()).frame(width: 34, alignment: .trailing)
                Text("ver").font(.caption2.bold()).frame(width: 20, alignment: .center)
            }
            .foregroundStyle(.secondary)

            ForEach(Array(pairs.enumerated()), id: \.element.id) { _, pair in
                let diff = pair.frameA.medianNDVI - pair.frameB.medianNDVI
                let pbA = pair.frameA.processingBaseline ?? "?"
                let pbB = pair.frameB.processingBaseline ?? "?"
                let versionMatch = pbA == pbB
                HStack(spacing: 3) {
                    Text(pair.dateString).font(.caption2.monospacedDigit()).frame(width: 70, alignment: .leading)
                    Text(String(format: "%.3f", pair.frameA.medianNDVI)).font(.caption2.monospacedDigit()).frame(width: 38, alignment: .trailing)
                    Text(String(format: "%.3f", pair.frameB.medianNDVI)).font(.caption2.monospacedDigit()).frame(width: 38, alignment: .trailing)
                    Text(String(format: "%+.3f", diff)).font(.caption2.monospacedDigit()).frame(width: 34, alignment: .trailing)
                        .foregroundStyle(abs(diff) > 0.02 ? Color.red : Color.secondary)
                    Text(pbA).font(.caption2.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    Text(pbB).font(.caption2.monospacedDigit()).frame(width: 34, alignment: .trailing)
                        .foregroundStyle(versionMatch ? Color.primary : Color.red)
                    Text(versionMatch ? "\u{2713}" : "\u{2717}").font(.caption2).frame(width: 20, alignment: .center)
                        .foregroundStyle(versionMatch ? Color.green : Color.red)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Per-date scatter grid with band selector

    @ViewBuilder
    private func perDateScatterGrid(srcA: String, srcB: String, pairs: [ComparisonPair]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Date Scatter Plots")
                .font(.headline)
                .padding(.horizontal)

            // Plot type selector
            Picker("Plot", selection: $plotType) {
                ForEach(PlotType.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // Axis info
            let range = plotType.axisRange
            Text("\(plotType.axisLabel): \(srcA) (x) vs \(srcB) (y)  |  range \(String(format: "%.1f", range.lowerBound))–\(String(format: "%.1f", range.upperBound))")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            // Grid of scatter plots (2 columns)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(Array(pairs.enumerated()), id: \.element.id) { _, pair in
                    perDateScatterCell(pair: pair, srcA: srcA, srcB: srcB)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func perDateScatterCell(pair: ComparisonPair, srcA: String, srcB: String) -> some View {
        let stats = pair.stats
        let points = plotType.pairs(from: stats)
        let bias = plotType.bias(from: stats)
        let range = plotType.axisRange
        let lo = range.lowerBound
        let hi = range.upperBound
        let pbA = pair.frameA.processingBaseline ?? "?"
        let pbB = pair.frameB.processingBaseline ?? "?"
        let vMatch = pbA == pbB
        let isExpanded = expandedDateID == pair.id

        VStack(spacing: 1) {
            // Date header
            HStack(spacing: 2) {
                Text(pair.dateString).font(.system(size: 9).bold().monospacedDigit())
                Spacer()
                if !vMatch {
                    Text("\u{26A0}").font(.system(size: 8))
                }
                Text(String(format: "%+.4f", bias))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(abs(bias) > 0.02 ? Color.red : Color.secondary)
            }

            // Scatter plot
            Chart {
                LineMark(x: .value("x", lo), y: .value("y", lo))
                    .foregroundStyle(.gray.opacity(0.4))
                LineMark(x: .value("x", hi), y: .value("y", hi))
                    .foregroundStyle(.gray.opacity(0.4))
                ForEach(Array(points.prefix(800).enumerated()), id: \.offset) { _, pt in
                    PointMark(x: .value(srcA, Double(pt.a)), y: .value(srcB, Double(pt.b)))
                        .symbolSize(3)
                        .foregroundStyle(plotType.color.opacity(0.35))
                }
            }
            .chartXScale(domain: lo...hi)
            .chartYScale(domain: lo...hi)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let val = v.as(Double.self) {
                            Text(String(format: "%.1f", val)).font(.system(size: 7))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let val = v.as(Double.self) {
                            Text(String(format: "%.1f", val)).font(.system(size: 7))
                        }
                    }
                }
            }
            .frame(height: 120)

            // Stats row
            HStack(spacing: 4) {
                Text("n=\(stats.n)").font(.system(size: 7).monospacedDigit())
                Text("R\u{00B2}=\(String(format: "%.3f", stats.ndviR2))").font(.system(size: 7).monospacedDigit())
                Text("PB:\(pbA)/\(pbB)").font(.system(size: 7).monospacedDigit())
                    .foregroundStyle(vMatch ? Color.secondary : Color.red)
            }
            .foregroundStyle(.secondary)

            // Expandable detail
            if isExpanded {
                expandedDetail(pair: pair, srcA: srcA, srcB: srcB)
            }
        }
        .padding(4)
        .background(Color(.systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedDateID = isExpanded ? nil : pair.id
            }
        }
    }

    // MARK: - Expanded detail (tap a cell)

    @ViewBuilder
    private func expandedDetail(pair: ComparisonPair, srcA: String, srcB: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            // Thumbnails
            reflectanceThumbnails(pair: pair, srcA: srcA, srcB: srcB)

            // Version info
            versionInfo(pair: pair, srcA: srcA, srcB: srcB)

            // All bands mini grid (when not already showing that band)
            let stats = pair.stats
            Text("All bands").font(.system(size: 9).bold()).padding(.leading, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 5), spacing: 2) {
                miniBandCell("NDVI", stats.ndviPairs, bias: stats.ndviBias, range: PlotType.ndvi.axisRange, color: .blue)
                miniBandCell("Red", stats.bandRefl.red, bias: stats.redReflBias, range: PlotType.red.axisRange, color: .red)
                miniBandCell("NIR", stats.bandRefl.nir, bias: stats.nirReflBias, range: PlotType.nir.axisRange, color: .brown)
                miniBandCell("Grn", stats.bandRefl.green, bias: stats.greenReflBias, range: PlotType.green.axisRange, color: .green)
                miniBandCell("Blue", stats.bandRefl.blue, bias: stats.blueReflBias, range: PlotType.blue.axisRange, color: .blue)
            }
        }
    }

    @ViewBuilder
    private func miniBandCell(_ label: String, _ points: [(a: Float, b: Float)], bias: Float, range: ClosedRange<Double>, color: Color) -> some View {
        let lo = range.lowerBound
        let hi = range.upperBound
        VStack(spacing: 0) {
            Text(label).font(.system(size: 7).bold())
            Chart {
                LineMark(x: .value("x", lo), y: .value("y", lo))
                    .foregroundStyle(.gray.opacity(0.3))
                LineMark(x: .value("x", hi), y: .value("y", hi))
                    .foregroundStyle(.gray.opacity(0.3))
                ForEach(Array(points.prefix(400).enumerated()), id: \.offset) { _, pt in
                    PointMark(x: .value("a", Double(pt.a)), y: .value("b", Double(pt.b)))
                        .symbolSize(2)
                        .foregroundStyle(color.opacity(0.3))
                }
            }
            .chartXScale(domain: lo...hi)
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 50)
            Text(String(format: "%+.3f", bias)).font(.system(size: 6).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Reflectance thumbnails

    @ViewBuilder
    private func reflectanceThumbnails(pair: ComparisonPair, srcA: String, srcB: String) -> some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(srcA).font(.caption2.bold())
                if let img = Self.renderReflectanceThumbnail(pair.frameA) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("No RGB").font(.caption2).foregroundStyle(.secondary)
                        .frame(height: 80)
                }
            }
            VStack(spacing: 2) {
                Text(srcB).font(.caption2.bold())
                if let img = Self.renderReflectanceThumbnail(pair.frameB) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("No RGB").font(.caption2).foregroundStyle(.secondary)
                        .frame(height: 80)
                }
            }
        }
    }

    /// Render true-color thumbnail with DN->reflectance conversion applied
    static func renderReflectanceThumbnail(_ frame: NDVIFrame) -> CGImage? {
        let w = frame.width, h = frame.height
        guard w > 0, h > 0 else { return nil }
        guard let green = frame.greenBand, let blue = frame.blueBand else { return nil }

        let offset = frame.dnOffset
        var pixels = [UInt32](repeating: 0, count: w * h)
        for row in 0..<h {
            for col in 0..<w {
                let rRefl = (Float(frame.redBand[row][col]) + offset) / 10000.0
                let gRefl: Float
                let bRefl: Float
                if row < green.count && col < green[row].count {
                    gRefl = (Float(green[row][col]) + offset) / 10000.0
                } else { gRefl = 0 }
                if row < blue.count && col < blue[row].count {
                    bRefl = (Float(blue[row][col]) + offset) / 10000.0
                } else { bRefl = 0 }
                let r8 = UInt8(max(0, min(255, rRefl / 0.3 * 255)))
                let g8 = UInt8(max(0, min(255, gRefl / 0.3 * 255)))
                let b8 = UInt8(max(0, min(255, bRefl / 0.3 * 255)))
                pixels[row * w + col] = UInt32(r8) | (UInt32(g8) << 8) | (UInt32(b8) << 16) | (255 << 24)
            }
        }
        var mutable = pixels
        let data = mutable.withUnsafeMutableBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Version info

    @ViewBuilder
    private func versionInfo(pair: ComparisonPair, srcA: String, srcB: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            let pbA = pair.frameA.processingBaseline ?? "?"
            let pbB = pair.frameB.processingBaseline ?? "?"
            let vMatch = pbA == pbB
            HStack(spacing: 4) {
                Text("PB: \(pbA) / \(pbB)")
                    .font(.system(size: 8).monospacedDigit())
                if !vMatch {
                    Text("MISMATCH").font(.system(size: 7).bold()).foregroundStyle(Color.red)
                }
            }
            let verA = extractVersion(pair.frameA.productURI)
            let verB = extractVersion(pair.frameB.productURI)
            if verA != nil || verB != nil {
                Text("Ver: \(verA ?? "?") / \(verB ?? "?")")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle((verA == verB) ? Color.secondary : Color.red)
            }
            if let scA = pair.frameA.sceneID {
                Text(scA).font(.system(size: 7).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            if let scB = pair.frameB.sceneID {
                Text(scB).font(.system(size: 7).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 4) {
                Text("\(srcA) ofs:\(String(format: "%.0f", pair.frameA.dnOffset))")
                    .font(.system(size: 7).monospacedDigit())
                    .foregroundStyle(pair.frameA.dnOffset != 0 ? Color.orange : Color.secondary)
                Text("\(srcB) ofs:\(String(format: "%.0f", pair.frameB.dnOffset))")
                    .font(.system(size: 7).monospacedDigit())
                    .foregroundStyle(pair.frameB.dnOffset != 0 ? Color.orange : Color.secondary)
            }
        }
        .padding(.leading, 2)
    }

    // MARK: - Offset summary

    @ViewBuilder
    private func offsetSummary(srcA: String, srcB: String, pairs: [ComparisonPair]) -> some View {
        let offsetsA = Set(pairs.map { $0.frameA.dnOffset })
        let offsetsB = Set(pairs.map { $0.frameB.dnOffset })
        let consistentA = offsetsA.count == 1
        let consistentB = offsetsB.count == 1

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(srcA).font(.caption2.bold())
                    if consistentA, let ofs = offsetsA.first {
                        let applied = ofs != 0
                        Text(applied ? "offset \(String(format: "%.0f", ofs))" : "no offset")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(applied ? Color.orange : Color.green)
                    } else {
                        Text("MIXED: \(offsetsA.sorted().map { String(format: "%.0f", $0) }.joined(separator: ","))")
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundStyle(Color.red)
                    }
                }
                HStack(spacing: 4) {
                    Text(srcB).font(.caption2.bold())
                    if consistentB, let ofs = offsetsB.first {
                        let applied = ofs != 0
                        Text(applied ? "offset \(String(format: "%.0f", ofs))" : "no offset")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(applied ? Color.orange : Color.green)
                    } else {
                        Text("MIXED: \(offsetsB.sorted().map { String(format: "%.0f", $0) }.joined(separator: ","))")
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundStyle(Color.red)
                    }
                }
            }
            Text("reflectance = (DN + offset) / 10000")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    /// Extract N-version (e.g. "N0509") from product URI
    private func extractVersion(_ uri: String?) -> String? {
        guard let uri else { return nil }
        let parts = uri.split(separator: "_")
        return parts.first(where: { $0.hasPrefix("N") && $0.count == 5 && $0.dropFirst().allSatisfy(\.isNumber) }).map(String.init)
    }

    /// Extract processing date from product URI (last date component)
    private func extractProcessingDate(_ uri: String?) -> String? {
        guard let uri else { return nil }
        let noSafe = uri.replacingOccurrences(of: ".SAFE", with: "")
        let parts = noSafe.split(separator: "_")
        if let last = parts.last, last.count >= 8, last.prefix(4).allSatisfy(\.isNumber) {
            return String(last.prefix(8))
        }
        return nil
    }

    // MARK: - Helpers

    private func statBox(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().bold())
        }
    }

    private func bandStatBox(_ label: String, _ bias: Float, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(color)
            Text(String(format: "%+.4f", bias)).font(.system(size: 10).monospacedDigit().bold())
        }
    }

    private func aggregateStats(pairs: [ComparisonPair]) -> PairStats {
        var allNDVI = [(a: Float, b: Float)]()
        var allRed = [(a: Float, b: Float)]()
        var allNIR = [(a: Float, b: Float)]()
        var allGreen = [(a: Float, b: Float)]()
        var allBlue = [(a: Float, b: Float)]()
        for pair in pairs {
            let s = ComparisonPair.computeStats(pair.frameA, pair.frameB)
            allNDVI.append(contentsOf: s.ndviPairs)
            allRed.append(contentsOf: s.bandRefl.red)
            allNIR.append(contentsOf: s.bandRefl.nir)
            allGreen.append(contentsOf: s.bandRefl.green)
            allBlue.append(contentsOf: s.bandRefl.blue)
        }
        return Self.statsFromPairs(ndviPairs: allNDVI, bandRefl: BandPairs(red: allRed, nir: allNIR, green: allGreen, blue: allBlue))
    }

    static func statsFromPairs(ndviPairs: [(a: Float, b: Float)], bandRefl: BandPairs) -> PairStats {
        let n = ndviPairs.count
        guard n > 0 else {
            return PairStats(n: 0, ndviBias: 0, ndviRMSE: 0, ndviR2: 0, ndviPairs: [],
                           bandRefl: BandPairs(red: [], nir: [], green: [], blue: []),
                           redReflBias: 0, nirReflBias: 0, greenReflBias: 0, blueReflBias: 0)
        }

        var sumDiff: Float = 0, sumSqDiff: Float = 0, sumB: Float = 0
        for p in ndviPairs {
            let d = p.a - p.b
            sumDiff += d; sumSqDiff += d * d
            sumB += p.b
        }
        let bias = sumDiff / Float(n)
        let rmse = sqrt(sumSqDiff / Float(n))
        let meanB = sumB / Float(n)
        var ssTot: Float = 0, ssRes: Float = 0
        for p in ndviPairs {
            ssTot += (p.b - meanB) * (p.b - meanB)
            ssRes += (p.b - p.a) * (p.b - p.a)
        }
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0

        func meanBias(_ pairs: [(a: Float, b: Float)]) -> Float {
            guard !pairs.isEmpty else { return 0 }
            return pairs.reduce(Float(0)) { $0 + $1.a - $1.b } / Float(pairs.count)
        }

        return PairStats(n: n, ndviBias: bias, ndviRMSE: rmse, ndviR2: r2,
                        ndviPairs: ndviPairs, bandRefl: bandRefl,
                        redReflBias: meanBias(bandRefl.red), nirReflBias: meanBias(bandRefl.nir),
                        greenReflBias: meanBias(bandRefl.green), blueReflBias: meanBias(bandRefl.blue))
    }
}

// MARK: - Per-pair pixel comparison

extension SourceComparisonView.ComparisonPair {
    static func computeStats(_ a: NDVIFrame, _ b: NDVIFrame) -> SourceComparisonView.PairStats {
        let h = min(a.height, b.height)
        let w = min(a.width, b.width)
        let quantVal: Float = 10000.0
        var ndviPairs = [(a: Float, b: Float)]()
        var redPairs = [(a: Float, b: Float)]()
        var nirPairs = [(a: Float, b: Float)]()
        var greenPairs = [(a: Float, b: Float)]()
        var bluePairs = [(a: Float, b: Float)]()
        let stride = max(1, (h * w) / 5000)
        var idx = 0
        for row in 0..<h {
            for col in 0..<w {
                let va = a.ndvi[row][col]
                let vb = b.ndvi[row][col]
                guard !va.isNaN && !vb.isNaN else { continue }
                idx += 1
                if idx % stride == 0 {
                    ndviPairs.append((a: va, b: vb))
                    let redA = (Float(a.redBand[row][col]) + a.dnOffset) / quantVal
                    let redB = (Float(b.redBand[row][col]) + b.dnOffset) / quantVal
                    redPairs.append((a: redA, b: redB))

                    let nirA = (Float(a.nirBand[row][col]) + a.dnOffset) / quantVal
                    let nirB = (Float(b.nirBand[row][col]) + b.dnOffset) / quantVal
                    nirPairs.append((a: nirA, b: nirB))

                    if let gA = a.greenBand, let gB = b.greenBand {
                        let gAOK = row < gA.count && col < gA[row].count
                        let gBOK = row < gB.count && col < gB[row].count
                        if gAOK && gBOK {
                            let greenA = (Float(gA[row][col]) + a.dnOffset) / quantVal
                            let greenB = (Float(gB[row][col]) + b.dnOffset) / quantVal
                            greenPairs.append((a: greenA, b: greenB))
                        }
                    }

                    if let bA = a.blueBand, let bB = b.blueBand {
                        let bAOK = row < bA.count && col < bA[row].count
                        let bBOK = row < bB.count && col < bB[row].count
                        if bAOK && bBOK {
                            let blueA = (Float(bA[row][col]) + a.dnOffset) / quantVal
                            let blueB = (Float(bB[row][col]) + b.dnOffset) / quantVal
                            bluePairs.append((a: blueA, b: blueB))
                        }
                    }
                }
            }
        }
        let bandRefl = SourceComparisonView.BandPairs(red: redPairs, nir: nirPairs, green: greenPairs, blue: bluePairs)
        return SourceComparisonView.statsFromPairs(ndviPairs: ndviPairs, bandRefl: bandRefl)
    }
}
