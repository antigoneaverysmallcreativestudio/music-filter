import Foundation

/// An immutable identity for one read or command in one Music process session.
/// Safe to pass between execution contexts; the owning state remains serialized.
public struct MusicSessionToken: Equatable, Hashable, Sendable {
    public let generation: UInt64
    public let requestID: UInt64
    public let processID: Int32

    public init(generation: UInt64, requestID: UInt64, processID: Int32) {
        self.generation = generation
        self.requestID = requestID
        self.processID = processID
    }
}

/// Pure lifecycle bookkeeping. The caller owns timers, UI, preferences, and
/// process observation, and mutates this value from a single serialized context.
/// A stale completion must be rejected before it changes any application state.
public struct MusicSessionState: Sendable {
    public private(set) var processID: Int32?
    public private(set) var generation: UInt64 = 0
    private var requestCounter: UInt64 = 0
    private var pendingRequest: MusicSessionToken?

    public init() {}

    public var isBusy: Bool { pendingRequest != nil }

    /// Reconcile with the currently running process, not an unverified old
    /// notification. Repeated observations preserve the in-flight request.
    @discardableResult
    public mutating func reconcile(processID: Int32?) -> Bool {
        let currentProcess = processID.flatMap { $0 > 0 ? $0 : nil }
        guard self.processID != currentProcess else { return false }
        self.processID = currentProcess
        generation += 1
        pendingRequest = nil
        return true
    }

    /// Invalidate any in-flight work when Music stops or the owner shuts down.
    @discardableResult
    public mutating func stop() -> Bool {
        reconcile(processID: nil)
    }

    /// At most one read or command is accepted in the current session.
    public mutating func beginRequest() -> MusicSessionToken? {
        guard let processID, pendingRequest == nil else { return nil }
        requestCounter += 1
        let token = MusicSessionToken(generation: generation, requestID: requestCounter, processID: processID)
        pendingRequest = token
        return token
    }

    public func accepts(_ token: MusicSessionToken) -> Bool {
        token.processID == processID && token.generation == generation && pendingRequest == token
    }

    /// Consumes only this session's current request. A late callback must not
    /// clear the busy state of a newer request or process.
    @discardableResult
    public mutating func finishRequest(_ token: MusicSessionToken) -> Bool {
        guard accepts(token) else { return false }
        pendingRequest = nil
        return true
    }
}
