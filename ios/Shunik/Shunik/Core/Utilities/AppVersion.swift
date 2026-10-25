import Foundation

/// The built bundle's marketing version + commit SHA for the Profile
/// version label (profile-version-sha): `v0.1.3 (a1b2c3d)` on Release builds,
/// `v0.1.3 (a1b2c3d) • Debug` on Debug builds. The `v` prefix marks the digits as
/// build metadata. Marketing-version truth lives in `project.yml`
/// (`info.properties`); the SHA is stamped at build time by the
/// `Stamp GIT_COMMIT_SHA` Run Script Phase (`git rev-parse --short=7 HEAD`,
/// fallback `"?"`) into the built bundle's `GIT_COMMIT_SHA` key — same
/// read-the-built-bundle pattern as `AppConfig` reading `API_BASE_URL`.
/// `CFBundleVersion` / `CURRENT_PROJECT_VERSION` keep incrementing for App
/// Store Connect uploads but are no longer displayed.
enum AppVersion {
    /// Pure formatting core with explicit inputs, so tests can cover both
    /// configurations without depending on the running build's bundle keys.
    /// Missing bundle keys fall back to `"?"` (defensive only — a built app
    /// bundle always carries the marketing key, and the stamp script leaves
    /// `"?"` in `GIT_COMMIT_SHA` when git is unavailable).
    static func formatted(
        marketing: String?,
        build: String?,
        isDebug: Bool,
        debugSuffix: String
    ) -> String {
        let base = "v\(marketing ?? "?") (\(build ?? "?"))"
        guard isDebug else { return base }
        return "\(base) • \(debugSuffix)"
    }

    /// The version label for this build. Whether the `Debug` suffix is
    /// appended is a compile-time fact (`#if DEBUG`, matching the repo's
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG` pattern), not a runtime
    /// config lookup.
    static var text: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let sha = Bundle.main.object(forInfoDictionaryKey: "GIT_COMMIT_SHA") as? String
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return formatted(
            marketing: marketing,
            build: sha,
            isDebug: isDebug,
            debugSuffix: L10n.profileVersionDebugSuffix.text
        )
    }
}
