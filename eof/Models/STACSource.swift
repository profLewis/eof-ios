import Foundation

/// Identifies a data source.
enum SourceID: String, CaseIterable, Codable, Identifiable {
    case aws = "aws"
    case planetary = "planetary"
    case cdse = "cdse"
    case earthdata = "earthdata"
    case gee = "gee"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .aws: return "cloud"
        case .planetary: return "globe.americas"
        case .cdse: return "globe.europe.africa"
        case .earthdata: return "globe.central.south.asia"
        case .gee: return "globe.badge.chevron.backward"
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

/// Authentication type for asset access.
enum AssetAuthType: String, Codable {
    case none
    case sasToken       // Microsoft Planetary Computer
    case bearerToken    // CDSE, NASA Earthdata
    case geeOAuth       // Google Earth Engine OAuth2
}

/// Complete configuration for a single data source.
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

    static func cdseDefault() -> STACSourceConfig {
        STACSourceConfig(
            sourceID: .cdse,
            isEnabled: false,
            displayName: "Copernicus Data Space",
            shortName: "CDSE",
            searchURL: "https://catalogue.dataspace.copernicus.eu/odata/v1/Products",
            collection: "sentinel-2-l2a",
            assetAuthType: .bearerToken,
            bandMapping: BandMapping(
                red: "B04", nir: "B08", green: "B03",
                blue: "B02", scl: "SCL",
                projTransformKey: "B04"
            )
        )
    }

    static func earthdataDefault() -> STACSourceConfig {
        STACSourceConfig(
            sourceID: .earthdata,
            isEnabled: false,
            displayName: "NASA Earthdata (HLS)",
            shortName: "NASA",
            searchURL: "https://cmr.earthdata.nasa.gov/stac/LPCLOUD/search",
            collection: "HLSS30.v2.0",
            assetAuthType: .bearerToken,
            bandMapping: BandMapping(
                red: "B04", nir: "B8A", green: "B03",
                blue: "B02", scl: "Fmask",
                projTransformKey: "B04"
            )
        )
    }

    static func geeDefault() -> STACSourceConfig {
        STACSourceConfig(
            sourceID: .gee,
            isEnabled: false,
            displayName: "Google Earth Engine",
            shortName: "GEE",
            searchURL: "https://earthengine.googleapis.com/v1",
            collection: "COPERNICUS/S2_SR_HARMONIZED",
            assetAuthType: .geeOAuth,
            bandMapping: BandMapping(
                red: "B4", nir: "B8", green: "B3",
                blue: "B2", scl: "SCL",
                projTransformKey: "B4"
            )
        )
    }
}
