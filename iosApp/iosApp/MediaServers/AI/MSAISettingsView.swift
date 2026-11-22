#if !os(macOS)
import SwiftUI

/// Where a person adds their own OpenAI, Claude, or DeepSeek key. The key
/// translates descriptions and subtitles of Emby, Plex, and IPTV titles.
struct MSAISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = MSAISettings.provider
    @State private var keys: [MSAIProvider: String] = [:]
    @State private var models: [MSAIProvider: String] = [:]
    @State private var language = MSAISettings.targetLanguage
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, passed(String), failed(String)
    }

    private static let languages = ["ar", "en", "fr", "es", "de", "tr", "ur", "fa", "id", "hi"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("الخدمة", selection: $provider) {
                        ForEach(MSAIProvider.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    Picker("لغة الترجمة", selection: $language) {
                        ForEach(Self.languages, id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                } footer: {
                    Text("تترجم هذه الخدمة قصة ووصف أفلام ومسلسلات Emby وPlex وIPTV وترجماتها. عناوين Silo تبقى على ترجمة خادم Silo.")
                }

                ForEach(MSAIProvider.allCases) { item in
                    Section(item.displayName) {
                        SecureField("مفتاح API (\(item.keyHint))", text: binding(for: item, in: $keys))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("النموذج (\(item.defaultModel))", text: binding(for: item, in: $models))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                }

                Section {
                    Button {
                        save()
                        test()
                    } label: {
                        HStack {
                            Text("حفظ وتجربة")
                            Spacer()
                            switch testState {
                            case .idle: EmptyView()
                            case .running: ProgressView()
                            case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    Button("حفظ وإغلاق") {
                        save()
                        dismiss()
                    }
                } footer: {
                    switch testState {
                    case .passed(let sample): Text("يعمل: \(sample)")
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    default: EmptyView()
                    }
                }
            }
            .navigationTitle("مفاتيح الذكاء الاصطناعي")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            #endif
        }
        .onAppear(perform: load)
    }

    private func binding(for item: MSAIProvider, in map: Binding<[MSAIProvider: String]>) -> Binding<String> {
        Binding(get: { map.wrappedValue[item] ?? "" }, set: { map.wrappedValue[item] = $0 })
    }

    private func load() {
        for item in MSAIProvider.allCases {
            keys[item] = MSAISettings.key(for: item) ?? ""
            let model = MSAISettings.model(for: item)
            models[item] = model == item.defaultModel ? "" : model
        }
    }

    private func save() {
        MSAISettings.provider = provider
        MSAISettings.targetLanguage = language
        for item in MSAIProvider.allCases {
            MSAISettings.setKey(keys[item], for: item)
            MSAISettings.setModel(models[item] ?? "", for: item)
        }
    }

    private func test() {
        testState = .running
        Task {
            do {
                let sample = try await MSAITranslator.shared.translate(["Welcome back. Shall we continue watching?"])
                testState = .passed(sample.first ?? "")
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
