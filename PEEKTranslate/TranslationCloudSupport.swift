import CryptoKit
import Foundation
import Security

enum TranslationCloudProvider: String, CaseIterable, Identifiable, Sendable {
    case baidu
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baidu: return L10n.tr("百度翻译")
        case .google: return L10n.tr("Google 翻译")
        }
    }

    var systemImage: String {
        switch self {
        case .baidu: return "character.bubble.fill"
        case .google: return "globe.americas.fill"
        }
    }
}

struct TranslationCloudConfiguration: Equatable, Sendable {
    let provider: TranslationCloudProvider
    let appID: String?
    let secret: String
}

enum TranslationCloudPhase: Equatable, Sendable {
    case idle
    case translating
    case translated(String)
    case failed(String)

    var output: String? {
        guard case .translated(let value) = self else { return nil }
        return value
    }
}

enum TranslationCloudConfigurationPolicy {
    static func isComplete(
        provider: TranslationCloudProvider,
        appID: String?,
        hasSecret: Bool
    ) -> Bool {
        guard hasSecret else { return false }
        switch provider {
        case .baidu:
            return !(appID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .google:
            return true
        }
    }
}

@MainActor
final class TranslationCloudSettings: ObservableObject {
    static let shared = TranslationCloudSettings()

    private enum DefaultsKey {
        static let baiduEnabled = "translation.cloud.baidu.enabled"
        static let baiduAppID = "translation.cloud.baidu.appID"
        static let googleEnabled = "translation.cloud.google.enabled"
    }

    private let defaults: UserDefaults
    private let keychain: TranslationCredentialStore

    @Published var baiduEnabled: Bool {
        didSet { defaults.set(baiduEnabled, forKey: DefaultsKey.baiduEnabled) }
    }
    @Published var baiduAppID: String {
        didSet { defaults.set(baiduAppID, forKey: DefaultsKey.baiduAppID) }
    }
    @Published var googleEnabled: Bool {
        didSet { defaults.set(googleEnabled, forKey: DefaultsKey.googleEnabled) }
    }
    @Published private(set) var hasBaiduSecret: Bool
    @Published private(set) var hasGoogleAPIKey: Bool

    init(
        defaults: UserDefaults = .standard,
        keychain: TranslationCredentialStore = .init()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        baiduEnabled = defaults.bool(forKey: DefaultsKey.baiduEnabled)
        baiduAppID = defaults.string(forKey: DefaultsKey.baiduAppID) ?? ""
        googleEnabled = defaults.bool(forKey: DefaultsKey.googleEnabled)
        hasBaiduSecret = keychain.hasCredential(for: .baidu)
        hasGoogleAPIKey = keychain.hasCredential(for: .google)
    }

    func isConfigured(_ provider: TranslationCloudProvider) -> Bool {
        switch provider {
        case .baidu:
            return baiduEnabled && TranslationCloudConfigurationPolicy.isComplete(
                provider: .baidu,
                appID: baiduAppID,
                hasSecret: hasBaiduSecret
            )
        case .google:
            return googleEnabled && TranslationCloudConfigurationPolicy.isComplete(
                provider: .google,
                appID: nil,
                hasSecret: hasGoogleAPIKey
            )
        }
    }

    var configuredProviders: [TranslationCloudProvider] {
        TranslationCloudProvider.allCases.filter(isConfigured)
    }

    func saveCredential(_ value: String, for provider: TranslationCloudProvider) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try keychain.save(normalized, for: provider)
        refreshCredentialState()
    }

    func removeCredential(for provider: TranslationCloudProvider) throws {
        try keychain.remove(for: provider)
        refreshCredentialState()
    }

    func configuration(for provider: TranslationCloudProvider) throws -> TranslationCloudConfiguration? {
        guard isConfigured(provider), let secret = try keychain.credential(for: provider) else {
            return nil
        }
        switch provider {
        case .baidu:
            return TranslationCloudConfiguration(
                provider: provider,
                appID: baiduAppID.trimmingCharacters(in: .whitespacesAndNewlines),
                secret: secret
            )
        case .google:
            return TranslationCloudConfiguration(provider: provider, appID: nil, secret: secret)
        }
    }

