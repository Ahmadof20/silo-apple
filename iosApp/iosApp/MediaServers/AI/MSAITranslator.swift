#if !os(macOS)
import Foundation
import Security

/// The AI services a person can bring their own API key for. They translate
/// descriptions and subtitles of Emby, Plex, and IPTV titles; Silo titles
/// keep using the Silo server's own AI translation.
enum MSAIProvider: String, CaseIterable, Identifiable, Codable {
    case openai
    case anthropic
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI (ChatGPT)"
        case .anthropic: "Claude (Anthropic)"
        case .deepseek: "DeepSeek"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: "gpt-4o-mini"
        case .anthropic: "claude-opus-5-5"
        case .deepseek: "deepseek-chat"
        }
    }

    var keyHint: String {
        switch self {
        case .openai: "sk-…"
        case .anthropic: "sk-ant-…"
        case .deepseek: "sk-…"
        }
    }
}

/// API keys live in the keychain; the chosen provider, models, and target
/// language in UserDefaults.
enum MSAISettings {
    private static let service = "org.siloserver.silo.ai-keys"
    private static let providerKey = "mediaServers.ai.provider"
    private static let languageKey = "mediaServers.ai.language"
    private static let modelKeyPrefix = "mediaServers.ai.model."

    static var provider: MSAIProvider {
        get { UserDefaults.standard.string(forKey: providerKey).flatMap(MSAIProvider.init(rawValue:)) ?? .openai }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// The language translations go into, as a code ("ar", "en").
    static var targetLanguage: String {
        get { UserDefaults.standard.string(forKey: languageKey) ?? "ar" }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }

    static func model(for provider: MSAIProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: modelKeyPrefix + provider.rawValue) ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }

    static func setModel(_ model: String, for provider: MSAIProvider) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKeyPrefix + provider.rawValue)
    }

    /// True when the chosen provider has a key, so AI translation is offered.
    static var isConfigured: Bool { key(for: provider) != nil }

    static func key(for provider: MSAIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func setKey(_ key: String?, for provider: MSAIProvider) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

enum MSAIError: LocalizedError {
    case notConfigured
    case refused
    case badAnswer
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add an AI API key in Settings first."
        case .refused: "The AI service declined this text."
        case .badAnswer: "The AI service sent an answer that could not be read."
        case .http(let code, let message): message.isEmpty ? "The AI service answered \(code)." : message
        }
    }
}

/// Translates lists of short texts with the chosen provider. Results are
/// cached on disk, so a description or subtitle is paid for once.
actor MSAITranslator {
    static let shared = MSAITranslator()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    private var memory: [String: String] = [:]

    // MARK: - Public

    /// One text, such as a description.
    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        return try await translate([trimmed]).first ?? text
    }

    /// Many short texts, such as subtitle lines, in their order.
    func translate(_ texts: [String]) async throws -> [String] {
        let provider = MSAISettings.provider
        guard let key = MSAISettings.key(for: provider) else { throw MSAIError.notConfigured }
        let language = MSAISettings.targetLanguage
        let model = MSAISettings.model(for: provider)

        var output = texts
        var missing: [Int] = []
        for (index, text) in texts.enumerated() {
            if let hit = cached(text, language: language) { output[index] = hit } else { missing.append(index) }
        }
        guard !missing.isEmpty else { return output }

        let answer = try await request(provider: provider, key: key, model: model,
                                       texts: missing.map { texts[$0] }, language: language)
        for (slot, index) in missing.enumerated() where slot < answer.count {
            output[index] = answer[slot]
            store(answer[slot], for: texts[index], language: language)
        }
        return output
    }

    /// Whether a text is already mostly in the target language, so it
    /// needs no translation.
    nonisolated static func isInTargetLanguage(_ text: String) -> Bool {
        let language = MSAISettings.targetLanguage
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        let arabic = letters.filter { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) }
        let share = Double(arabic.count) / Double(letters.count)
        switch language {
        case "ar", "fa", "ur": return share > 0.5
        default: return share < 0.2 && language == "en"
        }
    }

    // MARK: - Requests

    private func prompt(_ texts: [String], language: String) throws -> (system: String, user: String) {
        let name = MSAISettings.languageName(language)
        let system = """
        You translate movie and TV text into \(name). Keep names of people and places, keep line breaks inside \
        each item, and write natural subtitles a viewer reads quickly. You receive a JSON array of strings and \
        reply with only a JSON array of the same length, each item the translation of the item at the same index.
        """
        let data = try JSONSerialization.data(withJSONObject: texts)
        return (system, String(decoding: data, as: UTF8.self))
    }

    private func request(provider: MSAIProvider, key: String, model: String,
                         texts: [String], language: String) async throws -> [String] {
        let (system, user) = try prompt(texts, language: language)
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .openai, .deepseek:
            let url = provider == .openai
                ? URL(string: "https://api.openai.com/v1/chat/completions")!
                : URL(string: "https://api.deepseek.com/chat/completions")!
            request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            // On a policy decline the API retries the request on a fallback
            // model inside the same call.
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body = [
                "model": model,
                "max_tokens": 16000,
                "system": system,
                "messages": [["role": "user", "content": user]],
                // Translation needs little reasoning; low effort keeps it fast and cheap.
                "output_config": ["effort": "low"],
                "fallbacks": "default",
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MSAIError.http(status, "")
        }
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
            throw MSAIError.http(status, message)
        }

        let text: String
        switch provider {
        case .openai, .deepseek:
            let choice = (json["choices"] as? [[String: Any]])?.first
            guard let content = (choice?["message"] as? [String: Any])?["content"] as? String else {
                throw MSAIError.badAnswer
            }
            text = content
        case .anthropic:
            // Check the stop reason before reading content.
            if json["stop_reason"] as? String == "refusal" { throw MSAIError.refused }
            let blocks = json["content"] as? [[String: Any]] ?? []
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        return try Self.parseArray(text, expected: texts.count)
    }

    /// The JSON array inside the answer, tolerating code fences and notes.
    static func parseArray(_ text: String, expected: Int) throws -> [String] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw MSAIError.badAnswer
        }
        let strings = array.map { "\($0)" }
        guard !strings.isEmpty else { throw MSAIError.badAnswer }
        return strings.count >= expected ? Array(strings.prefix(expected)) : strings
    }

    // MARK: - Cache

    private static let cacheKey = "mediaServers.ai.cache.v1"
    private static let cacheLimit = 4000

    private func cacheId(_ text: String, language: String) -> String {
        "\(language)|\(text.hashValue)|\(text.count)|\(text.prefix(40))"
    }

    private func cached(_ text: String, language: String) -> String? {
        let id = cacheId(text, language: language)
        if let hit = memory[id] { return hit }
        // Descriptions persist across launches; subtitle lines stay in memory.
        guard text.count > 120 else { return nil }
        let disk = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String]
        return disk?[Self.stableId(text, language: language)]
    }

    private func store(_ translation: String, for text: String, language: String) {
        memory[cacheId(text, language: language)] = translation
        if memory.count > 20000 { memory.removeAll() }
        guard text.count > 120 else { return }
        var disk = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
        if disk.count > Self.cacheLimit { disk.removeAll() }
        disk[Self.stableId(text, language: language)] = translation
        UserDefaults.standard.set(disk, forKey: Self.cacheKey)
    }

    /// `hashValue` changes between launches, so the disk key is built from
    /// the text itself.
    private static func stableId(_ text: String, language: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return "\(language)|\(String(hash, radix: 36))"
    }
}
#endif
