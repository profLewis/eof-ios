# eof-ios

**Earth Observation Fetch** — a native iOS app for Sentinel-2 NDVI time series analysis, phenology fitting, and field-scale vegetation monitoring.

## What It Does

- Fetches Sentinel-2 L2A imagery from multiple data sources: **AWS Earth Search**, **Planetary Computer**, **Copernicus Data Space (CDSE)**, **NASA Earthdata (HLS)**, and **Google Earth Engine**
- Reads Cloud-Optimized GeoTIFF (COG) bands directly — no server-side processing needed
- Computes **NDVI** (or **DVI**) per pixel, with SCL-based cloud/shadow masking
- **Source comparison mode** for cross-validating data from different centres
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
      SourceBenchmark.swift      — benchmark results for source ranking
      SourceProgress.swift       — download progress tracking
      STACModels.swift           — STAC API response models, DN offset logic
      STACSource.swift           — STAC source configuration + defaults
    Services/
      BearerTokenManager.swift   — OAuth2 token management for CDSE + Earthdata
      COGReader.swift            — Cloud-Optimized GeoTIFF reader (HTTP range requests)
      DoubleLogistic.swift       — Beck double logistic fitting (Nelder-Mead + Huber loss)
      GEEService.swift           — Google Earth Engine search + computePixels
      GEETokenManager.swift      — GEE OAuth2 token management
      GEETiffParser.swift        — Multi-band GeoTIFF parser for GEE responses
      NDVIProcessor.swift        — full pipeline: STAC search -> COG read -> VI compute
      PixelPhenologyFitter.swift — parallel per-pixel phenology fitting
      SASTokenManager.swift      — Planetary Computer SAS token signing
      SigV4Signer.swift          — AWS SigV4 request signing (for CDSE S3)
      SourceBenchmarkService.swift — source latency benchmarking
      STACService.swift          — STAC catalog search client
    Views/
      AOIView.swift              — area of interest selection (map, GeoJSON, manual)
      ClusterView.swift          — cluster analysis visualisation (pie, histograms, IQR)
      ContentView.swift          — main UI: movie, chart, phenology controls, gestures
      DataSourcesView.swift      — data source configuration + compare trigger
      NDVIMapView.swift          — pixel renderer (NDVI, FCC, RCC, SCL, phenology maps)
      PixelDetailSheet.swift     — long-press pixel inspection
      SelectionAnalysisView.swift — sub-AOI rectangle analysis
      SettingsView.swift         — settings, S2 band reference, SCL mask config
      SourceComparisonView.swift — cross-source comparison scatter plots + statistics
      SourceProgressView.swift   — per-stream download progress bars
    eofApp.swift                 — app entry point
    SF_field.geojson             — bundled default AOI (South Africa wheat field)
