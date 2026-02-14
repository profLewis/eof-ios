import Foundation
import CryptoKit

/// Signs HTTP requests using AWS Signature Version 4 for S3-compatible endpoints.
struct SigV4Signer {
    let accessKey: String
    let secretKey: String
    let region: String
    let service: String

    /// Sign a URLRequest in-place by adding Authorization, x-amz-date, and x-amz-content-sha256 headers.
    func sign(_ request: inout URLRequest) {
        guard let url = request.url, let host = url.host else { return }

        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : Self.uriEncodePath(url.path)
        let query = Self.canonicalQueryString(from: url)
        let payloadHash = "UNSIGNED-PAYLOAD"

        // Set required headers
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Build canonical headers (sorted by lowercase name)
        let signedHeaderNames = ["host", "x-amz-content-sha256", "x-amz-date"]
        let canonicalHeaders = """
            host:\(host)
            x-amz-content-sha256:\(payloadHash)
            x-amz-date:\(amzDate)

            """
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n") + "\n"

        let signedHeaders = signedHeaderNames.joined(separator: ";")

        // Canonical request
        let canonicalRequest = [method, path, query, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")

        // String to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(Self.sha256Hex(canonicalRequest))"

        // Signing key
        let kDate = Self.hmac(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = Self.hmac(key: kDate, data: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, data: Data("aws4_request".utf8))

        let signature = Self.hmacHex(key: kSigning, data: Data(stringToSign.utf8))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Date Formatters

    private static let amzDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private static let dateStampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    // MARK: - Crypto Helpers

    private static func hmac(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    private static func hmacHex(key: Data, data: Data) -> String {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ string: String) -> String {
        let hash = SHA256.hash(data: Data(string.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URI Encoding

    /// URI-encode each path segment individually (per SigV4 spec).
    private static func uriEncodePath(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.map { segment in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            return String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
        }.joined(separator: "/")
    }

    /// Sort query parameters alphabetically for canonical query string.
    private static func canonicalQueryString(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return "" }
        return items
            .sorted { $0.name < $1.name }
            .map { "\(uriEncode($0.name))=\(uriEncode($0.value ?? ""))" }
            .joined(separator: "&")
    }

    private static func uriEncode(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
