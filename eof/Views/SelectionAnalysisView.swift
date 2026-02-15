import SwiftUI
import Charts

/// Analysis sheet for a sub-AOI rectangle selection on the movie.
/// Shows mean NDVI, reflectance spectra, and phenology for the selected pixels.
struct SelectionAnalysisView: View {
    let minRow: Int, maxRow: Int
    let minCol: Int, maxCol: Int
    let frames: [NDVIFrame]
    let pixelPhenology: PixelPhenologyResult?
    let medianFit: DLParams?
    var unmixResults: [UUID: FrameUnmixResult] = [:]
    var useFVC: Bool = false

    @Environment(\.dismiss) private var dismiss

    // Async-computed results
    @State private var isProcessing = true
    @State private var computeTask: Task<Void, Never>?
    @State private var ndviPoints: [(date: Date, mean: Double)] = []
    @State private var fitCurve: [(date: Date, ndvi: Double)] = []
    @State private var medianCurve: [(date: Date, ndvi: Double)] = []
    @State private var selectionFit: DLParams?
    @State private var reflData: [(date: Date, value: Double, band: String)] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    selectionHeader
                    bodyContent
                }
                .padding()
            }
            .navigationTitle("Selection (\(maxCol - minCol + 1)x\(maxRow - minRow + 1))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                }
            }
            .onAppear {
                guard computeTask == nil else { return }
                computeTask = Task { await computeAll() }
            }
            .onDisappear {
                computeTask?.cancel()
                computeTask = nil
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if isProcessing {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Processing \((maxCol - minCol + 1) * (maxRow - minRow + 1)) pixels...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 200)
        } else {
            ndviTimeSeriesChart
            if let fit = selectionFit {
                fitParameterRow(fit)
            }
            reflectanceChart
            if pixelPhenology != nil {
                phenologyStats
            }
        }
    }

    // MARK: - Async Computation

    private func computeAll() async {
        let sorted = frames.sorted { $0.date < $1.date }
        let cal = Calendar.current
        let rMin = minRow, rMax = maxRow, cMin = minCol, cMax = maxCol

        // Mean NDVI or fVeg per frame
        let points: [(date: Date, mean: Double)] = sorted.compactMap { frame in
            var sum: Double = 0, count = 0
            if useFVC, let ur = unmixResults[frame.id] {
                // Use fVeg from unmixing
                for row in rMin...min(rMax, ur.height - 1) {
                    for col in cMin...min(cMax, ur.width - 1) {
                        let v = ur.fveg[row][col]
                        if !v.isNaN { sum += Double(v); count += 1 }
                    }
                }
            } else {
                for row in rMin...min(rMax, frame.height - 1) {
                    for col in cMin...min(cMax, frame.width - 1) {
                        let v = frame.ndvi[row][col]
                        if !v.isNaN { sum += Double(v); count += 1 }
                    }
                }
            }
            guard count > 0 else { return nil }
            return (date: frame.date, mean: sum / Double(count))
        }

        // DL fit for selection
        let data = points.map {
            DoubleLogistic.DataPoint(
                doy: Double(cal.ordinality(of: .day, in: .year, for: $0.date) ?? 1),
                ndvi: $0.mean
            )
        }

        var fitCurveLocal: [(date: Date, ndvi: Double)] = []
        var medianCurveLocal: [(date: Date, ndvi: Double)] = []
        var selFit: DLParams? = nil

        if let first = points.first, let last = points.last, data.count >= 4 {
            let year = cal.component(.year, from: first.date)
            let doyFirst = cal.ordinality(of: .day, in: .year, for: first.date) ?? 1
            let doyLast = cal.ordinality(of: .day, in: .year, for: last.date) ?? 365
            let step = max(1, (doyLast - doyFirst) / 60)

            let s = AppSettings.shared
            let result = DoubleLogistic.ensembleFit(data: data, nRuns: 20,
                                                   perturbation: s.pixelPerturbation,
                                                   slopePerturbation: s.pixelSlopePerturbation,
                                                   minSeasonLength: Double(s.minSeasonLength),
                                                   maxSeasonLength: Double(s.maxSeasonLength))
            selFit = result.best

            for doy in stride(from: doyFirst, through: doyLast, by: step) {
                if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                    fitCurveLocal.append((date: d, ndvi: result.best.evaluate(t: Double(doy))))
                }
            }

            if let median = medianFit {
                for doy in stride(from: doyFirst, through: doyLast, by: step) {
                    if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                        medianCurveLocal.append((date: d, ndvi: median.evaluate(t: Double(doy))))
                    }
                }
            }
        }

        // Mean reflectance per band per frame
        var reflLocal: [(date: Date, value: Double, band: String)] = []
        for frame in sorted {
            var rSum = 0.0, nSum = 0.0, gSum = 0.0, bSum = 0.0
            var count = 0, gCount = 0, bCount = 0
            for row in rMin...min(rMax, frame.height - 1) {
                for col in cMin...min(cMax, frame.width - 1) {
                    let ndvi = frame.ndvi[row][col]
                    guard !ndvi.isNaN else { continue }
                    let ofs = Double(frame.dnOffset)
                    rSum += (Double(frame.redBand[row][col]) + ofs) / 10000
                    nSum += (Double(frame.nirBand[row][col]) + ofs) / 10000
                    count += 1
                    if let g = frame.greenBand { gSum += (Double(g[row][col]) + ofs) / 10000; gCount += 1 }
                    if let b = frame.blueBand { bSum += (Double(b[row][col]) + ofs) / 10000; bCount += 1 }
                }
            }
            guard count > 0 else { continue }
            let n = Double(count)
            reflLocal.append((date: frame.date, value: rSum / n, band: "Red"))
            reflLocal.append((date: frame.date, value: nSum / n, band: "NIR"))
            if gCount > 0 { reflLocal.append((date: frame.date, value: gSum / Double(gCount), band: "Green")) }
            if bCount > 0 { reflLocal.append((date: frame.date, value: bSum / Double(bCount), band: "Blue")) }
        }

        // Update UI on main actor
        await MainActor.run {
            ndviPoints = points
            fitCurve = fitCurveLocal
            medianCurve = medianCurveLocal
            selectionFit = selFit
            reflData = reflLocal
            isProcessing = false
        }
    }

    // MARK: - Header

    private var selectionHeader: some View {
        let totalPixels = (maxRow - minRow + 1) * (maxCol - minCol + 1)
        let validInFirst = frames.first.map { frame -> Int in
            var count = 0
            for row in minRow...maxRow {
                for col in minCol...maxCol {
                    if row < frame.height, col < frame.width, !frame.ndvi[row][col].isNaN {
                        count += 1
                    }
                }
            }
            return count
        } ?? 0

        var phenoGood = 0, phenoPoor = 0, phenoOutlier = 0
        if let pp = pixelPhenology {
            for row in minRow...min(maxRow, pp.height - 1) {
                for col in minCol...min(maxCol, pp.width - 1) {
                    guard let px = pp.pixels[row][col] else { continue }
                    switch px.fitQuality {
                    case .good: phenoGood += 1
                    case .poor: phenoPoor += 1
                    case .outlier: phenoOutlier += 1
                    case .skipped: break
                    }
                }
            }
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text("Pixels (\(minCol),\(minRow)) to (\(maxCol),\(maxRow))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                VStack {
                    Text("\(totalPixels)").font(.title3.bold())
                    Text("Total").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                VStack {
                    Text("\(validInFirst)").font(.title3.bold()).foregroundStyle(.green)
                    Text("Valid").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                if pixelPhenology != nil {
                    VStack {
                        Text("\(phenoGood)").font(.title3.bold()).foregroundStyle(.green)
                        Text("Good fit").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    if phenoPoor > 0 {
                        VStack {
                            Text("\(phenoPoor)").font(.title3.bold()).foregroundStyle(.red)
                            Text("Poor").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                    if phenoOutlier > 0 {
                        VStack {
                            Text("\(phenoOutlier)").font(.title3.bold()).foregroundStyle(.purple)
                            Text("Outlier").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - NDVI Chart

    private var ndviTimeSeriesChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(useFVC ? "Mean FVC (selection)" : "Mean NDVI (selection)")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                if !fitCurve.isEmpty {
                    Text("DL fit")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
                if !medianCurve.isEmpty {
                    Text("Field median")
                        .font(.system(size: 8))
                        .foregroundStyle(.green.opacity(0.4))
                }
            }
            Chart {
                ForEach(0..<ndviPoints.count, id: \.self) { i in
                    PointMark(
                        x: .value("Date", ndviPoints[i].date),
                        y: .value("NDVI", ndviPoints[i].mean)
                    )
                    .foregroundStyle(.green)
                    .symbolSize(30)

                    LineMark(
                        x: .value("Date", ndviPoints[i].date),
                        y: .value("NDVI", ndviPoints[i].mean),
                        series: .value("Series", "Selection")
                    )
                    .foregroundStyle(.green.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                ForEach(0..<fitCurve.count, id: \.self) { i in
                    LineMark(
                        x: .value("Date", fitCurve[i].date),
                        y: .value("NDVI", fitCurve[i].ndvi),
                        series: .value("Series", "Sel fit")
                    )
                    .foregroundStyle(.yellow)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                ForEach(0..<medianCurve.count, id: \.self) { i in
                    LineMark(
                        x: .value("Date", medianCurve[i].date),
                        y: .value("NDVI", medianCurve[i].ndvi),
                        series: .value("Series", "Median")
                    )
                    .foregroundStyle(.green.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                }
            }
            .chartYScale(domain: useFVC ? 0.0...1.0 : -0.2...1.0)
            .frame(height: 180)
        }
    }

    // MARK: - Fit Parameters

    private func fitParameterRow(_ fit: DLParams) -> some View {
        HStack(spacing: 6) {
            paramLabel("mn", fit.mn, "%.2f")
            paramLabel("amp", fit.delta, "%.2f")
            paramLabel("sos", fit.sos, "%.0f")
            paramLabel("rsp", fit.rsp, "%.3f")
            paramLabel("season", fit.seasonLength, "%.0f")
            paramLabel("rau", fit.rau, "%.3f")
            paramLabel("mx", fit.mx, "%.2f", color: .secondary)
            paramLabel("eos", fit.eos, "%.0f", color: .secondary)
            Text("RMSE \(String(format: "%.4f", fit.rmse))")
                .font(.system(size: 7).monospacedDigit())
                .foregroundStyle(.orange)
        }
    }

    private func paramLabel(_ name: String, _ value: Double, _ fmt: String, color: Color = .yellow) -> some View {
        VStack(spacing: 0) {
            Text(name).font(.system(size: 7).bold()).foregroundStyle(color)
            Text(String(format: fmt, value)).font(.system(size: 7).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Reflectance Chart

    private var reflectanceChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Mean Reflectance")
                .font(.caption.bold())
            Chart {
                ForEach(0..<reflData.count, id: \.self) { i in
                    LineMark(
                        x: .value("Date", reflData[i].date),
                        y: .value("Reflectance", reflData[i].value),
                        series: .value("Band", reflData[i].band)
                    )
                    .foregroundStyle(bandColor(reflData[i].band))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                    PointMark(
                        x: .value("Date", reflData[i].date),
                        y: .value("Reflectance", reflData[i].value)
                    )
                    .foregroundStyle(bandColor(reflData[i].band))
                    .symbolSize(12)
                }
            }
            .chartForegroundStyleScale([
                "Red": Color.red, "NIR": Color.purple,
                "Green": Color.green, "Blue": Color.blue,
            ])
            .frame(height: 140)
        }
    }

    private func bandColor(_ band: String) -> Color {
        switch band {
        case "Red": return .red
        case "NIR": return .purple
        case "Green": return .green
        case "Blue": return .blue
        default: return .gray
        }
    }

    // MARK: - Phenology Stats

    private var phenologyStats: some View {
        guard let pp = pixelPhenology else { return AnyView(EmptyView()) }

        var goodParams: [DLParams] = []
        for row in minRow...min(maxRow, pp.height - 1) {
            for col in minCol...min(maxCol, pp.width - 1) {
                if let px = pp.pixels[row][col], px.fitQuality == .good {
                    goodParams.append(px.params)
                }
            }
        }

        guard !goodParams.isEmpty else {
            return AnyView(
                Text("No good-fit pixels in selection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
        }

        let paramNames = ["mn", "amp", "sos", "rsp", "season", "rau"]
        let extractors: [(DLParams) -> Double] = [
            { $0.mn }, { $0.delta }, { $0.sos }, { $0.rsp }, { $0.seasonLength }, { $0.rau }
        ]
        let formats = ["%.3f", "%.3f", "%.1f", "%.4f", "%.1f", "%.4f"]

        struct ParamStat {
            let name: String
            let mean: Double
            let std: Double
            let format: String
        }

        let stats: [ParamStat] = zip(zip(paramNames, extractors), formats).map { pair, fmt in
            let (name, extract) = pair
            let values = goodParams.map { extract($0) }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            return ParamStat(name: name, mean: mean, std: sqrt(variance), format: fmt)
        }

        return AnyView(VStack(alignment: .leading, spacing: 4) {
            Text("Phenology Parameters (\(goodParams.count) good-fit pixels)")
                .font(.caption.bold())
            HStack(spacing: 0) {
                Text("Param").font(.system(size: 8).bold()).frame(maxWidth: .infinity).foregroundStyle(.yellow)
                Text("Mean").font(.system(size: 8).bold()).frame(maxWidth: .infinity).foregroundStyle(.yellow)
                Text("Std").font(.system(size: 8).bold()).frame(maxWidth: .infinity).foregroundStyle(.yellow)
            }
            ForEach(0..<stats.count, id: \.self) { i in
                HStack(spacing: 0) {
                    Text(stats[i].name)
                        .font(.system(size: 8).bold())
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                    Text(String(format: stats[i].format, stats[i].mean))
                        .font(.system(size: 8).monospacedDigit())
                        .frame(maxWidth: .infinity)
                    Text(String(format: stats[i].format, stats[i].std))
                        .font(.system(size: 8).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.orange)
                }
            }
        })
    }
}
