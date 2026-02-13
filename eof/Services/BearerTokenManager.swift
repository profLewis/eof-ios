import Foundation

/// Manages bearer token acquisition and caching for CDSE and NASA Earthdata.
actor BearerTokenManager {
    let sourceID: SourceID

    private var cachedToken: CachedToken?

    struct CachedToken {
        let token: String
        let expiry: Date
        var isValid: Bool { Date() < expiry.addingTimeInterval(-60) }
    }

    init(sourceID: SourceID) {
        self.sourceID = sourceID
    }

    /// Get a valid bearer token, fetching/refreshing as needed.
    func getToken() async throws -> String {
        if let cached = cachedToken, cached.isValid {
            return cached.token
        }

        switch sourceID {
        case .cdse:
            return try await fetchCDSEToken()
        case .earthdata:
            return try await fetchEarthdataToken()
        default:
            throw BearerTokenError.unsupportedSource(sourceID.rawValue)
        }
    }

    /// Build auth headers dict for use with COGReader.
    func authHeaders() async throws -> [String: String] {
        let token = try await getToken()
        return ["Authorization": "Bearer \(token)"]
    }

    func invalidate() {
        cachedToken = nil
    }

    // MARK: - CDSE OAuth2

    private func fetchCDSEToken() async throws -> String {
        guard let username = KeychainService.retrieve(key: "cdse.username"),
              let password = KeychainService.retrieve(key: "cdse.password"),
              !username.isEmpty, !password.isEmpty else {
            throw BearerTokenError.missingCredentials("CDSE")
        }

        let url = URL(string: "https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let bodyStr = "grant_type=password&username=\(urlEncode(username))&password=\(urlEncode(password))&client_id=cdse-public"
        request.httpBody = Data(bodyStr.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BearerTokenError.authFailed("CDSE", code)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw BearerTokenError.invalidResponse("CDSE")
        }

        cachedToken = CachedToken(token: token, expiry: Date().addingTimeInterval(Double(expiresIn)))
        return token
    }

    // MARK: - NASA Earthdata

    private func fetchEarthdataToken() async throws -> String {
        guard let username = KeychainService.retrieve(key: "earthdata.username"),
              let password = KeychainService.retrieve(key: "earthdata.password"),
              !username.isEmpty, !password.isEmpty else {
            throw BearerTokenError.missingCredentials("Earthdata")
        }

        // Earthdata token endpoint
        let url = URL(string: "https://urs.earthdata.nasa.gov/api/users/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        let credentials = "\(username):\(password)"
        let base64 = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BearerTokenError.authFailed("Earthdata", code)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            // Earthdata may return token directly as string in some endpoints
            if let tokenStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tokenStr.isEmpty, tokenStr.count < 500 {
                cachedToken = CachedToken(token: tokenStr, expiry: Date().addingTimeInterval(86400))
                return tokenStr
            }
            throw BearerTokenError.invalidResponse("Earthdata")
        }

        // Earthdata tokens typically last 90 days; cache for 24h
        cachedToken = CachedToken(token: token, expiry: Date().addingTimeInterval(86400))
        return token
    }

    private func urlEncode(_ str: String) -> String {
        str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }
}

enum BearerTokenError: Error, LocalizedError {
    case unsupportedSource(String)
    case missingCredentials(String)
    case authFailed(String, Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let s): return "Bearer token not supported for \(s)"
        case .missingCredentials(let s): return "\(s) credentials not configured — add them in Data Sources settings"
        case .authFailed(let s, let code): return "\(s) authentication failed (HTTP \(code))"
        case .invalidResponse(let s): return "Invalid \(s) token response"
        }
    }
}
