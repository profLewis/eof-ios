import SwiftUI
import Charts

/// Detail sheet showing per-pixel NDVI time series, DL fit, and reflectance data.
struct PixelDetailView: View {
    @Binding var isPresented: Bool
    let row: Int
    let col: Int
    let frames: [NDVIFrame]
    let pixelFit: PixelPhenology?
    let medianFit: DLParams?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    pixelHeader
                    rejectionDetailSection
                    pixelNDVIChart
                    if let fit = pixelFit, let median = medianFit {
                        parameterComparison(pixel: fit.params, median: median)
                    }
                    reflectanceChart
                    sclHistory
                }
                .padding()
            }
            .navigationTitle("Pixel (\(col), \(row))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: - Header

    private var pixelHeader: some View {
        HStack {
            if let fit = pixelFit {
                let badge: (String, Color) = switch fit.fitQuality {
                case .good: ("Good", .green)
                case .poor: ("Poor", .red)
                case .skipped: ("Skipped", .gray)
                case .outlier: ("Outlier", .purple)
                }
                Text(badge.0)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(badge.1.opacity(0.2), in: Capsule())
                    .foregroundStyle(badge.1)

                Text("RMSE \(String(format: "%.4f", fit.params.rmse))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text("\(fit.nValidObs) obs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No fit data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - NDVI Time Series

    private var pixelNDVIChart: some View {
        let sorted = frames.sorted { $0.date < $1.date }
        let cal = Calendar.current

        // Extract this pixel's NDVI values
        struct PixelPoint: Identifiable {
            let id: String
            let date: Date
            let ndvi: Double
            let isFiltered: Bool  // removed by cycle contamination filter
        }

        // Build all data points
        let allData: [DoubleLogistic.DataPoint] = sorted.compactMap { frame in
            guard row < frame.height, col < frame.width else { return nil }
            let val = frame.ndvi[row][col]
            guard !val.isNaN else { return nil }
            return DoubleLogistic.DataPoint(
                doy: Double(cal.ordinality(of: .day, in: .year, for: frame.date) ?? 1),
                ndvi: Double(val)
            )
        }

        // Run cycle contamination filter to find which points survive
        let filtered = DoubleLogistic.filterCycleContamination(data: allData)
        let filteredDoys = Set(filtered.map { $0.doy })

        let points: [PixelPoint] = sorted.compactMap { frame in
            guard row < frame.height, col < frame.width else { return nil }
            let val = frame.ndvi[row][col]
            guard !val.isNaN else { return nil }
            let doy = Double(cal.ordinality(of: .day, in: .year, for: frame.date) ?? 1)
            return PixelPoint(
                id: frame.dateString, date: frame.date, ndvi: Double(val),
                isFiltered: !filteredDoys.contains(doy)
            )
        }

        // Generate fit curves
        struct CurvePoint: Identifiable {
            let id: String
            let date: Date
            let ndvi: Double
            let series: String
        }

        var curvePoints = [CurvePoint]()
        if let first = sorted.first, let last = sorted.last {
            let year = cal.component(.year, from: first.date)
            let doyFirst = cal.ordinality(of: .day, in: .year, for: first.date) ?? 1
            let doyLast = cal.ordinality(of: .day, in: .year, for: last.date) ?? 365
            let step = max(1, (doyLast - doyFirst) / 60)
            let doys = stride(from: doyFirst, through: doyLast, by: step)

            if let fit = pixelFit, fit.fitQuality != .skipped {
                for doy in doys {
                    if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                        curvePoints.append(CurvePoint(
                            id: "px_\(doy)", date: d,
                            ndvi: fit.params.evaluate(t: Double(doy)),
                            series: "Pixel fit"
                        ))
                    }
                }
            }
            if let median = medianFit {
                for doy in doys {
                    if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                        curvePoints.append(CurvePoint(
                            id: "med_\(doy)", date: d,
                            ndvi: median.evaluate(t: Double(doy)),
                            series: "Median fit"
                        ))
                    }
                }
            }
        }

        let nFiltered = points.filter { $0.isFiltered }.count

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("NDVI")
                    .font(.caption.bold())
                if pixelFit != nil {
                    Text("Pixel fit")
                        .font(.system(size: 8).bold())
                        .foregroundStyle(.yellow)
                }
                if medianFit != nil {
                    Text("Median fit")
                        .font(.system(size: 8))
                        .foregroundStyle(.green.opacity(0.4))
                }
                if nFiltered > 0 {
                    Text("\(nFiltered) filtered")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                }
            }
            Chart {
                // Good points (green)
                ForEach(points.filter { !$0.isFiltered }) { pt in
                    PointMark(
                        x: .value("Date", pt.date),
                        y: .value("NDVI", pt.ndvi)
                    )
                    .foregroundStyle(.green)
                    .symbolSize(30)
                }
                // Filtered/outlier points (red, hollow)
                ForEach(points.filter { $0.isFiltered }) { pt in
                    PointMark(
                        x: .value("Date", pt.date),
                        y: .value("NDVI", pt.ndvi)
                    )
                    .foregroundStyle(.red.opacity(0.6))
                    .symbolSize(30)
                    .symbol(.cross)
                }
                ForEach(curvePoints) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value("NDVI", pt.ndvi),
                        series: .value("Series", pt.series)
                    )
                    .foregroundStyle(pt.series == "Pixel fit" ? .yellow : .green.opacity(0.4))
                    .lineStyle(StrokeStyle(
                        lineWidth: pt.series == "Pixel fit" ? 2 : 1,
                        dash: pt.series == "Pixel fit" ? [] : [4, 2]
                    ))
                }
            }
            .chartYScale(domain: -0.2...1.0)
            .frame(height: 160)
        }
    }

    // MARK: - Parameter Comparison

    private func parameterComparison(pixel: DLParams, median: DLParams) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Parameters (pixel vs median)")
                .font(.caption.bold())
            HStack(spacing: 0) {
                ForEach(["", "mn", "amp", "sos", "rsp", "len", "rau", "mx", "eos"], id: \.self) { label in
                    Text(label.isEmpty ? "" : label)
                        .font(.system(size: 8).bold())
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.yellow)
                }
            }
            HStack(spacing: 0) {
                Text("Px")
                    .font(.system(size: 7).bold())
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
                paramCell(pixel.mn, "%.2f")
                paramCell(pixel.delta, "%.2f")
                paramCell(pixel.sos, "%.0f")
                paramCell(pixel.rsp, "%.3f")
                paramCell(pixel.seasonLength, "%.0f")
                paramCell(pixel.rau, "%.3f")
                paramCell(pixel.mx, "%.2f")
                paramCell(pixel.eos, "%.0f")
            }
            HStack(spacing: 0) {
                Text("Med")
                    .font(.system(size: 7).bold())
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
                paramCell(median.mn, "%.2f")
                paramCell(median.delta, "%.2f")
                paramCell(median.sos, "%.0f")
                paramCell(median.rsp, "%.3f")
                paramCell(median.seasonLength, "%.0f")
                paramCell(median.rau, "%.3f")
                paramCell(median.mx, "%.2f")
                paramCell(median.eos, "%.0f")
            }
        }
    }

    private func paramCell(_ value: Double, _ fmt: String) -> some View {
        Text(String(format: fmt, value))
            .font(.system(size: 8).monospacedDigit())
            .frame(maxWidth: .infinity)
            .foregroundStyle(.secondary)
    }

    // MARK: - Reflectance Chart

    private var reflectanceChart: some View {
        let sorted = frames.sorted { $0.date < $1.date }

        struct ReflPoint: Identifiable {
            let id: String
            let date: Date
            let value: Double
            let band: String
        }

        var points = [ReflPoint]()
        for frame in sorted {
            guard row < frame.height, col < frame.width else { continue }
            let ofs = Double(frame.dnOffset)
            let redRefl = (Double(frame.redBand[row][col]) + ofs) / 10000
            let nirRefl = (Double(frame.nirBand[row][col]) + ofs) / 10000
            points.append(ReflPoint(id: "r_\(frame.dateString)", date: frame.date, value: redRefl, band: "Red"))
            points.append(ReflPoint(id: "n_\(frame.dateString)", date: frame.date, value: nirRefl, band: "NIR"))
            if let g = frame.greenBand {
                let gRefl = (Double(g[row][col]) + ofs) / 10000
                points.append(ReflPoint(id: "g_\(frame.dateString)", date: frame.date, value: gRefl, band: "Green"))
            }
            if let b = frame.blueBand {
                let bRefl = (Double(b[row][col]) + ofs) / 10000
                points.append(ReflPoint(id: "b_\(frame.dateString)", date: frame.date, value: bRefl, band: "Blue"))
            }
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text("Reflectance")
                .font(.caption.bold())
            Chart(points) { pt in
                LineMark(
                    x: .value("Date", pt.date),
                    y: .value("Reflectance", pt.value),
                    series: .value("Band", pt.band)
                )
                .foregroundStyle(bandColor(pt.band))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                PointMark(
                    x: .value("Date", pt.date),
                    y: .value("Reflectance", pt.value)
                )
                .foregroundStyle(bandColor(pt.band))
                .symbolSize(12)
            }
            .chartForegroundStyleScale([
                "Red": Color.red,
                "NIR": Color.purple,
                "Green": Color.green,
                "Blue": Color.blue,
            ])
            .frame(height: 120)
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

    // MARK: - SCL History

    // MARK: - Rejection Detail

    private var rejectionDetailSection: some View {
        Group {
            if let detail = pixelFit?.rejectionDetail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rejection Reason")
                        .font(.caption.bold())
                    Text(detail.humanReadable)
                        .font(.caption)
                        .foregroundStyle(.red)

                    if let zScores = detail.paramZScores, !zScores.isEmpty {
                        Text("Parameter z-scores")
                            .font(.system(size: 8).bold())
                            .foregroundStyle(.purple)
                        HStack(spacing: 0) {
                            ForEach(zScores.sorted(by: { $0.key < $1.key }), id: \.key) { name, z in
                                VStack(spacing: 1) {
                                    Text(name)
                                        .font(.system(size: 7).bold())
                                        .foregroundStyle(.purple.opacity(0.7))
                                    Text(String(format: "%.1f", z))
                                        .font(.system(size: 8).monospacedDigit())
                                        .foregroundStyle(z > 4 ? .red : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }

                    if let dist = detail.clusterDistance, let thresh = detail.clusterThreshold {
                        HStack {
                            Text("Cluster distance: \(String(format: "%.1f", dist))")
                                .font(.system(size: 9).monospacedDigit())
                            Text("(threshold: \(String(format: "%.1f", thresh)))")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - SCL History

    private var sclHistory: some View {
        let sorted = frames.sorted { $0.date < $1.date }

        struct SCLEntry: Identifiable {
            let id: String
            let date: Date
            let sclClass: UInt16
        }

        let entries: [SCLEntry] = sorted.compactMap { frame in
            guard let scl = frame.sclBand, row < scl.count, col < scl[row].count else { return nil }
            return SCLEntry(id: "scl_\(frame.dateString)", date: frame.date, sclClass: scl[row][col])
        }

        guard !entries.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(VStack(alignment: .leading, spacing: 2) {
            Text("SCL Class History")
                .font(.caption.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(entries) { entry in
                        let (r, g, b) = NDVIMapView.sclColor(entry.sclClass)
                        VStack(spacing: 1) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
                                .frame(width: 14, height: 14)
                            Text("\(entry.sclClass)")
                                .font(.system(size: 6))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        })
    }
}

/// Compact sheet shown when tapping a pixel in "Bad Data" mode.
struct PixelDetailSheet: View {
    let pixel: PixelPhenology
    let frames: [NDVIFrame]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Quality badge
                    HStack {
                        let badge: (String, Color) = switch pixel.fitQuality {
                        case .good: ("Good", .green)
                        case .poor: ("Poor", .red)
                        case .skipped: ("Skipped", .gray)
                        case .outlier: ("Outlier", .purple)
                        }
                        Text(badge.0)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(badge.1.opacity(0.2), in: Capsule())
                            .foregroundStyle(badge.1)

                        Text("\(pixel.nValidObs) obs")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        if pixel.fitQuality != .skipped {
                            Text("RMSE \(String(format: "%.4f", pixel.params.rmse))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    // Rejection reason
                    if let detail = pixel.rejectionDetail {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.humanReadable)
                                .font(.callout)
                                .foregroundStyle(.red)

                            if let zScores = detail.paramZScores, !zScores.isEmpty {
                                Text("Parameter z-scores:")
                                    .font(.caption.bold())
                                    .foregroundStyle(.purple)
                                HStack(spacing: 0) {
                                    ForEach(zScores.sorted(by: { $0.key < $1.key }), id: \.key) { name, z in
                                        VStack(spacing: 1) {
                                            Text(name)
                                                .font(.system(size: 8).bold())
                                                .foregroundStyle(.purple.opacity(0.7))
                                            Text(String(format: "%.1f", z))
                                                .font(.system(size: 10).monospacedDigit())
                                                .foregroundStyle(z > 4 ? .red : .secondary)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }

                    // Mini NDVI chart
                    miniNDVIChart
                }
                .padding()
            }
            .navigationTitle("Pixel (\(pixel.col), \(pixel.row))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var miniNDVIChart: some View {
        let sorted = frames.sorted { $0.date < $1.date }
        let cal = Calendar.current

        struct Pt: Identifiable {
            let id: String
            let date: Date
            let ndvi: Double
        }

        let points: [Pt] = sorted.compactMap { frame in
            guard pixel.row < frame.height, pixel.col < frame.width else { return nil }
            let val = frame.ndvi[pixel.row][pixel.col]
            guard !val.isNaN else { return nil }
            return Pt(id: frame.dateString, date: frame.date, ndvi: Double(val))
        }

        // Generate pixel fit curve
        struct CurvePt: Identifiable {
            let id: String
            let date: Date
            let ndvi: Double
        }

        var curvePts = [CurvePt]()
        if pixel.fitQuality != .skipped, let first = sorted.first, let last = sorted.last {
            let year = cal.component(.year, from: first.date)
            let doyFirst = cal.ordinality(of: .day, in: .year, for: first.date) ?? 1
            let doyLast = cal.ordinality(of: .day, in: .year, for: last.date) ?? 365
            let step = max(1, (doyLast - doyFirst) / 50)
            for doy in stride(from: doyFirst, through: doyLast, by: step) {
                if let d = cal.date(from: DateComponents(year: year, day: doy)) {
                    curvePts.append(CurvePt(
                        id: "c_\(doy)", date: d,
                        ndvi: pixel.params.evaluate(t: Double(doy))
                    ))
                }
            }
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text("NDVI Time Series")
                .font(.caption.bold())
            Chart {
                ForEach(points) { pt in
                    PointMark(x: .value("Date", pt.date), y: .value("NDVI", pt.ndvi))
                        .foregroundStyle(.green)
                        .symbolSize(20)
                }
                ForEach(curvePts) { pt in
                    LineMark(x: .value("Date", pt.date), y: .value("NDVI", pt.ndvi))
                        .foregroundStyle(.yellow)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartYScale(domain: -0.2...1.0)
            .frame(height: 140)
        }
    }
}
