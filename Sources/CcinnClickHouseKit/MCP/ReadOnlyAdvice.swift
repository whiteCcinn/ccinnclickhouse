import Foundation

/// The recommended way to give AI clients (or anyone) read-only access: a dedicated ClickHouse user
/// whose *settings profile* is read-only and who holds SELECT grants only. The server then enforces
/// read-only access by itself — through proxies that drop URL settings (chproxy) too — and table
/// functions that reach outside ClickHouse (`url`, `file`, `s3`, `remote`, …) stay denied because the
/// user lacks the SOURCES grants they need. The app's `readonly=1` parameter and its SQL guard remain
/// additional layers.
public enum ReadOnlyAdvice {
    public static let summary = """
        For real isolation, connect AI access as a dedicated ClickHouse user whose settings profile is read-only \
        and who has SELECT grants only (no SOURCES, URL, FILE, REMOTE, S3 … grants). ClickHouse then enforces \
        read-only access itself, also behind proxies such as chproxy that drop the readonly parameter.
        """

    /// SQL an administrator can run (ClickHouse 22.x and later; verified on 22.8 and 26.8).
    public static let setupSQL = """
        CREATE SETTINGS PROFILE IF NOT EXISTS ai_readonly SETTINGS readonly = 1;
        CREATE USER IF NOT EXISTS ai_reader IDENTIFIED WITH sha256_password BY 'choose-a-password' SETTINGS PROFILE 'ai_readonly';
        GRANT SELECT ON analytics.* TO ai_reader;
        -- Grant nothing else: without SOURCES grants, url(), file(), s3(), remote() … stay denied.
        """

    /// Shown after a successful connection test.
    public static func connectionNote(profileIsReadOnly: Bool, enforcedByUserProfile: Bool) -> String? {
        if enforcedByUserProfile { return "read-only enforced by this user's server profile (recommended for AI access)" }
        if profileIsReadOnly { return "read-only via readonly=1 — for AI access a dedicated user with a read-only profile is recommended" }
        return nil
    }
}
