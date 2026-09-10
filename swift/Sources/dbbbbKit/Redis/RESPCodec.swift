import Foundation
import NIOCore

/// One RESP2 reply value. Bulk strings decode as lossy UTF-8 — BullMQ stores
/// only text (JSON payloads) — while command *encoding* is binary-safe on the
/// wire. Server error replies surface as `.error` and are thrown by the
/// connection, except inside pipelines where they land per command.
public enum RedisValue: Sendable, Equatable {
    case status(String)
    case error(String)
    case integer(Int64)
    /// nil is the null bulk string ($-1).
    case bulk(String?)
    /// nil is the null array (*-1).
    indirect case array([RedisValue]?)
}

/// One reply slot of a pipelined batch: either the command's value or the
/// server's error text (mirrors ioredis' `[error, result]` pairs).
public enum RedisPipelineReply: Sendable, Equatable {
    case value(RedisValue)
    case error(String)
}

/// RESP2 wire codec. Encoding and decoding are pure, buffer-based functions
/// so they are unit-testable without a channel.
public enum RESPCodec {
    /// Encodes one command as a RESP array of bulk strings.
    public static func encodeCommand(_ arguments: [String]) -> ByteBuffer {
        var buffer = ByteBuffer()
        encodeCommand(arguments, into: &buffer)
        return buffer
    }

    public static func encodeCommand(_ arguments: [String], into buffer: inout ByteBuffer) {
        buffer.writeString("*\(arguments.count)\r\n")
        for argument in arguments {
            let bytes = Array(argument.utf8)
            buffer.writeString("$\(bytes.count)\r\n")
            buffer.writeBytes(bytes)
            buffer.writeString("\r\n")
        }
    }

    /// Decodes one value from the front of `buffer`, consuming exactly its
    /// bytes. Returns nil (consuming nothing) when the buffer holds only a
    /// partial value.
    public static func decode(_ buffer: inout ByteBuffer) throws -> RedisValue? {
        let mark = buffer.readerIndex
        do {
            return try decodeValue(&buffer)
        } catch DecodeFailure.incomplete {
            buffer.moveReaderIndex(to: mark)
            return nil
        }
    }

    private enum DecodeFailure: Error { case incomplete }

    private static func decodeValue(_ buffer: inout ByteBuffer) throws -> RedisValue {
        guard let head = buffer.readInteger(as: UInt8.self) else { throw DecodeFailure.incomplete }
        switch head {
        case UInt8(ascii: "+"):
            return .status(try readLine(&buffer))
        case UInt8(ascii: "-"):
            return .error(try readLine(&buffer))
        case UInt8(ascii: ":"):
            let line = try readLine(&buffer)
            guard let value = Int64(line) else { throw RedisError.unexpectedReply }
            return .integer(value)
        case UInt8(ascii: "$"):
            let line = try readLine(&buffer)
            guard let length = Int(line) else { throw RedisError.unexpectedReply }
            if length < 0 { return .bulk(nil) }
            guard let bytes = buffer.readBytes(length: length) else { throw DecodeFailure.incomplete }
            try readCRLF(&buffer)
            return .bulk(String(decoding: bytes, as: UTF8.self))
        case UInt8(ascii: "*"):
            let line = try readLine(&buffer)
            guard let count = Int(line) else { throw RedisError.unexpectedReply }
            if count < 0 { return .array(nil) }
            var elements: [RedisValue] = []
            elements.reserveCapacity(count)
            for _ in 0..<count {
                elements.append(try decodeValue(&buffer))
            }
            return .array(elements)
        default:
            throw RedisError.unexpectedReply
        }
    }

    private static func readLine(_ buffer: inout ByteBuffer) throws -> String {
        let view = buffer.readableBytesView
        guard let newline = view.firstIndex(of: UInt8(ascii: "\n")) else {
            throw DecodeFailure.incomplete
        }
        let length = view.distance(from: view.startIndex, to: newline)
        guard var line = buffer.readString(length: length) else { throw DecodeFailure.incomplete }
        buffer.moveReaderIndex(forwardBy: 1) // the "\n" itself
        guard line.hasSuffix("\r") else { throw RedisError.unexpectedReply }
        line.removeLast()
        return line
    }

    private static func readCRLF(_ buffer: inout ByteBuffer) throws {
        guard let cr = buffer.readInteger(as: UInt8.self),
              let lf = buffer.readInteger(as: UInt8.self) else { throw DecodeFailure.incomplete }
        guard cr == UInt8(ascii: "\r"), lf == UInt8(ascii: "\n") else {
            throw RedisError.unexpectedReply
        }
    }
}
