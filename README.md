# eof-ios

**Earth Observation Fetch** — a native iOS app for Sentinel-2 NDVI time series analysis, phenology fitting, and field-scale vegetation monitoring.

## What It Does

- Fetches Sentinel-2 L2A imagery from **AWS Earth Search** and **Planetary Computer** STAC catalogs
- Reads Cloud-Optimized GeoTIFF (COG) bands directly — no server-side processing needed
- Computes **NDVI** per pixel, with SCL-based cloud/shadow masking
- Plays the time series as an animated movie with multiple display modes:
  - **NDVI** colormapped
  - **False Color Composite** (NIR-R-G)
  - **True Color** (R-G-B)
  - **Scene Classification Layer** with class boundaries
- Fits a **Beck double logistic** phenology model to the median NDVI time series
- **Per-pixel phenology fitting** with parallel processing — generates spatial parameter maps (SOS, EOS, peak NDVI, RMSE, etc.)
- Long-press any pixel to inspect its individual NDVI time series, DL fit curve, reflectance data, and SCL history
- Satellite basemap underneath imagery (Apple Maps)
- Multi-source redundancy with automatic HTTP error fallback between AWS and Planetary Computer
- Configurable: date range, AOI (GeoJSON polygon, URL, or manual lat/lon), cloud threshold, SCL class filtering, concurrency

## Getting It On Your iPhone

### Prerequisites

- A Mac with **Xcode 16+** installed (free from the Mac App Store)
- An iPhone running **iOS 17+**
- A USB-C or Lightning cable to connect your phone
- An **Apple ID** (free — no paid developer account needed)

### Step 1: Clone the Repository

```bash
git clone https://github.com/profLewis/eof-ios.git
cd eof-ios
```

### Step 2: Open in Xcode

Double-click the project file, or run:

```bash
open eof.xcodeproj
```

### Step 3: Set Up Signing

1. In Xcode, click **eof** in the project navigator (left sidebar, top item)
2. Select the **eof** target under "TARGETS"
3. Go to the **Signing & Capabilities** tab
4. Check **"Automatically manage signing"**
5. Under **Team**, select your Apple ID (if not listed, click "Add an Account..." and sign in)
6. Xcode will create a provisioning profile automatically

### Step 4: Enable Developer Mode on Your iPhone

1. Connect your iPhone to your Mac with a cable
2. On your iPhone, go to **Settings > Privacy & Security > Developer Mode**
3. Toggle **Developer Mode ON**
4. Your iPhone will restart — confirm when prompted
5. After restart, tap **Turn On** when asked

> If you don't see Developer Mode in Settings, connect your phone to Xcode first. It should appear after Xcode detects the device.

### Step 5: Build and Install

1. In Xcode's toolbar at the top, click the **device selector** (next to the play button) and choose your connected iPhone
2. Click the **Play button** (or press `Cmd+R`) to build and run
3. The first time, you may see **"Could not launch"** — this is normal

### Step 6: Trust the Developer Certificate

The first time you install, iOS blocks the app because it's not from the App Store:

1. On your iPhone, go to **Settings > General > VPN & Device Management**
2. Under "Developer App", tap your **Apple ID email**
3. Tap **"Trust [your email]"**
4. Confirm by tapping **Trust**

Now go back to Xcode and click **Play** again, or tap the **eof** app icon on your home screen.

### Subsequent Builds

After the initial setup, just:

```bash
cd eof-ios
open eof.xcodeproj
# Press Cmd+R in Xcode with your phone connected
```

Or from the command line:

```bash
# Build
xcodebuild -scheme eof \
  -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
  -allowProvisioningUpdates build

# Install (replace DEVICE_UUID with your device's UUID)
xcrun devicectl device install app \
  --device YOUR_DEVICE_UUID \
  path/to/DerivedData/eof-xxx/Build/Products/Debug-iphoneos/eof.app

# Launch
xcrun devicectl device process launch \
  --device YOUR_DEVICE_UUID uk.ac.ucl.eof
```

To find your device ID, run:

```bash
xcrun devicectl list devices
```

### Troubleshooting

| Problem | Solution |
|---------|----------|
| "Untrusted Developer" | Settings > General > VPN & Device Management > Trust |
| "Developer Mode" not visible | Connect phone to Xcode first, then check Settings |
| Build fails with signing error | Make sure you selected your Apple ID team in Signing & Capabilities |
| "No such module" errors | Clean build: `Cmd+Shift+K` then `Cmd+B` |
| App crashes on launch | Check Xcode console for logs. Try deleting the app from the phone and reinstalling |

## Project Structure