```

## Data Sources

The app can fetch Sentinel-2 L2A data from multiple independent data centres. Each centre hosts an independent copy of the ESA Sentinel-2 archive, served via different APIs and with different processing conventions.

| Source | API | Auth | Format | Status |
|--------|-----|------|--------|--------|
| **AWS Earth Search** | `earth-search.aws.element84.com/v1` STAC | None (public) | COG (GeoTIFF) | Fully supported |
| **Planetary Computer** | `planetarycomputer.microsoft.com/api/stac/v1` STAC | SAS token (auto) | COG (GeoTIFF) | Fully supported |
| **Copernicus Data Space (CDSE)** | `catalogue.dataspace.copernicus.eu/stac` STAC | Bearer token or S3 keys | JP2 (JPEG2000) | Search only (JP2 not supported for pixel fetch) |
| **NASA Earthdata (HLS)** | `cmr.earthdata.nasa.gov/stac/LPCLOUD` STAC | Bearer token | COG (GeoTIFF) | Supported (HLS S30 product, uses Fmask instead of SCL) |
| **Google Earth Engine** | `earthengine.googleapis.com/v1` REST | OAuth2 | GeoTIFF (via computePixels) | Supported (requires GEE project + OAuth sign-in) |

### Authentication

- **AWS**: No authentication needed. Public access via HTTP.
- **Planetary Computer**: Automatic SAS token signing via the PC token endpoint. No credentials required.
- **CDSE**: Requires a free account at [dataspace.copernicus.eu](https://dataspace.copernicus.eu). Enter username/password or S3 access keys in Settings > Data Sources > CDSE. Note: CDSE currently serves JP2 files, which the app's COG reader cannot process. CDSE is useful for search/benchmark testing but pixel fetch will fail.
- **NASA Earthdata**: Requires a free account at [urs.earthdata.nasa.gov](https://urs.earthdata.nasa.gov). Enter username/password in Data Sources. Uses HLS S30 v2.0 (Harmonized Landsat Sentinel-2), which has different band naming and uses Fmask instead of SCL for cloud masking.
- **Google Earth Engine**: Requires a GEE-enabled Google Cloud project. OAuth sign-in via Data Sources. The app uses `computePixels` to fetch multi-band GeoTIFF tiles server-side.

### Source Selection and Redundancy

The app probes all enabled sources at startup via a benchmark (STAC search + COG header fetch). When **Smart Stream Allocation** is enabled (Settings > Data Sources), concurrent download streams are allocated proportionally to each source's measured speed. If a source returns HTTP errors during a fetch, the app automatically retries the same scene from an alternate source.

Sources can be reordered by dragging in the Data Sources list. The order determines trust priority when multiple sources have data for the same date — the first source in the list is preferred unless it's slower (when smart allocation is on).

### DN to Reflectance Conversion

Different data centres apply different processing to the raw ESA Sentinel-2 data. Understanding the **DN (Digital Number) to surface reflectance** conversion is critical for consistent cross-source analysis.

**The standard ESA formula is:**

```
reflectance = (DN + BOA_ADD_OFFSET) / QUANTIFICATION_VALUE
```

Where `QUANTIFICATION_VALUE = 10000` and `BOA_ADD_OFFSET = -1000` for processing baseline >= 04.00 (all data from ~January 2022 onwards).

**How each source handles this:**

| Source | Raw DN range (typical vegetation red band) | `earthsearch:boa_offset_applied` | `s2:processing_baseline` | What the app does |
|--------|---------------------------------------------|----------------------------------|--------------------------|-------------------|
| **AWS** | ~100–700 | `true` | e.g. `05.10` | AWS has **already subtracted 1000** from the DNs. The app uses `dnOffset = 0`, so `reflectance = DN / 10000`. |
| **PC** | ~1100–1700 | not present | e.g. `05.10` | PC serves **raw ESA DNs** with the +1000 still present. The app detects `processing_baseline >= 4.0` and applies `dnOffset = -1000`, so `reflectance = (DN - 1000) / 10000`. |
| **CDSE** | ~1100–1700 | not present | e.g. `05.10` | Same as PC — raw ESA DNs. Same offset correction. |
| **GEE** | ~100–700 (S2_SR_HARMONIZED) | n/a | n/a | GEE's `S2_SR_HARMONIZED` collection has already applied the offset. `dnOffset = 0`, so `reflectance = DN / 10000`. |
| **HLS** | ~100–700 | n/a | n/a | HLS has its own harmonization pipeline. No BOA offset. `reflectance = DN / 10000`. |

**Verification:** For the same scene (tile T35JPL, 2024-06-14), GDAL pixel extraction confirms:
- AWS red band DN median: **1104**
- PC red band DN median: **2108**
- Difference: **1004** (≈1000, confirming the offset)
- After correction: AWS `1104/10000 = 0.1104`, PC `(2108-1000)/10000 = 0.1108` — matching to within 0.0004

The tiny residual difference (0.04%) comes from different processing versions and atmospheric correction runs between the data centres.

## Source Comparison Mode

Source comparison mode fetches the **same scenes from all enabled sources** and generates detailed per-pixel, per-band, cross-source statistics. This is the primary tool for verifying that the app's DN-to-reflectance conversion is consistent across data centres.

### How to Run a Source Comparison

1. **Enable at least 2 sources** in Settings > Data Sources (e.g., AWS and Planetary Computer). Both must be reachable — run "Test Sources" first to verify.
2. **Tap "Compare Sources"** in the Benchmarks section of Settings > Data Sources.
3. The app dismisses settings and starts a special fetch that downloads every scene from **all** enabled sources, not just the fastest one.
4. When the fetch completes, a **Source Comparison** sheet appears with scatter plots and statistics.

### What the Comparison Shows

The comparison view is organised by **source pair** (e.g., "AWS vs PC"). If you have 3 sources enabled, you'll see a segmented picker to switch between all pairwise comparisons (AWS vs PC, AWS vs CDSE, PC vs CDSE).

For each source pair, the view displays:

#### 1. Per-Band Reflectance Bias

A row of 4 numbers showing the mean difference in corrected reflectance between source A and source B, for each band:

```
Red: +0.0003   NIR: -0.0001   Green: +0.0002   Blue: +0.0001
```

**What to expect:** If the offset correction is working correctly, all biases should be **very close to zero** (< 0.001 reflectance units). A bias of exactly +0.1000 in all bands would indicate that one source has an unhandled +1000 DN offset.

#### 2. Band Reflectance Scatter Plots (2x2 grid)

Four scatter plots (Red, NIR, Green, Blue) showing corrected reflectance from source A (x-axis) vs source B (y-axis) for all matched valid pixels. A 1:1 reference line is shown.

**What to expect:**
- **Correctly calibrated sources**: Points should lie tightly along the 1:1 line with minimal scatter. The bias annotation below each plot should be near zero.
- **Offset error**: If one source has an unhandled +1000 offset, the scatter would show a systematic shift — all points displaced from the 1:1 line by +0.1 reflectance.
- **Different SCL masks**: Some scatter is expected because the two sources may use slightly different processing versions, resulting in different cloud masks. Pixels valid in both sources are compared; pixels masked in one source but not the other are excluded.
- **Typical scatter**: Even for perfectly calibrated sources, expect some scatter (R² ~ 0.95–0.99) due to different atmospheric correction versions, different reprocessing dates, and numerical precision.

#### 3. Aggregate NDVI Statistics

Summary statistics across all paired pixels and dates:

| Statistic | Description | Expected range |
|-----------|-------------|----------------|
| **NDVI Bias** | Mean difference in NDVI between source A and B | < 0.01 |
| **NDVI RMSE** | Root mean square difference in NDVI | < 0.02 |
| **NDVI R²** | Coefficient of determination (1 = perfect agreement) | > 0.95 |

#### 4. NDVI Scatter Plot

Aggregated scatter plot of NDVI (source A vs source B) across all dates. The x-axis range is -0.2 to 1.0 and a 1:1 line is shown.

**What to expect:** A tight cloud of points along the 1:1 line. Dense vegetation (NDVI > 0.5) and bare soil (NDVI < 0.2) should both agree. Small systematic offsets may be visible as slight displacement from the 1:1 line.

#### 5. Median NDVI Time Series

Overlay of median NDVI from source A (blue) and source B (orange) at each date (day of year). This shows whether the two sources track each other over the growing season.

**What to expect:** The two series should overlap closely. If one source consistently shows higher NDVI, it indicates a systematic bias. Occasional divergence on individual dates may indicate different cloud masking (one source masks more pixels on a cloudy date, changing the median).

#### 6. Per-Date Table

A tabular summary for each acquisition date:

| Column | Description |
|--------|-------------|
| **Date** | Acquisition date |
| **[srcA]** | Median NDVI from source A |
| **[srcB]** | Median NDVI from source B |
| **Δ** | Difference (A − B). Values > 0.02 are highlighted in red. |
| **nA** | Number of valid pixels in source A |
| **nB** | Number of valid pixels in source B |
| **offA** | DN offset applied for source A (0 = no offset, -1000 = offset subtracted) |
| **offB** | DN offset applied for source B |

**What to expect:**
- **Δ (NDVI difference)**: Should be small (< 0.01) for most dates. Dates highlighted in red (Δ > 0.02) may have different cloud masks or different scene geometries.
- **nA vs nB**: The valid pixel counts should be similar. Large differences indicate that one source masks significantly more pixels (e.g., stricter cloud detection).
- **offA vs offB**: AWS should show 0 (offset already applied), PC should show -1000 (app corrects it). If both show 0 or both show -1000, there may be a configuration issue.

### Interpreting Results

**Scenario 1: Everything looks correct**
- Band reflectance biases all < 0.001
- NDVI bias < 0.005, RMSE < 0.015, R² > 0.98
- Scatter plots show tight 1:1 agreement
- Per-date table shows consistent offA/offB values and small Δ

This means the DN-to-reflectance conversion is working correctly across sources, and you can confidently mix data from different centres in your analysis.

**Scenario 2: Systematic offset in all bands**
- Band reflectance bias ~+0.1000 in all bands
- NDVI bias may be small (ratio-based index is robust to additive offsets)
- Scatter plots show a clear shift from the 1:1 line

This indicates an unhandled DN offset (1000/10000 = 0.1). Check the per-date table — if one source shows offA = 0 when it should show -1000 (or vice versa), the offset detection logic may be wrong for that source's metadata format.

**Scenario 3: Large scatter but zero mean bias**
- Band biases near zero but scatter plots show wide spread
- NDVI R² < 0.90

This typically means different scene geometries (the two sources are serving different processing versions of the same acquisition) or different SCL masks (one source's cloud detection is more aggressive). Check valid pixel counts in the per-date table.

**Scenario 4: Different valid pixel counts**
- nA and nB differ significantly (e.g., 150 vs 80)
- NDVI medians may differ because they're computed over different pixel subsets

This occurs when the two sources have different SCL (Scene Classification Layer) values for the same pixels. ESA periodically reprocesses the archive, and different data centres may serve different processing versions. The comparison only uses pixels valid in **both** sources for the scatter plots, but the median NDVI values and valid pixel counts in the table are computed per-source.

### Technical Details

- **Pixel matching**: The comparison aligns frames by their MGRS tile grid and pixel coordinates. Both sources read from the same UTM projection and 10m pixel grid, so pixels are co-registered by definition.
- **Subsampling**: To keep the scatter plots responsive, pixels are subsampled to ~5000 points per date pair. The bias and RMSE statistics are computed on the full (subsampled) dataset.
- **Band loading**: In comparison mode, all 4 bands (Red, NIR, Green, Blue) are downloaded for every scene, regardless of the current display mode setting. This is different from normal mode where green/blue are lazy-loaded only when needed.
- **Multiple sources**: If more than 2 sources are enabled, all pairwise combinations are generated. For example, 3 sources produce 3 pairs. A segmented picker at the top lets you switch between pairs.

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
4. **Nelder-Mead optimization with Huber loss** — each run minimizes **Huber loss** (not RMSE) between model and data using the simplex algorithm (reflect/expand/contract/shrink) with convergence tolerance 1e-8 and configurable max iterations (2000 for median, 500 for per-pixel). The Huber loss is quadratic for small residuals (`|r| <= δ`) and linear for large ones (`|r| > δ`), limiting the influence of outlier observations that survive cloud masking. `δ = 0.10` NDVI units, so residuals beyond 0.10 are down-weighted. After convergence, true RMSE is computed for quality reporting.
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

## Related Projects

- [eof](https://github.com/profLewis/eof) — Python package for multi-sensor EO data retrieval
- [ARC](https://github.com/profLewis/ARC) — Archetype-based crop monitoring using PROSAIL + data assimilation

## License

UCL / Prof. P. Lewis
