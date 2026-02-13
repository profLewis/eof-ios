import SwiftUI
import Charts

struct SettingsView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared
    @State private var showingBandInfo = false
    @State private var showingAbout = false
    @State private var showingAOI = false
    @State private var showingDataSources = false
    @State private var showingSCLMask = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Visualization") {
                    Picker("Display", selection: $settings.displayMode) {
                        Text("NDVI").tag(AppSettings.DisplayMode.ndvi)
                        Text("FCC").tag(AppSettings.DisplayMode.fcc)
                        Text("RGB").tag(AppSettings.DisplayMode.rcc)
                        Text("SCL").tag(AppSettings.DisplayMode.scl)
                    }
                    .pickerStyle(.segmented)

                    Text(displayModeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.displayMode == .ndvi {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("NDVI Threshold")
                                Spacer()
                                Text(String(format: "%.2f", settings.ndviThreshold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.ndviThreshold, in: -0.5...1, step: 0.05)
                        }
                        Text("Pixels below this threshold are shown muted. Negative values include bare soil/water.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("SCL Class Boundaries", isOn: $settings.showSCLBoundaries)
                    Toggle("SCL Colors on Masked Pixels", isOn: $settings.showMaskedClassColors)
                    Toggle("Satellite Basemap", isOn: $settings.showBasemap)
                    if settings.showBasemap {
                        Text("Apple Maps satellite imagery (date varies by location, typically 1-3 years old)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Playback Speed", selection: $settings.playbackSpeed) {
                        Text("0.5x").tag(0.5)
                        Text("1x").tag(1.0)
                        Text("2x").tag(2.0)
                        Text("4x").tag(4.0)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    bandsUsedRow
                    Button {
                        showingBandInfo = true
                    } label: {
                        Label("Sentinel-2 Band Reference", systemImage: "waveform.circle")
                    }
                } header: {
                    Text("Bands")
                } footer: {
                    Text("Only bands needed for the selected mode are downloaded. Cached bands are reused when switching modes.")
                }

                Section {
                    Button {
                        showingAOI = true
                    } label: {
                        HStack {
                            Label("Area of Interest", systemImage: "mappin.and.ellipse")
                            Spacer()
                            Text(settings.aoiSourceLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let geo = settings.aoiGeometry {
                        LabeledContent("Extent", value: settings.aoiSummary)
                            .font(.caption)
                    }
                }

                Section("Date Range") {
                    DatePicker("Start", selection: $settings.startDate, displayedComponents: .date)
                    DatePicker("End", selection: $settings.endDate, displayedComponents: .date)
                }

                Section("Filters") {
                    Toggle("Enforce AOI Polygon", isOn: $settings.enforceAOI)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("AOI Buffer")
                            Spacer()
                            Text("\(Int(settings.aoiBufferMeters))m")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.aoiBufferMeters, in: 0...500, step: 10)
                    }
                    if settings.aoiBufferMeters > 0 {
                        Text("Fetches \(Int(settings.aoiBufferMeters))m beyond AOI boundary. Useful for multi-resolution data fusion.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("SCL Mask", isOn: $settings.cloudMask)
                    if settings.cloudMask {
                        Button {
                            showingSCLMask = true
                        } label: {
                            HStack {
                                Label("Valid SCL Classes", systemImage: "square.grid.3x3")
                                Spacer()
                                Text("\(settings.sclValidClasses.count) of 12")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max Cloud Cover")
                            Spacer()
                            Text("\(Int(settings.cloudThreshold))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.cloudThreshold, in: 0...100, step: 5)
                    }
                    Text("SCL mask hides pixels by class. Threshold skips entire scenes. When AOI polygon is off, all pixels in the chip are processed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Per-Pixel Phenology") {
                    Stepper("Ensemble Runs: \(settings.pixelEnsembleRuns)",
                            value: $settings.pixelEnsembleRuns, in: 1...20)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Perturbation")
                            Spacer()
                            Text("\(Int(settings.pixelPerturbation * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.pixelPerturbation, in: 0.05...1.0, step: 0.05)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Slope Perturbation (rsp/rau)")
                            Spacer()
                            Text("\(Int(settings.pixelSlopePerturbation * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.pixelSlopePerturbation, in: 0.05...0.50, step: 0.05)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("RMSE Threshold")
                            Spacer()
                            Text(String(format: "%.2f", settings.pixelFitRMSEThreshold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.pixelFitRMSEThreshold, in: 0.02...0.30, step: 0.01)
                    }
                    Stepper("Min Observations: \(settings.pixelMinObservations)",
                            value: $settings.pixelMinObservations, in: 3...10)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Cluster Filter Threshold")
                            Spacer()
                            Text(String(format: "%.1f MADs", settings.clusterFilterThreshold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.clusterFilterThreshold, in: 2.0...8.0, step: 0.5)
                    }
                    Stepper("Min Season Length: \(settings.minSeasonLength) days",
                            value: $settings.minSeasonLength, in: 10...200, step: 10)
                    Stepper("Max Season Length: \(settings.maxSeasonLength) days",
                            value: $settings.maxSeasonLength, in: 100...365, step: 10)
                    Text("Per-pixel fitting uses median fit as starting point. Higher perturbation explores more but is slower. Cluster filter threshold controls outlier sensitivity — lower values are stricter. Spatial regularization rescues isolated outliers with good neighbors. Season length constraints limit EOS − SOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showingDataSources = true
                    } label: {
                        HStack {
                            Label("Data Sources", systemImage: "server.rack")
                            Spacer()
                            Text("\(settings.enabledSources.count) active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        showingAbout = true
                    } label: {
                        Label("About eof", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $showingBandInfo) {
                BandInfoView(isPresented: $showingBandInfo)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingAbout) {
                AboutView(isPresented: $showingAbout)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingAOI) {
                AOIView(isPresented: $showingAOI)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingDataSources) {
                DataSourcesView(isPresented: $showingDataSources)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingSCLMask) {
                SCLMaskView(isPresented: $showingSCLMask)
                    .presentationDetents([.large])
            }
        }
    }

    private var bandsUsedRow: some View {
        HStack {
            Text("Active Bands")
            Spacer()
            Group {
                switch settings.displayMode {
                case .ndvi:
                    Text("B04 (Red), B08 (NIR)")
                case .fcc:
                    Text("B03, B04, B08")
                case .rcc:
                    Text("B02, B03, B04")
                case .scl:
                    Text("SCL (20m)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var displayModeDescription: String {
        switch settings.displayMode {
        case .ndvi:
            "Normalized Difference Vegetation Index: (NIR \u{2212} Red) / (NIR + Red)"
        case .fcc:
            "False Color: NIR \u{2192} R, Red \u{2192} G, Green \u{2192} B. Vegetation appears red."
        case .rcc:
            "True Color: Red, Green, Blue bands. Natural appearance."
        case .scl:
            "Scene Classification Layer: per-pixel land cover and cloud classification."
        }
    }
}

// MARK: - Sentinel-2 Band Reference

struct BandInfoView: View {
    @Binding var isPresented: Bool

    // Band data: name, center wavelength (nm), FWHM (nm), resolution (m), use, color
    // Colors approximate CIE visible spectrum; NIR/SWIR use conventional false-color representations
    private static let bandData: [(name: String, center: Double, fwhm: Double, res: String, use: String, color: Color)] = [
        ("B01", 443, 20, "60 m", "Aerosol", Color(red: 0.3, green: 0.0, blue: 0.8)),    // violet
        ("B02", 490, 65, "10 m", "Blue", Color(red: 0.0, green: 0.3, blue: 1.0)),        // blue
        ("B03", 560, 35, "10 m", "Green", Color(red: 0.0, green: 0.7, blue: 0.0)),       // green
        ("B04", 665, 30, "10 m", "Red / NDVI", Color(red: 0.9, green: 0.0, blue: 0.0)),  // red
        ("B05", 705, 15, "20 m", "Red Edge 1", Color(red: 0.8, green: 0.0, blue: 0.1)),  // deep red
        ("B06", 740, 15, "20 m", "Red Edge 2", Color(red: 0.7, green: 0.0, blue: 0.15)), // dark red
        ("B07", 783, 20, "20 m", "Red Edge 3", Color(red: 0.6, green: 0.0, blue: 0.2)),  // darker red
        ("B08", 842, 115, "10 m", "NIR / NDVI", Color(red: 0.5, green: 0.0, blue: 0.3)), // NIR (maroon)
        ("B8A", 865, 20, "20 m", "Narrow NIR", Color(red: 0.45, green: 0.0, blue: 0.35)),
        ("B09", 945, 20, "60 m", "Water Vapour", Color(red: 0.4, green: 0.2, blue: 0.4)),
        ("B11", 1610, 90, "20 m", "SWIR 1", Color(red: 0.6, green: 0.4, blue: 0.1)),    // warm brown
        ("B12", 2190, 180, "20 m", "SWIR 2", Color(red: 0.5, green: 0.3, blue: 0.05)),   // dark brown
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Sentinel-2 MSI carries 13 spectral bands from visible to SWIR. Level-2A products provide surface reflectance (atmospherically corrected).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Spectral Response Functions") {
                    spectralPlot
                        .padding(.vertical, 4)
                }

                Section("Spectral Bands") {
                    ForEach(Self.bandData, id: \.name) { band in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(band.color)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(band.name)
                                        .font(.subheadline.bold())
                                    Text(band.use)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(band.res)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("\u{03BB} \(Int(band.center)) nm, FWHM \(Int(band.fwhm)) nm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }

                Section("DN to Reflectance") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AWS / Planetary Computer L2A COGs:")
                            .font(.caption.bold())
                        Text("reflectance = DN / 10000")
                            .font(.system(.caption, design: .monospaced))
                        Text("DN = 0: nodata, DN = 65535: saturated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Valid reflectance range: 0.0 \u{2013} 1.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Scene Classification (SCL)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The SCL band (20m, upsampled to 10m) classifies each pixel. Only pixels with valid land-cover classes are retained:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 3) {
                            sclRow(value: 4, name: "Vegetation", valid: true)
                            sclRow(value: 5, name: "Not Vegetated", valid: true)
                            sclRow(value: 6, name: "Water", valid: true)
                            sclRow(value: 7, name: "Unclassified", valid: true)
                        }

                        Text("Masked (set to NaN):")
                            .font(.caption.bold())
                            .foregroundStyle(.red)

                        VStack(alignment: .leading, spacing: 3) {
                            sclRow(value: 0, name: "No Data", valid: false)
                            sclRow(value: 1, name: "Saturated / Defective", valid: false)
                            sclRow(value: 2, name: "Dark Area Pixels", valid: false)
                            sclRow(value: 3, name: "Cloud Shadows", valid: false)
                            sclRow(value: 8, name: "Cloud Medium Prob.", valid: false)
                            sclRow(value: 9, name: "Cloud High Prob.", valid: false)
                            sclRow(value: 10, name: "Thin Cirrus", valid: false)
                            sclRow(value: 11, name: "Snow / Ice", valid: false)
                        }
                    }
                }

                Section("Additional Masking") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Beyond SCL, additional filters are applied:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        bulletPoint("Polygon containment: only pixels inside the GeoJSON boundary")
                        bulletPoint("DN checks: DN=0 (nodata) and DN=65535 (saturated) excluded")
                        bulletPoint("Reflectance: negative values after conversion excluded")
                        bulletPoint("NDVI stats: only pixels with NDVI \u{2265} 0 contribute to mean/median")
                        bulletPoint("Scene-level: scenes exceeding cloud threshold are skipped entirely")
                        bulletPoint("Empty frames: dates with zero valid pixels are dropped")
                    }
                }

                Section("Data Version") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Collection", value: "sentinel-2-l2a")
                        LabeledContent("Processing", value: "Baseline \u{2265} 04.00")
                        LabeledContent("Level", value: "L2A (BOA reflectance)")
                        LabeledContent("SCL Version", value: "Sen2Cor")
                        Text("SCL is generated by the Sen2Cor atmospheric correction processor as part of the L2A product. Classification uses spectral rules and thresholds applied to TOA reflectance and auxiliary data (DEM, meteorological).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Source: AWS Earth Search (Element 84), Collection sentinel-2-l2a, STAC API v1.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sentinel-2 Bands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: - Spectral Plot

    private var spectralPlot: some View {
        // Generate Gaussian SRF curves for each band
        let wavelengths = stride(from: 400.0, through: 2400.0, by: 5.0).map { $0 }

        struct SRFPoint: Identifiable {
            let id = UUID()
            let band: String
            let wavelength: Double
            let response: Double
            let color: Color
        }

        var points = [SRFPoint]()
        for band in Self.bandData {
            let sigma = band.fwhm / 2.355  // FWHM to sigma
            for wl in wavelengths {
                let r = exp(-0.5 * pow((wl - band.center) / sigma, 2))
                if r > 0.01 {
                    points.append(SRFPoint(band: band.name, wavelength: wl, response: r, color: band.color))
                }
            }
        }

        return Chart(points) { pt in
            AreaMark(
                x: .value("Wavelength", pt.wavelength),
                y: .value("Response", pt.response),
                series: .value("Band", pt.band)
            )
            .foregroundStyle(by: .value("Band", pt.band))
            .opacity(0.3)

            LineMark(
                x: .value("Wavelength", pt.wavelength),
                y: .value("Response", pt.response),
                series: .value("Band", pt.band)
            )
            .foregroundStyle(by: .value("Band", pt.band))
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartForegroundStyleScale(domain: Self.bandData.map { $0.name },
                                   range: Self.bandData.map { $0.color })
        .chartXAxis {
            AxisMarks(values: [400, 600, 800, 1000, 1200, 1600, 2000, 2400]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1.0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.1f", v))
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .chartXScale(domain: 400...2400)
        .chartYScale(domain: 0...1.1)
        .frame(height: 160)
        .overlay(alignment: .bottom) {
            Text("Wavelength (nm)")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .offset(y: -2)
        }
    }

    // MARK: - Helpers

    private func sclRow(value: Int, name: String, valid: Bool) -> some View {
        HStack(spacing: 6) {
            let (r, g, b) = NDVIMapView.sclColor(UInt16(value))
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            Text("\(value)")
                .font(.caption.monospacedDigit().bold())
                .frame(width: 18, alignment: .trailing)
            Text(name)
                .font(.caption)
            Spacer()
            Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(valid ? .green : .red)
                .font(.caption)
        }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("eof")
                            .font(.title.bold())
                        Text("Earth Observation Fetch")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Sentinel-2 NDVI time series viewer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Data Sources") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sentinel-2 Level-2A")
                            .font(.subheadline.bold())
                        Text("Surface reflectance (BOA) imagery from the Copernicus Sentinel-2 mission, accessed via Cloud Optimized GeoTIFF (COG) on AWS Open Data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("AWS Earth Search STAC API")
                            .font(.subheadline.bold())
                        Text("SpatioTemporal Asset Catalog provided by Element 84. No authentication required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Section("Copyright & License") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Copernicus Sentinel Data")
                            .font(.subheadline.bold())
                        Text("Contains modified Copernicus Sentinel data \(Calendar.current.component(.year, from: Date())). Sentinel data is provided free of charge under the Copernicus data policy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("European Space Agency (ESA)")
                            .font(.subheadline.bold())
                        Text("The Copernicus Sentinel-2 mission is operated by ESA on behalf of the European Commission. Data is made available under the terms of the Copernicus Open Access Data Policy (Commission Delegated Regulation (EU) No 1159/2013).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("AWS Open Data")
                            .font(.subheadline.bold())
                        Text("Sentinel-2 data on AWS is provided as part of the AWS Open Data Sponsorship Program.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Section("SCL Color Scheme") {
                    Text("Scene Classification Layer colors follow the standard Sentinel Hub visualization (custom-scripts.sentinel-hub.com).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Related Apps") {
                    Link(destination: URL(string: "https://apps.apple.com/app/copernicus-satellite/id1548498915")!) {
                        HStack {
                            Image(systemName: "satellite.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Copernicus Satellite")
                                    .font(.subheadline)
                                Text("ESA's official Copernicus programme app")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Technical Details") {
                    LabeledContent("Collection", value: "sentinel-2-l2a")
                    LabeledContent("API", value: "earth-search.aws.element84.com")
                    LabeledContent("Format", value: "Cloud Optimized GeoTIFF")
                    LabeledContent("Resolution", value: "10m (visible/NIR)")
                    LabeledContent("SCL Resolution", value: "20m (upsampled)")
                    LabeledContent("Auth Required", value: "None")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }
}

// MARK: - SCL Mask View

struct SCLMaskView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Toggle which Scene Classification Layer (SCL) classes are treated as valid pixels. Invalid pixels are masked (set to NaN) and excluded from NDVI statistics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Typically Valid") {
                    sclToggle(4, "Vegetation")
                    sclToggle(5, "Not Vegetated")
                    sclToggle(6, "Water")
                    sclToggle(7, "Unclassified")
                }

                Section("Typically Masked") {
                    sclToggle(0, "No Data")
                    sclToggle(1, "Saturated / Defective")
                    sclToggle(2, "Dark Area Pixels")
                    sclToggle(3, "Cloud Shadows")
                    sclToggle(8, "Cloud Medium Prob.")
                    sclToggle(9, "Cloud High Prob.")
                    sclToggle(10, "Thin Cirrus")
                    sclToggle(11, "Snow / Ice")
                }

                Section {
                    HStack {
                        Button("Select All") {
                            settings.sclValidClasses = Set(0...11)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Default") {
                            settings.sclValidClasses = [4, 5]
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Clear All") {
                            settings.sclValidClasses = []
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
            .navigationTitle("SCL Mask Classes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func sclToggle(_ value: Int, _ name: String) -> some View {
        Toggle(isOn: Binding(
            get: { settings.sclValidClasses.contains(value) },
            set: { on in
                if on { settings.sclValidClasses.insert(value) }
                else { settings.sclValidClasses.remove(value) }
            }
        )) {
            HStack(spacing: 8) {
                let (r, g, b) = NDVIMapView.sclColor(UInt16(value))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
                    .frame(width: 20, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
                Text("\(value)")
                    .font(.subheadline.monospacedDigit().bold())
                    .frame(width: 24, alignment: .trailing)
                Text(name)
                    .font(.subheadline)
            }
        }
    }
}
