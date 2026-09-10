import Foundation
import dbbbbCore
import NIOCore
import NIOPosix
import NIOSSL
import Synchronization

/// FIFO pairing of outbound commands to inbound replies: Redis answers in
/// order on one connection, so each decoded reply completes the oldest waiter.
/// Waiters are either single-command continuations or pipeline batch handlers.
final class RedisResponseRouter: Sendable {
    enum Waiter {
        case single(CheckedContinuation<RedisValue, any Error>)
        case batch(@Sendable (Result<RedisValue, any Error>) -> Void)
    }

    private struct State {
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    func enqueue(_ waiter: Waiter) {
        state.withLock { $0.waiters.append(waiter) }
    }

    /// Routes one decoded reply to the oldest waiter. A reply with no waiter
    /// (e.g. it outlived a timeout) is dropped — the caller has already seen
    /// a timeout error and the connection is closing anyway.
    func complete(_ value: RedisValue) {
        let waiter = state.withLock { state -> Waiter? in
            state.waiters.isEmpty ? nil : state.waiters.removeFirst()
        }
        switch waiter {
        case .single(let continuation): continuation.resume(returning: value)
        case .batch(let handler): handler(.success(value))
        case nil: break
        }
    }

    func failAll(_ error: any Error) {
        let waiters = state.withLock { state -> [Waiter] in
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            switch waiter {
            case .single(let continuation): continuation.resume(throwing: error)
            case .batch(let handler): handler(.failure(error))
            }
        }
    }
}

/// Decodes RESP2 frames from the byte stream.
struct RESPMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = RedisValue

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let value = try RESPCodec.decode(&buffer) else { return .needMoreData }
        context.fireChannelRead(wrapInboundOut(value))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        .needMoreData
    }
}

/// Hands decoded replies to the router; any channel failure or close fails
/// every pending waiter so commands never hang.
final class RedisInboundHandler: ChannelInboundHandler {
    typealias InboundIn = RedisValue

    private let router: RedisResponseRouter

