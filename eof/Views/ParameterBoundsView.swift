import SwiftUI

/// Settings panel for DL phenology parameter physical constraints.
struct ParameterBoundsView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared
    @State private var cropCalendarStatus = ""
    @State private var isFetchingCalendar = false
    @State private var availableCountries: [CropCalendarService.CountryEntry] = []
    @State private var countryCrops: [CropCalendarService.CropEntry] = []
    @State private var detectedCountry = ""
    @State private var selectedCropID = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Physical constraints on DL model parameters. These bound the optimizer during fitting. Separate from perturbation settings which control pixel-level variation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Baseline NDVI (mn)") {
                    boundRow(label: "Min", value: $settings.boundMnMin, range: -1.0...0.5, step: 0.05, fmt: "%.2f")
                    boundRow(label: "Max", value: $settings.boundMnMax, range: 0.0...1.0, step: 0.05, fmt: "%.2f")
                }

                Section("Amplitude (mx \u{2212} mn)") {
                    boundRow(label: "Min", value: $settings.boundDeltaMin, range: 0.01...0.5, step: 0.01, fmt: "%.2f")
                    boundRow(label: "Max", value: $settings.boundDeltaMax, range: 0.5...2.0, step: 0.05, fmt: "%.2f")
                }

                Section("Start of Season (SOS, DOY)") {
                    boundRow(label: "Min", value: $settings.boundSosMin, range: 1...365, step: 1, fmt: "%.0f")
                    boundRow(label: "Max", value: $settings.boundSosMax, range: 1...365, step: 1, fmt: "%.0f")
                }

                Section("Green-up Rate (rsp)") {
                    boundRow(label: "Min", value: $settings.boundRspMin, range: 0.005...0.3, step: 0.005, fmt: "%.3f")
                    boundRow(label: "Max", value: $settings.boundRspMax, range: 0.1...1.0, step: 0.05, fmt: "%.2f")
                }

                Section("Senescence Rate (rau)") {
                    boundRow(label: "Min", value: $settings.boundRauMin, range: 0.005...0.3, step: 0.005, fmt: "%.3f")
                    boundRow(label: "Max", value: $settings.boundRauMax, range: 0.1...1.0, step: 0.05, fmt: "%.2f")
                }

                Section {
                    Button("Reset to Defaults") {
                        settings.boundMnMin = -0.5
                        settings.boundMnMax = 0.8
                        settings.boundDeltaMin = 0.05
                        settings.boundDeltaMax = 1.5
                        settings.boundSosMin = 1
                        settings.boundSosMax = 365
                        settings.boundRspMin = 0.02
                        settings.boundRspMax = 0.6
                        settings.boundRauMin = 0.02
                        settings.boundRauMax = 0.6
                    }
                    .foregroundStyle(.red)
                }

                Section("Crop Calendar") {
                    cropCalendarSection
                }
            }
            .navigationTitle("Parameter Bounds")
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

    // MARK: - Bound Row

    @ViewBuilder
    private func boundRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: - Crop Calendar

    @ViewBuilder
    private var cropCalendarSection: some View {
        Text("Populate SOS bounds from FAO Crop Calendar based on AOI location and crop type. Coverage: ~60 developing countries.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if detectedCountry.isEmpty {
            Button("Detect Country from AOI") {
                detectCountry()
            }
        } else {
            LabeledContent("Country", value: detectedCountry)
                .font(.caption)
        }

        if !countryCrops.isEmpty {
            Picker("Crop", selection: $selectedCropID) {
                Text("Select...").tag("")
                ForEach(countryCrops, id: \.crop_id) { crop in
                    Text(crop.crop_name).tag(crop.crop_id)
                }
            }
        } else if !detectedCountry.isEmpty {
            // Show common crops as fallback
            Picker("Crop", selection: $selectedCropID) {
                Text("Select...").tag("")
                ForEach(CropCalendarService.commonCrops) { crop in
                    Text(crop.name).tag(crop.id)
                }
            }
        }

        if !selectedCropID.isEmpty && !detectedCountry.isEmpty {
            Button {
                fetchCalendar()
            } label: {
                HStack {
                    if isFetchingCalendar {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Text("Populate from Crop Calendar")
                }
            }
            .disabled(isFetchingCalendar)
        }

        if !cropCalendarStatus.isEmpty {
            Text(cropCalendarStatus)
                .font(.caption)
                .foregroundStyle(cropCalendarStatus.contains("Error") || cropCalendarStatus.contains("not available") ? .red : .green)
        }

        if !detectedCountry.isEmpty {
            Link(destination: URL(string: "https://cropcalendar.apps.fao.org/#/home?id=\(detectedCountry)")!) {
                HStack(spacing: 4) {
                    Image(systemName: "safari")
                    Text("View FAO Crop Calendar")
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Actions

    private func detectCountry() {
        guard let geo = settings.aoiGeometry else {
            cropCalendarStatus = "No AOI set"
            return
        }
        let centroid = geo.centroid
        Task {
            if let code = await CropCalendarService.countryCode(lat: centroid.lat, lon: centroid.lon) {
                await MainActor.run {
                    detectedCountry = code
                    cropCalendarStatus = "Detected: \(code)"
                }
                // Fetch available crops for this country
                do {
                    let crops = try await CropCalendarService.fetchCrops(country: code)
                    await MainActor.run {
                        countryCrops = crops
                        if crops.isEmpty {
                            cropCalendarStatus = "\(code) not available in FAO database"
                        }
                    }
                } catch {
                    await MainActor.run {
                        cropCalendarStatus = "Error fetching crops: \(error.localizedDescription)"
                    }
                }
            } else {
                await MainActor.run {
                    cropCalendarStatus = "Could not detect country from AOI"
                }
            }
        }
    }

    private func fetchCalendar() {
        guard !detectedCountry.isEmpty, !selectedCropID.isEmpty else { return }
        isFetchingCalendar = true
        cropCalendarStatus = ""

        Task {
            do {
                let entries = try await CropCalendarService.fetchCalendar(
                    country: detectedCountry, cropID: selectedCropID)

                await MainActor.run {
                    isFetchingCalendar = false

                    guard let bounds = CropCalendarService.extractBounds(from: entries) else {
                        cropCalendarStatus = "No sowing/harvest data found"
                        return
                    }

                    // Apply bounds — widen SOS range slightly for safety
                    let sosPadding = 15 // days before/after
                    settings.boundSosMin = Double(max(1, bounds.sosMin - sosPadding))
                    settings.boundSosMax = Double(min(365, bounds.sosMax + sosPadding))

                    // Update season length from harvest data
                    let minLen = max(30, bounds.eosMin - bounds.sosMax)
                    let maxLen = min(350, bounds.eosMax - bounds.sosMin)
                    if minLen > 0 && maxLen > minLen {
                        settings.minSeasonLength = minLen
                        settings.maxSeasonLength = maxLen
                    }

                    let aez = bounds.aezName.map { " (\($0))" } ?? ""
                    cropCalendarStatus = "\(bounds.cropName)\(aez): SOS \(bounds.sosMin)\u{2013}\(bounds.sosMax), harvest \(bounds.eosMin)\u{2013}\(bounds.eosMax) DOY"
                    settings.selectedCrop = bounds.cropName
                }
            } catch {
                await MainActor.run {
                    isFetchingCalendar = false
                    cropCalendarStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
