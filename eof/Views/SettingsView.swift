import SwiftUI
import Charts

struct SettingsView: View {
    @Binding var isPresented: Bool
    var onCompare: (() -> Void)?
    @State private var settings = AppSettings.shared
    @State private var showingBandInfo = false
    @State private var showingAbout = false
    @State private var showingAOI = false
    @State private var showingDataSources = false
    @State private var showingSCLMask = false
    @State private var showingParameterBounds = false

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

                    Picker("Band", selection: $settings.displayMode) {
                        Text("Red").tag(AppSettings.DisplayMode.bandRed)
                        Text("NIR").tag(AppSettings.DisplayMode.bandNIR)
                        Text("Green").tag(AppSettings.DisplayMode.bandGreen)
                        Text("Blue").tag(AppSettings.DisplayMode.bandBlue)
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
                    Text("Draw outlines around contiguous SCL regions on the map.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("SCL Colors on Masked Pixels", isOn: $settings.showMaskedClassColors)
                    Text("Show SCL class colors for masked pixels instead of leaving them transparent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Satellite Basemap", isOn: $settings.showBasemap)
                    if settings.showBasemap {
                        Text("Apple Maps satellite imagery (date varies by location, typically 1-3 years old)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Playback Speed")
                            .font(.subheadline)
                        Picker("Playback Speed", selection: $settings.playbackSpeed) {
                            Text("0.5x").tag(0.5)
                            Text("1x").tag(1.0)
                            Text("2x").tag(2.0)
                            Text("4x").tag(4.0)
                        }
                        .pickerStyle(.segmented)
                    }
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

                Section("Date Range") {
                    DatePicker("Start", selection: $settings.startDate, displayedComponents: .date)
                    DatePicker("End", selection: $settings.endDate, displayedComponents: .date)
                }

                Section("Vegetation Index") {
                    Picker("Fitting VI", selection: $settings.vegetationIndex) {
                        ForEach(AppSettings.VegetationIndex.allCases, id: \.self) { vi in
                            Text(vi.label).tag(vi)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.vegetationIndex.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("DVI averages linearly across pixel sizes. NDVI is normalized but non-linear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Network") {
                    Toggle("Allow Cellular Downloads", isOn: $settings.allowCellularDownload)
                    Text("When off, shows estimated size and asks for confirmation on cellular data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Spectral Unmixing") {
                    Toggle("Enable Spectral Unmixing", isOn: $settings.enableSpectralUnmixing)
                    Text("Linear mixture model: refl = a\u{00D7}GV + b\u{00D7}NPV + c\u{00D7}Soil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.enableSpectralUnmixing {
                        Toggle("Show Fraction Time Series", isOn: $settings.showFractionTimeSeries)
                        Picker("DL Fit Target", selection: $settings.dlFitTarget) {
                            ForEach(AppSettings.DLFitTarget.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("Fit double logistic to VI values or green vegetation fraction (fveg).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Filters") {
                    Toggle("Enforce AOI Polygon", isOn: $settings.enforceAOI)
                    if settings.enforceAOI {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Pixel Coverage")
                                Spacer()
                                Text("\(Int(settings.pixelCoverageThreshold * 100))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.pixelCoverageThreshold, in: 0.01...0.50, step: 0.01)
                        }
                        Text("Minimum fraction of a pixel that must overlap the AOI polygon to be included. Uses Sutherland-Hodgman clipping.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("When off, all pixels in the image chip are processed regardless of AOI boundary.")
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
                        Text("Pixels with invalid SCL classes are masked (set to NaN).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Text("Scenes exceeding this cloud fraction are skipped entirely during search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Fitting — Optimization") {
                    Stepper("Ensemble Runs: \(settings.pixelEnsembleRuns)",
                            value: $settings.pixelEnsembleRuns, in: 1...20)
                    Text("Number of random restarts per pixel. More runs find better fits but take longer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                    Text("How much to jitter starting parameters between ensemble runs. Higher = wider search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Slope Perturbation")
                            Spacer()
                            Text("\(Int(settings.pixelSlopePerturbation * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.pixelSlopePerturbation, in: 0.05...0.50, step: 0.05)
                    }
                    Text("Separate jitter range for green-up/senescence slope (rsp/rau). Slopes are sensitive — keep lower than general perturbation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Fitting — Second Pass") {
                    Toggle("Second Pass (DL-weighted)", isOn: $settings.enableSecondPass)
                    Text("Re-fit using weights derived from the first-pass DL curve. Observations near peak season get higher weight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.enableSecondPass {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Weight Min")
                                Spacer()
                                Text(String(format: "%.1f", settings.secondPassWeightMin))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.secondPassWeightMin, in: 0.1...2.0, step: 0.1)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Weight Max")
                                Spacer()
                                Text(String(format: "%.1f", settings.secondPassWeightMax))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.secondPassWeightMax, in: 1.0...5.0, step: 0.1)
                        }
                        Text("DL curve values are rescaled to [min, max] as observation weights. Higher max emphasizes peak-season data more strongly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Fitting — Quality Control") {
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
                    Text("Fits with RMSE above this are marked 'poor'. Lower = stricter quality requirement.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper("Min Observations: \(settings.pixelMinObservations)",
                            value: $settings.pixelMinObservations, in: 3...10)
                    Text("Pixels with fewer valid observations are skipped (use median fit instead).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Cluster Filter")
                            Spacer()
                            Text(String(format: "%.1f MADs", settings.clusterFilterThreshold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.clusterFilterThreshold, in: 2.0...8.0, step: 0.5)
                    }
                    Text("Outlier detection: pixels whose parameters are more than N median absolute deviations from the median are flagged. Lower = stricter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Fitting — Season Constraints") {
                    Stepper("Min Season: \(settings.minSeasonLength) days",
                            value: $settings.minSeasonLength, in: 10...200, step: 10)
                    Stepper("Max Season: \(settings.maxSeasonLength) days",
                            value: $settings.maxSeasonLength, in: 100...365, step: 10)
                    Text("Constrains the growing season duration (SOS to EOS). Prevents unrealistically short or long seasons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper("Slope Symmetry: \(settings.slopeSymmetry)%",
                            value: $settings.slopeSymmetry, in: 0...100, step: 5)
                    Text("Constrains senescence rate (rau) to be within N% of green-up rate (rsp). 0% = unconstrained, 100% = symmetric.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Pixel Inspector") {
                    Stepper("Window: \(settings.pixelInspectWindow)\u{00D7}\(settings.pixelInspectWindow)",
                            value: $settings.pixelInspectWindow, in: 1...9, step: 2)
                    Text("Size of the pixel neighbourhood shown when tapping the map. 1\u{00D7}1 = single pixel, 3\u{00D7}3 = 9 pixels, etc.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showingParameterBounds = true
                    } label: {
                        HStack {
                            Label("Parameter Bounds", systemImage: "ruler")
                            Spacer()
                            Text("Physical constraints")
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
                DataSourcesView(isPresented: $showingDataSources, onCompare: {
                    showingDataSources = false
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onCompare?()
                    }
                })
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingParameterBounds) {
                ParameterBoundsView(isPresented: $showingParameterBounds)
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
                case .bandRed:
                    Text("B04 (Red, 665nm)")
                case .bandNIR:
                    Text("B08 (NIR, 842nm)")
                case .bandGreen:
                    Text("B03 (Green, 560nm)")
                case .bandBlue:
                    Text("B02 (Blue, 490nm)")
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
        case .bandRed:
            "Red band (B04, 665nm). Greyscale reflectance."
        case .bandNIR:
            "NIR band (B08, 842nm). Greyscale reflectance. Bright = high vegetation/soil reflectance."
        case .bandGreen:
            "Green band (B03, 560nm). Greyscale reflectance."
        case .bandBlue:
            "Blue band (B02, 490nm). Greyscale reflectance."
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
            .foregroundStyle(pt.color.opacity(0.3))

            LineMark(
                x: .value("Wavelength", pt.wavelength),
                y: .value("Response", pt.response),
                series: .value("Band", pt.band)
            )
            .foregroundStyle(pt.color)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
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
        .chartYScale(domain: 0...1.0)
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

                Section("Author") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Philip Lewis, UCL")
                            .font(.subheadline.bold())
                        Text("Assisted by Claude (Anthropic)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Data Sources") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sentinel-2 Level-2A")
                            .font(.subheadline.bold())
                        Text("Surface reflectance (BOA) from Copernicus Sentinel-2A/2B MSI. 13 spectral bands, 10\u{2013}60m resolution, 5-day revisit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AWS Earth Search")
                            .font(.caption.bold())
                        Text("STAC API by Element 84. COG format, no auth. DN/10000 = reflectance (no offset).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Microsoft Planetary Computer")
                            .font(.caption.bold())
                        Text("STAC API + SAS token auth. PB\u{2265}04.00: reflectance = (DN\u{2212}1000)/10000.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Copernicus Data Space (CDSE)")
                            .font(.caption.bold())
                        Text("ESA official archive. Bearer token auth. PB\u{2265}04.00: reflectance = (DN\u{2212}1000)/10000.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NASA Earthdata (HLS)")
                            .font(.caption.bold())
                        Text("Harmonized Landsat Sentinel-2. Bearer token auth. DN/10000 = reflectance.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Google Earth Engine")
                            .font(.caption.bold())
                        Text("Pixel-level REST API. OAuth2 auth. Requires GCP project. DN/10000 = reflectance.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FAO Crop Calendar")
                            .font(.caption.bold())
                        Text("api-cropcalendar.apps.fao.org. Sowing/harvest dates by country and crop. ~60 countries.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                    LabeledContent("Format", value: "Cloud Optimized GeoTIFF")
                    LabeledContent("Resolution", value: "10m (B02\u{2013}B04, B08)")
                    LabeledContent("SCL Resolution", value: "20m (upsampled to 10m)")
                    LabeledContent("Processing", value: "L2A (Sen2Cor BOA)")
                    LabeledContent("Phenology Model", value: "Beck double logistic")
                    LabeledContent("Optimizer", value: "Nelder-Mead + Huber loss")
                    LabeledContent("Fitting", value: "Ensemble + per-pixel")
                    LabeledContent("Outlier Detection", value: "MAD-based cluster filter")
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
