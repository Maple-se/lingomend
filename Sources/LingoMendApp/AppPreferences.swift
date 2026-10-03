import CoachCore
import CryptoKit
import Foundation
import Security

struct AppPreferences: Codable, Equatable, Sendable {
    var immersiveEnabled = false
    var allowedApplications: Set<String> = []
    var networkEnabled = false
    var provider = DeepSeekExpressionProvider.preset
    var context = WritingContext.general
    var correctionLevel = CorrectionLevel.correct
    var experimentalAcceptance = false
    var learningEnabled = true
    var statisticsEnabled = false

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "LingoMend.preferences.v1") else { return Self() }
        return decoded(data)
    }

    static func decoded(_ data: Data) -> Self {
        guard let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var migrated = preferences
        // Stage 1 never enabled networking; replace its empty placeholder preset only.
        if migrated.provider.model.isEmpty {
            migrated.provider = DeepSeekExpressionProvider.preset
            migrated.networkEnabled = false
        }
        return migrated
    }

    func persist() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "LingoMend.preferences.v1")
    }
}

enum CredentialError: Error { case unavailable }

/// Credentials are bound to the complete normalized endpoint, not just host.
/// Switching endpoints never sends the previous endpoint's key to a new service.
enum ProviderCredentials {
    private static let service = "com.maplese.lingomend.provider"

    private static func query(for configuration: ProviderConfiguration) throws -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: try account(for: configuration)]
    }

    static func account(for configuration: ProviderConfiguration) throws -> String {
        let endpoint = try configuration.endpoint().absoluteString
        return SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(for configuration: ProviderConfiguration) throws -> String {
        var query = try query(for: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw CredentialError.unavailable }
        return key
    }

    static func save(_ key: String, for configuration: ProviderConfiguration) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.contains(where: { $0.isNewline }) else { throw CoachingProviderError.invalidConfiguration }
        let query = try query(for: configuration)
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CredentialError.unavailable }
        } else if status != errSecSuccess { throw CredentialError.unavailable }
    }

    static func remove(for configuration: ProviderConfiguration) throws {
        let status = SecItemDelete(try query(for: configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
    }
}

func providerMessage(_ error: Error) -> String {
    if error is CredentialError { return "钥匙串不可用；请允许访问或重新填写此地址的密钥。" }
    guard let error = error as? CoachingProviderError else { return "服务或本地数据暂不可用；请检查设置。" }
    switch error {
    case .invalidConfiguration, .insecureEndpoint: return "请配置模型和安全的服务地址；仅本机服务允许 HTTP。"
    case .unauthorized: return "服务未接受凭据；请检查此地址对应的 API Key。"
    case .rateLimited: return "服务限流；稍后重试。"
    case .timedOut, .network: return "暂时无法连接服务；输入未被修改。"
    case .refused: return "服务未提供可用建议。"
    case .inputTooLarge, .responseTooLarge: return "内容超过处理上限；请缩短文本。"
    case .httpStatus(402): return "服务余额不足；请检查 DeepSeek 账户余额。"
    case .httpStatus(let status): return "服务返回 HTTP \(status)；请检查模型与输出格式。"
    default: return "建议格式不完整或未通过检查；未应用到原文。"
    }
}