```
eof-ios/
  eof/
    Models/
      AppSettings.swift          — persistent settings (UserDefaults)
      NDVIFrame.swift            — per-date frame with NDVI + band data
      PixelPhenology.swift       — per-pixel phenology results, cluster filter, parameter maps
      SourceProgress.swift       — download progress tracking
      STACSource.swift           — STAC source configuration
    Services/
      COGReader.swift            — Cloud-Optimized GeoTIFF reader
      DoubleLogistic.swift       — Beck double logistic fitting (Nelder-Mead)
      NDVIProcessor.swift        — full pipeline: STAC search -> COG read -> NDVI
      PixelPhenologyFitter.swift — parallel per-pixel phenology fitting
      SASTokenManager.swift      — Planetary Computer SAS token auth
      STACService.swift          — STAC catalog search
    Views/
      ContentView.swift          — main UI: movie, chart, phenology controls, gestures
      NDVIMapView.swift          — pixel renderer (NDVI, FCC, RCC, SCL, phenology maps)
      PixelDetailView.swift      — per-pixel inspection (NDVI, reflectance, SCL)
      SelectionAnalysisView.swift — sub-AOI rectangle analysis
      ClusterView.swift          — cluster analysis visualisation (pie, histograms, IQR)
      SettingsView.swift         — settings, S2 band reference, SCL mask config
      SourceProgressView.swift   — per-stream download progress bars
      AOIView.swift              — area of interest selection
      DataSourcesView.swift      — data source configuration
    eofApp.swift                 — app entry point
    SF_field.geojson             — bundled default AOI (South Africa wheat field)
```

## Data Sources

| Source | API | Auth | Bands |
|--------|-----|------|-------|
| AWS Earth Search | `earth-search.aws.element84.com/v1` | None | B04 (Red), B08 (NIR), B03 (Green), B02 (Blue), SCL |
| Planetary Computer | `planetarycomputer.microsoft.com/api/stac/v1` | SAS token (auto) | B04, B08, B03, B02, SCL |

The app probes both sources at startup, round-robin allocates scenes, and automatically retries from the alternate source on HTTP errors.

## Phenology Model

The app fits the **Beck double logistic** to NDVI time series:

```
f(t) = mn + (mx - mn) * (1/(1+exp(-rsp*(t-sos))) + 1/(1+exp(rau*(t-eos))) - 1)
```

Parameters:
- **mn** — minimum NDVI (winter baseline)
- **mx** — maximum NDVI (peak greenness)
- **sos** — start of season (day of year)
- **rsp** — rate of spring green-up
- **eos** — end of season (day of year)
- **rau** — rate of autumn senescence

### Fitting Algorithm

All fitting (median-level and per-pixel) uses the same **Nelder-Mead simplex** optimizer with ensemble restarts from perturbed starting points:

1. **Initial guess** — estimated from the data: mn/mx from 10th/90th percentile NDVI values, sos/eos from the first/last midpoint crossings in the time series, rsp/rau initialised to 0.05.
2. **Cycle contamination filter** — before fitting, observations that appear to belong to an adjacent growing cycle are removed. The algorithm identifies the main peak (3-point moving average), computes a baseline threshold, and trims leading points that are above threshold and decreasing (previous cycle's senescence) and trailing points that are above threshold and increasing (next cycle's green-up).
3. **Ensemble runs** — the optimizer is run N times (default 50 for median, 5 for per-pixel). Run 0 uses the initial guess directly. Runs 1..N-1 use **multiplicative uniform perturbation** of each parameter:
   - For amplitude/timing parameters (mn, mx, sos, eos): `perturbed = guess * (1 + U(-p, p))` where `p` is the perturbation fraction (default 50%)
   - For slope parameters (rsp, rau): `perturbed = guess * (1 + U(-sp, sp))` where `sp` is the slope perturbation fraction (default 10%). Slopes need less variation because the sigmoid shape is sensitive to these rates.
   - All perturbations are drawn from a **flat (uniform) distribution**, not Gaussian.
   - After perturbation, parameters are clamped to physical bounds (mn: -0.5–0.8, mx: 0.0–1.2, sos: 1–250, rsp: 0.001–0.5, eos: 100–366, rau: 0.001–0.5).
4. **Nelder-Mead optimization** — each run minimizes RMSE between model and data using the simplex algorithm (reflect/expand/contract/shrink) with convergence tolerance 1e-8 and configurable max iterations (2000 for median, 500 for per-pixel).
5. **Season length constraint** — a soft penalty is added to the cost function when `eos - sos` falls outside the allowed range: `cost += |violation| * 0.01`. This steers the optimizer away from physically implausible season lengths without hard-clipping.
6. **Best fit selection** — the run with the lowest RMSE is kept. For the median ensemble, all solutions within 1.5x of the best RMSE are retained as "viable" for uncertainty visualization.

