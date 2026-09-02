// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dbbbb",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "dbbbb", targets: ["dbbbbApp"]),
        .library(name: "dbbbbCore", targets: ["dbbbbCore"]),
        .library(name: "dbbbbKit", targets: ["dbbbbKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.9.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "dbbbbCore"),
        .target(
            name: "dbbbbKit",
            dependencies: [
                "dbbbbCore",
                .product(name: "MongoKitten", package: "MongoKitten"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "dbbbbApp",
            dependencies: ["dbbbbCore", "dbbbbKit"]
        ),
        .testTarget(name: "dbbbbCoreTests", dependencies: ["dbbbbCore"]),
        .testTarget(name: "dbbbbKitTests", dependencies: ["dbbbbKit"]),
    ]
)
