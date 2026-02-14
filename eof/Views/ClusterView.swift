import SwiftUI
import Charts

/// Sheet showing cluster analysis results — parameter distributions and outlier detection.
struct ClusterView: View {
    @Binding var isPresented: Bool
    let result: PixelPhenologyResult

    private let paramNames = ["SOS", "Season", "Amp", "Min", "rsp", "rau"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summarySection
                    qualityPieChart
                    parameterDistributions
                    uncertaintyTable
                }
                .padding()
            }
            .navigationTitle("Cluster Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pixel Classification")
                .font(.caption.bold())
            HStack(spacing: 12) {
                qualityBadge("Good", count: result.goodCount, color: .green)
                qualityBadge("Poor", count: result.poorCount, color: .red)
                qualityBadge("Skip", count: result.skippedCount, color: .gray)
                qualityBadge("Outlier", count: result.outlierCount, color: .purple)
            }
        }
    }

    private func qualityBadge(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pie Chart

    private var qualityPieChart: some View {
        let counts = [result.goodCount, result.poorCount, result.skippedCount, result.outlierCount]
        let labels = ["Good", "Poor", "Skipped", "Outlier"]
        let colors: [Color] = [.green, .red, .gray, .purple]
        let total = counts.reduce(0, +)

        return Chart {
            ForEach(0..<4, id: \.self) { i in
                if counts[i] > 0 {
                    SectorMark(
                        angle: .value("Count", counts[i]),
                        innerRadius: .ratio(0.5),
                        angularInset: 1
                    )
                    .foregroundStyle(colors[i])
                    .annotation(position: .overlay) {
                        if counts[i] * 10 > total {
                            Text("\(labels[i]) \(counts[i])")
                                .font(.system(size: 8).bold())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .frame(height: 140)
    }

    // MARK: - Parameter Distributions

    private func extractParam(_ index: Int, _ params: DLParams) -> Double {
        switch index {
        case 0: return params.sos
        case 1: return params.seasonLength
        case 2: return params.delta
        case 3: return params.mn
        case 4: return params.rsp
        case 5: return params.rau
        default: return 0
        }
    }

    private var parameterDistributions: some View {
        let goodPixels = result.pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .good }
        let outlierPixels = result.pixels.flatMap { $0 }.compactMap { $0 }.filter { $0.fitQuality == .outlier }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Parameter Distributions")
                .font(.caption.bold())

            ForEach(0..<6, id: \.self) { i in
                parameterHistogram(
                    name: paramNames[i],
                    goodValues: goodPixels.map { extractParam(i, $0.params) },
                    outlierValues: outlierPixels.map { extractParam(i, $0.params) }
                )
            }
        }
    }

    private func parameterHistogram(name: String, goodValues: [Double], outlierValues: [Double]) -> some View {
        let allValues = goodValues + outlierValues
        let minVal = allValues.min() ?? 0
        let maxVal = allValues.max() ?? 1
        let range = maxVal - minVal

        if goodValues.isEmpty || range < 1e-10 {
            return AnyView(EmptyView())
        }

        let nBins = 20
        let binWidth = range / Double(nBins)

        // Build histogram data as simple arrays
        var centers = [Double]()
        var counts = [Int]()
        var series = [String]()

        for i in 0..<nBins {
            let lo = minVal + Double(i) * binWidth
            let hi = lo + binWidth
            let center = (lo + hi) / 2
            let gCount = goodValues.filter { $0 >= lo && $0 < hi }.count
            let oCount = outlierValues.filter { $0 >= lo && $0 < hi }.count
            if gCount > 0 {
                centers.append(center); counts.append(gCount); series.append("Good")
            }
            if oCount > 0 {
                centers.append(center); counts.append(oCount); series.append("Outlier")
            }
        }

        return AnyView(VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 9).bold())
                .foregroundStyle(.secondary)
            Chart {
                ForEach(0..<centers.count, id: \.self) { i in
                    BarMark(
                        x: .value(name, centers[i]),
                        y: .value("Count", counts[i])
                    )
                    .foregroundStyle(series[i] == "Good" ? Color.green.opacity(0.6) : Color.purple.opacity(0.8))
                }
            }
            .frame(height: 50)
            .chartYAxis(.hidden)
        })
    }

    // MARK: - Uncertainty Table

    private var uncertaintyTable: some View {
        let uncertainties = result.parameterUncertainty()
        if uncertainties.isEmpty {
            return AnyView(EmptyView())
        }

        return AnyView(VStack(alignment: .leading, spacing: 4) {
            Text("Parameter Uncertainty (IQR)")
                .font(.caption.bold())
            HStack(spacing: 0) {
                Text("Param")
                    .font(.system(size: 8).bold())
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.yellow)
                Text("Median")
                    .font(.system(size: 8).bold())
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.yellow)
                Text("IQR")
                    .font(.system(size: 8).bold())
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.yellow)
                Text("Rel %")
                    .font(.system(size: 8).bold())
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.yellow)
            }
            ForEach(0..<uncertainties.count, id: \.self) { i in
                let u = uncertainties[i]
                HStack(spacing: 0) {
                    Text(u.name)
                        .font(.system(size: 8).bold())
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                    Text(formatParam(u.name, u.median))
                        .font(.system(size: 8).monospacedDigit())
                        .frame(maxWidth: .infinity)
                    Text(formatParam(u.name, u.iqr))
                        .font(.system(size: 8).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.orange)
                    Text(u.median != 0 ? String(format: "%.1f%%", abs(u.iqr / u.median) * 100) : "-")
                        .font(.system(size: 8).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.orange)
                }
            }
        })
    }

    private func formatParam(_ name: String, _ value: Double) -> String {
        switch name {
        case "mn", "mx": return String(format: "%.3f", value)
        case "sos", "eos": return String(format: "%.1f", value)
        case "rsp", "rau": return String(format: "%.4f", value)
        default: return String(format: "%.3f", value)
        }
    }
}
