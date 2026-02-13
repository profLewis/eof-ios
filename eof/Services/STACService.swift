import Foundation

/// Client for STAC API search — supports multiple data sources.
struct STACService {
    let config: STACSourceConfig

    init(config: STACSourceConfig = .awsDefault()) {
        self.config = config
    }

    var searchURL: URL { URL(string: config.searchURL)! }
    var collection: String { config.collection }

    /// Search for Sentinel-2 items overlapping a geometry within a date range.
    func search(
        geometry: GeoJSONGeometry,
        startDate: String,
        endDate: String,
        maxCloudCover: Double = 80
    ) async throws -> [STACItem] {
        let body: [String: Any] = [
            "collections": [collection],
            "intersects": geometry.asDict,
            "datetime": "\(startDate)T00:00:00Z/\(endDate)T23:59:59Z",
            "query": [
                "eo:cloud_cover": ["lt": maxCloudCover]
            ],
            "limit": 100
        ]

        var allItems = [STACItem]()
        var nextURL: URL? = searchURL
        var isFirst = true

        while let url = nextURL {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30

            // Add optional API key header for Planetary Computer
            if config.sourceID == .planetary,
               let apiKey = KeychainService.retrieve(key: "planetary.apikey"),
               !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            }

            let data: Data
            let response: URLResponse

            if isFirst {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                (data, response) = try await URLSession.shared.data(for: request)
                isFirst = false
            } else {
                // Pagination — follow next link with GET
                (data, response) = try await URLSession.shared.data(for: request)
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw STACError.httpError(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let searchResponse = try decoder.decode(STACSearchResponse.self, from: data)
            allItems.append(contentsOf: searchResponse.features)

            // Check for pagination — stop if all results returned
            nextURL = nil
            if let ctx = searchResponse.context,
               let matched = ctx.matched, let returned = ctx.returned,
               returned >= matched {
                // All results already fetched
            } else if let links = searchResponse.links,
                      let next = links.first(where: { $0.rel == "next" }),
                      let nextLink = URL(string: next.href),
                      nextLink != url {
                nextURL = nextLink
            }
        }

        // Filter to single MGRS tile (most common one)
        let filtered = filterToSingleTile(items: allItems)

        // Sort by date
        return filtered.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// Pick the MGRS tile that appears most frequently and filter to just those items.
    private func filterToSingleTile(items: [STACItem]) -> [STACItem] {
        var tileCounts = [String: Int]()
        for item in items {
            if let tile = item.mgrsTile {
                tileCounts[tile, default: 0] += 1
            }
        }

        guard let bestTile = tileCounts.max(by: { $0.value < $1.value })?.key else {
            return items
        }

        return items.filter { $0.mgrsTile == bestTile }
    }
}

enum STACError: Error, LocalizedError {
    case httpError(Int)
    case noItems
    case missingAsset(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "STAC API HTTP error \(code)"
        case .noItems: return "No Sentinel-2 items found"
        case .missingAsset(let name): return "Missing asset: \(name)"
        }
    }
}
