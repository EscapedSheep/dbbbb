import Foundation
import dbbbbCore

/// A canned SQL table (or view) for the demo adapter.
struct DemoTable: Sendable {
    let object: DatabaseObject
    let columns: [ColumnMeta]
    let rows: [[DisplayValue]]
}

/// A canned MongoDB collection for the demo adapter.
struct DemoCollection: Sendable {
    let object: DatabaseObject
    let documents: [DisplayValue]
}

/// Static, bounded in-memory dataset backing one demo connection.
struct DemoFixture: Sendable {
    let objects: [DatabaseObject]
    let tables: [DemoTable]
    let collections: [DemoCollection]
    /// Canned server-activity rows (ROADMAP M2 ⑨); SQLite is file-local and
    /// has no server processes, so its demo fixture stays empty.
    let activities: [ServerActivity]

    static func fixture(for engine: DatabaseEngine) -> DemoFixture {
        switch engine {
        case .postgresql: postgres
        case .mysql: mysql
        case .mongodb: mongo
        case .sqlite: sqlite
        case .bullmq: empty
        }
    }

    /// BullMQ demo sessions never read a fixture — they delegate to a real
    /// `BullmqAdapter` over the in-memory `DemoRedisClient` (see DemoAdapter).
    static let empty = DemoFixture(objects: [], tables: [], collections: [], activities: [])

    // MARK: PostgreSQL — a "warehouse" database with users/orders.

    static let postgres: DemoFixture = {
        let schema = DatabaseObject(id: "pg.schema.public", parentID: nil, name: "public", kind: .schema)
        let users = DatabaseObject(id: "pg.table.users", parentID: schema.id, name: "users", kind: .table)
        let orders = DatabaseObject(id: "pg.table.orders", parentID: schema.id, name: "orders", kind: .table)
        let activeUsers = DatabaseObject(id: "pg.view.active_users", parentID: schema.id, name: "active_users", kind: .view)

        let userColumns = [
            ColumnMeta(name: "id", typeName: "int8", numeric: true),
            ColumnMeta(name: "email", typeName: "text"),
            ColumnMeta(name: "display_name", typeName: "text"),
            ColumnMeta(name: "balance", typeName: "numeric(12,2)", numeric: true),
            ColumnMeta(name: "is_active", typeName: "bool"),
            ColumnMeta(name: "last_login_at", typeName: "timestamptz"),
            ColumnMeta(name: "avatar", typeName: "bytea"),
        ]
        let userRows: [[DisplayValue]] = (1...120).map { i -> [DisplayValue] in
            let lastLogin: DisplayValue = i % 10 == 0
                ? .null
                : .string(String(format: "2026-08-%02d 09:1%d:00+00", (i % 28) + 1, i % 6))
            let avatar: DisplayValue = i % 25 == 0
                ? .binary(Data([0x89, 0x50, 0x4E, 0x47, UInt8(i & 0xFF)]))
                : .null
            // balance is a decimal: it crosses as string to preserve precision.
            return [
                .number(Double(i)),
                .string("user\(i)@example.com"),
                .string("User \(i)"),
                .string(String(format: "%.2f", Double(i) * 13.37)),
                .bool(i % 3 != 0),
                lastLogin,
                avatar,
            ]
        }

        let orderColumns = [
            ColumnMeta(name: "id", typeName: "int8", numeric: true),
            ColumnMeta(name: "user_id", typeName: "int8", numeric: true),
            ColumnMeta(name: "status", typeName: "text"),
            ColumnMeta(name: "total", typeName: "numeric(10,2)", numeric: true),
            ColumnMeta(name: "created_at", typeName: "timestamptz"),
        ]
        let statuses = ["pending", "paid", "shipped", "refunded"]
        // 620 rows: over the default 500-row cap, so the truncation path is visible.
        let orderRows: [[DisplayValue]] = (1...620).map { i -> [DisplayValue] in
            let total: DisplayValue = .string(String(format: "%.2f", Double((i * 7) % 900) + 9.99))
            let createdAt: DisplayValue = .string(String(format: "2026-08-%02d 1%d:30:00+00", (i % 28) + 1, i % 10))
            return [
                .number(Double(10_000 + i)),
                .number(Double((i % 120) + 1)),
                .string(statuses[i % statuses.count]),
                total,
                createdAt,
            ]
        }

        let activeUserColumns = [
            ColumnMeta(name: "id", typeName: "int8", numeric: true),
            ColumnMeta(name: "email", typeName: "text"),
            ColumnMeta(name: "login_count", typeName: "int8", numeric: true),
        ]
        let activeUserRows: [[DisplayValue]] = (1...8).map { i -> [DisplayValue] in
            [.number(Double(i * 3)), .string("user\(i * 3)@example.com"), .number(Double(20 - i))]
        }

        return DemoFixture(
            objects: [schema, users, orders, activeUsers],
            tables: [
                DemoTable(object: users, columns: userColumns, rows: userRows),
                DemoTable(object: orders, columns: orderColumns, rows: orderRows),
                DemoTable(object: activeUsers, columns: activeUserColumns, rows: activeUserRows),
            ],
            collections: [],
            activities: [
                ServerActivity(
                    id: "8124", user: "etl", database: "warehouse",
                    statement: "UPDATE orders SET status = 'paid' WHERE created_at < now() - interval '30 days'",
                    age: .seconds(43), state: "active"),
                ServerActivity(
                    id: "8301", user: "reporting", database: "warehouse",
                    statement: "SELECT user_id, count(*) FROM orders GROUP BY user_id ORDER BY 2 DESC",
                    age: .seconds(3), state: "active"),
                ServerActivity(
                    id: "8310", user: "reporting", database: "warehouse",
                    statement: nil, age: nil, state: "idle"),
            ]
        )
    }()

