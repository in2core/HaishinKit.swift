import Foundation
import HaishinKit
import libsrt
import Logboard

/// Waits for each listener on its own SRT epoll instance, then calls
/// `srt_accept` on that exact listener socket. Separate epoll instances keep
/// one listener's accept/close lifecycle from changing another's readiness.
private actor SRTListenerAcceptor {
    static let shared = SRTListenerAcceptor()

    private struct PendingAccept {
        let epoll: Int32
        let continuation: CheckedContinuation<SRTSOCKET, Swift.Error>
    }

    private var pending: [SRTSOCKET: PendingAccept] = [:]

    func accept(listener: SRTSOCKET) async throws -> SRTSOCKET {
        return try await withCheckedThrowingContinuation { continuation in
            guard pending[listener] == nil else {
                continuation.resume(throwing: SRTSocket.Error.illegalState(
                    "An accept is already pending for listener socket \(listener)"
                ))
                return
            }

            let epoll = srt_epoll_create()
            guard epoll != SRT_ERROR else {
                continuation.resume(throwing: SRTSocket.Error.illegalState(
                    "Could not create SRT epoll instance: \(String(cString: srt_getlasterror_str()))"
                ))
                return
            }

            var events = Int32(SRT_EPOLL_IN.rawValue)
            guard srt_epoll_add_usock(epoll, listener, &events) != SRT_ERROR else {
                _ = srt_epoll_release(epoll)
                continuation.resume(throwing: SRTSocket.Error.illegalState(
                    "Could not add listener socket \(listener) to SRT epoll: \(String(cString: srt_getlasterror_str()))"
                ))
                return
            }
            pending[listener] = PendingAccept(epoll: epoll, continuation: continuation)
            Task { await runAcceptLoop(listener: listener, epoll: epoll) }
        }
    }

    func cancel(listener: SRTSOCKET) {
        guard let accept = pending.removeValue(forKey: listener) else { return }
        _ = srt_epoll_remove_usock(accept.epoll, listener)
        accept.continuation.resume(throwing: CancellationError())
    }

    private func runAcceptLoop(listener: SRTSOCKET, epoll: Int32) async {
        while pending[listener] != nil {
            let (waitResult, readySocket, waitError) = await Task.detached(priority: .userInitiated) {
                var readSockets = [SRTSOCKET](repeating: SRT_INVALID_SOCK, count: 1)
                var readCount: Int32 = 1
                var writeCount: Int32 = 0
                let result = readSockets.withUnsafeMutableBufferPointer { buffer in
                    srt_epoll_wait(epoll, buffer.baseAddress, &readCount, nil, &writeCount,
                                   -1, nil, nil, nil, nil)
                }
                let ready = result > 0 && readCount > 0 ? readSockets[0] : SRT_INVALID_SOCK
                let error = result == SRT_ERROR ? String(cString: srt_getlasterror_str()) : ""
                return (result, ready, error)
            }.value

            guard let entry = pending[listener] else {
                _ = srt_epoll_release(epoll)
                return
            }

            if waitResult == 0 {
                continue
            }

            if waitResult == SRT_ERROR {
                pending.removeValue(forKey: listener)
                _ = srt_epoll_release(epoll)
                entry.continuation.resume(throwing: SRTSocket.Error.illegalState(waitError))
                return
            }

            guard readySocket == listener else {
                pending.removeValue(forKey: listener)
                _ = srt_epoll_release(epoll)
                let message = "SRT epoll returned unexpected listener socket \(readySocket)"
                entry.continuation.resume(throwing: SRTSocket.Error.illegalState(message))
                return
            }

            pending.removeValue(forKey: listener)
            _ = srt_epoll_remove_usock(epoll, listener)
            _ = srt_epoll_release(epoll)
            let acceptedSocket = srt_accept(listener, nil, nil)
            if acceptedSocket == SRT_ERROR {
                let message = String(cString: srt_getlasterror_str())
                entry.continuation.resume(throwing: SRTSocket.Error.illegalState(message))
            } else {
                entry.continuation.resume(returning: acceptedSocket)
            }
            return
        }

        _ = srt_epoll_release(epoll)
    }
}

