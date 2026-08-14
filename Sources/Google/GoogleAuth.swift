import Foundation
import Combine
#if os(macOS)
import Network
import AppKit
#endif

/// Google OAuth 2.0 for a desktop app (loopback redirect). The user supplies
/// their own OAuth client from console.cloud.google.com (Desktop app type,
/// Calendar API enabled). Connect is macOS-only; tokens enable Google-side
/// guest lists and Meet creation.
@MainActor
final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()

    @Published private(set) var isConnected: Bool = false
    @Published var statusMessage = ""

    private let defaults = UserDefaults.standard
    private var accessToken: String?
    private var refreshToken: String?
    private var expiry: Date?

    private init() {
        accessToken = defaults.string(forKey: "gAccessToken")
        refreshToken = defaults.string(forKey: "gRefreshToken")
        expiry = defaults.object(forKey: "gTokenExpiry") as? Date
        isConnected = refreshToken != nil
    }

    private func persist() {
        defaults.set(accessToken, forKey: "gAccessToken")
        defaults.set(refreshToken, forKey: "gRefreshToken")
        defaults.set(expiry, forKey: "gTokenExpiry")
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        expiry = nil
        persist()
        isConnected = false
        statusMessage = "Disconnected"
    }

    /// A currently-valid access token, refreshing if needed. nil = not connected.
    func validToken() async -> String? {
        if let token = accessToken, let expiry, expiry > Date().addingTimeInterval(60) {
            return token
        }
        return await refresh()
    }

    private func refresh() async -> String? {
        let settings = AppSettings.shared
        guard let refreshToken, !settings.googleClientID.isEmpty else { return nil }
        var body = [
            "client_id": settings.googleClientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if !settings.googleClientSecret.isEmpty {
            body["client_secret"] = settings.googleClientSecret
        }
        do {
            let json = try await postForm(url: "https://oauth2.googleapis.com/token", body: body)
            guard let token = json["access_token"] as? String else { return nil }
            accessToken = token
            expiry = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3500)
            persist()
            return token
        } catch {
            statusMessage = "Token refresh failed"
            return nil
        }
    }

    #if os(macOS)
    func connect() async {
        let settings = AppSettings.shared
        guard !settings.googleClientID.isEmpty else {
            statusMessage = "Enter an OAuth Client ID first"
            return
        }
        statusMessage = "Waiting for Google sign-in in your browser…"
        do {
            let server = try LoopbackServer()
            let port = try await server.waitForPort()
            let redirect = "http://127.0.0.1:\(port)"
            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                URLQueryItem(name: "client_id", value: settings.googleClientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(comps.url!)
            let code = try await server.waitForCode()
            server.stop()

            var body = [
                "client_id": settings.googleClientID,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": redirect,
            ]
            if !settings.googleClientSecret.isEmpty {
                body["client_secret"] = settings.googleClientSecret
            }
            let json = try await postForm(url: "https://oauth2.googleapis.com/token", body: body)
            guard let access = json["access_token"] as? String else {
                statusMessage = "Google rejected the token exchange: \(json["error_description"] as? String ?? "unknown error")"
                return
            }
            accessToken = access
            refreshToken = json["refresh_token"] as? String ?? refreshToken
            expiry = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3500)
            persist()
            isConnected = refreshToken != nil
            statusMessage = isConnected ? "Connected" : "Connected (no refresh token — reconnect and approve again)"
        } catch {
            statusMessage = "Connect failed: \(error.localizedDescription)"
        }
    }
    #endif

    private func postForm(url: String, body: [String: String]) async throws -> [String: Any] {
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
}

#if os(macOS)
/// Minimal one-shot HTTP listener on 127.0.0.1 that captures the OAuth ?code=.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cwandt.loopback")
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
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

    func waitForCode() async throws -> String {
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
            if let firstLine = request.components(separatedBy: "\r\n").first,
               let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
               let comps = URLComponents(string: "http://localhost\(pathPart)") {
                code = comps.queryItems?.first(where: { $0.name == "code" })?.value
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
                self.codeContinuation?.resume(returning: code)
                self.codeContinuation = nil
            }
        }
    }
}
#endif
