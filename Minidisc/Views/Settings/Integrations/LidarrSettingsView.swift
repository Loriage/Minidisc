// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import OSLog

/// Connects Minidisc to a Lidarr instance. Lidarr manages a music collection and downloads new
/// releases. This first version tests and stores the connection, and shows the instance status.
struct LidarrSettingsView: View {
    @Environment(\.appContainer) private var container

    @State private var urlInput = ""
    @State private var apiKeyInput = ""
    @State private var headerRows: [CustomHeaderEntry] = []
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var status: LidarrSystemStatus?
    @State private var artistCount: Int?
    @State private var showDisconnectAlert = false
    @State private var didLoad = false

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

    private var settings: LidarrSettings? { container?.lidarrSettings }
    private var isConnected: Bool { settings?.isConnected == true }

    var body: some View {
        Form {
            aboutSection
            connectionSection
            headersSection
            if isConnected {
                statusSection
            }
        }
        .navigationTitle("Lidarr")
        .navigationBarTitleDisplayModeInline()
        .task {
            guard !didLoad else { return }
            didLoad = true
            urlInput = settings?.baseURL ?? ""
            if let creds = await settings?.currentCredentials() {
                apiKeyInput = creds.apiKey
                headerRows = creds.headers.map { CustomHeaderEntry(key: $0.key, value: $0.value) }
            }
            if isConnected { await refreshStatus() }
        }
    }

    // MARK: - Sections

    private var aboutSection: some View {
        Section {
            Text("Lidarr manages your music collection and downloads new releases for you. Connect it to check its status from Minidisc.")
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)
            Link("Learn about Lidarr →", destination: URL(string: "https://lidarr.audio")!)
                .font(.minidiscCaption)
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("", text: $urlInput, prompt: Text(verbatim: "http://nas.local:8686"))
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            SecureField("API key", text: $apiKeyInput)
                .textContentType(.password)
                .autocorrectionDisabled()

            Button {
                Task { await testAndSave() }
            } label: {
                HStack {
                    Text(isConnected ? "Test and Update" : "Connect")
                    if isTesting {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!canConnect || isTesting)

            if let testResult {
                switch testResult {
                case .success:
                    Label("Connected.", systemImage: "checkmark.circle")
                        .font(.minidiscCaption)
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.minidiscCaption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Instance")
        } footer: {
            Text("Find the API key in Lidarr under Settings, then General.")
        }
    }

    private var headersSection: some View {
        Section {
            DisclosureGroup("Custom Headers") {
                ForEach($headerRows) { $row in
                    CustomHeaderRowView(
                        key: $row.key,
                        value: $row.value,
                        onRemove: { headerRows.removeAll { $0.id == row.id } }
                    )
                }
                Button {
                    headerRows.append(CustomHeaderEntry())
                } label: {
                    Label("Add Header", systemImage: "plus")
                }
            }
        } footer: {
            Text("Optional headers sent with every request. Use them if Lidarr is behind a reverse proxy, for example Cloudflare Access or Authelia.")
        }
    }

    private var statusSection: some View {
        Section {
            if let status {
                LabeledContent("Version") { Text(status.version) }
                if let name = status.instanceName, !name.isEmpty {
                    LabeledContent("Instance") { Text(name) }
                }
            }
            LabeledContent("Artists") {
                if let artistCount {
                    Text("\(artistCount)").monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            Button("Disconnect", role: .destructive) { showDisconnectAlert = true }
        } header: {
            Text("Status")
        }
        .alert("Disconnect Lidarr?", isPresented: $showDisconnectAlert) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Minidisc forgets the address and the API key. Your Lidarr instance is not changed.")
        }
    }

    // MARK: - Helpers

    private var canConnect: Bool {
        !urlInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    /// Tests the connection, and saves it only after a good round-trip, so a typo cannot store a
    /// connection that does not work.
    private func testAndSave() async {
        guard let settings else { return }
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = headersDict()
        guard let client = LidarrClient(urlString: url, apiKey: key, headers: headers) else {
            testResult = .failure(String(localized: "That does not look like a valid address."))
            return
        }

        do {
            let fetchedStatus = try await client.systemStatus()
            let fetchedCount = (try? await client.artistCount())
            try await settings.connect(baseURL: url, apiKey: key, headers: headers)
            status = fetchedStatus
            artistCount = fetchedCount
            testResult = .success
        } catch let error as LidarrError {
            Logger.integrations.warning("[LIDARR-TEST] failed: \(String(describing: error), privacy: .public)")
            testResult = .failure(message(for: error))
        } catch {
            Logger.integrations.warning("[LIDARR-TEST] failed: \(error, privacy: .public)")
            testResult = .failure(error.localizedDescription)
        }
    }

    private func refreshStatus() async {
        guard let client = await settings?.makeClient() else { return }
        status = try? await client.systemStatus()
        artistCount = try? await client.artistCount()
    }

    private func disconnect() async {
        await settings?.disconnect()
        apiKeyInput = ""
        headerRows = []
        status = nil
        artistCount = nil
        testResult = nil
    }

    /// Non-empty, valid header rows as a dictionary.
    private func headersDict() -> [String: String] {
        var result: [String: String] = [:]
        for row in headerRows {
            let name = row.key.trimmingCharacters(in: .whitespaces)
            let value = row.value.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty,
                  HeaderValidator.isValidName(name), HeaderValidator.isValidValue(value) else { continue }
            result[name] = value
        }
        return result
    }

    private func message(for error: LidarrError) -> String {
        switch error {
        case .unauthorized:
            return String(localized: "The API key was rejected.")
        case .htmlResponse:
            return String(localized: "The server returned a web page, not Lidarr data. A reverse proxy is probably blocking the request. Add its headers under Custom Headers.")
        case .cancelled:
            return String(localized: "The request was cancelled.")
        case .badURL:
            return String(localized: "That does not look like a valid address.")
        case .transport(let detail), .decoding(let detail):
            return detail
        }
    }
}
