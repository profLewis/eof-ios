import Foundation

/// Manages per-collection SAS token acquisition and caching for Microsoft Planetary Computer.
/// Tokens are persisted to UserDefaults so they survive app restarts (valid ~1 hour).
/// Each Azure collection requires its own SAS token.
actor SASTokenManager {
    private static let baseURL = "https://planetarycomputer.microsoft.com/api/sas/v1/token/"
    private static let defaults = UserDefaults.standard
    private static let prefix = "eof_sas_"

    /// In-memory cache keyed by collection ID.
    private var cache: [String: SASToken] = [:]

    struct SASToken: Codable {
        let token: String
        let expiry: Date
        let collection: String

        var isValid: Bool { Date() < expiry.addingTimeInterval(-120) } // 2 min buffer
    }

    init() {
        // Load persisted tokens into memory
        loadPersistedTokens()
    }

    /// Get a valid SAS token for a collection, fetching/refreshing as needed.
    func getToken(for collection: String = "sentinel-2-l2a") async throws -> String {
        if let cached = cache[collection], cached.isValid {
            return cached.token
        }

        let token = try await fetchToken(for: collection)
        cache[collection] = token
        persistToken(token)
        return token.token
    }

    /// Sign an asset URL by appending SAS query parameters for the given collection.
    /// The token is already percent-encoded from the API, so we use
    /// percentEncodedQuery to avoid double-encoding (which causes 403).
    func signURL(_ url: URL, collection: String = "sentinel-2-l2a") async throws -> URL {
        let tokenStr = try await getToken(for: collection)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        let existing = components.percentEncodedQuery ?? ""
        components.percentEncodedQuery = existing.isEmpty ? tokenStr : "\(existing)&\(tokenStr)"
        return components.url ?? url
    }

    /// Invalidate cached token for a collection.
    func invalidate(collection: String = "sentinel-2-l2a") {
        cache.removeValue(forKey: collection)
        Self.defaults.removeObject(forKey: Self.prefix + collection)
    }

    /// Fetch all currently cached tokens (for UI display).
    func cachedTokens() -> [SASToken] {
        Array(cache.values).sorted { $0.collection < $1.collection }
    }

    // MARK: - Network

    private func fetchToken(for collection: String) async throws -> SASToken {
        guard let url = URL(string: Self.baseURL + collection) else {
            throw NSError(domain: "SASToken", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid collection ID: \(collection)"])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        if let apiKey = KeychainService.retrieve(key: "planetary.apikey"),
           !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "SASToken", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "SAS token for \(collection): HTTP \(http.statusCode)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenStr = json["token"] as? String,
              let expiryStr = json["msft:expiry"] as? String else {
            throw NSError(domain: "SASToken", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid SAS token response for \(collection)"])
        }

        let fmt = ISO8601DateFormatter()
        let expiry = fmt.date(from: expiryStr) ?? Date().addingTimeInterval(3600)

        return SASToken(token: tokenStr, expiry: expiry, collection: collection)
    }

    // MARK: - Persistence

    private func persistToken(_ token: SASToken) {
        if let data = try? JSONEncoder().encode(token) {
            Self.defaults.set(data, forKey: Self.prefix + token.collection)
        }
        // Also maintain a list of known collection IDs
        var known = Self.defaults.stringArray(forKey: Self.prefix + "collections") ?? []
        if !known.contains(token.collection) {
            known.append(token.collection)
            Self.defaults.set(known, forKey: Self.prefix + "collections")
        }
    }

    private func loadPersistedTokens() {
        let known = Self.defaults.stringArray(forKey: Self.prefix + "collections") ?? []
        for collection in known {
            if let data = Self.defaults.data(forKey: Self.prefix + collection),
               let token = try? JSONDecoder().decode(SASToken.self, from: data),
               token.isValid {
                cache[collection] = token
            }
        }
    }
}
