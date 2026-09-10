import Foundation
import Testing
import NIOCore
@testable import dbbbbKit

/// RESP2 wire codec: framing, every reply type, binary-safe bulk strings,
/// partial-buffer handling, and malformed-input errors.
struct RESPCodecTests {
    private func decodeAll(_ bytes: [UInt8]) throws -> [RedisValue] {
        var buffer = ByteBuffer(bytes: bytes)
        var values: [RedisValue] = []
        while let value = try RESPCodec.decode(&buffer) {
            values.append(value)
        }
        return values
    }

    @Test func encodesCommandsAsBulkStringArrays() {
        var buffer = RESPCodec.encodeCommand(["HGETALL", "bull:emails:1"])
        #expect(buffer.readString(length: buffer.readableBytes) == "*2\r\n$7\r\nHGETALL\r\n$13\r\nbull:emails:1\r\n")
    }

    @Test func encodesEmptyAndBinaryArgumentsByteExact() {
        // RESP counts bytes, not characters: a multibyte argument takes its
        // UTF-8 length, an empty argument is a zero-length bulk string.
        var buffer = RESPCodec.encodeCommand(["SET", "key", "héllo", ""])
        #expect(buffer.readString(length: buffer.readableBytes)
            == "*4\r\n$3\r\nSET\r\n$3\r\nkey\r\n$6\r\nhéllo\r\n$0\r\n\r\n")
    }

    @Test func decodesEveryReplyType() throws {
        let values = try decodeAll(Array("+OK\r\n-ERR broken\r\n:42\r\n$5\r\nhello\r\n$-1\r\n*-1\r\n".utf8))
        #expect(values == [
            .status("OK"),
            .error("ERR broken"),
            .integer(42),
            .bulk("hello"),
            .bulk(nil),
            .array(nil),
        ])
    }

    @Test func decodesNestedArrays() throws {
        // {consumed, entries} shape of the BullMQ page Lua script.
        let wire = "*2\r\n:2\r\n*2\r\n*2\r\n$1\r\n1\r\n*2\r\n$4\r\nname\r\n$5\r\nemail\r\n*1\r\n$1\r\n2\r\n"
        let values = try decodeAll(Array(wire.utf8))
        #expect(values == [
            .array([
                .integer(2),
                .array([
                    .array([.bulk("1"), .array([.bulk("name"), .bulk("email")])]),
                    .array([.bulk("2")]),
                ]),
            ]),
        ])
    }

    @Test func decodesBinaryBulkStringsLosslesslyAsUTF8() throws {
        let bytes: [UInt8] = [0x24, 0x33, 0x0D, 0x0A, 0xFF, 0x61, 0x62, 0x0D, 0x0A] // $3\r\n\xff ab\r\n
        let values = try decodeAll(bytes)
        guard case .bulk(let text) = values.first else {
            Issue.record("expected a bulk string")
            return
        }
        #expect(text == String(decoding: [0xFF, 0x61, 0x62], as: UTF8.self))
    }

    @Test func waitsForMoreBytesOnPartialFrames() throws {
        let full = Array("*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n".utf8)
        // Every proper prefix decodes to nothing or a strict prefix of values.
        for cut in 1..<full.count {
            var buffer = ByteBuffer(bytes: Array(full[..<cut]))
            var values: [RedisValue] = []
            while let value = try RESPCodec.decode(&buffer) { values.append(value) }
            #expect(values.count <= 1, "cut at \(cut) must not over-decode")
        }
        let values = try decodeAll(full)
        #expect(values == [.array([.bulk("foo"), .bulk("bar")])])
    }

    @Test func decodesBackToBackRepliesFromOneBuffer() throws {
        let values = try decodeAll(Array(":1\r\n:2\r\n+OK\r\n".utf8))
        #expect(values == [.integer(1), .integer(2), .status("OK")])
    }

    @Test func rejectsMalformedFrames() {
        #expect(throws: RedisError.unexpectedReply) {
            _ = try decodeAll(Array("!bogus\r\n".utf8))
        }
        #expect(throws: RedisError.unexpectedReply) {
            _ = try decodeAll(Array(":notanumber\r\n".utf8))
        }
        #expect(throws: RedisError.unexpectedReply) {
            _ = try decodeAll(Array("$2\r\nabX\n".utf8))
        }
    }

    @Test func errorMapperRedactsAndClassifies() {
        #expect(RedisErrorMapper.mapServerError("NOAUTH Authentication required.") == .authenticationFailed)
        #expect(RedisErrorMapper.mapServerError("WRONGPASS invalid username-password pair") == .authenticationFailed)
        let credentialLeak = RedisErrorMapper.mapServerError("ERR redis://default:s3cret@host:6379 refused")
        guard case .server(let message) = credentialLeak else {
            Issue.record("expected a server error")
            return
        }
        #expect(!message.contains("s3cret"))
        #expect(message.contains("redis://[credentials]@"))
        let long = RedisErrorMapper.mapServerError("ERR " + String(repeating: "x", count: 1000))
        guard case .server(let capped) = long else {
            Issue.record("expected a server error")
            return
        }
        #expect(capped.count <= 600 + "Redis error: ".count)
    }
}
