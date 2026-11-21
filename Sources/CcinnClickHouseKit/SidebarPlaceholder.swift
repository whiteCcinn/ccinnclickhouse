import ClickHouseKit

/// What the sidebar says instead of a blank list when it shows no database.
public enum SidebarPlaceholder: Equatable, Sendable {
    /// The connected user can see no database.
    case noDatabases
    /// Every database the user can see is a system database, and system databases are hidden.
    case onlySystemDatabases

    /// `nil` before the first load finishes, when the load failed (its error is shown instead), and when
    /// databases are listed.
    public static func make(hasLoaded: Bool, failed: Bool, databases: [DatabaseInfo], showSystem: Bool) -> SidebarPlaceholder? {
        guard hasLoaded, !failed else { return nil }
        if databases.isEmpty { return .noDatabases }
        if !showSystem, databases.allSatisfy(\.isSystem) { return .onlySystemDatabases }
        return nil
    }
}
