import Foundation

/// Manages SAS token acquisition and refresh for Microsoft Planetary Computer.
actor SASTokenManager {
    private static let tokenURL = URL(string:
        "https://planetarycomputer.microsoft.com/api/sas/v1/token/sentinel-2-l2a")!

    private var cachedToken: SASToken?

    struct SASToken {
        let token: String       // query string: "se=...&sig=...&sp=..."
        let expiry: Date

        var isValid: Bool { Date() < expiry.addingTimeInterval(-120) } // 2 min buffer
    }

    /// Get a valid SAS token, fetching/refreshing as needed.
    func getToken() async throws -> String {
        if let cached = cachedToken, cached.isValid {
            return cached.token
        }

        var request = URLRequest(url: Self.tokenURL)
        request.timeoutInterval = 15

        // Add optional API key
        if let apiKey = KeychainService.retrieve(key: "planetary.apikey"),
           !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "SASToken", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "SAS token fetch failed: HTTP \(http.statusCode)"])
        }

        // Parse {"msft:expiry": "2025-03-12T20:47:34Z", "token": "se=...&sig=..."}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenStr = json["token"] as? String,
              let expiryStr = json["msft:expiry"] as? String else {
            throw NSError(domain: "SASToken", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid SAS token response"])
        }

        let fmt = ISO8601DateFormatter()
        let expiry = fmt.date(from: expiryStr) ?? Date().addingTimeInterval(3600)

        cachedToken = SASToken(token: tokenStr, expiry: expiry)
        return tokenStr
    }

    /// Sign an asset URL by appending SAS query parameters.
    /// The token is already percent-encoded from the API, so we use
    /// percentEncodedQuery to avoid double-encoding (which causes 403).
    func signURL(_ url: URL) async throws -> URL {
        let token = try await getToken()
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        let existing = components.percentEncodedQuery ?? ""
        components.percentEncodedQuery = existing.isEmpty ? token : "\(existing)&\(token)"
        return components.url ?? url
    }

    /// Invalidate cached token (e.g., on 403 error).
    func invalidate() {
        cachedToken = nil
    }
}
