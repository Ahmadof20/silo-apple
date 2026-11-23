#if !os(macOS)
import SwiftUI

// MARK: - IPTV (Xtream Codes)

struct MSAddIPTVView: View {
    let onAdded: (MediaServerAccount) -> Void

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $address, prompt: Text("http://provider.example:8080"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: address) { _, value in fillFromLink(value) }
            } header: {
                Text("Server")
            } footer: {
                Text("Paste the whole M3U link from your provider (get.php?username=…&password=…) and the fields fill in.")
            }

            Section("Account") {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $password)
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Text(isConnecting ? "Connecting…" : "Sign In")
                        if isConnecting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isConnecting || address.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .navigationTitle("IPTV")
        .msScreen()
    }

    /// An M3U or player_api link carries the username and password.
    private func fillFromLink(_ value: String) {
        guard value.contains("username="), let components = URLComponents(string: value) else { return }
        let items = components.queryItems ?? []
        if let user = items.first(where: { $0.name == "username" })?.value, !user.isEmpty { username = user }
        if let pass = items.first(where: { $0.name == "password" })?.value, !pass.isEmpty { password = pass }
        var root = components
        root.path = ""
        root.query = nil
        if let base = root.url?.absoluteString, base != value { address = base }
    }

    private func connect() {
        isConnecting = true
        error = nil
        Task {
            do {
                let (account, token) = try await IPTVClient.signIn(address: address, username: username, password: password)
                MediaServerStore.shared.add(account, token: token)
                isConnecting = false
                onAdded(account)
            } catch {
                self.error = error.msMessage
                isConnecting = false
            }
        }
    }
}

// MARK: - Emby / Jellyfin

struct MSAddEmbyView: View {
    let onAdded: (MediaServerAccount) -> Void

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $address, prompt: Text("192.168.1.10:8096 or emby.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("Server")
            } footer: {
                Text("Without a port, 8096 is used for http. Type https:// for a secure address.")
            }

            Section("Account") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Text(isConnecting ? "Connecting…" : "Sign In")
                        if isConnecting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isConnecting || address.isEmpty || username.isEmpty)
            }
        }
        .navigationTitle("Emby / Jellyfin")
        .msScreen()
    }

    private func connect() {
        isConnecting = true
        error = nil
        Task {
            do {
                let (account, token) = try await EmbyClient.signIn(address: address, username: username, password: password)
                MediaServerStore.shared.add(account, token: token)
                isConnecting = false
                onAdded(account)
            } catch {
                self.error = error.msMessage
                isConnecting = false
            }
        }
    }
}

// MARK: - Plex

struct MSAddPlexView: View {
    let onAdded: (MediaServerAccount) -> Void

    private enum Phase {
        case starting
        case waiting(PlexClient.Pin)
        case loadingServers
        case pickServer([MSPlexServerChoice], accountToken: String, user: PlexClient.PlexUser)
        case connecting(String)
    }

    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .starting
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var manualAddress = ""
    @State private var manualToken = ""
    @State private var showsManual = false

    var body: some View {
        Form {
            signInSection

            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Start Over") { startPin() }
                }
            }

            Section {
                Toggle("Connect with address and token", isOn: $showsManual)
                if showsManual {
                    TextField("Server address", text: $manualAddress, prompt: Text("192.168.1.10:32400"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("X-Plex-Token", text: $manualToken)
                    Button("Connect") { connectManually() }
                        .disabled(manualAddress.isEmpty || manualToken.isEmpty)
                }
            } footer: {
                Text("Use this for a server that isn't linked to a plex.tv account.")
            }
        }
        .navigationTitle("Plex")
        .msScreen()
        .onAppear { if case .starting = phase { startPin() } }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var signInSection: some View {
        switch phase {
        case .starting:
            Section { HStack { ProgressView(); Text("Getting a sign-in code…") } }

        case .waiting(let pin):
            Section {
                #if os(tvOS)
                VStack(alignment: .leading, spacing: 18) {
                    Text("On your phone or computer, open")
                    Text("plex.tv/link").font(.title2.bold())
                    Text("and enter this code:")
                    Text(pin.code)
                        .font(.system(size: 64, weight: .heavy, design: .monospaced))
                        .kerning(8)
                }
                .padding(.vertical, 10)
                #else
                Text("Sign in with your Plex account in the browser, then come back here. This screen continues by itself.")
                Button {
                    if let url = PlexClient.authURL(for: pin) { openURL(url) }
                } label: {
                    Label("Sign in with Plex", systemImage: "person.crop.circle.badge.checkmark")
                }
                #endif
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for approval…").foregroundStyle(.secondary)
                }
            } header: {
                Text("Sign in")
            }

        case .loadingServers:
            Section { HStack { ProgressView(); Text("Finding your servers…") } }

        case .pickServer(let servers, let accountToken, let user):
            Section {
                ForEach(servers) { server in
                    Button {
                        choose(server, accountToken: accountToken, user: user)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.name).font(.headline)
                                Text(server.owned ? "Your server" : "Shared with you")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Choose a server")
            }

        case .connecting(let name):
            Section { HStack { ProgressView(); Text("Connecting to \(name)…") } }
        }
    }

    private func startPin() {
        pollTask?.cancel()
        error = nil
        phase = .starting
        pollTask = Task {
            do {
                #if os(tvOS)
                let pin = try await PlexClient.createPin(strong: false)
                #else
                let pin = try await PlexClient.createPin(strong: true)
                #endif
                phase = .waiting(pin)
                // PINs live about 15 minutes; poll every 2 seconds.
                for _ in 0..<450 {
                    try await Task.sleep(for: .seconds(2))
                    if let token = try await PlexClient.checkPin(pin) {
                        await loadServers(accountToken: token)
                        return
                    }
                }
                throw MediaServerError.pinExpired
            } catch is CancellationError {
                return
            } catch {
                self.error = error.msMessage
            }
        }
    }

    private func loadServers(accountToken: String) async {
        phase = .loadingServers
        do {
            async let user = PlexClient.user(accountToken: accountToken)
            async let servers = PlexClient.servers(accountToken: accountToken)
            let (u, s) = try await (user, servers)
            guard !s.isEmpty else { throw MediaServerError.noServers }
            if s.count == 1 {
                choose(s[0], accountToken: accountToken, user: u)
            } else {
                phase = .pickServer(s.sorted { $0.owned && !$1.owned }, accountToken: accountToken, user: u)
            }
        } catch {
            self.error = error.msMessage
        }
    }

    private func choose(_ server: MSPlexServerChoice, accountToken: String, user: PlexClient.PlexUser) {
        phase = .connecting(server.name)
        error = nil
        Task {
            do {
                let base = try await PlexClient.bestConnection(for: server)
                let account = PlexClient.makeAccount(server: server, baseURL: base, user: user)
                MediaServerStore.shared.add(account, token: server.accessToken)
                onAdded(account)
            } catch {
                self.error = error.msMessage
            }
        }
    }

    private func connectManually() {
        error = nil
        let address = manualAddress, token = manualToken
        Task {
            do {
                let account = try await PlexClient.connectManually(address: address, token: token)
                MediaServerStore.shared.add(account, token: token)
                onAdded(account)
            } catch {
                self.error = error.msMessage
            }
        }
    }
}
#endif
