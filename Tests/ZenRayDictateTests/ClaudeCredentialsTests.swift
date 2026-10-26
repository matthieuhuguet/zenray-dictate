import XCTest
@testable import ZenRayDictate

// 26 October 2026, 11:50 CEST: the expired sign-in incident (« There was a bad response from the server »).
// These tests fail on the old code, which cached the token forever and refreshed only on an in-band error frame.
// FR : incident du jeton expiré ; ces tests échouent sur l'ancien code.
final class ClaudeCredentialsTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func store(keychain: @escaping () throws -> ClaudeCredentials.Lease, refresh: @escaping (String) async throws -> Void = { _ in }, now: Date = Date()) -> ClaudeCredentials {
        let c = ClaudeCredentials()
        c.readKeychain = keychain; c.runRefresh = refresh; c.now = { now }
        return c
    }
    private func lease(_ token: String, in seconds: TimeInterval, now: Date = Date()) -> ClaudeCredentials.Lease {
        .init(token: token, expiresAt: now.addingTimeInterval(seconds))
    }

    func testValidTokenIsUsedWithoutRefresh() async throws {
        let refreshes = Counter()
        let c = store(keychain: { self.lease("A", in: 3600) }, refresh: { _ in refreshes.bump() })
        let token = try await c.freshToken(cli: "cli")
        XCTAssertEqual(token, "A"); XCTAssertEqual(refreshes.value, 0)
    }

    func testExpiredTokenIsRefreshedThroughTheCLI() async throws {
        let refreshes = Counter(); let renewed = Counter()
        let c = store(keychain: { renewed.value > 0 ? self.lease("NEW", in: 28800) : self.lease("OLD", in: -600) },
                      refresh: { _ in refreshes.bump(); renewed.bump() })
        let token = try await c.freshToken(cli: "cli")
        XCTAssertEqual(token, "NEW"); XCTAssertEqual(refreshes.value, 1)
    }

    func testTokenExpiringWithinTheSkewCountsAsExpired() {
        let c = store(keychain: { self.lease("SOON", in: 60) })       // skew is 120 s
        XCTAssertNil(c.validToken())
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let refreshes = Counter(); let renewed = Counter()
        let c = store(keychain: { renewed.value > 0 ? self.lease("NEW", in: 28800) : self.lease("OLD", in: -600) },
                      refresh: { _ in refreshes.bump(); try await Task.sleep(nanoseconds: 150_000_000); renewed.bump() })
        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<6 { group.addTask { try await c.freshToken(cli: "cli") } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(tokens), ["NEW"]); XCTAssertEqual(refreshes.value, 1, "six callers must trigger a single CLI call")
    }

    func testRefreshThatLeavesTheTokenExpiredFailsLoudly() async {
        let c = store(keychain: { self.lease("OLD", in: -600) })
        do { _ = try await c.freshToken(cli: "cli"); XCTFail("must throw") }
        catch { guard case ClaudeDictationFailure.notSignedIn = error else { return XCTFail("wrong error \(error)") } }
    }

    func testMissingKeychainItemIsReported() async {
        let c = store(keychain: { throw ClaudeDictationFailure.noToken })
        do { _ = try await c.freshToken(cli: "cli"); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? ClaudeDictationFailure, .noToken) }
    }

    func testForceRefreshRenewsEvenWhenTheStoredExpiryLooksFine() async throws {
        let refreshes = Counter(); let renewed = Counter()
        let c = store(keychain: { renewed.value > 0 ? self.lease("NEW", in: 28800) : self.lease("REVOKED", in: 3600) },
                      refresh: { _ in refreshes.bump(); renewed.bump() })
        c.forget()
        let token = try await c.forceRefresh(cli: "cli")
        XCTAssertEqual(token, "NEW"); XCTAssertEqual(refreshes.value, 1)
    }

    func testKeepFreshRefreshesOnlyWhenLessThanTheMarginRemains() async {
        let refreshes = Counter(); let renewed = Counter()
        var fresh = true
        let c = store(keychain: { renewed.value > 0 ? self.lease("NEW", in: 28800) : self.lease("OLD", in: fresh ? 6 * 3600 : 600) },
                      refresh: { _ in refreshes.bump(); renewed.bump() })
        await c.keepFresh(cli: "cli"); XCTAssertEqual(refreshes.value, 0, "6 hours left: nothing to do")
        fresh = false
        await c.keepFresh(cli: "cli"); XCTAssertEqual(refreshes.value, 1, "10 minutes left: renew in the background")
    }

    // MARK: Error classification

    func testHTTP401OnUpgradeIsUnauthorizedNotABadResponse() {
        let bad = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)
        XCTAssertEqual(ClaudeDictationFailure.classify(bad, status: 401), .unauthorized)
        XCTAssertEqual(ClaudeDictationFailure.classify(bad, status: 403), .unauthorized)
        XCTAssertEqual(ClaudeDictationFailure.classify(bad, status: 502), .rejected("HTTP 502"))
    }

    func testOfflineIsANetworkFailure() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut] {
            guard case .network = ClaudeDictationFailure.classify(NSError(domain: NSURLErrorDomain, code: code), status: nil) else { return XCTFail("code \(code)") }
        }
    }

    func testServerFramesAreMappedToTypedFailures() {
        XCTAssertEqual(TranscriptCollector.frameFailure(["type": "error", "error": ["message": "Invalid authorization", "details": ["error_code": "account_session_invalid"]]]), .unauthorized)
        XCTAssertEqual(TranscriptCollector.frameFailure(["type": "TranscriptError", "error_code": "rate_limit", "limit": "concurrent", "description": "Too many active sessions."]), .busy)
        XCTAssertEqual(TranscriptCollector.closeFailure(code: 4029, reason: "Rate limit exceeded"), .busy)
        XCTAssertEqual(TranscriptCollector.closeFailure(code: 1008, reason: "Invalid authorization"), .unauthorized)
        XCTAssertEqual(TranscriptCollector.closeFailure(code: 1003, reason: "harmonic provider does not support the requested language"), .rejected("harmonic provider does not support the requested language"))
    }

    func testUserFacingMessagesAreFrenchAndSayWhatToDo() {
        XCTAssertTrue(ClaudeDictationFailure.notSignedIn("x").localizedDescription.contains("claude /login"))
        XCTAssertFalse(ClaudeDictationFailure.unauthorized.localizedDescription.contains("bad response"))
    }

    func testKeytermsSkipSnippetsAndStayWithinTheBudget() {
        var preferences = DictationPreferences()
        preferences.claudeKeyterms = "Houdini, " + String(repeating: "x", count: 60) + ", Unreal"
        preferences.claudeKeytermLimit = 50
        let terms = ClaudeVoiceTranscriber.keyterms(preferences: preferences)
        XCTAssertTrue(terms.contains("Houdini") && terms.contains("Unreal"))
        XCTAssertFalse(terms.contains { $0.count > ClaudeVoiceTranscriber.Wire.maxKeytermLength }, "a 60-character entry is a snippet")
        XCTAssertLessThanOrEqual(terms.joined(separator: ",").count, ClaudeVoiceTranscriber.Wire.maxKeytermCharacters)
    }

    // MARK: Durability (26 October 2026)

    @MainActor func testHealthVerdictsRaiseAlarmsOnlyForRealEngineFaults() {
        XCTAssertEqual(ClaudeHealth.verdict(for: nil), .healthy)
        XCTAssertEqual(ClaudeHealth.verdict(for: .empty), .healthy, "silence is the expected answer to 0.6 s of silence")
        XCTAssertEqual(ClaudeHealth.verdict(for: .busy), .skip)
        XCTAssertEqual(ClaudeHealth.verdict(for: .network("offline")), .skip, "being offline says nothing about the engine")
        for failure in [ClaudeDictationFailure.unauthorized, .noToken, .notSignedIn("x"), .rejected("HTTP 404")] {
            guard case .unhealthy = ClaudeHealth.verdict(for: failure) else { return XCTFail("\(failure) must raise the alarm") }
        }
    }

    func testSilenceNeverTriggersTheLocalFallback() {
        XCTAssertFalse(ClaudeDictationFailure.empty.allowsLocalFallback, "Whisper invents words on silence")
        for failure in [ClaudeDictationFailure.unauthorized, .busy, .network("x"), .rejected("x"), .noToken, .notSignedIn("x")] {
            XCTAssertTrue(failure.allowsLocalFallback)
        }
    }

    func testLocalFallbackIsOnByDefault() {
        XCTAssertTrue(DictationPreferences().allowLocalFallback)
    }

    func testDeadlineGivesUpOnAHangingServer() async {
        do {
            _ = try await TranscriptionPipeline.withDeadline(seconds: 0.2) { try await Task.sleep(nanoseconds: 5_000_000_000); return "late" }
            XCTFail("must time out")
        } catch { guard case ClaudeDictationFailure.network = error else { return XCTFail("wrong error \(error)") } }
        let quick = try? await TranscriptionPipeline.withDeadline(seconds: 5) { "fast" }
        XCTAssertEqual(quick, "fast")
    }
}