    private func refreshCredentialState() {
        hasBaiduSecret = keychain.hasCredential(for: .baidu)
        hasGoogleAPIKey = keychain.hasCredential(for: .google)
    }
}

struct TranslationCredentialStore: Sendable {
    private let service = "com.shawnshoper.peek.translation"

    func credential(for provider: TranslationCloudProvider) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TranslationCredentialError.keychain(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw TranslationCredentialError.invalidCredential
        }
        return value
    }

    func hasCredential(for provider: TranslationCloudProvider) -> Bool {
        (try? credential(for: provider)) != nil
    }

    func save(_ value: String, for provider: TranslationCloudProvider) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: provider)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TranslationCredentialError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw TranslationCredentialError.keychain(updateStatus)
        }
    }

    func remove(for provider: TranslationCloudProvider) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranslationCredentialError.keychain(status)
        }
    }

    private func baseQuery(for provider: TranslationCloudProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

enum TranslationCredentialError: LocalizedError {
    case keychain(OSStatus)
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return L10n.tr("无法访问钥匙串（错误 %d）", status)
        case .invalidCredential:
            return L10n.tr("保存的密钥格式无效")
        }
    }
}

enum TranslationCloudLanguageMapper {
    static func code(
        for identifier: String?,
        provider: TranslationCloudProvider,
        isSource: Bool
    ) -> String? {
        guard let identifier else { return isSource ? (provider == .baidu ? "auto" : nil) : nil }
        let normalized = identifier.lowercased()
        let base = TranslationLanguagePresentation.baseLanguageCode(identifier).lowercased()

        if normalized.contains("hant") || normalized.hasSuffix("-tw") || normalized.hasSuffix("-hk") {
            return provider == .baidu ? "cht" : "zh-TW"
        }
        if base == "zh" {
            return provider == .baidu ? "zh" : "zh-CN"
        }

        let common: [String: String] = [
            "en": "en", "de": "de", "it": "it", "nl": "nl", "pt": "pt",
            "ru": "ru", "uk": "uk", "bg": "bg", "sr": "sr", "ar": "ar",
            "he": "he", "hi": "hi", "th": "th", "vi": "vi", "tr": "tr",
            "pl": "pl", "cs": "cs", "da": "da", "fi": "fi", "sv": "sv",
            "no": "no", "el": "el", "id": "id", "ms": "ms"
        ]
        let baiduOverrides = ["ja": "jp", "ko": "kor", "fr": "fra", "es": "spa"]
        if provider == .baidu, let value = baiduOverrides[base] { return value }
        return common[base] ?? ["ja": "ja", "ko": "ko", "fr": "fr", "es": "es"][base]
    }
}

enum TranslationCloudError: LocalizedError {
    case invalidConfiguration
    case unsupportedTarget
    case invalidResponse
    case provider(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return L10n.tr("翻译服务配置不完整")
        case .unsupportedTarget: return L10n.tr("该翻译服务暂不支持目标语言")
        case .invalidResponse: return L10n.tr("翻译服务返回了无效结果")
        case .provider(let message): return message
        case .http(let status): return L10n.tr("翻译服务请求失败（HTTP %d）", status)
        }
    }
}

enum TranslationCloudRequestBuilder {
    private static let googleTranslationV2URL = URL(
        string: "https://translation.googleapis.com/language/translate/v2"
    )!

    /// Builds the Cloud Translation Basic (v2) request without placing credentials in the URL.
    /// Keeping the API key in a request header prevents it from leaking through URL logs/history.
    static func googleTranslationV2(
        text: String,
        sourceIdentifier: String?,
        targetIdentifier: String,
        apiKey: String
    ) throws -> URLRequest {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            throw TranslationCloudError.invalidConfiguration
        }
        guard let target = TranslationCloudLanguageMapper.code(
            for: targetIdentifier,
            provider: .google,
            isSource: false
        ) else {
            throw TranslationCloudError.unsupportedTarget
        }