final actor SRTSocket {
    static let payloadSize: Int = 1316

    enum Error: Swift.Error {
        case notConnected
        case invalidArgument(_ message: String)
        case rejected(_ reason: SRTRejectReason)
        case illegalState(_ message: String)
    }

    enum Status: Int, CustomDebugStringConvertible {
        case unknown
        case `init`
        case opened
        case listening
        case connecting
        case connected
        case broken
        case closing
        case closed
        case nonexist

        var debugDescription: String {
            switch self {
            case .unknown:
                return "unknown"
            case .`init`:
                return "init"
            case .opened:
                return "opened"
            case .listening:
                return "listening"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .broken:
                return "broken"
            case .closing:
                return "closing"
            case .closed:
                return "closed"
            case .nonexist:
                return "nonexist"
            }
        }

        init?(_ status: SRT_SOCKSTATUS) {
            self.init(rawValue: Int(status.rawValue))
            defer {
                logger.trace(debugDescription)
            }
        }
    }

    var inputs: AsyncStream<Data> {
        AsyncStream<Data> { continuation in
            Task.detached { [self] in
                let descriptor = await self.socket
                let bufferSize = await self.windowSizeC

                var buffer = Data(count: Int(bufferSize))

                while await self.connected {
                    let result = buffer.withUnsafeMutableBytes { pointer -> Int32 in
                        guard let bytes = pointer.baseAddress?
                            .assumingMemoryBound(to: CChar.self) else {
                            return SRT_ERROR
                        }

                        return srt_recvmsg(descriptor, bytes, bufferSize)
                    }

                    guard result >= 0 else {
                        await self.stopRunning()
                        break
                    }

                    continuation.yield(
                        buffer.subdata(in: 0..<Int(result))
                    )
                }

                continuation.finish()
            }
        }
    }

    var performanceData: SRTPerformanceData {
        .init(mon: perf)
    }

    var status: Status {
        .init(srt_getsockstate(socket)) ?? .unknown
    }

    var streamID: String? {
        get throws {
            var value = try getSocketOption(.streamid).stringValue
            guard value.isEmpty == false else {
                return peerHost() ?? nil
            }
            return value
        }
    }
    
    private(set) var isRunning = false
    private var perf: CBytePerfMon = .init()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var outputs: AsyncStream<Data>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var connected: Bool {
        status == .connected
    }
    private var windowSizeC: Int32 = 1024 * 4
    private lazy var incomingBuffer: Data = .init(count: Int(windowSizeC))

    init() {
        socket = srt_create_socket()
    }

    init(socket: SRTSOCKET, options: [SRTSocketOption]) async throws {
        self.socket = socket
        guard configure(options, restriction: .post) else {
            throw makeSocketError()
        }
        if incomingBuffer.count < windowSizeC {
            incomingBuffer = .init(count: Int(windowSizeC))
        }
    }

    func getSocketOption(_ name: SRTSocketOption.Name) throws -> SRTSocketOption {
        return try SRTSocketOption(name: name, socket: socket)
    }

    func setSocketOption(_ option: SRTSocketOption) throws {
        try option.setSockflag(socket)
    }

    func open(_ url: SRTSocketURL) async throws {
        if socket == SRT_INVALID_SOCK {
            throw makeSocketError()
        }
        guard configure(url.options, restriction: .pre) else {
            throw makeSocketError()
        }
        let status: Int32 = try await {
            guard socket != SRT_INVALID_SOCK else {
                throw CancellationError()
            }
            switch url.mode {
            case .caller:
                guard let host = url.url.host else {
                    throw Error.invalidArgument("missing remote url")
                }

                let port = url.url.port ?? SRTSocketURL.defaultPort
                let descriptor = socket

                return try await Task.detached {
                    try AddrInfo(host: host, port: port).resolve(AI_ADDRCONFIG) {
                        name, length in
                        srt_connect(descriptor, name, length)
                    }
                }.value
            case .listener:
                guard let local = url.local else {
                    throw Error.invalidArgument("missing local url")
                }
                let _: Int32 = try local.resolve(AI_PASSIVE) { name, length in
                    let status = srt_bind(socket, name, length)
                    if status == SRT_ERROR {
                        return nil
                    } else {
                        return status
                    }
                }
                return srt_listen(socket, 1)
            case .rendezvous:
                guard let remote = url.remote else {
                    throw Error.invalidArgument("missing remote url")
                }
                guard let local = url.local else {
                    throw Error.invalidArgument("missing local url")
                }
                return try remote.resolve(AI_PASSIVE | AI_ADDRCONFIG) { remotename, remotelen in
                    return try local.resolve(AI_PASSIVE | AI_ADDRCONFIG) { localname, locallen in
                        let status = srt_rendezvous(socket, localname, locallen, remotename, remotelen)
                        if status == SRT_ERROR {
                            return nil
                        } else {
                            return status
                        }
                    }
                }
            }
        }()
        guard status != SRT_ERROR else {
            let reason = SRTRejectReason(socket: socket) ?? .unknown
            throw Error.rejected(reason)
        }
        switch url.mode {
        case .listener:
            break
        default:
            guard configure(url.options, restriction: .post) else {
                throw makeSocketError()
            }
            if incomingBuffer.count < windowSizeC {
                incomingBuffer = .init(count: Int(windowSizeC))
            }
        }
        await startRunning()
    }

    func accept(_ options: [SRTSocketOption]) async throws -> SRTSocket {
        let listenerHandle = socket
        let acceptedHandle = try await SRTListenerAcceptor.shared.accept(listener: listenerHandle)
        let acceptedSocket = try await SRTSocket(socket: acceptedHandle, options: options)
        await acceptedSocket.startRunning()
        return acceptedSocket
    }

    func send(_ data: Data) throws {
        guard connected else {
            throw Error.notConnected
        }
        for data in data.chunk(Self.payloadSize) {
            outputs?.yield(data)
        }
    }

    private func configure(_ options: [SRTSocketOption], restriction: SRTSocketOption.Restriction) -> Bool {
        var failures: [String] = []
        for option in options where option.name.restriction == restriction {
            do {
                try option.setSockflag(socket)
            } catch {
                failures.append(option.name.rawValue)
            }
        }
        guard failures.isEmpty else {
            logger.error(failures)
            return false
        }
        return true
    }

    private func bstats() -> Int32 {
        guard socket != SRT_INVALID_SOCK else {
            return SRT_ERROR
        }
        return srt_bstats(socket, &perf, 1)
    }

    private func makeSocketError() -> Error {
        let error_message = String(cString: srt_getlasterror_str())
        defer {
            logger.error(error_message)
        }
        if socket != SRT_INVALID_SOCK {
            srt_close(socket)
            socket = SRT_INVALID_SOCK
        }
        return .illegalState(error_message)
    }

    @inline(__always)
    private func sendmsg(_ data: Data) -> Int32 {
        return data.withUnsafeBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_sendmsg(socket, buffer, Int32(data.count), -1, 0)
        }
    }

    @inline(__always)
    private func recvmsg() -> Int32 {
        return incomingBuffer.withUnsafeMutableBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_recvmsg(socket, buffer, windowSizeC)
        }
    }
    
    func peerHost() -> String? {
        var storage = sockaddr_storage()
        var length = Int32(MemoryLayout<sockaddr_storage>.size)

        let result = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                srt_getpeername(socket, $0, &length)
            }
        }

        guard result != SRT_ERROR else {
            return nil
        }

        switch Int32(storage.ss_family) {
        case AF_INET:
            var addr = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee
                }
            }

            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

            inet_ntop(
                AF_INET,
                &addr.sin_addr,
                &ip,
                socklen_t(INET_ADDRSTRLEN)
            )

            let end = ip.firstIndex(of: 0) ?? ip.endIndex
            return String(decoding: ip[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)

        case AF_INET6:
            var addr = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee
                }
            }

            var ip :[CChar] = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            
            inet_ntop(
                AF_INET6,
                &addr.sin6_addr,
                &ip,
                socklen_t(INET6_ADDRSTRLEN)
            )
            
            let end = ip.firstIndex(of: 0) ?? ip.endIndex
            return String(decoding: ip[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)

        default:
            return nil
        }
    }
}

extension SRTSocket: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() async {
        guard !isRunning, socket != SRT_INVALID_SOCK else {
            return
        }
        let stream = AsyncStream<Data> { continuation in
            self.outputs = continuation
        }
        Task {
            for await data in stream {
                let result = sendmsg(data)
                if result == -1 {
                    await stopRunning()
                }
            }
        }
        isRunning = true
    }

    func stopRunning() async {
        let descriptor = socket

        socket = SRT_INVALID_SOCK
        outputs = nil
        isRunning = false

        guard descriptor != SRT_INVALID_SOCK else {
            return
        }

        await SRTListenerAcceptor.shared.cancel(listener: descriptor)
        srt_close(descriptor)
    }
}

extension SRTSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkTransportReport() -> NetworkTransportReport {
        _ = bstats()
        let performanceData = self.performanceData
        return .init(
            queueBytesOut: Int(performanceData.byteSndBuf),
            totalBytesIn: Int(performanceData.byteRecvTotal),
            totalBytesOut: Int(performanceData.byteSentTotal)
        )
    }

    func makeNetworkMonitor() -> NetworkMonitor {
        return .init(self)
    }
}
