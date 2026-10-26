import Foundation

// 26 October 2026, 11:20 CEST: the Claude sign-in used by the dictation engine.
// Root cause of the « bad response from the server » failure: the OAuth token lasts about 8 hours (expiresAt read from the
// keychain item « Claude Code-credentials »); once expired the server answers HTTP 401 at the WebSocket upgrade, which
// URLSession reports as NSURLErrorBadServerResponse. The old code cached the token forever and only refreshed on an in-band error frame.
// FR : le jeton OAuth dure environ 8 h ; expiré, le serveur répond 401 à l'ouverture, ce que macOS appelle « bad response ».
// This type reads the token with its expiry, refreshes it BEFORE it expires (in the background) and exactly once at a time.

enum ClaudeDictationFailure: LocalizedError, Equatable {
    case noToken                 // keychain item missing
    case notSignedIn(String)     // refresh did not produce a valid token
    case unauthorized            // server answered 401 or 403
    case rejected(String)        // server error frame or unexpected close
    case busy                    // too many concurrent sessions (close code 4029)
    case network(String)         // offline, timeout, connection lost
    case empty                   // the server heard no speech

    var errorDescription: String? {
        switch self {
        case .noToken: return "Aucune connexion Claude trouvée. Ouvre Claude Code ou l'app Claude une fois, puis réessaie."
        case let .notSignedIn(detail): return "Connexion Claude expirée et non renouvelée (\(detail)). Lance « claude /login » dans un terminal."
        case .unauthorized: return "Connexion Claude refusée par le serveur."
        case let .rejected(reason): return "Le serveur de dictée a refusé la demande : \(reason)"
        case .busy: return "Trop de dictées en même temps, réessaie dans un instant."
        case let .network(detail): return "Pas de connexion au serveur de dictée (\(detail))."
        case .empty: return "Aucun texte entendu."
        }
    }

    /// Maps what URLSession reports to a typed failure. `status` is the HTTP status of the upgrade request, nil when unknown.
    static func classify(_ error: Error, status: Int?) -> ClaudeDictationFailure {
        if let failure = error as? ClaudeDictationFailure { return failure }
        if let status, status == 401 || status == 403 { return .unauthorized }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff:
                return .network(ns.localizedDescription)
            case NSURLErrorBadServerResponse:
                return .rejected(status.map { "HTTP \($0)" } ?? "réponse invalide")
            default: break
            }
        }
        return .rejected(error.localizedDescription)
    }
}

final class ClaudeCredentials: @unchecked Sendable {
    static let shared = ClaudeCredentials()

    /// Timing and process values. Change them here only. / valeurs de temps et de processus.
    struct Settings {
        var keychainService = "Claude Code-credentials"
        var skew: TimeInterval = 120               // a token expiring within 2 minutes counts as expired
        var refreshMargin: TimeInterval = 1800     // refresh in the background when less than 30 minutes remain
        var refreshTimeout: TimeInterval = 30      // the Claude CLI call must finish within this
        var checkInterval: TimeInterval = 300      // background check period
    }
    var settings = Settings()

    struct Lease { let token: String; let expiresAt: Date }

    private let lock = NSLock()
    private var lease: Lease?
    private var inflight: Task<Lease, Error>?
    /// Replaceable for tests. / remplaçables dans les tests.
    var readKeychain: () throws -> Lease = ClaudeCredentials.readKeychainLease
    var runRefresh: (String) async throws -> Void = ClaudeCredentials.runCLI
    var now: () -> Date = Date.init

    init() {}

    // MARK: Read

    /// A token that is valid right now, without any refresh, or nil. Fast when cached; one keychain read otherwise.
    func validToken() -> String? {
        if let cached = cachedLease(), cached.expiresAt.timeIntervalSince(now()) > settings.skew { return cached.token }
        guard let fresh = try? readKeychain() else { return nil }
        store(fresh)
        return fresh.expiresAt.timeIntervalSince(now()) > settings.skew ? fresh.token : nil
    }

    /// Seconds before the stored token expires, nil when unreadable. / secondes avant l'expiration.
    func remaining() -> TimeInterval? {
        if let read = try? readKeychain() { store(read); return read.expiresAt.timeIntervalSince(now()) }
        return cachedLease()?.expiresAt.timeIntervalSince(now())
    }

