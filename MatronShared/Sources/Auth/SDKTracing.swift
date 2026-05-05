import Foundation
import MatrixRustSDK
import os

/// Process-wide one-shot setup of `matrix-rust-sdk`'s tracing pipeline.
///
/// The SDK's `initPlatform(config:useLightweightTokioRuntime:)` configures
/// both the rust-side `tracing` subscriber AND the tokio runtime. It MUST
/// be called exactly once per process and BEFORE the first `Client` is
/// built (the underlying tracing subscriber and runtime are set on the
/// process by side effect; calling twice trips a uniffi-bridged panic on
/// the rust side).
///
/// Without this call the SDK runs with no tracing at all — every internal
/// operation (sliding sync, `enableRecovery`, `getSessionVerificationController`,
/// `/keys/query`, all the matrix-rust-sdk surfaces we depend on) is silent.
/// Live debugging surfaced this gap during the matron-vs-matron-ui scenario:
/// the recovery-key generate flow stalled inside `encryption.enableRecovery`
/// with NO diagnostic anywhere in the unified log because no Swift-side
/// logger spanned the SDK round-trip and the rust side wasn't logging.
/// Element X iOS calls the equivalent setup at app launch from
/// `AppCoordinator.init` via its `Tracing.buildConfiguration` helper —
/// see `ElementX/Sources/Other/Logging/Tracing.swift`.
///
/// Call once from each app target's bootstrap (`MatronApp.bootstrap()` /
/// `MatronMacApp.bootstrap()`). Subsequent calls no-op via the
/// `didSetup` guard so the safety contract holds even if a future caller
/// double-invokes by mistake.
@MainActor
public enum MatronSDKTracing {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "sdk-tracing")
    private static var didSetup = false

    /// Call once at app launch with a writable directory for rotated log
    /// files. The SDK rotates log files (default 100 MB / 1 week ceiling
    /// per Element X parity) so the directory is safe to leave permanent.
    ///
    /// `useLightweightTokioRuntime` is `false` for host apps and would be
    /// `true` for memory-constrained extensions (iOS NSE) — Phase 4 wires
    /// the NSE side and will pass `true` from there.
    /// Default rotated-log directory under the user's caches:
    ///   - macOS unsandboxed Debug build: `~/Library/Caches/matron-sdk-trace/`
    ///   - macOS sandboxed Release build: `~/Library/Containers/<bundleID>/Data/Library/Caches/matron-sdk-trace/`
    ///   - iOS / iOS Simulator: `<app-data>/Library/Caches/matron-sdk-trace/`
    ///
    /// All three are reachable from the integration harness (the iOS sim
    /// path resolves via `xcrun simctl get_app_container <UDID> chat.matron.app
    /// data`; the macOS Debug path is plain filesystem) so trace files
    /// survive a failed UI test for post-mortem.
    public nonisolated static var defaultLogsDirectory: URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("matron-sdk-trace", isDirectory: true)
    }

    public static func setup(
        logsDirectory: URL = defaultLogsDirectory,
        logLevel: LogLevel = .debug,
        useLightweightTokioRuntime: Bool = false
    ) {
        guard !didSetup else { return }

        do {
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("setup: createDirectory(\(logsDirectory.path, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            // Continue regardless — initPlatform may still succeed with
            // stdoutOrSystem-only output even when file-output setup
            // partially fails. Better to have one channel than zero.
        }

        let fileConfig = TracingFileConfiguration(
            path: logsDirectory.path,
            filePrefix: "matron-sdk",
            fileSuffix: ".log",
            // 100 MB total / 1 week max age — matches Element X's
            // `Tracing.buildConfiguration` ceiling.
            maxTotalSizeBytes: 100 * 1024 * 1024,
            maxAgeSeconds: 7 * 24 * 60 * 60
        )
        let config = TracingConfiguration(
            logLevel: logLevel,
            traceLogPacks: [],
            // `extraTargets` lets the rust side know which span targets
            // to hold to the global level. Our own os.Logger subsystem
            // is `chat.matron`; wiring it here keeps the SDK's
            // `extraTargets` registry consistent with the os.Logger
            // filter the harness uses.
            extraTargets: ["chat.matron"],
            writeToStdoutOrSystem: true,
            writeToFiles: fileConfig,
            sentryConfig: nil
        )

        do {
            try initPlatform(config: config, useLightweightTokioRuntime: useLightweightTokioRuntime)
            didSetup = true
            logger.notice("setup: initPlatform OK — logs at \(logsDirectory.path, privacy: .public) (level=\(String(describing: logLevel), privacy: .public))")
        } catch {
            logger.error("setup: initPlatform threw: \(error.localizedDescription, privacy: .public) — SDK will run silent")
        }
    }
}
