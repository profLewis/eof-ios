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

The app offers an optional credential export feature:

- Credentials are serialised as JSON, compressed with zlib, then encrypted with AES-256-GCM using a key derived from a user-supplied passphrase (PBKDF2, 100k iterations, random salt).
- The exported `.eofcred` file contains: 16-byte salt, 12-byte nonce, 16-byte GCM tag, and the ciphertext. It is also protected with iOS `FileProtectionComplete` on device.
- **You are responsible for the security of exported credential files and your passphrase.**

To decrypt an exported `.eofcred` file outside the app (e.g. for backup recovery), you can use the following Python script:

```python
#!/usr/bin/env python3
"""Decrypt an eof .eofcred credential file."""
import sys, zlib, json, getpass
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

def decrypt_eofcred(path, passphrase):
    data = open(path, "rb").read()
    salt, nonce, tag = data[:16], data[16:28], data[28:44]
    ciphertext = data[44:]
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32,
                      salt=salt, iterations=100_000)
    key = kdf.derive(passphrase.encode())
    plaintext = AESGCM(key).decrypt(nonce, ciphertext + tag, None)
    return json.loads(zlib.decompress(plaintext))

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else input("Path to .eofcred: ")
    pw = getpass.getpass("Passphrase: ")
    creds = decrypt_eofcred(path, pw)
    for k, v in creds.items():
        print(f"  {k}: {v}")
```

Requires: `pip install cryptography`

## Third-Party Data Sharing

This app does **not** share any data with third parties beyond the search and download requests described above.

## Analytics and Tracking

This app does **not** include any analytics, tracking, advertising, or telemetry of any kind. There are no third-party SDKs beyond Apple system frameworks.

## Children's Privacy

This app does not knowingly collect any personal information from children or any other users.

## Contact

If you have questions about this privacy policy, please open an issue on the [GitHub repository](https://github.com/profLewis/eof-ios).
