import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a SRT connection.
///
/// Supports a one-to-one connection. Multiple connections cannot be established.
public actor SRTConnection: NetworkConnection {
    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
        /// The uri isn’t supported.
        case unsupportedUri(_ uri: URL?)
        /// The failed to connect.
        case failedToConnect(_ reason: SRTRejectReason)
    }

    /// The SRT Library version.
    public static let version: String = SRT_VERSION_STRING
    /// The URI passed to the `connect()` method.
    public private(set) var uri: URL?
    /// This instance connect to server(true) or not(false)
    @Published public private(set) var connected = false
    /// The performance data.
    public var performanceData: SRTPerformanceData? {
        get async {
            return await socket?.performanceData
        }
    }

    public private(set) var streamId: String?
    
    private var socket: SRTSocket?
    private var streams: [SRTStream] = []
    private var listener: SRTSocket?
    private var networkMonitor: NetworkMonitor?
    private var isClosed = false
    private var isConnecting = false
    private var closeTask: Task<Void, Never>?

    /// Creates an object.
    public init() {
        srt_startup()
        socket = SRTSocket()
    }

    deinit {
        streams.removeAll()
        srt_cleanup()
    }

    /// Gets a SRTSocketOption.
    public func getSocketOption(_ name: SRTSocketOption.Name) async throws -> SRTSocketOption? {
        try await socket?.getSocketOption(name)
    }

    /// Sets a SRTSocketOption.
    public func setSocketOption(_ option: SRTSocketOption) async throws {
        if connected {
            guard option.name.restriction == .post else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        } else {
            guard option.name.restriction == .pre else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        }
    }

    private func monitorConnection(on activeSocket: SRTSocket) async {
        guard !isClosed, socket === activeSocket else { return }

        let monitor = await activeSocket.makeNetworkMonitor()

        guard !isClosed, socket === activeSocket else { return }

        networkMonitor = monitor
        await monitor.startRunning()

        guard !isClosed, networkMonitor === monitor else {
            await monitor.stopRunning()
            return
        }

        for await event in await monitor.event {
            guard !isClosed, networkMonitor === monitor else {
                break
            }

            for stream in streams {
                await stream.dispatch(event)
            }
        }
    }
    
    /// Creates a connection to the server or waits for an incoming connection.
    ///
    /// - Parameters:
    ///   - uri: You can specify connection options in the URL. This follows the standard SRT format.
    ///
    /// - srt://192.168.1.1:9000?mode=caller
    ///   - Connect to the specified server.
    /// - srt://:9000?mode=listener
    ///   - Wait for connections as a server.
    public func connect(_ uri: URL?) async throws {
        guard !isClosed else { throw CancellationError() }
        guard !isConnecting else { throw Error.invalidState }

        guard let url = SRTSocketURL(uri) else {
            throw Error.unsupportedUri(uri)
        }

        guard let openingSocket = socket else {
            throw Error.invalidState
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            try await openingSocket.open(url)

            guard !isClosed, socket === openingSocket else {
                throw CancellationError()
            }

            self.uri = uri

            let activeSocket: SRTSocket

            switch url.mode {
            case .caller, .rendezvous:
                activeSocket = openingSocket

            case .listener:
                listener = openingSocket

                let acceptedSocket = try await openingSocket.accept(url.options)

                guard !isClosed else {
                    await acceptedSocket.stopRunning()
                    throw CancellationError()
                }

                socket = acceptedSocket
                activeSocket = acceptedSocket

                streamId = try await acceptedSocket.streamID

                guard !isClosed else {
                    throw CancellationError()
                }

                await openingSocket.stopRunning()

                if listener === openingSocket {
                    listener = nil
                }
            }

            guard !isClosed else {
                throw CancellationError()
            }

            let status = await activeSocket.status

            guard !isClosed, socket === activeSocket else {
                throw CancellationError()
            }

            connected = status == .connected

            if connected {
                Task { [weak self] in
                    await self?.monitorConnection(on: activeSocket)
                }
            }

        } catch {
            let currentSocket = socket
            let currentListener = listener

            await currentSocket?.stopRunning()

            if let currentListener, currentListener !== currentSocket {
                await currentListener.stopRunning()
            }

            guard !isClosed else {
                throw CancellationError()
            }

            socket = SRTSocket()
            listener = nil
            self.uri = nil
            streamId = nil
            connected = false

            if error is CancellationError {
                throw CancellationError()
            }

            if let error = error as? SRTSocket.Error {
                switch error {
                case .rejected(let reason):
                    throw Error.failedToConnect(reason)
                default:
                    throw Error.invalidState
                }
            }

            throw Error.invalidState
        }
    }

    /// Closes a connection.
    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }

        // Invalidate pending operations before any await.
        isClosed = true
        connected = false
        uri = nil
        streamId = nil

        let oldSocket = socket
        let oldListener = listener
        let oldMonitor = networkMonitor
        let oldStreams = streams

        socket = nil
        listener = nil
        networkMonitor = nil

        let task = Task {
            // Close sockets first to interrupt pending SRT operations.
            await oldSocket?.stopRunning()

            if let oldListener, oldListener !== oldSocket {
                await oldListener.stopRunning()
            }

            await oldMonitor?.stopRunning()

            for stream in oldStreams {
                await stream.close()
            }
        }

        closeTask = task
        await task.value
    }

    func send(_ data: Data) async {
        do {
            try await socket?.send(data)
        } catch {
            await close()
        }
    }

    func recv() {
        guard !isClosed, let activeSocket = socket else { return }

        Task { [weak self] in
            for await data in await activeSocket.inputs {
                await self?.deliverInput(data, from: activeSocket)
            }

            if await self?.isCurrentSocket(activeSocket) == true {
                await self?.close()
            }
        }
    }

    private func isCurrentSocket(_ candidate: SRTSocket) -> Bool {
        !isClosed && socket === candidate
    }

    private func deliverInput(_ data: Data, from source: SRTSocket) async {
        guard isCurrentSocket(source) else { return }
        await streams.first?.doInput(data)
    }

    func addStream(_ stream: SRTStream) {
        guard !streams.contains(where: { $0 === stream }) else {
            return
        }
        streams.append(stream)
    }

    func removeStream(_ stream: SRTStream) {
        if let index = streams.firstIndex(where: { $0 === stream }) {
            streams.remove(at: index)
        }
    }
}
