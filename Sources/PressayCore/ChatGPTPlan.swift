import CryptoKit
import Foundation
import Security

/// Cleanup on the user's ChatGPT plan via Sign in with ChatGPT (developers.openai.com/siwc).
/// Only transcript text is sent.
public enum ChatGPTPlan {
    public static let authorizeEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let discovery = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let responsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    public static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
    public static let usageSettings = URL(string: "https://chatgpt.com/settings/usage")!
    public static let callbackPath = "/auth/callback"
    public static let agentName = "Pressay"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
}

public enum ChatGPTCleanupModel {
    /// Fixed low-latency dictation route; notes retain their own defaults.
    public static let dictationSlug = "gpt-6-luna"
    public static let dictationEffort = "medium"

    public static let defaultSlug = "gpt-6.1-sol"

    public static let effort = "medium"

    public static func displayName(for slug: String) -> String {
        slug.split(separator: "-").map { part in
            part == "gpt" ? "GPT" : part.prefix(1).uppercased() + part.dropFirst()
        }
        .joined(separator: " ")
        .replacingOccurrences(of: "GPT ", with: "GPT-")
    }
}

public struct ChatGPTCredentials: Codable, Equatable, Sendable {
    public var email: String?
    public var subject: String
    public var clientID: String
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]

    public var planUsageGranted: Bool { scopes.contains(ChatGPTPlan.planScope) }
    /// Early, so a token never expires mid-request.
    public var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

