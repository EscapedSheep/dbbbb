import XCTest
import Foundation
@testable import dbbbbKit
@testable import MySQLNIO
import NIOCore

/// Row-budget tests for the text-protocol query command, driving the command
/// with hand-crafted wire packets — no server needed.
final class MySQLTextQueryTests: XCTestCase {
    private let capabilities = MySQLProtocol.CapabilityFlags.clientDefault

    private static func packet(_ bytes: [UInt8]) -> MySQLPacket {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return MySQLPacket(payload: buffer)
    }

    private static func lengthEncodedString(_ text: String) -> [UInt8] {
        [UInt8(text.utf8.count)] + Array(text.utf8)
    }

    /// One INT column definition (`ColumnDefinition41`), matching the decoder's
    /// fixed-length block: charset(1) + collate(1) + length(4) + type(1) +
    /// flags(2) + decimals(1) + filler(2).
    private static func columnDefinitionPacket(name: String) -> MySQLPacket {
        var bytes: [UInt8] = []
        for string in ["def", "", "", "", name, name] {
            bytes.append(contentsOf: lengthEncodedString(string))
        }
        bytes.append(0x0C)
        bytes.append(33)                            // charset utf8_general_ci
        bytes.append(0)                             // collate
        bytes.append(contentsOf: [11, 0, 0, 0])     // column length
        bytes.append(0x03)                          // MYSQL_TYPE_LONG
        bytes.append(contentsOf: [0, 0])            // flags
        bytes.append(0)                             // decimals
        bytes.append(contentsOf: [0, 0])            // filler
        return packet(bytes)
    }

    private static func rowPacket(_ value: String) -> MySQLPacket {
        packet(lengthEncodedString(value))
    }

    private static func eofPacket() -> MySQLPacket {
        packet([0xFE, 0x00, 0x00, 0x02, 0x00])
    }

    func testRowBudgetStopsAccumulationButStillDrains() throws {
        let command = MySQLTextQueryCommand(sql: "SELECT n FROM t", rowLimit: 3)

        var countPacket = Self.packet([0x01])
        _ = try command.handle(packet: &countPacket, capabilities: capabilities)
        var columnPacket = Self.columnDefinitionPacket(name: "n")
        _ = try command.handle(packet: &columnPacket, capabilities: capabilities)
        for value in 0..<10 {
            var row = Self.rowPacket(String(value))
            _ = try command.handle(packet: &row, capabilities: capabilities)
        }
        var eof = Self.eofPacket()
        let final = try command.handle(packet: &eof, capabilities: capabilities)

        XCTAssertTrue(final.done)
        XCTAssertEqual(command.result.columns.map(\.name), ["n"])
        // Rows past the budget are decoded and dropped, never appended.
        XCTAssertEqual(command.result.rows.count, 3)
        XCTAssertEqual(
            command.result.rows.map { $0.column("n")?.string },
            ["0", "1", "2"])
    }

    func testResultBelowBudgetIsKeptInFull() throws {
        let command = MySQLTextQueryCommand(sql: "SELECT n FROM t", rowLimit: 4)

        var countPacket = Self.packet([0x01])
        _ = try command.handle(packet: &countPacket, capabilities: capabilities)
        var columnPacket = Self.columnDefinitionPacket(name: "n")
        _ = try command.handle(packet: &columnPacket, capabilities: capabilities)
        for value in 0..<3 {
            var row = Self.rowPacket(String(value))
            _ = try command.handle(packet: &row, capabilities: capabilities)
        }
        var eof = Self.eofPacket()
        let final = try command.handle(packet: &eof, capabilities: capabilities)

        XCTAssertTrue(final.done)
        XCTAssertEqual(command.result.rows.count, 3)
    }
}