### Per-Pixel Phenology Fitting

The app fits the double logistic model to **every individual pixel** in the AOI, not just the median time series:

1. **Median fit as starting point** — the field-level median NDVI is fitted first using the ensemble algorithm above. This provides robust initial parameter estimates.
2. **Per-pixel ensemble fitting** — each pixel's NDVI time series is extracted from all frames. The median fit parameters (not the data-derived initial guess) are used as the starting point. Perturbation fractions and ensemble size are taken from settings. The best fit (lowest RMSE) is kept.
3. **Quality classification** — each pixel is classified as:
   - **Good** — converged fit with RMSE below threshold
   - **Poor** — fit converged but RMSE exceeds threshold
   - **Skipped** — too few valid observations to fit (< min observations)
4. **Spatial parameter maps** — after fitting, any DL parameter (SOS, EOS, peak NDVI, min NDVI, green-up rate, senescence rate, RMSE, season length) can be displayed as a colour-mapped spatial map overlaid on the imagery.

### Cluster-Based Outlier Filtering

After per-pixel fitting, a cluster filter can identify and flag outlier pixels whose fitted parameters are statistically inconsistent with the field-level distribution:

1. **Robust statistics** — the median and MAD (median absolute deviation) of each of the 6 DL parameters are computed across all good-fit pixels.
2. **Normalized distance** — for each pixel, a normalized distance is computed as the RMS of per-parameter z-scores: `z_i = |param_i - median_i| / MAD_i`, then `distance = sqrt(mean(z^2))`.
3. **Threshold** — pixels with distance exceeding the configurable threshold (default 4.0 MADs) are flagged as candidate outliers.
4. **Spatial regularization** — candidate outliers are checked against their 8-connected neighbors. If >=50% of the pixel's valid neighbors are non-outlier (good fit), the pixel is "rescued" and kept as good. This prevents isolated statistical outliers surrounded by spatially coherent good fits from being incorrectly removed.
5. **Filtered median refit** — after filtering, the median NDVI is recomputed using only good-fit pixels, and the DL model is re-fitted to this cleaned median using the same ensemble algorithm. This provides an improved field-level phenology estimate.

**Settings:**

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| Ensemble Runs | 5 | 1–20 | Number of fits per pixel from perturbed starts |
| Perturbation | 50% | 5–100% | Multiplicative perturbation of mn, mx, sos, eos (uniform) |
| Slope Perturbation | 10% | 5–50% | Multiplicative perturbation of rsp, rau (uniform, tighter) |
| RMSE Threshold | 0.10 | 0.02–0.30 | Maximum RMSE for "good" fit classification |
| Min Observations | 4 | 3–10 | Minimum valid observations to attempt fit |
| Min Season Length | 50 days | 10–200 | Minimum allowed EOS − SOS (soft penalty) |
| Max Season Length | 150 days | 100–365 | Maximum allowed EOS − SOS (soft penalty) |
| Cluster Threshold | 4.0 MADs | 2.0–8.0 | Outlier distance threshold (lower = stricter) |

### Parameter Uncertainty

Parameter uncertainty is estimated using the **interquartile range (IQR)** of each parameter across all good-fit pixels in the AOI or selection. The IQR provides a robust measure of parameter spread that is insensitive to outliers. This is displayed in the Analysis view.

## Sub-AOI Selection

A rectangle selection tool allows inspection of a sub-region of the AOI:

1. Tap the selection pin icon on the movie overlay to enter select mode
2. Drag a rectangle over the area of interest
3. The app computes mean NDVI time series, DL fit, mean reflectance spectra (Red, NIR, Green, Blue), and phenology parameter statistics (mean ± std) for the selected pixels
4. Good/poor/outlier pixel counts are shown in the header

## Per-Pixel Inspection

Long-press on any pixel in the map to open a detail sheet showing:

- **NDVI time series** — scatter plot of this pixel's NDVI across all dates, with points colour-coded (green = used in fit, red crosses = filtered by cycle contamination)
- **DL fit curves** — pixel's own fit (yellow) and field median fit (green dashed) for comparison
- **Parameter comparison** — side-by-side table of pixel vs median DL parameters
- **Reflectance time series** — Red, NIR, Green, Blue reflectance (DN/10000) across all dates
- **SCL history** — colour-coded strip showing the Scene Classification class for each date

## Related Projects

- [eof](https://github.com/profLewis/eof) — Python package for multi-sensor EO data retrieval
- [ARC](https://github.com/profLewis/ARC) — Archetype-based crop monitoring using PROSAIL + data assimilation

## License

UCL / Prof. P. Lewis