    // MARK: MongoDB — an "analytics" database with an events collection.

    static let mongo: DemoFixture = {
        let events = DatabaseObject(id: "mongo.collection.events", parentID: nil, name: "events", kind: .collection)
        let sessions = DatabaseObject(id: "mongo.collection.sessions", parentID: nil, name: "sessions", kind: .collection)

        let types = ["signup", "click", "purchase", "logout"]
        let eventDocs: [DisplayValue] = (1...14).map { i -> DisplayValue in
            let user: DisplayValue = .object([
                ("id", .number(Double(1000 + i))),
                ("email", .string("user\(i)@example.com")),
            ])
            let eventError: DisplayValue = i % 5 == 0 ? .string("timeout") : .null
            let pairs: [(String, DisplayValue)] = [
                ("_id", .string(String(format: "66b5f%013d", i))),
                ("type", .string(types[i % types.count])),
                ("user", user),
                ("tags", .array([.string("ios"), .string(i % 2 == 0 ? "beta" : "stable")])),
                ("ok", .bool(i % 5 != 0)),
                ("duration_ms", .number(Double((i * 37) % 400))),
                ("at", .string(String(format: "2026-08-%02dT12:00:00Z", (i % 28) + 1))),
                ("error", eventError),
            ]
            return .object(pairs)
        }

        let sessionDocs: [DisplayValue] = (1...6).map { i -> DisplayValue in
            let device: DisplayValue = .object([
                ("os", .string(i % 2 == 0 ? "macOS" : "iOS")),
                ("version", .string("26.\(i)")),
            ])
            let pairs: [(String, DisplayValue)] = [
                ("_id", .string(String(format: "session-%04d", i))),
                ("user_id", .number(Double(1000 + i))),
                ("started_at", .string(String(format: "2026-08-%02dT08:00:00Z", (i % 28) + 1))),
                ("device", device),
                ("events", .array([.number(Double(i * 3)), .number(Double(i * 3 + 1))])),
            ]
            return .object(pairs)
        }

        return DemoFixture(
            objects: [events, sessions],
            tables: [],
            collections: [
                DemoCollection(object: events, documents: eventDocs),
                DemoCollection(object: sessions, documents: sessionDocs),
            ],
            activities: [
                ServerActivity(
                    id: "22041", user: nil, database: "analytics",
                    statement: #"{"find":"events","filter":{"type":"purchase"}}"#,
                    age: .seconds(12), state: "query"),
            ]
        )
    }()

    // MARK: MySQL — a small "shop" database.