        var request = URLRequest(url: googleTranslationV2URL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(normalizedAPIKey, forHTTPHeaderField: "x-goog-api-key")

        var body: [String: Any] = ["q": text, "target": target, "format": "text"]
        if let source = TranslationCloudLanguageMapper.code(
            for: sourceIdentifier,
            provider: .google,
            isSource: true
        ) {
            body["source"] = source
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

actor TranslationCloudClient {
    static let shared = TranslationCloudClient()

    func translate(
        text: String,
        sourceIdentifier: String?,
        targetIdentifier: String,
        configuration: TranslationCloudConfiguration
    ) async throws -> String {
        switch configuration.provider {
        case .baidu:
            return try await translateWithBaidu(
                text: text,
                sourceIdentifier: sourceIdentifier,
                targetIdentifier: targetIdentifier,
                configuration: configuration
            )
        case .google:
            return try await translateWithGoogle(
                text: text,
                sourceIdentifier: sourceIdentifier,
                targetIdentifier: targetIdentifier,
                configuration: configuration
            )
        }
    }

    private func translateWithBaidu(
        text: String,
        sourceIdentifier: String?,
        targetIdentifier: String,
        configuration: TranslationCloudConfiguration
    ) async throws -> String {
        guard let appID = configuration.appID, !appID.isEmpty else {
            throw TranslationCloudError.invalidConfiguration
        }
        guard let target = TranslationCloudLanguageMapper.code(
            for: targetIdentifier,
            provider: .baidu,
            isSource: false
        ) else { throw TranslationCloudError.unsupportedTarget }
        let source = TranslationCloudLanguageMapper.code(
            for: sourceIdentifier,
            provider: .baidu,
            isSource: true
        ) ?? "auto"
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let signature = Self.md5(appID + text + salt + configuration.secret)
        let fields = [
            "q": text, "from": source, "to": target,
            "appid": appID, "salt": salt, "sign": signature
        ]
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let payload = try JSONDecoder().decode(BaiduResponse.self, from: data)
        if let message = payload.errorMessage {
            throw TranslationCloudError.provider(message)
        }
        let output = payload.results?.map(\.destination).joined(separator: "\n") ?? ""
        guard !output.isEmpty else { throw TranslationCloudError.invalidResponse }
        return output
    }

    private func translateWithGoogle(
        text: String,
        sourceIdentifier: String?,
        targetIdentifier: String,
        configuration: TranslationCloudConfiguration
    ) async throws -> String {
        let request = try TranslationCloudRequestBuilder.googleTranslationV2(
            text: text,
            sourceIdentifier: sourceIdentifier,
            targetIdentifier: targetIdentifier,
            apiKey: configuration.secret
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let payload = try JSONDecoder().decode(GoogleResponse.self, from: data)
        if let message = payload.error?.message {
            throw TranslationCloudError.provider(message)
        }
        let output = payload.data?.translations.map(\.translatedText).joined(separator: "\n") ?? ""
        guard !output.isEmpty else { throw TranslationCloudError.invalidResponse }
        return Self.decodeHTMLEntities(output)
    }

    static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func formEncoded(_ fields: [String: String]) -> String {
        fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranslationCloudError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw TranslationCloudError.http(http.statusCode)
        }
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private struct BaiduResponse: Decodable {
        struct Result: Decodable {
            let destination: String
            enum CodingKeys: String, CodingKey { case destination = "dst" }
        }
        let results: [Result]?
        let errorMessage: String?
        enum CodingKeys: String, CodingKey {
            case results = "trans_result"
            case errorMessage = "error_msg"
        }
    }

    private struct GoogleResponse: Decodable {
        struct Payload: Decodable { let translations: [Translation] }
        struct Translation: Decodable { let translatedText: String }
        struct ErrorPayload: Decodable { let message: String }
        let data: Payload?
        let error: ErrorPayload?
    }
}
