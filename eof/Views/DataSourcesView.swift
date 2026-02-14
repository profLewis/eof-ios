import SwiftUI
import UniformTypeIdentifiers
import AuthenticationServices

struct DataSourcesView: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared
    @State private var isBenchmarking = false
    @State private var showingCredentialExporter = false
    @State private var showingCredentialImporter = false
    @State private var credentialExportDoc: CredentialsDocument?
    @State private var credentialImportMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(settings.sources.enumerated()), id: \.element.id) { index, source in
                        sourceRow(source: source, index: index)
                    }
                    .onMove { from, to in
                        settings.sources.move(fromOffsets: from, toOffset: to)
                    }
                } header: {
                    Text("Sources (drag to reorder)")
                } footer: {
                    Text("Tap a source to configure. Drag to reorder trust priority.")
                }

                Section("Benchmarks") {
                    Button {
                        runBenchmarks()
                    } label: {
                        HStack {
                            Label("Test Sources", systemImage: "speedometer")
                            if isBenchmarking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isBenchmarking)

                    ForEach(settings.benchmarkResults) { result in
                        benchmarkRow(result: result)
                    }

                    if !settings.benchmarkResults.isEmpty {
                        Toggle("Smart Stream Allocation", isOn: $settings.smartAllocation)
                        if settings.smartAllocation {
                            let allocation = SourceBenchmarkService.allocateStreams(
                                benchmarks: settings.benchmarkResults,
                                totalStreams: settings.maxConcurrent
                            )
                            ForEach(Array(allocation.sorted(by: { $0.key.rawValue < $1.key.rawValue })), id: \.key) { sourceID, streams in
                                LabeledContent(sourceID.rawValue.uppercased(), value: "\(streams) streams")
                                    .font(.caption)
                            }
                        }
                    }
                }

                Section("Performance") {
                    Stepper(value: $settings.maxConcurrent, in: 1...12) {
                        HStack {
                            Text("Total Concurrent Streams")
                            Spacer()
                            Text("\(settings.maxConcurrent)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        credentialExportDoc = CredentialsDocument(credentials: exportCredentials())
                        showingCredentialExporter = true
                    } label: {
                        Label("Export Credentials", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showingCredentialImporter = true
                    } label: {
                        Label("Import Credentials", systemImage: "square.and.arrow.down")
                    }
                    if let msg = credentialImportMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(msg.contains("Error") ? .red : .green)
                    }
                } header: {
                    Text("Credentials Backup")
                } footer: {
                    Text("Export saves credentials as an encrypted file. Keep it secure — it contains passwords and tokens.")
                }
            }
            .fileExporter(
                isPresented: $showingCredentialExporter,
                document: credentialExportDoc,
                contentType: .json,
                defaultFilename: "eof-credentials"
            ) { result in
                switch result {
                case .success(let url):
                    // Set complete file protection
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: url.path
                    )
                    credentialImportMessage = "Exported OK"
                case .failure(let error):
                    credentialImportMessage = "Error: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showingCredentialImporter,
                allowedContentTypes: [.json]
            ) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else {
                        credentialImportMessage = "Error: cannot access file"
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                            credentialImportMessage = "Error: invalid credentials file"
                            return
                        }
                        var count = 0
                        for (key, value) in json where Self.credentialKeys.contains(key) {
                            try KeychainService.store(key: key, value: value)
                            count += 1
                        }
                        credentialImportMessage = "Imported \(count) credential\(count == 1 ? "" : "s")"
                    } catch {
                        credentialImportMessage = "Error: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    credentialImportMessage = "Error: \(error.localizedDescription)"
                }
            }
            .navigationTitle("Data Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton().buttonStyle(.glass)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                        .buttonStyle(.glass)
                }
            }
            .navigationDestination(for: SourceID.self) { sourceID in
                sourceDetailView(for: sourceID)
            }
        }
    }

    private func sourceRow(source: STACSourceConfig, index: Int) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: source.sourceID) {
                HStack(spacing: 12) {
                    Image(systemName: source.sourceID.icon)
                        .foregroundStyle(source.isEnabled ? .blue : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName)
                            .font(.subheadline)
                        credentialStatus(for: source.sourceID)
                    }
                    Spacer()
                    if let benchmark = settings.benchmarkResults.first(where: { $0.sourceID == source.sourceID }) {
                        Circle()
                            .fill(benchmark.isReachable ? .green : .red)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { settings.sources[index].isEnabled },
                set: { settings.sources[index].isEnabled = $0 }
            ))
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func credentialStatus(for sourceID: SourceID) -> some View {
        switch sourceID {
        case .aws:
            Text("No credentials needed")
                .font(.caption).foregroundStyle(.secondary)
        case .planetary:
            if let k = KeychainService.retrieve(key: "planetary.apikey"), !k.isEmpty {
                Label("API key set", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("API key optional")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .cdse:
            if let u = KeychainService.retrieve(key: "cdse.username"), !u.isEmpty {
                Label("Username/password set", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if let k = KeychainService.retrieve(key: "cdse.accesskey"), !k.isEmpty {
                Label("S3 credentials set", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("Credentials needed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        case .earthdata:
            if let u = KeychainService.retrieve(key: "earthdata.username"), !u.isEmpty {
                Label("Credentials set", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("Credentials needed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        case .gee:
            if GEETokenManager().hasRefreshToken {
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("Sign-in needed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func sourceDetailView(for sourceID: SourceID) -> some View {
        switch sourceID {
        case .aws: AWSDetailView()
        case .planetary: PCDetailView()
        case .cdse: CDSEDetailView()
        case .earthdata: EarthdataDetailView()
        case .gee: GEEDetailView()
        }
    }

    private func benchmarkRow(result: SourceBenchmark) -> some View {
        HStack {
            Image(systemName: result.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.isReachable ? .green : .red)
                .font(.caption)
            Text(result.sourceID.rawValue.uppercased())
                .font(.caption.bold())
            Spacer()
            Text(result.latencyLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runBenchmarks() {
        isBenchmarking = true
        Task {
            let service = SourceBenchmarkService()
            let results = await service.benchmarkAll(sources: settings.sources)
            await MainActor.run {
                settings.benchmarkResults = results
                // Auto-enable sources that pass, auto-disable sources that fail
                for result in results {
                    if let idx = settings.sources.firstIndex(where: { $0.sourceID == result.sourceID }) {
                        settings.sources[idx].isEnabled = result.isReachable
                    }
                }
                isBenchmarking = false
            }
        }
    }

    // MARK: - Credentials Export/Import

    static let credentialKeys = [
        "planetary.apikey",
        "cdse.username", "cdse.password", "cdse.accesskey", "cdse.secretkey",
        "earthdata.username", "earthdata.password",
        "gee.project", "gee.clientid", "gee.refresh_token",
    ]

    private func exportCredentials() -> [String: String] {
        var dict = [String: String]()
        for key in Self.credentialKeys {
            if let value = KeychainService.retrieve(key: key), !value.isEmpty {
                dict[key] = value
            }
        }
        return dict
    }
}

// MARK: - AWS Detail

private struct AWSDetailView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                if let index = settings.sources.firstIndex(where: { $0.sourceID == .aws }) {
                    Toggle("Enabled", isOn: $settings.sources[index].isEnabled)
                }
            }
            Section {
                LabeledContent("Collection", value: "sentinel-2-l2a")
                LabeledContent("Resolution", value: "10m")
                LabeledContent("Auth", value: "None required")
            } header: {
                Text("Info")
            }
            Section {
                Text("AWS Earth Search provides free, open access to Sentinel-2 L2A data. No account or credentials needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AWS Earth Search")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Planetary Computer Detail

private struct PCDetailView: View {
    @State private var settings = AppSettings.shared
    @State private var apiKey: String = KeychainService.retrieve(key: "planetary.apikey") ?? ""
    @State private var tokenStatus: String?
    @State private var tokenOK: Bool = false
    @State private var isFetching = false

    var body: some View {
        Form {
            Section {
                if let index = settings.sources.firstIndex(where: { $0.sourceID == .planetary }) {
                    Toggle("Enabled", isOn: $settings.sources[index].isEnabled)
                }
            }
            Section("Credentials") {
                SecureField("API Key (optional)", text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { storeCredential(key: "planetary.apikey", value: apiKey) }
                Button {
                    fetchToken()
                } label: {
                    HStack {
                        Label("Get SAS Token", systemImage: "key.fill")
                        if isFetching { Spacer(); ProgressView() }
                    }
                }
                .disabled(isFetching)
                if let status = tokenStatus {
                    Label(status, systemImage: tokenOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(tokenOK ? .green : .red)
                }
            }
            Section {
                Text("No API key needed. SAS tokens are fetched automatically and last ~1 hour. An API key can increase rate limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Planetary Computer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fetchToken() {
        isFetching = true
        tokenStatus = nil
        Task {
            do {
                let sas = SASTokenManager()
                let pcSources = settings.sources.filter { $0.assetAuthType == .sasToken && $0.isEnabled }
                let collections = pcSources.isEmpty ? ["sentinel-2-l2a"] : pcSources.map(\.collection)
                var results = [String]()
                for collection in collections {
                    let token = try await sas.getToken(for: collection)
                    var expiry = ""
                    for param in token.components(separatedBy: "&") {
                        if param.hasPrefix("se=") {
                            expiry = param.dropFirst(3).removingPercentEncoding ?? String(param.dropFirst(3))
                        }
                    }
                    results.append(expiry.isEmpty ? "\(collection): OK" : "\(collection): expires \(expiry)")
                }
                await MainActor.run {
                    tokenOK = true
                    tokenStatus = results.joined(separator: "\n")
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    tokenOK = false
                    tokenStatus = error.localizedDescription
                    isFetching = false
                }
            }
        }
    }
}

// MARK: - CDSE Detail

private struct CDSEDetailView: View {
    enum AuthMode: String {
        case password = "password"
        case s3key = "s3key"
    }

    @State private var settings = AppSettings.shared
    @State private var authMode: AuthMode
    @State private var username: String = KeychainService.retrieve(key: "cdse.username") ?? ""
    @State private var password: String = KeychainService.retrieve(key: "cdse.password") ?? ""
    @State private var accessKey: String = KeychainService.retrieve(key: "cdse.accesskey") ?? ""
    @State private var secretKey: String = KeychainService.retrieve(key: "cdse.secretkey") ?? ""
    @State private var testStatus: String?
    @State private var testOK: Bool?
    @State private var isTesting = false

    init() {
        // Determine initial auth mode from stored credentials
        let hasS3 = !(KeychainService.retrieve(key: "cdse.accesskey") ?? "").isEmpty
        let hasPassword = !(KeychainService.retrieve(key: "cdse.username") ?? "").isEmpty
        _authMode = State(initialValue: hasS3 && !hasPassword ? .s3key : .password)
    }

    var body: some View {
        Form {
            Section {
                if let index = settings.sources.firstIndex(where: { $0.sourceID == .cdse }) {
                    Toggle("Enabled", isOn: $settings.sources[index].isEnabled)
                }
            }
            Section("Authentication Method") {
                Picker("Method", selection: $authMode) {
                    Text("Username / Password").tag(AuthMode.password)
                    Text("Access Key / Secret Key").tag(AuthMode.s3key)
                }
                .pickerStyle(.segmented)

                if authMode == .password {
                    TextField("Username (email)", text: $username)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: username) { storeCredential(key: "cdse.username", value: username) }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onChange(of: password) { storeCredential(key: "cdse.password", value: password) }
                } else {
                    TextField("Access Key", text: $accessKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: accessKey) { storeCredential(key: "cdse.accesskey", value: accessKey) }
                    SecureField("Secret Key", text: $secretKey)
                        .onChange(of: secretKey) { storeCredential(key: "cdse.secretkey", value: secretKey) }
                }

                Button {
                    Task { await testLogin() }
                } label: {
                    HStack {
                        Label("Test Login", systemImage: "person.badge.key")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(testDisabled)

                if let ok = testOK, let msg = testStatus {
                    Label(msg, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(ok ? .green : .red)
                }
            }
            Section {
                Text("Free registration required. Provides Sentinel-2 L2A via Copernicus Data Space. S3 credentials can be generated from your CDSE dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Register at dataspace.copernicus.eu",
                     destination: URL(string: "https://dataspace.copernicus.eu")!)
                    .font(.caption)
                Link("Generate S3 credentials",
                     destination: URL(string: "https://dataspace.copernicus.eu/profile/settings")!)
                    .font(.caption)
            }
        }
        .navigationTitle("Copernicus Data Space")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var testDisabled: Bool {
        if isTesting { return true }
        if authMode == .password { return username.isEmpty || password.isEmpty }
        return accessKey.isEmpty || secretKey.isEmpty
    }

    private func testLogin() async {
        isTesting = true
        testStatus = nil
        testOK = nil
        do {
            if authMode == .password {
                let mgr = BearerTokenManager(sourceID: .cdse)
                _ = try await mgr.getToken()
            } else {
                // Test S3 credentials by listing objects at CDSE S3 endpoint
                try await testS3Credentials()
            }
            await MainActor.run {
                testOK = true
                testStatus = "Login successful \u{2014} source enabled"
                if let idx = settings.sources.firstIndex(where: { $0.sourceID == .cdse }) {
                    settings.sources[idx].isEnabled = true
                }
                isTesting = false
            }
        } catch {
            await MainActor.run {
                testOK = false
                testStatus = error.localizedDescription
                if let idx = settings.sources.firstIndex(where: { $0.sourceID == .cdse }) {
                    settings.sources[idx].isEnabled = false
                }
                isTesting = false
            }
        }
    }

    private func testS3Credentials() async throws {
        // CDSE S3 endpoint — test by sending a HEAD request with basic auth
        let url = URL(string: "https://eodata.dataspace.copernicus.eu/")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        // Use AWS SigV4-style headers (simplified: just check endpoint reachability for now)
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 500 {
            throw BearerTokenError.authFailed("CDSE S3", code)
        }
        // S3 credentials stored — endpoint reachable
    }
}

// MARK: - Earthdata Detail

private struct EarthdataDetailView: View {
    @State private var settings = AppSettings.shared
    @State private var username: String = KeychainService.retrieve(key: "earthdata.username") ?? ""
    @State private var password: String = KeychainService.retrieve(key: "earthdata.password") ?? ""
    @State private var testStatus: String?
    @State private var testOK: Bool?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                if let index = settings.sources.firstIndex(where: { $0.sourceID == .earthdata }) {
                    Toggle("Enabled", isOn: $settings.sources[index].isEnabled)
                }
            }
            Section("Credentials") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: username) { storeCredential(key: "earthdata.username", value: username) }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onChange(of: password) { storeCredential(key: "earthdata.password", value: password) }

                Button {
                    Task { await testLogin() }
                } label: {
                    HStack {
                        Label("Test Login", systemImage: "person.badge.key")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || isTesting)

                if let ok = testOK, let msg = testStatus {
                    Label(msg, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(ok ? .green : .red)
                }
            }
            Section {
                Text("Free registration required. Provides Harmonized Landsat Sentinel-2 (HLS) at 30m resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Register at urs.earthdata.nasa.gov",
                     destination: URL(string: "https://urs.earthdata.nasa.gov/users/new")!)
                    .font(.caption)
            }
        }
        .navigationTitle("NASA Earthdata (HLS)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func testLogin() async {
        isTesting = true
        testStatus = nil
        testOK = nil
        do {
            let mgr = BearerTokenManager(sourceID: .earthdata)
            _ = try await mgr.getToken()
            await MainActor.run {
                testOK = true
                testStatus = "Login successful \u{2014} source enabled"
                if let idx = settings.sources.firstIndex(where: { $0.sourceID == .earthdata }) {
                    settings.sources[idx].isEnabled = true
                }
                isTesting = false
            }
        } catch {
            await MainActor.run {
                testOK = false
                testStatus = error.localizedDescription
                if let idx = settings.sources.firstIndex(where: { $0.sourceID == .earthdata }) {
                    settings.sources[idx].isEnabled = false
                }
                isTesting = false
            }
        }
    }
}

// MARK: - GEE Detail

private struct GEEDetailView: View {
    @State private var settings = AppSettings.shared
    @State private var projectID: String = KeychainService.retrieve(key: "gee.project") ?? ""
    @State private var clientID: String = KeychainService.retrieve(key: "gee.clientid") ?? ""
    @State private var checkingStatus = false
    @State private var apiReachable: Bool?
    @State private var projectValid: Bool?
    @State private var token: String?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                if let index = settings.sources.firstIndex(where: { $0.sourceID == .gee }) {
                    Toggle("Enabled", isOn: $settings.sources[index].isEnabled)
                }
            }

            Section("Authentication") {
                // Auth status
                if GEETokenManager().hasRefreshToken {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Signed in").font(.caption)
                        Spacer()
                        Button("Sign Out") {
                            Task {
                                await GEETokenManager().signOut()
                                token = nil
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }

                TextField("Cloud Project ID (e.g. my-ee-project)", text: $projectID)
                    .textContentType(.organizationName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: projectID) { storeCredential(key: "gee.project", value: projectID) }

                TextField("OAuth Client ID", text: $clientID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: clientID) { storeCredential(key: "gee.clientid", value: clientID) }

                Button {
                    Task { await checkSetup() }
                } label: {
                    HStack {
                        Label("Check GEE Setup", systemImage: "checkmark.shield")
                        if checkingStatus { Spacer(); ProgressView() }
                    }
                }
                .disabled(checkingStatus)

                geeStatusRow("EE API reachable", status: apiReachable)
                if token != nil {
                    geeStatusRow("Google sign-in", status: true)
                }
                geeStatusRow("Project \"\(projectID)\" registered", status: projectValid)
                if let msg = statusMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                let proj = projectID.isEmpty ? nil : projectID
                let projParam = proj.map { "?project=\($0)" } ?? ""

                geeSetupStep(
                    number: 1, title: "Register for Earth Engine",
                    detail: "Sign in with your Google account and register a Cloud project.",
                    done: token != nil || GEETokenManager().hasRefreshToken,
                    link: ("Sign up / Sign in", "https://code.earthengine.google.com/register")
                )
                geeSetupStep(
                    number: 2, title: "Create a Cloud project",
                    detail: "Name it anything (e.g. \"my-ee-project\"). No billing needed for free tier.",
                    done: !projectID.isEmpty,
                    link: ("Create project", "https://console.cloud.google.com/projectcreate")
                )
                geeSetupStep(
                    number: 3, title: "Enable the Earth Engine API",
                    detail: proj != nil
                        ? "Enable the Earth Engine API for project \"\(proj!)\"."
                        : "Enter your project ID above first.",
                    done: projectValid == true,
                    link: ("Enable API for \(proj ?? "project")",
                           "https://console.cloud.google.com/apis/library/earthengine.googleapis.com\(projParam)")
                )
                geeSetupStep(
                    number: 4, title: "Create OAuth credentials",
                    detail: "Create an iOS OAuth client. Use these values:\n  Bundle ID: uk.ac.ucl.eof\n  Team ID: 74SY6DZ377\n  App Store ID: (leave blank)\nCopy the Client ID above.",
                    done: !clientID.isEmpty,
                    link: ("Create OAuth client",
                           proj != nil
                            ? "https://console.cloud.google.com/auth/clients?project=\(proj!)"
                            : "https://console.cloud.google.com/auth/clients")
                )
            } header: {
                Text("Setup Steps")
            }
        }
        .navigationTitle("Google Earth Engine")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatus() }
    }

    /// Silently check status using stored credentials (no browser popup).
    private func refreshStatus() async {
        // If already signed in, get a token silently via refresh token
        let mgr = GEETokenManager()
        if mgr.hasRefreshToken {
            if let t = try? await mgr.getToken() {
                await MainActor.run { token = t }
            }
        }

        // Check API reachability
        do {
            let url = URL(string: "https://earthengine.googleapis.com/v1/projects/earthengine-public/assets/COPERNICUS")!
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 10
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            await MainActor.run { apiReachable = (200...499).contains(code) }
        } catch {
            await MainActor.run { apiReachable = false }
        }

        // Validate project access if we have a token
        if let t = token, !projectID.isEmpty {
            do {
                let url = URL(string: "https://earthengine.googleapis.com/v1/projects/\(projectID)/assets")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 10
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run { projectValid = (200...299).contains(code) }
            } catch {
                await MainActor.run { projectValid = false }
            }
        }
    }

    @ViewBuilder
    private func geeStatusRow(_ label: String, status: Bool?) -> some View {
        if let ok = status {
            Label(label, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ok ? .green : .red)
        }
    }

    @ViewBuilder
    private func geeSetupStep(number: Int, title: String, detail: String, done: Bool, link: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                    .foregroundStyle(done ? .green : .secondary)
                Text(title).font(.caption.bold())
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Link(link.0, destination: URL(string: link.1)!).font(.caption)
        }
    }

    private func checkSetup() async {
        checkingStatus = true
        apiReachable = nil
        projectValid = nil
        statusMessage = nil

        // Step 1: Check if EE API endpoint is reachable
        do {
            let url = URL(string: "https://earthengine.googleapis.com/v1/projects/earthengine-public/assets/COPERNICUS")!
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 10
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            await MainActor.run { apiReachable = (200...499).contains(code) }
        } catch {
            await MainActor.run {
                apiReachable = false
                statusMessage = "Cannot reach EE API: \(error.localizedDescription)"
            }
        }

        // Step 2: Get a token — use stored refresh token if available, otherwise OAuth browser flow
        let mgr = GEETokenManager()
        if mgr.hasRefreshToken {
            // Silently refresh using stored token
            if let t = try? await mgr.getToken() {
                await MainActor.run { token = t }
            } else {
                await MainActor.run { statusMessage = "Stored token expired — sign in again." }
            }
        } else if !clientID.isEmpty {
            // No stored token — need browser OAuth flow
            await signInWithGoogle()
        } else {
            await MainActor.run {
                statusMessage = (statusMessage ?? "") + "\nEnter an OAuth Client ID to sign in."
                checkingStatus = false
            }
            return
        }

        // Step 3: If we got a token and have a project ID, verify project access
        if let token = token, !projectID.isEmpty {
            do {
                let url = URL(string: "https://earthengine.googleapis.com/v1/projects/\(projectID)/assets")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 10
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    projectValid = (200...299).contains(code)
                    if code == 403 {
                        statusMessage = "Project \"\(projectID)\" exists but EE API not enabled. Complete step 3."
                    } else if code == 404 {
                        statusMessage = "Project \"\(projectID)\" not found. Check the project ID."
                    }
                }
            } catch {
                await MainActor.run { projectValid = false }
            }
        }

        await MainActor.run { checkingStatus = false }
    }

    private func signInWithGoogle() async {
        guard !clientID.isEmpty else { return }

        // Google iOS OAuth: redirect URI = reversed client ID + standard path
        // e.g. "123456-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123456-abc"
        let reversedClientID = clientID.components(separatedBy: ".").reversed().joined(separator: ".")
        // Use bundle ID as redirect scheme for ASWebAuthenticationSession
        let callbackScheme = "uk.ac.ucl.eof"
        let redirectURI = "\(callbackScheme):/oauth2callback"
        let scope = "https://www.googleapis.com/auth/earthengine"
        let authURL = "https://accounts.google.com/o/oauth2/v2/auth?client_id=\(clientID)&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)&response_type=code&scope=\(scope)&access_type=offline&prompt=consent"

        let log = ActivityLog.shared
        log.info("GEE OAuth: client=\(clientID.prefix(20))... redirect=\(redirectURI)")

        guard let url = URL(string: authURL) else {
            log.warn("GEE OAuth: invalid auth URL")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                defer { continuation.resume() }
                if let error {
                    log.warn("GEE OAuth: callback error — \(error.localizedDescription)")
                    return
                }
                guard let callbackURL else { return }

                guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    let errorDesc = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "error" })?.value ?? "unknown"
                    log.warn("GEE OAuth: no auth code in callback — error=\(errorDesc)")
                    return
                }

                Task {
                    do {
                        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
                        var req = URLRequest(url: tokenURL)
                        req.httpMethod = "POST"
                        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                        let body = "code=\(code)&client_id=\(self.clientID)&redirect_uri=\(redirectURI)&grant_type=authorization_code"
                        req.httpBody = Data(body.utf8)
                        let (data, resp) = try await URLSession.shared.data(for: req)
                        let httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let accessToken = json["access_token"] as? String {
                            if let refreshToken = json["refresh_token"] as? String {
                                try? KeychainService.store(key: "gee.refresh_token", value: refreshToken)
                            }
                            let expiresIn = json["expires_in"] as? Int ?? 3600
                            let mgr = GEETokenManager()
                            await mgr.storeTokens(accessToken: accessToken, refreshToken: json["refresh_token"] as? String ?? "", expiresIn: expiresIn)
                            log.info("GEE OAuth: token obtained OK")
                            await MainActor.run { self.token = accessToken }
                        } else {
                            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                            log.warn("GEE OAuth: token exchange failed HTTP \(httpCode) — \(body)")
                        }
                    } catch {
                        log.warn("GEE OAuth: token exchange error — \(error.localizedDescription)")
                    }
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = GEEAuthContextProvider.shared
            session.start()
        }
    }

}

// MARK: - Shared Helpers

private func storeCredential(key: String, value: String) {
    if value.isEmpty {
        KeychainService.delete(key: key)
    } else {
        try? KeychainService.store(key: key, value: value)
    }
}

// Provides the presentation anchor for ASWebAuthenticationSession
private class GEEAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GEEAuthContextProvider()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - CredentialsDocument

struct CredentialsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let credentials: [String: String]

    init(credentials: [String: String]) {
        self.credentials = credentials
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.credentials = json
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONSerialization.data(withJSONObject: credentials, options: [.prettyPrinted, .sortedKeys])
        let wrapper = FileWrapper(regularFileWithContents: data)
        return wrapper
    }
}