    /// Forget the cached token, after a 401 or when the keychain changed. / oublie le jeton en mémoire.
    func forget() { lock.lock(); lease = nil; lock.unlock() }  // keychain is read again next time

    // MARK: Refresh

    /// A valid token, refreshing through the Claude CLI when needed. Concurrent callers share one refresh.
    func freshToken(cli: String) async throws -> String {
        if let token = validToken() { return token }
        return try await refresh(cli: cli).token
    }

    /// Renews the sign-in even if the stored expiry looks fine, after the server rejected the token. / après un 401.
    func forceRefresh(cli: String) async throws -> String { try await refresh(cli: cli).token }

    /// Background upkeep: refreshes while the token still works, so that pressing Fn never waits.
    func keepFresh(cli: String) async {
        guard let left = remaining() else { return }
        guard left < settings.refreshMargin else { return }
        Log.write("Claude sign-in expires in \(Int(left)) s; refreshing in the background")
        do { _ = try await refresh(cli: cli); Log.write("Claude sign-in refreshed") }
        catch { Log.write("Claude sign-in refresh failed: \(error.localizedDescription)") }
    }

    private func refresh(cli: String) async throws -> Lease { try await refreshTask(cli: cli).value }

    /// Joins the refresh already running, or starts one. Synchronous on purpose: the lock stays out of async code.
    private func refreshTask(cli: String) -> Task<Lease, Error> {
        lock.lock(); defer { lock.unlock() }
        if let running = inflight { return running }
        let readKeychain = self.readKeychain, runRefresh = self.runRefresh, now = self.now, skew = settings.skew
        let task = Task<Lease, Error> { [weak self] in
            defer { self?.clearInflight() }
            try await runRefresh(cli)
            let lease = try readKeychain()
            guard lease.expiresAt.timeIntervalSince(now()) > skew else {
                throw ClaudeDictationFailure.notSignedIn("jeton toujours expiré après le renouvellement")
            }
            self?.store(lease)
            return lease
        }
        inflight = task
        return task
    }

    // Small synchronous helpers: an NSLock must not be taken inside async code. / verrou hors du code asynchrone.
    private func store(_ new: Lease) { lock.lock(); lease = new; lock.unlock() }
    private func cachedLease() -> Lease? { lock.lock(); defer { lock.unlock() }; return lease }
    private func clearInflight() { lock.lock(); inflight = nil; lock.unlock() }

    /// Test hook: pretend the cache holds this token. / pour les tests.
    func seed(token: String, expiresAt: Date) { store(Lease(token: token, expiresAt: expiresAt)) }

    // MARK: Real implementations

    /// Reads token and expiry through /usr/bin/security, which the keychain item already trusts.
    static func readKeychainLease() throws -> Lease {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", ClaudeCredentials.shared.settings.keychainService, "-w"]
        process.standardOutput = pipe; process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw ClaudeDictationFailure.noToken }
        let milliseconds = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init) ?? 0
        return Lease(token: token, expiresAt: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    /// The Claude CLI newest installed by the Claude app when the configured path is missing. / dernier Claude Code installé.
    static func resolveCLI(preferred: String) -> String? {
        if FileManager.default.isExecutableFile(atPath: preferred) { return preferred }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let builds = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(version).path)) ?? []
            for build in builds {
                let candidate = root.appendingPathComponent(version).appendingPathComponent(build).appendingPathComponent("claude.app/Contents/MacOS/claude").path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// One tiny headless Claude call: the CLI renews its own OAuth token, exactly as Claude Code does. No session is kept.
    static func runCLI(preferred: String) async throws {
        guard let cli = resolveCLI(preferred: preferred) else { throw ClaudeDictationFailure.noToken }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-p", "ok", "--model", "haiku", "--no-session-persistence"]
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ZenRayDictateRefresh", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        process.currentDirectoryURL = work
        process.standardOutput = Pipe(); process.standardError = Pipe()
        let timeout = ClaudeCredentials.shared.settings.refreshTimeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }
}
