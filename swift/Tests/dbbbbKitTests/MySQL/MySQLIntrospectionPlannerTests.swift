import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Offline coverage for the MySQL create-statement introspection, the
/// database-less connection shape, and the server-wide object tree.
final class MySQLIntrospectionPlannerTests: XCTestCase {
    func testShowCreateTableSQLQuotesIdentifiers() {
        let sql = MySQLIntrospectionPlanner.showCreateStatementSQL(
            database: "app`db", name: "order`items", isView: false)
        XCTAssertEqual(sql, "SHOW CREATE TABLE `app``db`.`order``items`")
    }

    func testShowCreateViewSQLUsesViewForm() {
        let sql = MySQLIntrospectionPlanner.showCreateStatementSQL(
            database: "analytics", name: "active_users", isView: true)
        XCTAssertEqual(sql, "SHOW CREATE VIEW `analytics`.`active_users`")
    }

    func testEmptyDatabaseIsAcceptedAndMarkedServerWide() async throws {
        let adapter = try MySQLAdapter(input: .init(
            name: "t", host: "localhost", username: "root",
            password: "", database: "  ", sslMode: .disable))
        XCTAssertEqual(adapter.profile.database, "server-wide")
        await adapter.close()
    }

    func testEmptyHostIsStillRejected() {
        XCTAssertThrowsError(try MySQLAdapter(input: .init(
            name: "t", host: " ", username: "root",
            password: "", database: "db", sslMode: .disable)))
    }

    func testObjectRefIDRoundTrip() {
        let ref = MySQLObjectRef(kind: .view, database: "analytics", name: "active_users")
        XCTAssertEqual(MySQLObjectRef(id: ref.id), ref)
        XCTAssertNil(MySQLObjectRef(id: "t1"))
        XCTAssertNil(MySQLObjectRef(id: "mysql:!!!not-base64!!!"))
        let databaseRef = MySQLObjectRef(kind: .database, database: "analytics", name: nil)
        XCTAssertEqual(MySQLObjectRef(id: databaseRef.id), databaseRef)
    }

    func testServerWideTreeGroupsChildrenUnderSchemaNodes() throws {
        let tree = try MySQLAdapter.serverWideTree(rows: [
            (schema: "app", name: "users", type: "BASE TABLE"),
            (schema: "app", name: "active_users", type: "VIEW"),
            (schema: "analytics", name: "events", type: "BASE TABLE"),
            (schema: "mysql", name: "ignored_type", type: "SYSTEM VIEW"),
        ])

        let roots = tree.objects.filter { $0.parentID == nil }
        XCTAssertEqual(roots.map(\.name), ["app", "analytics"])
        XCTAssertTrue(roots.allSatisfy { $0.kind == .database })

        let appChildren = tree.objects.filter { $0.parentID == roots[0].id }
        XCTAssertEqual(appChildren.map(\.name), ["users", "active_users"])
        XCTAssertEqual(appChildren.map(\.kind), [.table, .view])
        let analyticsChildren = tree.objects.filter { $0.parentID == roots[1].id }
        XCTAssertEqual(analyticsChildren.map(\.name), ["events"])

        // Every child's ref carries its own schema, so preview/editing/import
        // qualify correctly on a database-less connection.
        let usersRef = try XCTUnwrap(tree.refs[appChildren[0].id])
        XCTAssertEqual(usersRef.database, "app")
        XCTAssertEqual(usersRef.name, "users")
        let eventsRef = try XCTUnwrap(tree.refs[analyticsChildren[0].id])
        XCTAssertEqual(eventsRef.database, "analytics")
        // Non-table/view rows are skipped, never surfaced as objects.
        XCTAssertEqual(tree.objects.count, 5)
    }
}
