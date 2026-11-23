#if !os(macOS)
import SwiftUI

enum MSRoute: Hashable {
    case account(MediaServerAccount)
    case library(MediaServerAccount, MSLibrary)
    case item(MediaServerAccount, MSItem)
    case search(MediaServerAccount)
    case addEmby
    case addPlex
    case addIPTV
}

/// What the player cover is showing.
struct MSPlayRequest: Identifiable {
    let id = UUID()
    let account: MediaServerAccount
    let item: MSItem
    let resume: Bool
}

/// Presents the server hub full screen; used by both sign-in pages so
/// Emby, Plex, and IPTV are added from the same place as the Silo server.
struct MSOtherServersCover: ViewModifier {
    @Binding var isPresented: Bool

    static let buttonTitle = "اشتراكات أخرى: Emby · Plex · IPTV"

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            MediaServersHubView()
        }
    }
}

/// Entry to the Emby & Plex section: saved accounts and the two add buttons.
/// Presented full screen from server setup and from Settings.
struct MediaServersHubView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = MediaServerStore.shared
    @State private var path: [MSRoute] = []
    @State private var accountToRemove: MediaServerAccount?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !store.accounts.isEmpty {
                    Section("Your servers") {
                        ForEach(store.accounts) { account in
                            NavigationLink(value: MSRoute.account(account)) {
                                accountRow(account)
                            }
                            .contextMenu {
                                Button("Remove", role: .destructive) { accountToRemove = account }
                            }
                        }
                        #if os(iOS)
                        .onDelete { offsets in
                            for index in offsets { store.remove(store.accounts[index]) }
                        }
                        #endif
                    }
                }

                Section {
                    NavigationLink(value: MSRoute.addEmby) {
                        Label("Add Emby or Jellyfin server", systemImage: MediaServerKind.emby.systemImage)
                    }
                    NavigationLink(value: MSRoute.addPlex) {
                        Label("Add Plex server", systemImage: MediaServerKind.plex.systemImage)
                    }
                    NavigationLink(value: MSRoute.addIPTV) {
                        Label("Add IPTV subscription (Xtream)", systemImage: MediaServerKind.iptv.systemImage)
                    }
                    NavigationLink {
                        MSAISettingsView()
                    } label: {
                        Label("AI translation keys (OpenAI · Claude · DeepSeek)", systemImage: "translate")
                    }
                } header: {
                    Text("Add a server")
                } footer: {
                    Text("Emby and Jellyfin sign in with a server address and your username. Plex signs in with your plex.tv account.")
                }
            }
            .navigationTitle("Emby · Plex · IPTV")
            .msScreen()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                #endif
            }
            .navigationDestination(for: MSRoute.self) { route in
                destination(route)
            }
            .confirmationDialog(
                "Remove this server?",
                isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
                presenting: accountToRemove
            ) { account in
                Button("Remove \(account.serverName)", role: .destructive) { store.remove(account) }
            }
        }
    }

    private func accountRow(_ account: MediaServerAccount) -> some View {
        HStack(spacing: 14) {
            Image(systemName: account.kind.systemImage)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.serverName).font(.headline)
                Text([account.kind.displayName, account.username].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func destination(_ route: MSRoute) -> some View {
        switch route {
        case .addEmby:
            MSAddEmbyView { account in
                path = [.account(account)]
            }
        case .addPlex:
            MSAddPlexView { account in
                path = [.account(account)]
            }
        case .addIPTV:
            MSAddIPTVView { account in
                path = [.account(account)]
            }
        case .account(let account):
            if let client = store.client(for: account) {
                MSAccountHomeView(client: client)
            } else {
                MSMissingTokenView(account: account)
            }
        case .library(let account, let library):
            if let client = store.client(for: account) {
                MSLibraryView(client: client, library: library)
            }
        case .item(let account, let item):
            if let client = store.client(for: account) {
                #if os(tvOS)
                TVMSDetailView(client: client, item: item)
                #else
                MSItemDetailView(client: client, item: item)
                #endif
            }
        case .search(let account):
            if let client = store.client(for: account) {
                MSSearchView(client: client)
            }
        }
    }
}

/// Shown when the keychain lost a token (for example after a restore to a
/// new device): the account has to be added again.
private struct MSMissingTokenView: View {
    let account: MediaServerAccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("Sign in to \(account.serverName) again.")
                .font(.headline)
            Button("Remove and add again") {
                MediaServerStore.shared.remove(account)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}
#endif
