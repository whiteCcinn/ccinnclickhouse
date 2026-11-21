import ClickHouseKit
import Testing
@testable import CcinnClickHouseKit

@Suite("Sidebar placeholder")
struct SidebarPlaceholderTests {
    let shop = DatabaseInfo(name: "shop", engine: "Atomic")
    let system = DatabaseInfo(name: "system", engine: "Atomic")
    let informationSchema = DatabaseInfo(name: "information_schema", engine: "Memory")

    @Test func nothingBeforeTheFirstLoadOrWhenItFailed() {
        #expect(SidebarPlaceholder.make(hasLoaded: false, failed: false, databases: [], showSystem: false) == nil)
        #expect(SidebarPlaceholder.make(hasLoaded: true, failed: true, databases: [], showSystem: false) == nil)
    }

    @Test func aUserWhoSeesNoDatabaseIsTold() {
        #expect(SidebarPlaceholder.make(hasLoaded: true, failed: false, databases: [], showSystem: false) == .noDatabases)
        #expect(SidebarPlaceholder.make(hasLoaded: true, failed: false, databases: [], showSystem: true) == .noDatabases)
    }

    @Test func hiddenSystemDatabasesAreOffered() {
        #expect(SidebarPlaceholder.make(hasLoaded: true, failed: false, databases: [system, informationSchema], showSystem: false)
            == .onlySystemDatabases)
        #expect(SidebarPlaceholder.make(hasLoaded: true, failed: false, databases: [system, informationSchema], showSystem: true) == nil)
    }

    @Test func listedDatabasesNeedNoPlaceholder() {
        #expect(SidebarPlaceholder.make(hasLoaded: true, failed: false, databases: [shop, system], showSystem: false) == nil)
    }
}
