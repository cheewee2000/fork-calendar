import Foundation
import Combine
import CryptoKit
import AuthenticationServices
#if os(macOS)
import Network
import AppKit
#else
import UIKit
#endif

/// One signed-in Google account. Tokens live here (UserDefaults-backed, as
/// the single-account version did); the widget never needs them.
struct GoogleAccount: Codable, Identifiable, Hashable {
    var email: String
    var name: String?
    var refreshToken: String
    var accessToken: String?
    var tokenExpiry: Date?
    /// OAuth client the refresh token was minted with (refresh needs the same one).
    var clientID: String
    var clientSecret: String?
    var syncEnabled: Bool = true
    /// Set when refresh fails with invalid_grant — user must sign in again.
    var needsReauth: Bool = false
    var addedAt: Date = Date()

    var id: String { email }
}

enum AuthError: LocalizedError {
    case noClientID
    case notSignedIn(String)
    case needsReauth(String)
    case exchange(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noClientID: return "Enter an OAuth client ID in Settings first"
        case .notSignedIn(let email): return "\(email) isn't signed in"
        case .needsReauth(let email): return "\(email) needs to sign in again (Settings ⌘,)"
        case .exchange(let message): return "Google sign-in failed: \(message)"
        case .cancelled: return "Sign-in cancelled"
        }
    }
}