    static let mysql: DemoFixture = {
        let schema = DatabaseObject(id: "mysql.schema.shop", parentID: nil, name: "shop", kind: .schema)
        let products = DatabaseObject(id: "mysql.table.products", parentID: schema.id, name: "products", kind: .table)
        let customers = DatabaseObject(id: "mysql.table.customers", parentID: schema.id, name: "customers", kind: .table)

        let productColumns = [
            ColumnMeta(name: "id", typeName: "BIGINT", numeric: true),
            ColumnMeta(name: "sku", typeName: "VARCHAR(32)"),
            ColumnMeta(name: "title", typeName: "VARCHAR(255)"),
            ColumnMeta(name: "price", typeName: "DECIMAL(8,2)", numeric: true),
            ColumnMeta(name: "in_stock", typeName: "TINYINT(1)"),
        ]
        let productRows: [[DisplayValue]] = (1...24).map { i -> [DisplayValue] in
            [
                .number(Double(i)),
                .string(String(format: "SKU-%04d", i)),
                .string("Product \(i)"),
                .string(String(format: "%.2f", Double(i) * 4.5 + 0.99)),
                .bool(i % 4 != 0),
            ]
        }

        let customerColumns = [
            ColumnMeta(name: "id", typeName: "BIGINT", numeric: true),
            ColumnMeta(name: "name", typeName: "VARCHAR(255)"),
            ColumnMeta(name: "email", typeName: "VARCHAR(255)"),
            ColumnMeta(name: "created_at", typeName: "DATETIME"),
        ]
        let customerRows: [[DisplayValue]] = (1...18).map { i -> [DisplayValue] in
            [
                .number(Double(i)),
                .string("Customer \(i)"),
                .string("customer\(i)@example.com"),
                .string(String(format: "2026-07-%02d 10:00:00", (i % 28) + 1)),
            ]
        }

        return DemoFixture(
            objects: [schema, products, customers],
            tables: [
                DemoTable(object: products, columns: productColumns, rows: productRows),
                DemoTable(object: customers, columns: customerColumns, rows: customerRows),
            ],
            collections: [],
            activities: [
                ServerActivity(
                    id: "58", user: "nightly", database: "shop",
                    statement: "UPDATE products SET price = price * 1.05 WHERE in_stock = 1",
                    age: .seconds(95), state: "Query"),
                ServerActivity(
                    id: "61", user: "app", database: "shop",
                    statement: nil, age: nil, state: "Sleep"),
            ]
        )
    }()

    // MARK: SQLite — a tiny local notes database.

    static let sqlite: DemoFixture = {
        let notes = DatabaseObject(id: "sqlite.table.notes", parentID: nil, name: "notes", kind: .table)
        let settings = DatabaseObject(id: "sqlite.table.settings", parentID: nil, name: "settings", kind: .table)

        let noteColumns = [
            ColumnMeta(name: "id", typeName: "INTEGER", numeric: true),
            ColumnMeta(name: "title", typeName: "TEXT"),
            ColumnMeta(name: "body", typeName: "TEXT"),
            ColumnMeta(name: "pinned", typeName: "INTEGER"),
            ColumnMeta(name: "updated_at", typeName: "TEXT"),
        ]
        let noteRows: [[DisplayValue]] = (1...8).map { i -> [DisplayValue] in
            [
                .number(Double(i)),
                .string("Note \(i)"),
                .string("Body of note \(i)"),
                .bool(i == 1),
                .string(String(format: "2026-08-%02d 07:45:00", (i % 28) + 1)),
            ]
        }

        let settingColumns = [
            ColumnMeta(name: "key", typeName: "TEXT"),
            ColumnMeta(name: "value", typeName: "TEXT"),
        ]
        let settingRows: [[DisplayValue]] = [
            [.string("theme"), .string("system")],
            [.string("sync.enabled"), .string("true")],
            [.string("sync.endpoint"), .null],
            [.string("font.size"), .string("13")],
            [.string("last.backup"), .string("2026-08-30 02:00:00")],
        ]

        return DemoFixture(
            objects: [notes, settings],
            tables: [
                DemoTable(object: notes, columns: noteColumns, rows: noteRows),
                DemoTable(object: settings, columns: settingColumns, rows: settingRows),
            ],
            collections: [],
            // SQLite is file-local: no server processes to list.
            activities: []
        )
    }()
}
