import Foundation
import MySQLNIO

/// A text-protocol (COM_QUERY) result that keeps column metadata even when the
/// result set is empty. MySQLNIO's `simpleQuery` only exposes columns through
/// materialized rows, so an empty `SELECT` would lose its column definitions;
/// the Electron adapter always has them, and the UI needs them either way.
struct MySQLTextQueryResult: Sendable {
    var columns: [MySQLProtocol.ColumnDefinition41]
    var rows: [MySQLRow]
}

extension MySQLConnection {
    /// Runs a text query, keeping at most `rowLimit` rows. Rows past the budget
    /// are decoded and dropped as they arrive, so memory stays bounded even for
    /// huge result sets; the caller passes maxRows + 1 to detect truncation.
    func textQuery(_ sql: String, rowLimit: Int) -> EventLoopFuture<MySQLTextQueryResult> {
        let command = MySQLTextQueryCommand(sql: sql, rowLimit: rowLimit)
        return self.send(command, logger: self.logger).map { command.result }
    }
}

/// Mirrors MySQLNIO's private `MySQLSimpleQueryCommand`, additionally recording
/// column definitions. All mutation happens on the connection's event loop;
/// the result is read only after the send future completes.
final class MySQLTextQueryCommand: MySQLCommand, @unchecked Sendable {
    enum State {
        case ready
        case columns(count: UInt64)
        case rows
        case done
    }

    let sql: String
    let rowLimit: Int
    var state: State = .ready
    var columns: [MySQLProtocol.ColumnDefinition41] = []
    var rows: [MySQLRow] = []

    var result: MySQLTextQueryResult {
        MySQLTextQueryResult(columns: columns, rows: rows)
    }

    init(sql: String, rowLimit: Int) {
        self.sql = sql
        self.rowLimit = max(0, rowLimit)
    }

    func handle(
        packet: inout MySQLPacket,
        capabilities: MySQLProtocol.CapabilityFlags
    ) throws -> MySQLCommandState {
        guard !packet.isError else {
            self.state = .done
            let errorPacket = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
            switch errorPacket.errorCode {
            case .DUP_ENTRY:
                throw MySQLError.duplicateEntry(errorPacket.errorMessage)
            case .PARSE_ERROR:
                throw MySQLError.invalidSyntax(errorPacket.errorMessage)
            default:
                throw MySQLError.server(errorPacket)
            }
        }
        switch self.state {
        case .ready:
            if packet.isOK {
                self.state = .done
                return MySQLCommandState(done: true)
            }
            let response = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
            self.state = .columns(count: response.columnCount)
            return MySQLCommandState()
        case .columns(let total):
            let column = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
            self.columns.append(column)
            if self.columns.count == numericCast(total) {
                self.state = .rows
            }
            return MySQLCommandState()
        case .rows:
            guard !packet.isEOF else {
                self.state = .done
                return MySQLCommandState(done: true)
            }
            let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columns.count)
            if self.rows.count < self.rowLimit {
                self.rows.append(MySQLRow(format: .text, columnDefinitions: columns, values: row.values))
            }
            return MySQLCommandState()
        case .done:
            throw MySQLError.protocolError
        }
    }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        MySQLCommandState(response: [try .encode(MySQLProtocol.COM_QUERY(query: self.sql), capabilities: capabilities)])
    }
}
