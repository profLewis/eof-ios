import Foundation

/// Identifies a STAC data source.
enum SourceID: String, CaseIterable, Codable, Identifiable {
    case aws = "aws"
    case planetary = "planetary"
    // case cdse = "cdse"       // future: JP2K format, not COG

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .aws: return "cloud"
        case .planetary: return "globe.americas"
        }
    }
}

/// Maps logical band names to source-specific STAC asset keys.
struct BandMapping: Codable, Equatable {
    let red: String
    let nir: String
    let green: String
    let blue: String
    let scl: String
    let projTransformKey: String
}

/// Authentication type for COG asset access.
enum AssetAuthType: String, Codable {
    case none
    case sasToken       // Microsoft Planetary Computer
    case oauth2         // CDSE (future)
}

/// Complete configuration for a single STAC source.
struct STACSourceConfig: Codable, Identifiable, Equatable {
    let sourceID: SourceID
    var isEnabled: Bool
    var displayName: String
    var shortName: String
    var searchURL: String
    var collection: String
    var assetAuthType: AssetAuthType
    var bandMapping: BandMapping

    var id: String { sourceID.rawValue }

    // MARK: - Default Configurations

    static func awsDefault() -> STACSourceConfig {
        STACSourceConfig(
            sourceID: .aws,
            isEnabled: true,
            displayName: "AWS Earth Search",
            shortName: "AWS",
            searchURL: "https://earth-search.aws.element84.com/v1/search",
            collection: "sentinel-2-l2a",
            assetAuthType: .none,
            bandMapping: BandMapping(
                red: "red", nir: "nir", green: "green",
                blue: "blue", scl: "scl",
                projTransformKey: "red"
            )
        )
    }

    static func planetaryDefault() -> STACSourceConfig {
        STACSourceConfig(
            sourceID: .planetary,
            isEnabled: true,
            displayName: "Planetary Computer",
            shortName: "PC",
            searchURL: "https://planetarycomputer.microsoft.com/api/stac/v1/search",
            collection: "sentinel-2-l2a",
            assetAuthType: .sasToken,
            bandMapping: BandMapping(
                red: "B04", nir: "B08", green: "B03",
                blue: "B02", scl: "SCL",
                projTransformKey: "B04"
            )
        )
    }
}
