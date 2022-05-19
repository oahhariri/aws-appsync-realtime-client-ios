//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Combine

#if swift(>=5.5.2)

/// Appsync Real time connection that connects to subscriptions
/// through websocket.
@available(iOS 13.0, *)
public actor RealtimeConnectionProviderAsync: ConnectionProvider {
    /// Maximum number of seconds a connection may go without receiving a keep alive
    /// message before we consider it stale and force a disconnect
    static let staleConnectionTimeout: TimeInterval = 5 * 60

    let url: URL
    var listeners: [String: ConnectionProviderCallback]

    var messageInterceptors = [MessageInterceptorAsync]()
    var connectionInterceptors = [ConnectionInterceptorAsync]()

    let websocket: AppSyncWebsocketProviderAsync

    var status: ConnectionState

    func setStatus(_ status: ConnectionState) {
        self.status = status
    }

    /// A timer that automatically disconnects the current connection if it goes longer
    /// than `staleConnectionTimeout` without activity. Receiving any data or "keep
    /// alive" message will cause the timer to be reset to the full interval.
    var staleConnectionTimer: CountdownTimer

    /// Intermediate state when the connection is connected and connectivity updates to unsatisfied (offline)
    var isStaleConnection: Bool

    /// Manages concurrency for socket connections, disconnections, writes, and status reports.
    ///
    /// Each connection request will be sent to this queue. Connection request are
    /// handled one at a time.
//    let connectionQueue: DispatchQueue

    /// Monitor for connectivity updates
    let connectivityMonitor: ConnectivityMonitor

    /// The serial queue on which status & message callbacks from the web socket are invoked.
//    private let serialCallbackQueue: DispatchQueue

    /// Throttle when AppSync sends LimitExceeded error. High rate of subscriptions requests will cause AppSync to send
    /// connection level LimitExceeded errors for each subscribe made. A connection level error means that there is no
    /// subscription id associated with the error. When handling these errors, all subscriptions will receive a message
    /// for the error. Use this subject to send and throttle the errors on the client side.
    private(set) var limitExceededThrottleSink: Any?
    private(set) var iLimitExceededSubject: Any?
    var limitExceededSubject: PassthroughSubject<ConnectionProviderError, Never> {
        if iLimitExceededSubject == nil {
            iLimitExceededSubject = PassthroughSubject<ConnectionProviderError, Never>()
        }
        // swiftlint:disable:next force_cast
        return iLimitExceededSubject as! PassthroughSubject<ConnectionProviderError, Never>
    }

    init(
        url: URL,
        websocket: AppSyncWebsocketProviderAsync,
//        connectionQueue: DispatchQueue = DispatchQueue(
//            label: "com.amazonaws.AppSyncRealTimeConnectionProvider.serialQueue"
//        ),
//        serialCallbackQueue: DispatchQueue = DispatchQueue(
//            label: "com.amazonaws.AppSyncRealTimeConnectionProvider.callbackQueue"
//        ),
        connectivityMonitor: ConnectivityMonitor = ConnectivityMonitor()
    ) {
        self.url = url
        self.websocket = websocket
        self.listeners = [:]
        self.status = .notConnected
        self.staleConnectionTimer = CountdownTimer()
        self.isStaleConnection = false
//        self.connectionQueue = connectionQueue
//        self.serialCallbackQueue = serialCallbackQueue
        self.connectivityMonitor = connectivityMonitor

        connectivityMonitor.start(onUpdates: handleConnectivityUpdates(connectivity:))

//        subscribeToLimitExceededThrottle()
    }

    public convenience init(for url: URL, websocket: AppSyncWebsocketProviderAsync) {
        self.init(url: url, websocket: websocket)
    }

    // MARK: - ConnectionProvider methods

    func sendConnectionInitMessage() {
        let message = AppSyncMessage(type: .connectionInit("connection_init"))
        write(message)
    }

    func finishWrite(_ signedMessage: AppSyncMessage) async {
        let jsonEncoder = JSONEncoder()
        do {
            let jsonData = try jsonEncoder.encode(signedMessage)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                let jsonError = ConnectionProviderError.jsonParse(signedMessage.id, nil)
                updateCallback(event: .error(jsonError))
                return
            }
            await websocket.write(message: jsonString)
        } catch {
            AppSyncLogger.error(error)
            switch signedMessage.messageType {
            case .connectionInit:
                receivedConnectionInit()
            default:
                updateCallback(event: .error(ConnectionProviderError.jsonParse(signedMessage.id, error)))
            }
        }
    }

    public nonisolated func disconnect() {
        Task {
            await self.websocket.disconnect()
            await self.invalidateStaleConnectionTimer()
        }
    }

    public nonisolated func addListener(identifier: String, callback: @escaping ConnectionProviderCallback) {
        Task {
            await _addListener(identifier: identifier, callback: callback)
        }
    }

    private func _addListener(identifier: String, callback: @escaping ConnectionProviderCallback) {
        listeners[identifier] = callback
    }

    public nonisolated func removeListener(identifier: String) {
        Task {
            await _removeListener(identifier: identifier)
        }
    }

    private func _removeListener(identifier: String) async {
        listeners.removeValue(forKey: identifier)

        if listeners.isEmpty {
            AppSyncLogger.debug(
                "[RealtimeConnectionProvider] all subscriptions removed, disconnecting websocket connection."
            )
            status = .notConnected
            await websocket.disconnect()
            invalidateStaleConnectionTimer()
        }
    }

    // MARK: -

    /// Invokes all registered listeners with `event`. The event is dispatched on `serialCallbackQueue`,
    /// but internally this method uses the connectionQueue to get the currently registered listeners.
    ///
    /// - Parameter event: The connection event to dispatch
    nonisolated func updateCallback(event: ConnectionProviderEvent) {
        Task {
            let allListeners = Array(await self.listeners.values)
            allListeners.forEach { $0(event) }
        }
    }

//    @available(iOS 13.0, *)
//    func subscribeToLimitExceededThrottle() {
//        limitExceededThrottleSink = limitExceededSubject
//            .filter {
//                // Make sure the limitExceeded error is a connection level error (no subscription id present).
//                // When id is present, it is passed back directly subscription via `updateCallback`.
//                if case .limitExceeded(let id) = $0, id == nil {
//                    return true
//                }
//                return false
//            }
//            .throttle(for: .milliseconds(150), scheduler: connectionQueue, latest: true)
//            .sink { completion in
//                switch completion {
//                case .failure(let error):
//                    AppSyncLogger.verbose("limitExceededThrottleSink failed \(error)")
//                case .finished:
//                    AppSyncLogger.verbose("limitExceededThrottleSink finished")
//                }
//        } receiveValue: { result in
//            self.updateCallback(event: .error(result))
//        }
//    }

    /// - Warning: This must be invoked from the `connectionQueue`
    private func receivedConnectionInit() {
        status = .notConnected
        updateCallback(event: .error(ConnectionProviderError.connection))
    }

    public nonisolated func connect() {
        Task {
            await _connect()
        }
    }

    private func _connect() async {
            guard status == .notConnected else {
                updateCallback(event: .connection(status))
                return
            }
            status = .inProgress
            updateCallback(event: .connection(status))
            let request = AppSyncConnectionRequest(url: url)

            let signedRequest = await interceptConnection(request, for: url)
        await websocket.connect(
            url: signedRequest.url,
            protocols: ["graphql-ws"],
            delegate: self
        )
    }

    public nonisolated func write(_ message: AppSyncMessage) {
        Task {
            let signedMessage = await self.interceptMessage(message, for: self.url)
            await self.finishWrite(signedMessage)
        }
    }
}
#endif
