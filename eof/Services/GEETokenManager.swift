import Foundation

/// Manages Google Earth Engine OAuth2 tokens with automatic refresh.
actor GEETokenManager {
    private var cachedToken: CachedToken?

    struct CachedToken {
        let accessToken: String
        let expiry: Date
        var isValid: Bool { Date() < expiry.addingTimeInterval(-60) }
    }

    /// Get a valid access token, refreshing from stored refresh_token if expired.
    func getToken() async throws -> String {
        if let cached = cachedToken, cached.isValid {
            return cached.accessToken
        }
        return try await refreshAccessToken()
    }

    /// Build auth headers dict for use with GEE REST API.
    func authHeaders() async throws -> [String: String] {
        let token = try await getToken()
        return ["Authorization": "Bearer \(token)"]
    }

    /// Store tokens after initial OAuth flow (called from DataSourcesView).
    func storeTokens(accessToken: String, refreshToken: String, expiresIn: Int) {
        cachedToken = CachedToken(
            accessToken: accessToken,
            expiry: Date().addingTimeInterval(Double(expiresIn))
        )
        try? KeychainService.store(key: "gee.refresh_token", value: refreshToken)
    }

    /// Whether a refresh token is stored in Keychain.
    nonisolated var hasRefreshToken: Bool {
        KeychainService.retrieve(key: "gee.refresh_token") != nil
    }

    /// Invalidate cached token (force re-auth).
    func invalidate() {
        cachedToken = nil
    }

    /// Clear all stored GEE tokens (sign out).
    func signOut() {
        cachedToken = nil
        KeychainService.delete(key: "gee.refresh_token")
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = KeychainService.retrieve(key: "gee.refresh_token"),
              !refreshToken.isEmpty else {
            throw GEETokenError.noRefreshToken
        }
        guard let clientID = KeychainService.retrieve(key: "gee.clientid"),
              !clientID.isEmpty else {
            throw GEETokenError.missingClientID
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body = "client_id=\(urlEncode(clientID))&refresh_token=\(urlEncode(refreshToken))&grant_type=refresh_token"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 400 || code == 401 {
                // Refresh token revoked or expired — user must re-authenticate
                throw GEETokenError.refreshTokenRevoked
            }
            throw GEETokenError.authFailed(code)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw GEETokenError.invalidResponse
        }

        let expiresIn = json["expires_in"] as? Int ?? 3600
        cachedToken = CachedToken(
            accessToken: accessToken,
            expiry: Date().addingTimeInterval(Double(expiresIn))
        )

        // If a new refresh token is issued, store it
        if let newRefresh = json["refresh_token"] as? String {
            try? KeychainService.store(key: "gee.refresh_token", value: newRefresh)
        }

        return accessToken
    }

    private func urlEncode(_ str: String) -> String {
        str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }
}

enum GEETokenError: Error, LocalizedError {
    case noRefreshToken
    case missingClientID
    case refreshTokenRevoked
    case authFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noRefreshToken:
            return "GEE not authenticated — sign in via Data Sources settings"
        case .missingClientID:
            return "GEE OAuth Client ID not configured — add it in Data Sources settings"
        case .refreshTokenRevoked:
            return "GEE authentication expired — sign in again via Data Sources settings"
        case .authFailed(let code):
            return "GEE token refresh failed (HTTP \(code))"
        case .invalidResponse:
            return "Invalid GEE token response"
        }
    }
}
