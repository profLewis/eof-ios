import SwiftUI

/// Comprehensive help and documentation for eof.
struct HelpView: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 4) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.blue)
                        Text("Help & Documentation")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                gettingStartedSection
                dataSourcesSection
                displayModesSection
                vegetationIndicesSection
                phenologySection
                spectralUnmixingSection
                sclSection
                perPixelFittingSection
                spectralPlotSection
                cropCalendarSection
                dnReflectanceSection
                networkSection
                troubleshootingSection
                referencesSection
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: - Getting Started

    private var gettingStartedSection: some View {
        Section("Getting Started") {
            DisclosureGroup("What is eof?") {
                helpText("""
                eof (Earth Observation Fetch) analyses Sentinel-2 satellite imagery \
                to monitor vegetation over time. It downloads multispectral data from \
                cloud archives, computes vegetation indices (NDVI, DVI), fits phenology \
                models to track green-up and senescence, and performs spectral unmixing \
                to estimate vegetation, dry matter, and soil fractions.
                """)
            }
            DisclosureGroup("Quick start") {
                helpText("""
                1. Select an Area of Interest (AOI) — use the map, enter coordinates, \
                or choose a sample crop field from the database
                2. Set a date range (e.g. Jun–Dec 2024)
                3. Tap the fetch button to search and download imagery
                4. The app searches STAC catalogs, downloads Cloud-Optimized GeoTIFF \
                tiles, computes NDVI, and displays an animated time series
                5. Tap "Fit" to fit a double logistic phenology curve
                6. Tap "Per-Pixel" to run per-pixel phenology fitting
                7. Use the "Live" menu to display spatial parameter maps
                """)
            }
            DisclosureGroup("The main screen") {
                helpText("""
                • Header: Shows current settings (display mode, dates, sources)
                • Status bar: Fetch/Fit/Per-Pixel/Live controls
                • Image: Current frame with pinch-to-zoom and pan
                • Chart: Time series of VI values with DL fit curves
                • Spectral plot: Per-band reflectance for current frame
                • Phenology section: DL parameter sliders (collapsible)
                • Frame counter: Current position in time series

                Swipe left/right on the image to step through frames. \
                Long-press a pixel to inspect its individual time series. \
                Use the chart drag gesture to scrub through dates.
                """)
            }
        }
    }

    // MARK: - Data Sources

    private var dataSourcesSection: some View {
        Section("Data Sources") {
            DisclosureGroup("Overview") {
                helpText("""
                eof can fetch Sentinel-2 Level-2A (surface reflectance) data from \
                multiple cloud archives. Each source provides the same satellite data \
                but through different APIs and with different processing conventions. \
                Enable multiple sources for redundancy — the app automatically selects \
                the fastest available source for each scene.
                """)
            }
            DisclosureGroup("AWS Earth Search") {
                helpText("""
                Provider: Element 84 / AWS Open Data
                Product: Sentinel-2 L2A COG (Cloud-Optimized GeoTIFF)
                Collection: sentinel-2-l2a
                Auth: None (public, free)
                Coverage: Global, 2017–present

                AWS applies the BOA (Bottom of Atmosphere) offset correction \
                server-side, so DN values can be converted directly: \
                reflectance = DN / 10000.

                This is often the fastest source with no authentication overhead. \
                Recommended as the primary source.
                """)
            }
            DisclosureGroup("Microsoft Planetary Computer") {
                helpText("""
                Provider: Microsoft / AI for Earth
                Product: Sentinel-2 L2A COG
                Collection: sentinel-2-l2a
                Auth: SAS token (auto-generated, no account needed)
                Coverage: Global, 2017–present

                Planetary Computer provides raw ESA DNs. For data processed \
                since January 2022 (processing baseline ≥ 04.00), ESA added a \
                +1000 offset to avoid negative reflectances. The app detects \
                the processing baseline automatically and applies the correction: \
                reflectance = (DN − 1000) / 10000.

                SAS tokens are generated automatically and last ~1 hour.
                """)
            }
            DisclosureGroup("Copernicus Data Space (CDSE)") {
                helpText("""
                Provider: ESA / European Commission
                Product: Sentinel-2 L2A (JPEG2000)
                Collection: sentinel-2-l2a
                Auth: Bearer token (requires free CDSE account)
                Coverage: Global, 2017–present

                The official ESA archive. Data is in JPEG2000 format (not COG), \
                which may be slightly slower to read. Uses the same DN offset \
                convention as Planetary Computer.

                Register at dataspace.copernicus.eu and enter your credentials \
                in Data Sources settings.
                """)
            }
            DisclosureGroup("NASA Earthdata (HLS)") {
                helpText("""
                Provider: NASA LP DAAC
                Product: HLS S30 v2.0 (Harmonized Landsat Sentinel-2)
                Collection: HLSS30.v2.0
                Auth: Bearer token (requires free Earthdata account)
                Coverage: Global land, 2017–present (60°S to 84°N)

                HLS harmonizes Sentinel-2 and Landsat-8/9 to a common 30m grid \
                with BRDF-adjusted reflectance. Uses Fmask for cloud detection \
                (different from ESA's SCL).

                Note: Band names differ (B8A instead of B08 for NIR). \
                reflectance = DN × 0.0001.

                Register at urs.earthdata.nasa.gov.
                """)
            }
            DisclosureGroup("Google Earth Engine") {
                helpText("""
                Provider: Google
                Product: COPERNICUS/S2_SR_HARMONIZED
                Auth: OAuth2 + GCP project ID
                Coverage: Global, 2017–present

                GEE provides harmonized Sentinel-2 surface reflectance via its \
                computePixels REST API. The data is "harmonized" — GEE applies \
                the BOA offset correction server-side, similar to AWS.

                Requires a Google Cloud project with the Earth Engine API enabled. \
                Enter your GCP project ID in Data Sources settings, then sign in \
                with OAuth2.
                """)
            }
            DisclosureGroup("Source selection & racing") {
                helpText("""
                When multiple sources are enabled:
                • The app probes all sources at startup to check connectivity
                • For each scene, it picks the source with lowest recent latency
                • If a download fails or times out, it automatically retries from \
                an alternate source
                • Idle download slots may "race" — fetching the same scene from \
                a second source to reduce wait time
                • Processing baseline preference: sources providing PB ≥ 05.09 \
                are preferred (latest ESA processing)

                Enable 2–3 sources for best reliability.
                """)
            }
        }
    }

    // MARK: - Display Modes

    private var displayModesSection: some View {
        Section("Display Modes") {
            DisclosureGroup("NDVI colormap") {
                helpText("""
                Normalized Difference Vegetation Index mapped to a colour ramp:
                  Blue (< 0) → Green (0.2–0.4) → Yellow (0.5–0.6) → Red (> 0.7)

                Higher values indicate denser, healthier vegetation. Water and \
                bare soil typically show values near 0 or negative. Cloud-masked \
                and out-of-AOI pixels are transparent.
                """)
            }
            DisclosureGroup("False Color Composite (FCC)") {
                helpText("""
                NIR → Red channel, Red → Green channel, Green → Blue channel.

                Vegetation appears bright red/pink (high NIR reflectance). \
                Bare soil appears cyan/grey. Water appears dark blue/black. \
                This is the standard remote sensing visualization for vegetation.

                Requires bands: B03 (Green), B04 (Red), B08 (NIR).
                """)
            }
            DisclosureGroup("True Color (RGB)") {
                helpText("""
                Natural colour: Red → R, Green → G, Blue → B.

                Shows the scene as it would appear to the human eye. Useful for \
                visual context but less informative for vegetation analysis.

                Requires bands: B02 (Blue), B03 (Green), B04 (Red).
                """)
            }
            DisclosureGroup("Scene Classification (SCL)") {
                helpText("""
                ESA's Scene Classification Layer at 20m resolution, upsampled to \
                10m. Each pixel is classified into one of 12 classes (vegetation, \
                cloud, shadow, water, etc.). Colours follow the Sentinel Hub \
                convention.

                Useful for understanding which pixels are masked and why. See the \
                SCL section below for class definitions.
                """)
            }
            DisclosureGroup("Single-band modes") {
                helpText("""
                Red (B04, 665nm): Chlorophyll absorption band — vegetation is dark.
                NIR (B08, 842nm): Strong vegetation reflection — vegetation is bright.
                Green (B03, 560nm): Green peak reflectance.
                Blue (B02, 490nm): Atmospheric scattering, water penetration.

                Displayed as greyscale with auto-stretch. Useful for inspecting \
                individual band quality and understanding VI computation.
                """)
            }
            DisclosureGroup("Lazy band loading") {
                helpText("""
                The app only downloads the bands needed for the current display mode:
                • NDVI: Red (B04) + NIR (B08) + SCL
                • FCC: adds Green (B03)
                • RGB: adds Blue (B02)

                When you switch modes, any missing bands are downloaded in the \
                background. Previously downloaded bands are cached — switching \
                back is instant.
                """)
            }
        }
    }

    // MARK: - Vegetation Indices

    private var vegetationIndicesSection: some View {
        Section("Vegetation Indices") {
            DisclosureGroup("NDVI — Normalized Difference") {
                helpText("""
                Formula: NDVI = (NIR − Red) / (NIR + Red)
                Range: −1 to +1 (typically 0.1–0.8 for vegetation)

                The most widely used vegetation index. Normalizing by the sum \
                makes it relatively insensitive to illumination differences and \
                atmospheric effects. However, it saturates at high leaf area \
                index (LAI > 4) and is nonlinear, meaning the average NDVI of \
                a mixed pixel does not equal the average of pure-pixel NDVIs.

                Typical values:
                • Dense forest: 0.6–0.9
                • Cropland (peak): 0.5–0.8
                • Grassland: 0.2–0.5
                • Bare soil: 0.0–0.1
                • Water: −0.1 to 0.0
                """)
            }
            DisclosureGroup("DVI — Difference") {
                helpText("""
                Formula: DVI = NIR − Red
                Range: approximately −0.5 to +0.5 (reflectance units)

                A simple difference that is linear with vegetation amount. \
                Unlike NDVI, DVI does not saturate as readily at high LAI. \
                The arithmetic mean of DVI across pixels is physically \
                meaningful (unlike NDVI which is a ratio).

                DVI is more sensitive to soil background brightness and \
                atmospheric effects than NDVI.
                """)
            }
            DisclosureGroup("Which index to use?") {
                helpText("""
                • Use NDVI for general-purpose vegetation monitoring — it is \
                robust and widely understood
                • Use DVI when you need a linear measure for spatial averaging, \
                or when NDVI saturation is a concern (dense canopy)
                • The double logistic model can be fitted to either index — \
                select in Settings → Vegetation Index
                """)
            }
        }
    }

    // MARK: - Phenology Model

    private var phenologySection: some View {
        Section("Phenology Model") {
            DisclosureGroup("Double logistic function") {
                helpText("""
                The app fits a double logistic (Beck et al., 2006) curve to the \
                vegetation index time series:

                f(t) = mn + δ × [1/(1+e^(−rsp×(t−sos))) + 1/(1+e^(rau×(t−eos))) − 1]

                This models a single growing season with:
                • mn: baseline (winter minimum) VI
                • δ (delta): amplitude (mx − mn), seasonal range
                • sos: start of season (green-up inflection point, DOY)
                • rsp: rate of spring green-up (steepness)
                • eos: end of season (senescence inflection point, DOY)
                • rau: rate of autumn senescence (steepness)

                The inflection points (sos, eos) correspond roughly to the dates \
                when the VI reaches 50% of its seasonal range.
                """)
            }
            DisclosureGroup("Fitting algorithm") {
                helpText("""
                1. Initial guess from data: mn, mx from percentiles; sos, eos \
                from steepest rise/fall; slopes from finite differences
                2. Cycle contamination filter removes observations from adjacent \
                growing seasons (leading senescence, trailing green-up)
                3. Nelder-Mead simplex optimizer minimizes Huber loss (robust to \
                outliers — quadratic for small residuals, linear for large)
                4. Ensemble of N random restarts (default 50 for median, 5 per \
                pixel) with perturbed starting parameters
                5. Best fit selected by lowest RMSE; all fits within 1.5× best \
                RMSE retained as "viable" ensemble members
                6. Optional second pass: DL-weighted re-fit giving more weight \
                to observations near the fitted curve
                """)
            }
            DisclosureGroup("Phenology parameters explained") {
                helpText("""
                SOS (Start of Season): Day of year when green-up reaches 50% of \
                amplitude. Earlier SOS = earlier spring. Maps: blue (early) to \
                red (late).

                Season Length: EOS − SOS in days. Longer seasons appear red on maps.

                Amplitude (δ): Difference between peak and baseline VI. Higher \
                amplitude = more vigorous seasonal growth. Green ramp on maps.

                Min (mn): Winter baseline VI. Higher baseline may indicate \
                evergreen vegetation or background soil reflectance.

                Green-up rate (rsp): How quickly vegetation greens up. Higher \
                values = faster transition. Yellow to red on maps.

                Senescence rate (rau): How quickly vegetation senesces. Higher \
                values = faster autumn decline.

                RMSE: Root mean square error of the fit. Lower is better. \
                Green (good) to red (poor) on maps.
                """)
            }
            DisclosureGroup("Assumptions & limitations") {
                helpText("""
                • Single growing season: The model assumes one green-up and one \
                senescence per year. It will not correctly fit double-cropping \
                systems, irrigated perennials, or evergreen forests.

                • Cloud contamination: Despite SCL masking, residual cloud/shadow \
                contamination can bias the fit. The Huber loss and outlier detection \
                help mitigate this.

                • Temporal sampling: Sentinel-2 has a 5-day revisit (2 satellites). \
                With cloud filtering, the actual clear-sky frequency may be \
                10–30 days, which limits the precision of sos/eos estimates.

                • Spatial resolution: At 10m, mixed pixels (field edges, hedgerows) \
                will show intermediate VI values. Per-pixel fitting helps identify \
                these heterogeneous areas.
                """)
            }
            DisclosureGroup("Parameter bounds") {
                helpText("""
                Physical bounds constrain the optimizer to realistic values:
                • mn: −0.5 to 0.8 (allows slightly negative VI from soil)
                • delta: 0.05 to 1.5 (minimum detectable season)
                • sos: 1 to 365 (any day of year)
                • rsp, rau: 0.02 to 0.6 (gentle to very steep transitions)
                • Season length: 30 to 150 days (default, adjustable)
                • Slope symmetry: constrains |rsp − rau| (default 20%)

                Adjust bounds in Settings → Parameter Bounds if your study area \
                has unusual phenology (e.g. tropical, double cropping).
                """)
            }
        }
    }

    // MARK: - Spectral Unmixing

    private var spectralUnmixingSection: some View {
        Section("Spectral Unmixing") {
            DisclosureGroup("What is spectral unmixing?") {
                helpText("""
                Each Sentinel-2 pixel (10m) typically contains a mixture of \
                green vegetation, dry/dead vegetation (litter), and bare soil. \
                Spectral unmixing decomposes the observed reflectance into \
                fractional contributions from these pure materials ("endmembers"):

                observed = a×GreenVeg + b×NPV + c×BareSoil + residual

                where a + b + c = 1 and a, b, c ≥ 0.

                This gives physically meaningful quantities:
                • a (fVeg): Fractional Vegetation Cover (FVC)
                • b (fNPV): Non-Photosynthetic Vegetation (dry matter, litter)
                • c (fSoil): Bare soil fraction
                """)
            }
            DisclosureGroup("Endmember spectra") {
                helpText("""
                Three reference spectra are used, convolved to Sentinel-2 band \
                response functions:

                Green Vegetation: From the 6S radiative transfer code \
                (GroundReflectance.GreenVegetation). Typical canopy at LAI ~3–4. \
                Low visible reflectance, strong red edge, high NIR plateau (0.45), \
                SWIR water absorption dips.

                NPV (Non-Photosynthetic Vegetation): From the USGS Spectral \
                Library (dry grass/crop residue). Moderate, featureless visible \
                reflectance, no red edge, lower NIR (0.26), higher SWIR (cellulose \
                and lignin absorption features).

                Bare Soil: From 6S (GroundReflectance.Sand) / PROSAIL. \
                Monotonically increasing from visible to SWIR, no red edge. \
                Representative of dry sandy/loamy soil.

                These spectra cover 10 S2 bands (B02–B12). Currently the app \
                uses 4 bands (B02, B03, B04, B08) for unmixing — the system is \
                overdetermined (4 bands, 3 endmembers) which is good for stability.
                """)
            }
            DisclosureGroup("Solver: Fully Constrained Least Squares") {
                helpText("""
                The solver finds fractions that minimize the reconstruction error \
                subject to:
                  1. Non-negativity: all fractions ≥ 0
                  2. Sum-to-one: fractions sum to exactly 1.0

                Method: Lagrange multiplier for the sum-to-one constraint \
                (augmented normal equations), followed by iterative projection \
                onto the non-negative simplex.

                RMSE (reconstruction error) indicates how well the 3-endmember \
                model explains the observed spectrum. Low RMSE (< 0.02) means \
                the model is a good fit. High RMSE may indicate:
                • Water, urban, or other non-soil/veg surfaces
                • Cloud or shadow contamination
                • Endmember spectra not representative of the surface
                """)
            }
            DisclosureGroup("Fraction maps & time series") {
                helpText("""
                Select FVC as the vegetation index to use green vegetation fraction \
                as the primary quantity. Unmixing runs automatically. The chart shows \
                median fVeg (observations) with the DL fit curve.

                Fraction maps: Select FVC, NPV, Soil, or Unmix RMSE from the \
                Live menu. These are per-frame animated maps showing how fractions \
                change through the season.

                Fraction time series: fNPV (brown dashed) and fSoil (orange dashed) \
                are overlaid on the chart along with fitted temporal models:
                • fSoil: single decreasing logistic at SOS (soil exposed → vegetation cover)
                • fNPV: single increasing logistic at EOS (green → senesced vegetation)

                The fraction models are derived from the DL fit parameters (SOS, EOS, \
                rsp, rau) — the transition timing and rate are shared with fVeg.

                Second pass: When enabled, the per-pixel fit also derives \
                fraction model parameters for each pixel, giving spatially-resolved \
                soil exposure and senescence timing.
                """)
            }
        }
    }

    // MARK: - SCL

    private var sclSection: some View {
        Section("Scene Classification (SCL)") {
            DisclosureGroup("SCL classes") {
                helpText("""
                ESA's Scene Classification Layer assigns each 20m pixel to one \
                of 12 classes. The app uses SCL to mask unreliable pixels:

                Valid by default:
                  4 — Vegetation (green)
                  5 — Not Vegetated (orange)

                Masked by default:
                  0 — No Data (black)
                  1 — Saturated / Defective (dark red)
                  2 — Dark Area Pixels (dark grey)
                  3 — Cloud Shadows (dark blue)
                  6 — Water (blue)
                  7 — Unclassified (grey)
                  8 — Cloud Medium Probability (white)
                  9 — Cloud High Probability (bright white)
                  10 — Thin Cirrus (light cyan)
                  11 — Snow / Ice (light blue)

                Customise which classes are valid in Settings → SCL Mask. \
                Including class 6 (Water) can be useful for coastal/wetland sites.
                """)
            }
            DisclosureGroup("Masking pipeline") {
                helpText("""
                Pixels are masked (set to NaN) if ANY of these conditions apply:
                1. SCL class not in the valid set
                2. DN value is 0 (nodata) or 65535 (saturated)
                3. Reflectance outside −0.05 to 1.5 (physically implausible)
                4. Pixel is outside the AOI polygon (if "Enforce AOI" is on)
                5. Scene-level cloud fraction exceeds the cloud threshold

                The "Pixel Coverage" slider sets the minimum fraction of valid \
                pixels within the AOI — frames below this threshold are discarded \
                entirely (default 49%).
                """)
            }
        }
    }

    // MARK: - Per-Pixel Fitting

    private var perPixelFittingSection: some View {
        Section("Per-Pixel Phenology") {
            DisclosureGroup("How it works") {
                helpText("""
                After the median (area-level) DL fit, "Per-Pixel" fits a separate \
                double logistic curve to each pixel's time series:

                1. Uses the median fit parameters as the starting point
                2. Runs a small ensemble (default 5 restarts) per pixel
                3. Classifies each pixel's fit quality:
                   • Good: converged, RMSE ≤ threshold (default 0.15)
                   • Poor: converged, RMSE > threshold
                   • Skipped: fewer than minimum observations
                   • Outlier: parameters far from field median (cluster filter)
                """)
            }
            DisclosureGroup("Spatial parameter maps") {
                helpText("""
                After per-pixel fitting, the Live menu shows spatial maps of any \
                DL parameter:
                • SOS: Start of Season (blue=early, red=late)
                • Season: Season length in days
                • Amp: Seasonal amplitude (green ramp)
                • Min: Winter baseline
                • Green-up / Senescence: Transition rates
                • RMSE: Fit quality (green=good, red=poor)
                • Bad Data: Shows skipped/outlier/poor pixels

                These maps reveal within-field variability in phenology — for \
                example, parts of a field that green up earlier or have longer \
                growing seasons.
                """)
            }
            DisclosureGroup("Cluster-based outlier filtering") {
                helpText("""
                The cluster filter identifies pixels with anomalous phenology:

                1. For each DL parameter, compute median and MAD (median absolute \
                deviation) across all good-fit pixels
                2. For each pixel, compute a normalized distance: \
                sqrt(mean(z²)) where z = |param − median| / MAD
                3. Pixels with distance > 4 MADs are flagged as outliers
                4. Spatial rescue: flagged pixels are "rescued" if ≥50% of their \
                neighbors (3×3 window) have good fits — this prevents isolated \
                anomalies from being over-filtered
                5. The median VI is recomputed excluding outliers and the DL \
                curve is re-fitted

                Toggle the cluster filter in Settings → Quality Control.
                """)
            }
            DisclosureGroup("Pixel inspection (long-press)") {
                helpText("""
                Long-press any pixel in the image to inspect it:

                • Orange line: that pixel's VI time series across all frames
                • Cyan dashed line: individual pixel DL fit curve
                • Faint green lines: area max and min VI envelope
                • Green dashed line: area median VI time series
                • Below the chart: pixel's DL parameters and unmixing fractions

                The pixel inspector uses a configurable window (default 1×1). \
                Set window > 1 in Settings to average over a neighborhood (e.g. \
                3×3 = 9 pixels) for smoother time series.
                """)
            }
        }
    }

    // MARK: - Spectral Plot

    private var spectralPlotSection: some View {
        Section("Spectral Plot") {
            DisclosureGroup("Reading the spectral plot") {
                helpText("""
                The spectral plot shows reflectance vs wavelength for the current \
                frame:

                • Red line (Current): reflectance at each available band for the \
                displayed date
                • Green dashed (Peak): spectrum from the highest-NDVI date
                • Blue dashed (Min): spectrum from the lowest-NDVI date
                • Purple dashed (Predicted): reconstructed spectrum from spectral \
                unmixing (if enabled)

                Band labels (B02, B03, B04, B08) are annotated on the current \
                spectrum. The X-axis shows wavelength in nm (490–842nm for the \
                4 default bands).

                When inspecting a pixel, the plot shows that pixel's spectrum \
                instead of the area median.
                """)
            }
            DisclosureGroup("What the spectral shape tells you") {
                helpText("""
                Healthy vegetation: Low blue/red (chlorophyll absorption), \
                sharp rise at ~700nm (red edge), high NIR plateau.

                Dry/stressed vegetation: Higher red reflectance, weaker red edge, \
                lower NIR.

                Bare soil: Monotonically increasing from blue to NIR, no red edge.

                Water: Very low reflectance across all bands.

                Comparing observed vs predicted spectra reveals how well the \
                3-endmember model explains the surface.
                """)
            }
        }
    }

    // MARK: - Crop Calendar

    private var cropCalendarSection: some View {
        Section("Crop Calendar") {
            DisclosureGroup("FAO crop calendar") {
                helpText("""
                The app can query the FAO Crop Calendar API to get typical \
                planting and harvest dates for a given crop and country. This \
                helps set appropriate season constraints for the DL fit.

                Available for ~60 countries and 13 major crops: wheat, maize, \
                rice, soybean, barley, sorghum, cotton, sunflower, potato, \
                sugarcane, chickpea, lentil, groundnut.

                The calendar returns date ranges per agroecological zone (AEZ). \
                The app uses the widest range across all AEZs.
                """)
            }
            DisclosureGroup("Sample crop fields") {
                helpText("""
                The crop region database includes curated field locations from \
                8 regions: US (CDL), EU (EUCROPMAP), South Africa, India, China, \
                Brazil, Australia, and a global mixed set.

                Use these to quickly load a known crop field and set appropriate \
                dates. The app can also auto-query the FAO calendar based on the \
                selected crop and location.
                """)
            }
        }
    }

    // MARK: - DN to Reflectance

    private var dnReflectanceSection: some View {
        Section("DN-to-Reflectance Conversion") {
            DisclosureGroup("How it works") {
                helpText("""
                Sentinel-2 Level-2A data stores surface reflectance as Digital \
                Numbers (DN). The conversion depends on the data source and \
                processing baseline (PB):

                AWS Earth Search:
                  reflectance = DN / 10000
                  (BOA offset applied server-side)

                Planetary Computer / CDSE (PB ≥ 04.00, since Jan 2022):
                  reflectance = (DN − 1000) / 10000
                  (ESA added +1000 offset; app auto-detects PB)

                Planetary Computer / CDSE (PB < 04.00, before Jan 2022):
                  reflectance = DN / 10000

                NASA Earthdata (HLS):
                  reflectance = DN × 0.0001

                Google Earth Engine:
                  reflectance = DN / 10000
                  (harmonized server-side)

                Special DN values:
                  0 = nodata (masked)
                  65535 = saturated (masked)

                The app reads the processing baseline from STAC metadata and \
                applies the correct offset automatically. You can verify this \
                in the activity log.
                """)
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section("Network & Downloads") {
            DisclosureGroup("Download size estimation") {
                helpText("""
                The app estimates download size from:
                • AOI dimensions (width × height in 10m pixels)
                • Number of scenes (from date range or STAC search)
                • Number of bands per scene (3–5 depending on display mode)
                • COG header overhead (~128 KB per scene)
                • Typical compression ratio (~2.5× for S2 reflectance)

                A rough estimate is shown before download. After the STAC search \
                returns the actual scene count, a refined estimate appears in the \
                activity log.

                To reduce download size:
                • Reduce the date range
                • Lower the cloud threshold (skip cloudy scenes)
                • Use a smaller AOI
                • Use NDVI mode (needs fewer bands than FCC/RGB)
                """)
            }
            DisclosureGroup("Cellular data warning") {
                helpText("""
                When you're on cellular data (not WiFi), the app shows a \
                confirmation alert with the estimated download size before \
                proceeding. Options:
                • Download: proceed this time
                • Always Allow: skip future warnings (toggle in Settings)
                • Cancel: abort the download

                You can toggle "Allow Cellular Downloads" in Settings → Network.
                """)
            }
            DisclosureGroup("Concurrent downloads") {
                helpText("""
                The app downloads scenes in parallel using multiple concurrent \
                streams (default 8, configurable in Settings). Each stream \
                independently fetches, decompresses, and processes one scene \
                at a time.

                Reduce concurrency on slow connections to avoid timeouts. \
                Increase on fast connections for faster throughput.
                """)
            }
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            DisclosureGroup("No data found") {
                helpText("""
                • Check the date range — Sentinel-2 data starts from ~2017
                • Ensure at least one data source is enabled
                • Check credentials for authenticated sources (CDSE, Earthdata, GEE)
                • The AOI may be too small or in an area with sparse coverage
                • Try a different source — some sources have occasional outages
                """)
            }
            DisclosureGroup("Poor DL fit (high RMSE)") {
                helpText("""
                • Lower the cloud threshold to exclude cloudy observations
                • Check SCL mask — ensure only valid classes (4, 5) are selected
                • Increase ensemble runs for better optimization
                • Adjust season length bounds if the study area has unusual phenology
                • The site may not follow a single-season pattern (double cropping, \
                evergreen, irrigated)
                • Try fitting to DVI instead of NDVI (less saturation)
                """)
            }
            DisclosureGroup("Blank or noisy image") {
                helpText("""
                • Switch to SCL mode to check cloud/shadow masking
                • Enable "Show Masked Class Colors" to see which pixels are masked \
                and why
                • Check the "Pixel Coverage" percentage — low values mean most \
                pixels are masked
                • Reduce the cloud threshold to skip heavily-clouded scenes
                """)
            }
            DisclosureGroup("Slow downloads") {
                helpText("""
                • Try enabling a different data source (AWS is often fastest)
                • Reduce concurrent downloads if on a slow connection
                • Check if any sources show 403 errors in the log — these may \
                be rate-limited
                • CDSE (JPEG2000) can be slower than COG sources
                """)
            }
        }
    }

    // MARK: - References

    private var referencesSection: some View {
        Section("References") {
            DisclosureGroup("Key references") {
                helpText("""
                Beck, P.S.A. et al. (2006). Improved monitoring of vegetation \
                dynamics at very high latitudes: a new method using MODIS NDVI. \
                Remote Sensing of Environment, 100(3), 321-334.

                Jönsson, P. & Eklundh, L. (2004). TIMESAT — a program for \
                analyzing time-series of satellite sensor data. Computers & \
                Geosciences, 30(8), 833-845.

                Adams, J.B., Smith, M.O. & Johnson, P.E. (1986). Spectral \
                mixture modeling: A new analysis of rock and soil types at the \
                Viking Lander 1 site. Journal of Geophysical Research, 91(B8), \
                8098-8112.

                Vermote, E. et al. (2016). Preliminary analysis of the \
                performance of the Landsat 8/OLI land surface reflectance \
                product. Remote Sensing of Environment, 185, 46-56.

                Main-Knorn, M. et al. (2017). Sen2Cor for Sentinel-2. \
                Proc. SPIE 10427, Image and Signal Processing for Remote Sensing.
                """)
            }
        }
    }

    // MARK: - Helper

    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }
}
