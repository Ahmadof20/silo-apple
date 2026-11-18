#if !os(macOS)
import Foundation
import Observation
import Security

/// Access tokens for Emby and Plex accounts. Kept in this app's own keychain
/// service so they never mix with Silo's token store.
enum MediaServerKeychain {
    private static let service = "org.siloserver.silo.mediaservers"

    static func setToken(_ token: String, for accountId: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func token(for accountId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(for accountId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A stable per-install id both servers use to tell this device apart.
enum MediaServerDevice {
    private static let key = "mediaServers.deviceId"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    static var name: String {
        #if os(tvOS)
        "Apple TV"
        #else
        "iPhone"
        #endif
    }

    static var platform: String {
        #if os(tvOS)
        "tvOS"
        #else
        "iOS"
        #endif
    }

    static let product = "Silo"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

/// The saved Emby and Plex accounts. Records live in UserDefaults; tokens
/// live in the keychain.
@MainActor
@Observable
final class MediaServerStore {
    static let shared = MediaServerStore()

    private static let key = "mediaServers.accounts.v1"

    private(set) var accounts: [MediaServerAccount] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([MediaServerAccount].self, from: data) {
            accounts = decoded
        }
    }

    func add(_ account: MediaServerAccount, token: String) {
        MediaServerKeychain.setToken(token, for: account.id)
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        save()
    }

    func remove(_ account: MediaServerAccount) {
        MediaServerKeychain.deleteToken(for: account.id)
        accounts.removeAll { $0.id == account.id }
        save()
    }

    func client(for account: MediaServerAccount) -> (any MediaServerClient)? {
        guard let token = MediaServerKeychain.token(for: account.id) else { return nil }
        switch account.kind {
        case .emby: return EmbyClient(account: account, token: token)
        case .plex: return PlexClient(account: account, token: token)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
#endif
