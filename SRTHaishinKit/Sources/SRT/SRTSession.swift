@preconcurrency import Combine
import Foundation
import HaishinKit

actor SRTSession: StreamSession {
    var connected: Bool {
        get async {
            await connection.connected
        }
    }

    @AsyncStreamed(.closed)
    private(set) var readyState: AsyncStream<StreamSessionReadyState>

    var stream: any StreamConvertible {
        _stream
    }

    private(set) var streamId: String?
    
    private let uri: URL
    private let mode: StreamSessionMode
    private var retryCount: Int = 0
    private var maxRetryCount = kStreamSession_maxRetryCount
    private lazy var connection = SRTConnection()
    private lazy var _stream: SRTStream = {
        SRTStream(connection: connection)
    }()
    private var cancellables: Set<AnyCancellable> = []
    private var disconnctedTask: Task<Void, any Error>? {
        didSet {
            oldValue?.cancel()
        }
    }
    private var isClosed = false
    private var closeTask: Task<Void, Never>?
    
    init(uri: URL, mode: StreamSessionMode, configuration: (any StreamSessionConfiguration)?) {
        self.uri = uri
        self.mode = mode
    }

    func setMaxRetryCount(_ maxRetryCount: Int) {
        self.maxRetryCount = maxRetryCount
    }

    func connect(_ disconnected: @Sendable @escaping () -> Void) async throws {
        guard !isClosed else { throw CancellationError() }

        guard await !connection.connected else { return }
        guard !isClosed else { throw CancellationError() }

        _readyState.value = .connecting

        do {
            try await connection.connect(uri)
        } catch {
            guard !isClosed, !Task.isCancelled else {
                throw CancellationError()
            }

            if let error = error as? SRTConnection.Error {
                switch error {
                case .failedToConnect(let reason):
                    // If the timeout has expired, there is no prospect of successfully reconnecting
                    // even if a retry is attempted, so no retry will be performed.
                    guard reason == .timeout else {
                        retryCount = 0
                        _readyState.value = .closed
                        throw error
                    }
                default:
                    break
                }
            }

            guard retryCount < maxRetryCount else {
                retryCount = 0
                _readyState.value = .closed
                throw error
            }
            // It is being delayed using backoff for congestion control.
            try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000)

            guard !isClosed, !Task.isCancelled else {
                throw CancellationError()
            }

            retryCount += 1
            return try await connect(disconnected)
        }

        guard !isClosed else { throw CancellationError() }

        streamId = await connection.streamId
        guard !isClosed else { throw CancellationError() }

        switch mode {
        case .playback:
            await _stream.play()
        case .publish:
            await _stream.publish()
        }

        guard !isClosed else { throw CancellationError() }

        retryCount = 0
        _readyState.value = .open

        disconnctedTask = Task {
            guard !isClosed else { return }

            cancellables.removeAll()

            let subscription = await connection.$connected.sink {
                if !$0 {
                    disconnected()
                }
            }

            guard !isClosed else {
                subscription.cancel()
                return
            }

            subscription.store(in: &cancellables)
        }
    }

    func close() async throws {
        if let closeTask {
            await closeTask.value
            return
        }

        isClosed = true
        _readyState.value = .closing

        disconnctedTask = nil
        cancellables.removeAll()

        let connection = connection
        let task = Task {
            await connection.close()
        }

        closeTask = task
        await task.value

        retryCount = 0
        streamId = nil
        _readyState.value = .closed
    }
}