/// Owner-only JSON files (per SIWC docs). The host ID outlives sign-out; credentials don't.
public struct ChatGPTCredentialStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pressay", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var credentialsURL: URL { directory.appending(path: "chatgpt-auth.json") }
    private var hostURL: URL { directory.appending(path: "chatgpt-host.json") }

    public func load() -> ChatGPTCredentials? {
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? Self.decoder.decode(ChatGPTCredentials.self, from: data)
    }

    public func save(_ credentials: ChatGPTCredentials) throws {
        try write(Self.encoder.encode(credentials), to: credentialsURL)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: credentialsURL)
    }

    /// Stable, opaque `ext_agent_host_id` for this Mac.
    public func hostID() throws -> String {
        if let data = try? Data(contentsOf: hostURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data)["ext_agent_host_id"] {
            return saved
        }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        try write(JSONEncoder().encode(["ext_agent_host_id": id]), to: hostURL)
        return id
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(path: ".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public struct ChatGPTAuthAttempt: Sendable {
    public let state: String
    public let nonce: String
    public let verifier: String
    public let redirectURI: String
    /// `dynamic_agent_client` on first registration, the issued ID after.
    public let clientID: String

    public init(redirectURI: String, clientID: String?) {
        state = Self.random()
        nonce = Self.random()
        verifier = Self.random(bytes: 48)
        self.redirectURI = redirectURI
        self.clientID = clientID ?? "dynamic_agent_client"
    }

    public var isRegistration: Bool { clientID == "dynamic_agent_client" }

    public var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    public func authorizeURL(hostID: String, idTokenHint: String?, loginHint: String?) -> URL {
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: clientID),
            .init(name: "ext_agent_host_id", value: hostID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: ChatGPTPlan.scopes),
            .init(name: "resource", value: ChatGPTPlan.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        if isRegistration {
            items.append(.init(name: "agent_name_hint", value: ChatGPTPlan.agentName))
        } else {
            if let idTokenHint { items.append(.init(name: "id_token_hint", value: idTokenHint)) }
            if let loginHint { items.append(.init(name: "login_hint", value: loginHint)) }
        }
        var components = URLComponents(url: ChatGPTPlan.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // URLComponents leaves "+" and "/" alone; OAuth servers read "+" as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func random(bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

public enum ChatGPTAuthError: LocalizedError, Equatable {
    case denied
    case stateMismatch
    case missingClientID
    case clientMismatch
    case http(Int, String)
    case badToken(String)
    case planNotGranted
    case refreshExpired

    public var errorDescription: String? {
        switch self {
        case .denied: "Sign-in was cancelled."
        case .stateMismatch: "The sign-in response didn't match this request. Try again."
        case .missingClientID: "ChatGPT didn't finish registering Pressay. Try again."
        case .clientMismatch: "The sign-in returned a different app registration."
        case .http(let code, let body): "ChatGPT sign-in failed (HTTP \(code)): \(body)"
        case .badToken(let detail): "ChatGPT's sign-in token couldn't be verified: \(detail)"
        case .planNotGranted: "Pressay wasn't allowed to use your ChatGPT plan."
        case .refreshExpired: "Your ChatGPT sign-in expired. Sign in again."
        }
    }
}

public struct ChatGPTAuthClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(attempt: ChatGPTAuthAttempt, callback: URL, expectedSubject: String? = nil) async throws -> ChatGPTCredentials {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == attempt.state else { throw ChatGPTAuthError.stateMismatch }
        if value("error") != nil { throw ChatGPTAuthError.denied }
        guard let code = value("code") else { throw ChatGPTAuthError.denied }
        let clientID: String
        if attempt.isRegistration {
            guard let issued = value("client_id"), issued != "dynamic_agent_client" else {
                throw ChatGPTAuthError.missingClientID
            }
            clientID = issued
        } else {
            if let returned = value("client_id"), returned != attempt.clientID { throw ChatGPTAuthError.clientMismatch }
            clientID = attempt.clientID
        }
        let token = try await post(ChatGPTPlan.tokenEndpoint, [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": attempt.verifier,
            "redirect_uri": attempt.redirectURI,
            "resource": ChatGPTPlan.resource,
        ])
        guard let idToken = token["id_token"] as? String else { throw ChatGPTAuthError.badToken("no id_token") }
        let claims = try await verifyIDToken(idToken, clientID: clientID, nonce: attempt.nonce, expectedSubject: expectedSubject)
        let credentials = try Self.credentials(from: token, clientID: clientID, idToken: idToken, claims: claims)
        guard credentials.planUsageGranted else { throw ChatGPTAuthError.planNotGranted }
        return credentials
    }

    public func refresh(_ credentials: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        let token: [String: Any]
        do {
            token = try await post(ChatGPTPlan.tokenEndpoint, [
                "grant_type": "refresh_token",
                "client_id": credentials.clientID,
                "refresh_token": credentials.refreshToken,
                "resource": ChatGPTPlan.resource,
            ])
        } catch ChatGPTAuthError.http(let status, let body) where (400...401).contains(status) {
            let terminal = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                            "refresh_token_invalidated", "refresh_token_reused"]
            if terminal.contains(where: body.contains) { throw ChatGPTAuthError.refreshExpired }
            throw ChatGPTAuthError.http(status, body)
        }
        var updated = credentials
        guard let access = token["access_token"] as? String else { throw ChatGPTAuthError.badToken("no access_token") }
        updated.accessToken = access
        if let refresh = token["refresh_token"] as? String { updated.refreshToken = refresh }
        updated.expiresAt = Date().addingTimeInterval(token["expires_in"] as? Double ?? 3600)
        if let scope = token["scope"] as? String { updated.scopes = scope.split(separator: " ").map(String.init) }
        if let id = token["id_token"] as? String { updated.idToken = id }
        return updated
    }

    /// Best effort: the user can also disconnect Pressay in ChatGPT Settings.
    public func revoke(_ credentials: ChatGPTCredentials) async -> Bool {
        guard let config = try? await json(from: ChatGPTPlan.discovery),
              let endpoint = (config["revocation_endpoint"] as? String).flatMap(URL.init(string:)) else { return false }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = Self.form([
            "token": credentials.refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": credentials.clientID,
        ])
        let response = try? await session.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func credentials(
        from token: [String: Any],
        clientID: String,
        idToken: String,
        claims: [String: Any]
    ) throws -> ChatGPTCredentials {
        guard let access = token["access_token"] as? String,
              let refresh = token["refresh_token"] as? String,
              let subject = claims["sub"] as? String else {
            throw ChatGPTAuthError.badToken("missing tokens")
        }
        let scope = token["scope"] as? String ?? ""
        return ChatGPTCredentials(
            email: claims["email"] as? String,
            subject: subject,
            clientID: clientID,
            idToken: idToken,
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(token["expires_in"] as? Double ?? 3600),
            scopes: scope.split(separator: " ").map(String.init)
        )
    }

    // MARK: ID token

    func verifyIDToken(_ token: String, clientID: String, nonce: String, expectedSubject: String? = nil) async throws -> [String: Any] {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URLEncoded: parts[0]),
              let payloadData = Data(base64URLEncoded: parts[1]),
              let signature = Data(base64URLEncoded: parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTAuthError.badToken("malformed")
        }
        guard header["alg"] as? String == "RS256", let kid = header["kid"] as? String else {
            throw ChatGPTAuthError.badToken("unexpected algorithm")
        }
        guard let config = try? await json(from: ChatGPTPlan.discovery),
              let jwksURL = (config["jwks_uri"] as? String).flatMap(URL.init(string:)),
              let jwks = try? await json(from: jwksURL),
              let keys = jwks["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid }),
              let key = Self.rsaKey(jwk) else {
            throw ChatGPTAuthError.badToken("signing key not found")
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw ChatGPTAuthError.badToken("bad signature")
        }
        try Self.checkClaims(claims, clientID: clientID, nonce: nonce, expectedSubject: expectedSubject)
        return claims
    }

    static func checkClaims(_ claims: [String: Any], clientID: String, nonce: String, expectedSubject: String? = nil, now: Date = Date()) throws {
        guard claims["iss"] as? String == ChatGPTPlan.issuer else { throw ChatGPTAuthError.badToken("issuer") }
        let audiences = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard audiences.contains(clientID) else { throw ChatGPTAuthError.badToken("audience") }
        guard let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-60) else {
            throw ChatGPTAuthError.badToken("expired")
        }
        guard claims["nonce"] as? String == nonce else { throw ChatGPTAuthError.badToken("nonce") }
        if let expectedSubject, claims["sub"] as? String != expectedSubject {
            throw ChatGPTAuthError.badToken("account identity changed")
        }
    }

    /// PKCS#1 RSAPublicKey DER from a JWK's modulus and exponent.
    static func rsaKey(_ jwk: [String: Any]) -> SecKey? {
        guard jwk["kty"] as? String == "RSA",
              let n = (jwk["n"] as? String).flatMap(Data.init(base64URLEncoded:)),
              let e = (jwk["e"] as? String).flatMap(Data.init(base64URLEncoded:)) else { return nil }
        let der = DER.sequence(DER.integer(n) + DER.integer(e))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    // MARK: HTTP

    private func post(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ChatGPTAuthError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError.badToken("token response")
        }
        return object
    }

    private func json(from url: URL) async throws -> [String: Any] {
        let (data, _) = try await session.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }
}

/// Responses API client. The plan route requires `store: false` and `stream: true`,
/// and rejects `temperature` and `max_output_tokens`.
public struct ChatGPTCleaner: Sendable {
    public enum CleanupError: LocalizedError, Equatable {
        case usageLimit
        case notEligible
        case http(Int, String)
        case failed(String)
        case incomplete
        case implausible

        public var errorDescription: String? {
            switch self {
            case .usageLimit: "ChatGPT usage limit reached"
            case .notEligible: "ChatGPT plan usage isn't available for this account"
            case .http(let code, let body): "ChatGPT returned HTTP \(code): \(body)"
            case .failed(let code): "ChatGPT request failed (\(code))"
            case .incomplete: "ChatGPT stopped early"
            case .implausible: "ChatGPT's reply did not look like an edit of the dictation"
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func requestBody(
        transcript: String,
        targetBundleID: String?,
        vocabulary: [VocabularyParser.Entry],
        model: String,
        effort: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            // Stable per vocabulary, so the instructions are a cache hit.
            "instructions": ClaudeCleanupPrompt.system(vocabulary: vocabulary),
            "input": [[
                "role": "user",
                "content": ClaudeCleanupPrompt.user(transcript: transcript, targetBundleID: targetBundleID),
            ]],
            "store": false,
            "stream": true,
        ]
        if let effort { body["reasoning"] = ["effort": effort] }
        return body
    }

    public func clean(
        _ transcript: String,
        targetBundleID: String?,
        vocabulary: [VocabularyParser.Entry],
        model: String,
        effort: String?,
        accessToken: String,
        timeout: TimeInterval
    ) async throws -> String {
        let body = Self.requestBody(
            transcript: transcript,
            targetBundleID: targetBundleID,
            vocabulary: vocabulary,
            model: model,
            effort: effort
        )
        let cleaned = try await stream(body, accessToken: accessToken, timeout: timeout)
        guard ClaudeCleanupPolicy.isPlausibleEdit(of: transcript, output: cleaned) else {
            throw CleanupError.implausible
        }
        return cleaned
    }

    public func complete(
        instructions: String,
        user: String,
        model: String,
        effort: String?,
        accessToken: String,
        timeout: TimeInterval
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [["role": "user", "content": user]],
            "store": false,
            "stream": true,
        ]
        if let effort { body["reasoning"] = ["effort": effort] }
        return try await stream(body, accessToken: accessToken, timeout: timeout)
    }

    private func stream(_ body: [String: Any], accessToken: String, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: ChatGPTPlan.responsesEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 2000 { break }
            }
            throw Self.error(status: status, body: body)
        }
        var reader = SSEReader()
        for try await line in bytes.lines {
            guard let event = reader.feed(line) else { continue }
            if let text = try Self.handle(event, into: &reader) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw CleanupError.incomplete
    }

    static func handle(_ event: [String: Any], into reader: inout SSEReader) throws -> String? {
        switch event["type"] as? String {
        case "response.output_text.delta":
            reader.text += event["delta"] as? String ?? ""
        case "response.completed":
            return reader.text
        case "response.incomplete":
            throw CleanupError.incomplete
        case "response.failed", "error":
            let error = (event["response"] as? [String: Any])?["error"] as? [String: Any] ?? event["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "unknown"
            if code == "subscription_sharing_usage_limit_exceeded" { throw CleanupError.usageLimit }
            if code == "subscription_sharing_user_not_eligible" { throw CleanupError.notEligible }
            throw CleanupError.failed(code)
        default:
            break
        }
        return nil
    }

    static func error(status: Int, body: Data) -> CleanupError {
        let text = String(decoding: body.prefix(300), as: UTF8.self)
        if text.contains("subscription_sharing_usage_limit_exceeded") { return .usageLimit }
        if text.contains("subscription_sharing_user_not_eligible") { return .notEligible }
        return .http(status, text)
    }

    public func models(accessToken: String) async throws -> [(slug: String, name: String)] {
        var request = URLRequest(url: ChatGPTPlan.modelsEndpoint, timeoutInterval: 10)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.error(status: status, body: data) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = json?["models"] as? [[String: Any]] ?? []
        return models.compactMap { model in
            guard (model["visibility"] as? String ?? "list") == "list", let slug = model["slug"] as? String else { return nil }
            return (slug, model["display_name"] as? String ?? slug)
        }
    }
}

struct SSEReader {
    var text = ""

    /// `AsyncBytes.lines` drops blank lines, so each `data:` line is one event.
    mutating func feed(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { return nil }
        return json as? [String: Any]
    }
}

enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func integer(_ value: Data) -> Data {
        var v = Data(value.drop { $0 == 0 })
        if v.isEmpty { v = Data([0]) }
        if v.first! & 0x80 != 0 { v.insert(0, at: 0) }
        return Data([0x02]) + length(v.count) + v
    }

    static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
