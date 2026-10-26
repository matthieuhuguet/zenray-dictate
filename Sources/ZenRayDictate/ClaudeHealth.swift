import AppKit

// 26 October 2026, 12:10 CEST: the Claude dictation endpoint is not an official API (found by reverse engineering, 25 October 2026),
// so it can change or stop without notice. This monitor opens a real session with 0.6 s of silence at launch, every 6 hours and
// after each wake, so a break is seen in the menu-bar tooltip and the log BEFORE Matthieu dictates, and it records every use of
// the local Whisper fallback. A silent failure is the only one that cannot be fixed. / un échec silencieux ne se corrige jamais.
@MainActor
final class ClaudeHealth {
    static let shared = ClaudeHealth()

    /// Timing values. Change them here only. / valeurs de temps.
    struct Settings {
        var firstCheckDelay: TimeInterval = 15       // after launch, once the app has settled
        var interval: TimeInterval = 6 * 3600
        var afterWakeDelay: TimeInterval = 8         // the network needs a moment after wake
        var silenceChunks = 6                        // 6 x 100 ms of silence
    }
    var settings = Settings()

    enum State: Equatable { case unknown, ok(Date), degraded(String, Date) }
    enum Verdict: Equatable { case healthy, unhealthy(String), skip }

    private(set) var state: State = .unknown
    private(set) var lastFallback: (reason: String, at: Date)?
    var onChange: (() -> Void)?
    /// Fired the moment the local Whisper takes over, before it runs, so the interface can turn red. / au moment où Whisper prend le relais.
    var onFallbackStarted: (() -> Void)?
    private var running = false
    var isDegraded: Bool { if case .degraded = state { return true }; return false }

    /// What a check outcome means. Pure, tested. Busy and offline say nothing about the engine, so they never raise an alarm.
    /// FR : ce que veut dire le résultat ; occupé ou hors ligne ne prouvent rien contre le moteur.
    nonisolated static func verdict(for failure: ClaudeDictationFailure?) -> Verdict {
        switch failure {
        case nil, .some(.empty): return .healthy
        case .some(.busy), .some(.network): return .skip
        case let .some(other): return .unhealthy(other.localizedDescription)
        }
    }

    /// One real session with a little silence: it must connect, be accepted and close cleanly.
    func check(preferences: DictationPreferences) async {
        guard preferences.engine == .claude, !preferences.localOnly, !running else { return }
        running = true; defer { running = false }
        var failure = await probe(preferences)
        if failure == .unauthorized {
            // The server rejected a token that looked valid: renew it once and look again.
            ClaudeCredentials.shared.forget()
            _ = try? await ClaudeCredentials.shared.forceRefresh(cli: preferences.claudeExecutable)
            failure = await probe(preferences)
        }
        switch Self.verdict(for: failure) {
        case .healthy: state = .ok(Date()); Log.write("health: Claude dictation OK")
        case let .unhealthy(reason): state = .degraded(reason, Date()); Log.write("health: Claude dictation UNAVAILABLE, \(reason)")
        case .skip: Log.write("health: check skipped (\(failure?.localizedDescription ?? "busy"))")
        }
        onChange?()
    }

    private func probe(_ preferences: DictationPreferences) async -> ClaudeDictationFailure? {
        do {
            let token = try await ClaudeCredentials.shared.freshToken(cli: preferences.claudeExecutable)
            let session = try ClaudeLiveSession(preferences: preferences, token: token)
            for _ in 0..<settings.silenceChunks { session.feed(Data(count: ClaudeVoiceTranscriber.Wire.chunkBytes)); try await Task.sleep(nanoseconds: 100_000_000) }
            _ = try await session.finish()
            return nil
        } catch let failure as ClaudeDictationFailure { return failure }
        catch { return .rejected(error.localizedDescription) }
    }

    /// Called when a dictation had to use the local Whisper because Claude failed. / un repli Whisper a eu lieu.
    func noteFallback(reason: String) {
        lastFallback = (reason, Date())
        Log.write("health: local Whisper fallback used (\(reason))")
        onFallbackStarted?()
        onChange?()
    }

    /// Menu-bar tooltip suffix; empty when the Claude engine is not in use. / suffixe de l'infobulle.
    func tooltip(preferences: DictationPreferences) -> String {
        guard preferences.engine == .claude, !preferences.localOnly else { return "" }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        var parts: [String] = []
        switch state {
        case .unknown: parts.append("Dictée Claude : pas encore vérifiée")
        case let .ok(date): parts.append("Dictée Claude : OK à \(clock.string(from: date))")
        case let .degraded(reason, date): parts.append("⚠︎ Dictée Claude indisponible depuis \(clock.string(from: date)) (\(reason)), repli Whisper local")
        }
        if let fallback = lastFallback { parts.append("dernier repli Whisper à \(clock.string(from: fallback.at))") }
        return " · " + parts.joined(separator: " · ")
    }

    /// Launch, every `interval`, and after each wake. Runs only while the app is idle. / lancement, intervalle, réveil.
    func schedule(isIdle: @escaping @MainActor () -> Bool) {
        let run: @MainActor () -> Void = { [weak self] in
            guard let self, isIdle() else { return }
            let preferences = DictationLibrary.shared.document.preferences
            Task { await self.check(preferences: preferences) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.firstCheckDelay) { MainActor.assumeIsolated { run() } }
        Timer.scheduledTimer(withTimeInterval: settings.interval, repeats: true) { _ in MainActor.assumeIsolated { run() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [settings] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.afterWakeDelay) { MainActor.assumeIsolated { run() } }
        }
    }
}

extension ClaudeDictationFailure {
    /// Silence is not a fault of the engine: the local Whisper would hear nothing either, and may invent words on silence.
    /// Every other failure falls back to the local engine when the preference allows it. / le silence ne déclenche pas le repli.
    var allowsLocalFallback: Bool { self != .empty }
}
