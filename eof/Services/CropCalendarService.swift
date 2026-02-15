import Foundation
import CoreLocation

/// FAO Crop Calendar API client.
/// API docs: https://api-cropcalendar.apps.fao.org/
enum CropCalendarService {

    static let baseURL = "https://api-cropcalendar.apps.fao.org/api/v1"

    // MARK: - Common crops with FAO IDs

    struct CropOption: Identifiable {
        let id: String   // FAO crop_id e.g. "0373"
        let name: String // Display name
    }

    /// Common crops (subset — full list comes from API per country).
    static let commonCrops: [CropOption] = [
        CropOption(id: "0373", name: "Wheat"),
        CropOption(id: "0113", name: "Maize"),
        CropOption(id: "0303", name: "Rice"),
        CropOption(id: "0327", name: "Soybean"),
        CropOption(id: "0024", name: "Barley"),
        CropOption(id: "0325", name: "Sorghum"),
        CropOption(id: "0362", name: "Cotton"),
        CropOption(id: "0335", name: "Sunflower"),
        CropOption(id: "0283", name: "Potato"),
        CropOption(id: "0334", name: "Sugarcane"),
        CropOption(id: "0087", name: "Chickpea"),
        CropOption(id: "0200", name: "Lentil"),
        CropOption(id: "0262", name: "Groundnut"),
    ]

    // MARK: - API Response Models

    struct CountryEntry: Decodable {
        let id: String
        let name: String
    }

    struct CropEntry: Decodable {
        let crop_name: String
        let crop_id: String
    }

    struct CalendarEntry: Decodable {
        let crop: CropInfo
        let aez: AEZInfo?
        let sessions: [Session]

        struct CropInfo: Decodable {
            let id: String
            let name: String
        }
        struct AEZInfo: Decodable {
            let id: String
            let name: String
        }
        struct Session: Decodable {
            let additional_information: String?
            let early_sowing: DateField?
            let later_sowing: DateField?
            let early_harvest: DateField?
            let late_harvest: DateField?
            let growing_period: GrowingPeriod?
        }
        struct DateField: Decodable {
            let month: String
            let day: String
        }
        struct GrowingPeriod: Decodable {
            let period: String?
            let value: String?
        }
    }

    // MARK: - Fetch Available Countries

    static func fetchCountries() async throws -> [CountryEntry] {
        let url = URL(string: "\(baseURL)/countries?language=en")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([CountryEntry].self, from: data)
    }

    // MARK: - Fetch Crops for Country

    static func fetchCrops(country: String) async throws -> [CropEntry] {
        let url = URL(string: "\(baseURL)/countries/\(country)/crops?language=en")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode == 204 {
            return [] // Country not in FAO database
        }
        return try JSONDecoder().decode([CropEntry].self, from: data)
    }

    // MARK: - Fetch Crop Calendar

    static func fetchCalendar(country: String, cropID: String) async throws -> [CalendarEntry] {
        let url = URL(string: "\(baseURL)/countries/\(country)/cropCalendar?crop=\(cropID)&language=en")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode == 204 {
            return []
        }
        return try JSONDecoder().decode([CalendarEntry].self, from: data)
    }

    // MARK: - Reverse Geocode to Country Code

    static func countryCode(lat: Double, lon: Double) async -> String? {
        let location = CLLocation(latitude: lat, longitude: lon)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first?.isoCountryCode
        } catch {
            return nil
        }
    }

    // MARK: - Extract SOS/EOS Bounds from Calendar

    struct SeasonBounds {
        let sosMin: Int   // earliest sowing DOY
        let sosMax: Int   // latest sowing DOY
        let eosMin: Int   // earliest harvest DOY
        let eosMax: Int   // latest harvest DOY
        let cropName: String
        let aezName: String?
    }

    /// Extract season bounds from calendar entries. Takes the widest range across all AEZs/sessions.
    static func extractBounds(from entries: [CalendarEntry]) -> SeasonBounds? {
        var sosMin = 366
        var sosMax = 0
        var eosMin = 366
        var eosMax = 0
        var cropName = ""
        var aezName: String?

        for entry in entries {
            if cropName.isEmpty { cropName = entry.crop.name }
            if entries.count == 1 { aezName = entry.aez?.name }

            for session in entry.sessions {
                if let es = session.early_sowing, let doy = dayOfYear(month: es.month, day: es.day) {
                    sosMin = min(sosMin, doy)
                }
                if let ls = session.later_sowing, let doy = dayOfYear(month: ls.month, day: ls.day) {
                    sosMax = max(sosMax, doy)
                }
                if let eh = session.early_harvest, let doy = dayOfYear(month: eh.month, day: eh.day) {
                    eosMin = min(eosMin, doy)
                }
                if let lh = session.late_harvest, let doy = dayOfYear(month: lh.month, day: lh.day) {
                    eosMax = max(eosMax, doy)
                }
            }
        }

        guard sosMin < 366 && eosMax > 0 else { return nil }
        // If only early sowing found, use it for both
        if sosMax == 0 { sosMax = sosMin + 30 }
        if eosMin == 366 { eosMin = eosMax - 30 }

        return SeasonBounds(sosMin: sosMin, sosMax: sosMax, eosMin: eosMin, eosMax: eosMax,
                           cropName: cropName, aezName: aezName)
    }

    /// Convert month/day strings to day of year.
    private static func dayOfYear(month: String, day: String) -> Int? {
        guard let m = Int(month), let d = Int(day), m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        var components = DateComponents()
        components.year = 2024  // leap year for safety
        components.month = m
        components.day = d
        guard let date = Calendar.current.date(from: components) else { return nil }
        return Calendar.current.ordinality(of: .day, in: .year, for: date)
    }
}