    init(router: RedisResponseRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        router.complete(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        router.failAll(RedisErrorMapper.map(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        router.failAll(RedisError.closed)
        context.fireChannelInactive()
    }
}

/// Collects one pipeline's per-command replies and completes once every slot
/// has an answer. A transport failure fails the whole batch (first error wins).
private final class PipelineBatch: Sendable {
    private struct State {
        var nextIndex = 0
        var replies: [RedisPipelineReply?]
        /// Set exactly once, when the batch finishes — possibly before
        /// `awaitReplies` installs its continuation (timeout path).
        var result: Result<[RedisPipelineReply], any Error>?
        var continuation: CheckedContinuation<[RedisPipelineReply], any Error>?
    }

    private let state: Mutex<State>

    init(count: Int) {
        state = Mutex(State(replies: [RedisPipelineReply?](repeating: nil, count: count)))
    }

    /// One reply handler per pipelined command, handed out in command order.
    func makeHandler() -> @Sendable (Result<RedisValue, any Error>) -> Void {
        let index = state.withLock { state -> Int in
            let index = state.nextIndex
            state.nextIndex += 1
            return index
        }
        return { [self] incoming in
            let completed = state.withLock { state -> (CheckedContinuation<[RedisPipelineReply], any Error>, Result<[RedisPipelineReply], any Error>)? in
                guard state.result == nil else { return nil }
                let result: Result<[RedisPipelineReply], any Error>
                switch incoming {
                case .success(.error(let text)):
                    state.replies[index] = .error(text)
                    guard state.replies.allSatisfy({ $0 != nil }) else { return nil }
                    result = .success(state.replies.compactMap { $0 })
                case .success(let value):
                    state.replies[index] = .value(value)
                    guard state.replies.allSatisfy({ $0 != nil }) else { return nil }
                    result = .success(state.replies.compactMap { $0 })
                case .failure(let error):
                    result = .failure(error)
                }
                state.result = result
                guard let continuation = state.continuation else { return nil }
                state.continuation = nil
                return (continuation, result)
            }
            if let (continuation, result) = completed {
                continuation.resume(with: result)
            }
        }
    }

    func awaitReplies() async throws -> [RedisPipelineReply] {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { state -> Result<[RedisPipelineReply], any Error>? in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
}

/// A minimal RESP2 client over SwiftNIO: one TCP connection (optional TLS),
/// AUTH + SELECT on connect, strict request/response pairing, and pipelining.
/// A per-command watchdog closes the connection on timeout — a late reply
/// would desynchronize the FIFO pairing, so the connection cannot survive it.
public actor RedisConnection: RedisClienting {
    private let host: String
    private let port: Int
    private let password: String
    private let database: Int
    private let tls: Bool
    private let commandTimeout: Duration

    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private var router: RedisResponseRouter?

    public init(
        host: String,
        port: Int,
        password: String = "",
        database: Int = 0,
        tls: Bool = false,
        commandTimeout: Duration = .seconds(30)
    ) {
        self.host = host; self.port = port; self.password = password
        self.database = database; self.tls = tls
        self.commandTimeout = commandTimeout
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func connect() async throws {
        guard channel == nil else { return }
        let router = RedisResponseRouter()
        let host = self.host
        let useTLS = tls
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
        do {
            let channel = try await bootstrap.connect(host: host, port: port) { channel in
                // Event-loop-confined setup: syncOperations sidesteps the
                // Sendable requirements of the async addHandler variants.
                channel.eventLoop.makeCompletedFuture { () -> any Channel in
                    if useTLS {
                        var configuration = TLSConfiguration.makeClientConfiguration()
                        configuration.certificateVerification = .fullVerification
                        let sslContext = try NIOSSLContext(configuration: configuration)
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: sslContext, serverHostname: host))
                    }
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(RESPMessageDecoder()))
                    try channel.pipeline.syncOperations.addHandler(RedisInboundHandler(router: router))
                    return channel
                }
            }
            self.channel = channel
            self.router = router
            if !password.isEmpty {
                _ = try await command(["AUTH", password])
            }
            _ = try await command(["SELECT", String(database)])
        } catch {
            if let channel { try? await channel.close() }
            channel = nil
            self.router = nil
            throw RedisErrorMapper.map(error)
        }
    }

    public func ping() async throws {
        _ = try await command(["PING"])
    }

    public func disconnect() async {
        let channel = self.channel
        self.channel = nil
        let router = self.router
        self.router = nil
        router?.failAll(RedisError.closed)
        try? await channel?.close()
        try? await group.shutdownGracefully()
    }

    // MARK: - Commands

    /// Sends one command and awaits its reply. Server `-ERR` replies throw.
    public func command(_ arguments: [String]) async throws -> RedisValue {
        switch try await send(arguments) {
        case .error(let text): throw RedisErrorMapper.mapServerError(text)
        case let value: return value
        }
    }

    public func pipeline(_ commands: [[String]]) async throws -> [RedisPipelineReply] {
        guard !commands.isEmpty else { return [] }
        guard let channel, let router else { throw RedisError.closed }
        return try await withCommandTimeout {
            var buffer = RESPCodec.encodeCommand(commands[0])
            for arguments in commands.dropFirst() {
                RESPCodec.encodeCommand(arguments, into: &buffer)
            }
            let batch = PipelineBatch(count: commands.count)
            for _ in commands {
                router.enqueue(.batch(batch.makeHandler()))
            }
            channel.writeAndFlush(buffer).whenFailure { _ in
                // The byte stream may be torn; close so failAll releases waiters.
                channel.close(promise: nil)
            }
            return try await batch.awaitReplies()
        }
    }

    public func eval(_ script: String, keys: [String], arguments: [String]) async throws -> RedisValue {
        try await command(["EVAL", script, String(keys.count)] + keys + arguments)
    }

    public func scan(cursor: String, match: String, count: Int) async throws -> (nextCursor: String, keys: [String]) {
        let reply = try await command(["SCAN", cursor, "MATCH", match, "COUNT", String(count)])
        guard case .array(let parts) = reply, let parts, parts.count == 2,
              case .bulk(let next) = parts[0], let next,
              case .array(let keyValues) = parts[1] else {
            throw RedisError.unexpectedReply
        }
        return (next, try Self.stringArray(keyValues))
    }

    public func zcard(_ key: String) async throws -> Int {
        try await count(["ZCARD", key])
    }

    public func zcount(_ key: String, min: String, max: String) async throws -> Int {
        try await count(["ZCOUNT", key, min, max])
    }

    public func llen(_ key: String) async throws -> Int {
        try await count(["LLEN", key])
    }

    public func zrange(_ key: String, start: Int, stop: Int) async throws -> [String] {
        try await stringArrayCommand(["ZRANGE", key, String(start), String(stop)])
    }

    public func lrange(_ key: String, start: Int, stop: Int) async throws -> [String] {
        try await stringArrayCommand(["LRANGE", key, String(start), String(stop)])
    }

    public func zrangebyscore(_ key: String, min: String, max: String, offset: Int, count: Int) async throws -> [String] {
        try await stringArrayCommand(["ZRANGEBYSCORE", key, min, max, "LIMIT", String(offset), String(count)])
    }

    public func hgetall(_ key: String) async throws -> [String: String] {
        let reply = try await command(["HGETALL", key])
        guard case .array(let flat) = reply, let flat else { throw RedisError.unexpectedReply }
        var fields: [String: String] = [:]
        var index = 0
        while index + 1 < flat.count {
            guard case .bulk(let name) = flat[index], let name,
                  case .bulk(let value) = flat[index + 1] else {
                throw RedisError.unexpectedReply
            }
            fields[name] = value
            index += 2
        }
        return fields
    }

    // MARK: - Internals

    private func count(_ arguments: [String]) async throws -> Int {
        guard case .integer(let value) = try await command(arguments), value >= 0 else {
            throw RedisError.unexpectedReply
        }
        return Int(value)
    }

    private func stringArrayCommand(_ arguments: [String]) async throws -> [String] {
        let reply = try await command(arguments)
        guard case .array(let elements) = reply else { throw RedisError.unexpectedReply }
        return try Self.stringArray(elements)
    }

    private static func stringArray(_ elements: [RedisValue]?) throws -> [String] {
        guard let elements else { return [] }
        return try elements.map { element in
            guard case .bulk(let string) = element, let string else {
                throw RedisError.unexpectedReply
            }
            return string
        }
    }

    private func send(_ arguments: [String]) async throws -> RedisValue {
        guard let channel, let router else { throw RedisError.closed }
        return try await withCommandTimeout {
            let buffer = RESPCodec.encodeCommand(arguments)
            return try await withCheckedThrowingContinuation { continuation in
                router.enqueue(.single(continuation))
                channel.writeAndFlush(buffer).whenFailure { _ in
                    channel.close(promise: nil)
                }
            }
        }
    }

    /// Races the command against the watchdog. A timeout closes the
    /// connection — the outstanding reply would otherwise desync the pairing.
    private func withCommandTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard commandTimeout > .zero else { return try await operation() }
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: self.commandTimeout)
                    throw RedisError.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw RedisError.closed }
                return first
            }
        } catch RedisError.timedOut {
            await disconnect()
            throw RedisError.timedOut
        }
    }
}
