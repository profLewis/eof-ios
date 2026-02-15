# Privacy Policy — eof

**Last updated:** 15 February 2026

## Overview

eof is a satellite Earth observation tool for viewing and analysing Sentinel-2 imagery. It is designed to operate entirely on your device. It does not collect, transmit, or share personal data with the app developer or any analytics service.

## Data Stored on Your Device

The only data retained locally on your device is:

- **App preferences** — Display settings, analysis parameters, and UI state are stored in standard app storage (UserDefaults). These are purely functional settings with no personal information.
- **API credentials** — If you configure access to authenticated data sources (Copernicus Data Space, NASA Earthdata, or Google Earth Engine), your credentials (usernames, passwords, API keys, OAuth tokens) are stored in the iOS Keychain with `AfterFirstUnlock` protection. These are never transmitted anywhere other than to the data provider you configured.
- **Temporary access tokens** — Short-lived SAS tokens for Microsoft Planetary Computer are cached locally for approximately one hour and automatically refreshed.

No satellite imagery, analysis results, or other downloaded data is persisted to disk. All network sessions use ephemeral (non-caching) configurations.

## Location Data

The app requests location permission ("When In Use" only) if you choose to use the "My Location" feature to centre the map on your current position. Your location is:

- Used only transiently to set the area of interest and to look up the local country code for crop calendar queries.
- **Never stored persistently**, logged, or transmitted to any service other than Apple's built-in geocoder.
- Never accessed in the background.

## External Services

The app contacts the following third-party services solely to search for and download publicly available satellite imagery:

| Service | Purpose | Authentication |
|---------|---------|----------------|
| AWS Earth Search | Sentinel-2 imagery search | None required |
| Microsoft Planetary Computer | Sentinel-2 imagery search and download | Optional API key |
| Copernicus Data Space (CDSE) | Sentinel-2 imagery search and download | Free account (user-provided) |
| NASA Earthdata | Sentinel-2 imagery search and download | Free account (user-provided) |
| Google Earth Engine | Sentinel-2 imagery search | OAuth with user's GCP project |
| FAO Crop Calendar API | Crop planting/harvest dates by region | None required |
| Apple Maps (MapKit) | Satellite basemap tiles and geocoding | System-level (Apple) |

No data is sent to these services beyond the minimum required for search queries (geographic coordinates, date ranges, and authentication tokens). No personal information is included in these requests.

## Credential Export/Import

The app offers an optional credential export feature. Exported files are encrypted and protected with iOS `FileProtectionComplete`. You are responsible for the security of exported credential files.

## Third-Party Data Sharing

This app does **not** share any data with third parties beyond the search and download requests described above.

## Analytics and Tracking

This app does **not** include any analytics, tracking, advertising, or telemetry of any kind. There are no third-party SDKs beyond Apple system frameworks.

## Children's Privacy

This app does not knowingly collect any personal information from children or any other users.

## Contact

If you have questions about this privacy policy, please open an issue on the [GitHub repository](https://github.com/profLewis/eof-ios).