/// Holds every connected Google account and hands out valid access tokens.
@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var accounts: [GoogleAccount] = []
    @Published var statusMessage = ""
    @Published var isSigningIn = false

    private let defaults = UserDefaults.standard
    private let key = "googleAccounts"
    private var refreshTasks: [String: Task<String, Error>] = [:]

    private init() {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([GoogleAccount].self, from: data) {
            accounts = list
        }
        migrateLegacyToken()
    }

    /// v0.13 stored one account's tokens in flat keys; carry it over once.
    private func migrateLegacyToken() {
        guard accounts.isEmpty, let refresh = defaults.string(forKey: "gRefreshToken") else { return }
        let clientID = defaults.string(forKey: "googleClientID") ?? ""
        guard !clientID.isEmpty else { return }
        // Email unknown until the first token refresh + userinfo; use a
        // placeholder that gets replaced on first sync.
        accounts = [GoogleAccount(
            email: AccountManager.legacyPlaceholder, name: nil, refreshToken: refresh,
            accessToken: defaults.string(forKey: "gAccessToken"),
            tokenExpiry: defaults.object(forKey: "gTokenExpiry") as? Date,
            clientID: clientID, clientSecret: defaults.string(forKey: "googleClientSecret")
        )]
        persist()
        defaults.removeObject(forKey: "gRefreshToken")
        defaults.removeObject(forKey: "gAccessToken")
        defaults.removeObject(forKey: "gTokenExpiry")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: key)
        }
    }

    var enabledAccounts: [GoogleAccount] { accounts.filter { $0.syncEnabled && !$0.needsReauth } }

    func account(_ id: String) -> GoogleAccount? { accounts.first { $0.email == id } }

    func update(_ account: GoogleAccount) {
        if let i = accounts.firstIndex(where: { $0.email == account.email }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    func setSyncEnabled(_ enabled: Bool, for id: String) {
        guard var a = account(id) else { return }
        a.syncEnabled = enabled
        update(a)
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.email == id }
        persist()
        Task { await revoke(id) }
    }

    private func revoke(_ id: String) async {
        // Best effort; tokens are already gone locally.
        guard let token = account(id)?.refreshToken else { return }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)")!)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Sign in (or re-sign-in) a Google account through the browser.
    /// Existing account with the same email is replaced (re-auth path).
    func addAccount() async {
        let settings = AppSettings.shared
        let clientID: String
        let secret: String?
        #if os(iOS)
        clientID = settings.googleIOSClientID.isEmpty ? settings.googleClientID : settings.googleIOSClientID
        secret = settings.googleIOSClientID.isEmpty && !settings.googleClientSecret.isEmpty ? settings.googleClientSecret : nil
        #else
        clientID = settings.googleClientID
        secret = settings.googleClientSecret.isEmpty ? nil : settings.googleClientSecret
        #endif
        guard !clientID.isEmpty else {
            statusMessage = AuthError.noClientID.localizedDescription
            return
        }
        isSigningIn = true
        statusMessage = "Waiting for Google sign-in in your browser…"
        defer { isSigningIn = false }
        do {
            let tokens = try await GoogleOAuth.signIn(clientID: clientID, clientSecret: secret)
            guard let refresh = tokens.refreshToken else {
                statusMessage = "Google didn't return a refresh token — remove the app at myaccount.google.com/permissions and sign in again"
                return
            }
            let info = try await GoogleOAuth.userInfo(accessToken: tokens.accessToken)
            var account = GoogleAccount(
                email: info.email, name: info.name, refreshToken: refresh,
                accessToken: tokens.accessToken,
                tokenExpiry: Date().addingTimeInterval(tokens.expiresIn),
                clientID: clientID, clientSecret: secret
            )
            if let existing = self.account(info.email) {
                account.syncEnabled = existing.syncEnabled
                account.addedAt = existing.addedAt
            }
            // Drop the legacy placeholder once a real account exists
            accounts.removeAll { $0.email == AccountManager.legacyPlaceholder }
            update(account)
            statusMessage = "Signed in as \(info.email)"
        } catch AuthError.cancelled {
            statusMessage = "Sign-in cancelled"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    static let legacyPlaceholder = "google-account"

    /// The v0.13 migration doesn't know the account's email; learn it once.
    func resolvePlaceholders() async {
        guard let account = account(AccountManager.legacyPlaceholder) else { return }
        guard let token = try? await validToken(for: account.email) else { return }
        var a = account
        if let info = try? await GoogleOAuth.userInfo(accessToken: token) {
            a.email = info.email
            a.name = info.name
        } else if let list = try? await GoogleCalendarAPI.calendarList(token: token),
                  let primary = list.first(where: { $0.primary == true }) {
            // Legacy tokens lack the email scope; the primary calendar id is the address.
            a.email = primary.id.lowercased()
        } else {
            return
        }
        accounts.removeAll { $0.email == AccountManager.legacyPlaceholder }
        update(a)
    }

    /// A valid access token for the account, refreshing if needed.
    func validToken(for id: String) async throws -> String {
        guard let account = account(id) else { throw AuthError.notSignedIn(id) }
        if account.needsReauth { throw AuthError.needsReauth(id) }
        if let token = account.accessToken, let expiry = account.tokenExpiry, expiry > Date().addingTimeInterval(60) {
            return token
        }
        if let inflight = refreshTasks[id] { return try await inflight.value }
        let task = Task<String, Error> { @MainActor in
            defer { refreshTasks[id] = nil }
            return try await refresh(account)
        }
        refreshTasks[id] = task
        return try await task.value
    }

    private func refresh(_ account: GoogleAccount) async throws -> String {
        var body = [
            "client_id": account.clientID,
            "refresh_token": account.refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = account.clientSecret, !secret.isEmpty { body["client_secret"] = secret }
        let json = try await GoogleOAuth.postForm(url: "https://oauth2.googleapis.com/token", body: body)
        guard let token = json["access_token"] as? String else {
            let err = json["error"] as? String ?? "unknown"
            if err == "invalid_grant" || err == "invalid_client" {
                var a = account
                a.needsReauth = true
                update(a)
                throw AuthError.needsReauth(account.email)
            }
            throw AuthError.exchange(json["error_description"] as? String ?? err)
        }
        var a = self.account(account.email) ?? account
        a.accessToken = token
        a.tokenExpiry = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3500)
        update(a)
        return token
    }
}

/// OAuth 2.0 authorization-code flow with PKCE. macOS: loopback redirect in
/// the default browser (Desktop-app client). iOS: ASWebAuthenticationSession
/// with the reversed-client-id custom scheme (iOS client, or a Desktop client
/// when Google accepts it).
enum GoogleOAuth {
    struct Tokens {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
    }

    struct UserInfo {
        let email: String
        let name: String?
    }

    static let scopes = "https://www.googleapis.com/auth/calendar openid email profile"

    static func signIn(clientID: String, clientSecret: String?) async throws -> Tokens {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL()
        let state = randomString(16)

        let redirect: String
        let code: String
        #if os(macOS)
        let server = try LoopbackServer()
        let port = try await server.waitForPort()
        redirect = "http://127.0.0.1:\(port)"
        NSWorkspace.shared.open(authURL(clientID: clientID, redirect: redirect, challenge: challenge, state: state))
        defer { server.stop() }
        let (gotCode, gotState) = try await server.waitForCode()
        guard gotState == state else { throw AuthError.exchange("state mismatch") }
        code = gotCode
        #else
        let scheme = reversedScheme(clientID: clientID)
        redirect = "\(scheme):/oauth2redirect"
        let callback = try await WebAuthPresenter.shared.run(
            url: authURL(clientID: clientID, redirect: redirect, challenge: challenge, state: state),
            scheme: scheme
        )
        let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard let gotCode = comps?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.exchange(comps?.queryItems?.first(where: { $0.name == "error" })?.value ?? "no code")
        }
        guard comps?.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw AuthError.exchange("state mismatch")
        }
        code = gotCode
        #endif

        var body = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ]
        if let clientSecret, !clientSecret.isEmpty { body["client_secret"] = clientSecret }
        let json = try await postForm(url: "https://oauth2.googleapis.com/token", body: body)
        guard let access = json["access_token"] as? String else {
            throw AuthError.exchange(json["error_description"] as? String ?? json["error"] as? String ?? "unknown error")
        }
        return Tokens(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: json["expires_in"] as? Double ?? 3500
        )
    }

    static func userInfo(accessToken: String) async throws -> UserInfo {
        var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let email = json["email"] as? String else { throw AuthError.exchange("couldn't read account email") }
        return UserInfo(email: email.lowercased(), name: json["name"] as? String)
    }

    private static func authURL(clientID: String, redirect: String, challenge: String, state: String) -> URL {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return comps.url!
    }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
    static func reversedScheme(clientID: String) -> String {
        let parts = clientID.split(separator: ".").map(String.init)
        return parts.reversed().joined(separator: ".")
    }

    static func postForm(url: String, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

private extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if os(iOS)
@MainActor
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresenter()
    private var session: ASWebAuthenticationSession?

    func run(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    cont.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    cont.resume(throwing: AuthError.cancelled)
                } else {
                    cont.resume(throwing: AuthError.exchange(error?.localizedDescription ?? "unknown"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                cont.resume(throwing: AuthError.exchange("couldn't open the sign-in page"))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
#endif

#if os(macOS)
/// Minimal one-shot HTTP listener on 127.0.0.1 that captures the OAuth ?code=.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cwandt.loopback")
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var codeContinuation: CheckedContinuation<(String, String), Error>?
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp)
    }

    func waitForPort() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            portContinuation = cont
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue {
                        self.portContinuation?.resume(returning: port)
                        self.portContinuation = nil
                    }
                case .failed(let error):
                    self.portContinuation?.resume(throwing: error)
                    self.portContinuation = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// (code, state)
    func waitForCode() async throws -> (String, String) {
        try await withCheckedThrowingContinuation { cont in
            codeContinuation = cont
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            var code: String?
            var state = ""
            var errorText: String?
            if let firstLine = request.components(separatedBy: "\r\n").first,
               let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
               let comps = URLComponents(string: "http://localhost\(pathPart)") {
                code = comps.queryItems?.first(where: { $0.name == "code" })?.value
                state = comps.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
                errorText = comps.queryItems?.first(where: { $0.name == "error" })?.value
            }
            let message = code != nil
                ? "Fork Calendar is connected to Google. You can close this window."
                : "Sign-in was cancelled or failed. You can close this window."
            let body = "<html><body style=\"font-family:sans-serif;padding:40px\">\(message)</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if let code {
                self.codeContinuation?.resume(returning: (code, state))
                self.codeContinuation = nil
            } else if let errorText {
                self.codeContinuation?.resume(throwing: errorText == "access_denied" ? AuthError.cancelled : AuthError.exchange(errorText))
                self.codeContinuation = nil
            }
        }
    }
}
#endif
