import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// The double-click "run this SELECT" statement builder: qualified names are
/// recovered from the opaque object ids and quoted exactly like previews;
/// foreign handles fall back to quoting the bare object name.
final class SelectStatementBuilderTests: XCTestCase {
    func testPostgresQualifiedNameFromObjectID() throws {
        let ref = PostgresObjectRef(kind: .table, schema: "weird\"schema", name: "user\"s")
        let object = DatabaseObject(
            id: PostgresObjectIDCodec.encode(ref), parentID: nil, name: ref.name!, kind: .table)
        let statement = try SelectStatementBuilder.selectLimit100(engine: .postgresql, object: object)
        XCTAssertEqual(statement, #"select * from "weird""schema"."user""s" limit 100;"#)
    }

    func testPostgresFallsBackToQuotedBareName() throws {
        // Demo-fixture ids do not decode; the bare name is still quoted.
        let object = DatabaseObject(id: "pg.table.users", parentID: nil, name: "users", kind: .table)
        let statement = try SelectStatementBuilder.selectLimit100(engine: .postgresql, object: object)
        XCTAssertEqual(statement, #"select * from "users" limit 100;"#)
    }

    func testMySQLQualifiedNameFromObjectID() throws {
        let ref = MySQLObjectRef(kind: .table, database: "app`db", name: "order`items")
        let object = DatabaseObject(id: ref.id, parentID: nil, name: ref.name!, kind: .table)
        let statement = try SelectStatementBuilder.selectLimit100(engine: .mysql, object: object)
        XCTAssertEqual(statement, "select * from `app``db`.`order``items` limit 100;")
    }

    func testMySQLFallsBackToQuotedBareName() throws {
        let object = DatabaseObject(id: "t1", parentID: nil, name: "items", kind: .table)
        let statement = try SelectStatementBuilder.selectLimit100(engine: .mysql, object: object)
        XCTAssertEqual(statement, "select * from `items` limit 100;")
    }

    func testSQLiteQuotesBareName() throws {
        let object = DatabaseObject(id: "t1", parentID: nil, name: "weird\"table", kind: .table)
        let statement = try SelectStatementBuilder.selectLimit100(engine: .sqlite, object: object)
        XCTAssertEqual(statement, #"select * from "weird""table" limit 100;"#)
    }

    func testMongoDBHasNoSelect() {
        let object = DatabaseObject(id: "c1", parentID: nil, name: "events", kind: .collection)
        XCTAssertThrowsError(
            try SelectStatementBuilder.selectLimit100(engine: .mongodb, object: object)
        ) { error in
            XCTAssertEqual(error as? AdapterError, .engineMismatch)
        }
    }
}
