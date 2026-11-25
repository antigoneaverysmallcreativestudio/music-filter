import AppKit
import ApplicationServices

#if canImport(FiltreCore)
import FiltreCore
#endif

/// Experimental access to Music's existing upcoming queue UI. This controller never
/// opens the queue, scrolls, changes focus, sends keys, or edits a library item.
@MainActor
final class MusicQueueController {
    enum Status: Equatable, Sendable {
        case disabled, busy, cancelled
        case accessibilityRequired, musicNotRunning, queueNotVisible
        case upcomingNotVisible, metadataUnavailable, ready
        case failed(String)
    }

    struct Diagnostic: Sendable {
        let rowIndex: Int
        let values: [String]
        let actions: [String]
        let fields: [DiagnosticField]
        var section: QueueSectionParser.FutureSection? = nil
    }

    struct DiagnosticField: Sendable {
        let path: String
        let attribute: String
        let identifier: String?
        let role: String?
        let value: String
    }

    struct Report: Sendable {
        var status: Status
        var candidates: [QueueTrackMetadata] = []
        var matching: [QueueTrackMetadata] = []
        var removed: [QueueTrackMetadata] = []
        var removalAttempts = 0
        var observedDeletionActionNameString: String?
        /// Non-content diagnostics: no track names or other user data.
        var phase = "notStarted"
        var axCalls = 0
        var elapsedSeconds: TimeInterval = 0
        var budgetExhausted = false
        var callLimitReached = false
        var timeLimitReached = false
        /// Bounded confirmation outcomes and costs only; never contains music metadata.
        var confirmationTrace: [String] = []
        /// Populated only when explicitly requested; never written to disk.
        var diagnostics: [Diagnostic] = []
    }

    private(set) var enabled = false
    private let serial = DispatchQueue(label: "dev.julienmerault.FiltreMusique.queue-accessibility", qos: .utility)
    private let worker = MusicQueueAXWorker()
    private var active: MusicQueueCancellation?

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Call only in response to the user's explicit permission action.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func setEnabled(_ enabled: Bool) {
        invalidatePendingOperations()
        self.enabled = enabled
    }

    func invalidatePendingOperations() {
        active?.cancel()
        active = nil
    }

    /// The user explicitly retries the option. Keep uncertain removals blocked
    /// through ordinary cancellations and track changes until this reset.
    func resetRemovalAttempts() {
        serial.async { [worker] in worker.resetRemovalAttempts() }
    }

    deinit { active?.cancel() }

    func filterUpcoming(processID: pid_t, rules: [BanRule],
                        currentTrack: TrackSnapshot? = nil, dryRun: Bool = true,
                        maxRemovals: Int = 3, captureDiagnostics: Bool = false,
                        completion: @escaping (Report) -> Void) {
        guard enabled else { completion(Report(status: .disabled)); return }
        guard isAccessibilityTrusted else { completion(Report(status: .accessibilityRequired)); return }
        guard active == nil else { completion(Report(status: .busy)); return }
        let token = MusicQueueCancellation()
        active = token
        serial.async { [worker, weak self] in
            let report = worker.filter(processID: processID, rules: rules,
                                       currentTrack: currentTrack, dryRun: dryRun,
                                       maxRemovals: min(3, max(0, maxRemovals)),
                                       captureDiagnostics: captureDiagnostics, token: token)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.active === token { self.active = nil }
                var delivered = report
                if token.isCancelled { delivered.status = .cancelled }
                completion(delivered)
            }
        }
    }
}

private final class MusicQueueCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

/// All AX messaging is synchronous and confined to the controller's serial queue.
private final class MusicQueueAXWorker: @unchecked Sendable {
    typealias Report = MusicQueueController.Report
    typealias FutureSection = QueueSectionParser.FutureSection
    private let deletionActions = [
        NSAccessibility.Action.delete.rawValue,
        // Exact custom action advertised by the inspected Music queue rows.
        // Keep the entire returned name; do not infer actions from translations.
        "Name:Supprimer\nTarget:0x0\nSelector:(null)"
    ]
    private var attemptGate = QueueRemovalAttemptGate()
    private var attemptProcessID: pid_t?

    func resetRemovalAttempts() { attemptGate.reset() }

    private struct Row {
        let element: AXUIElement
        let values: [String]
        let actions: [String]
        let fields: [MusicQueueController.DiagnosticField]
        let metadata: QueueTrackMetadata?
        let structuredPairs: [StructuredPair]
        let deletionElement: AXUIElement?
        let deletionActionName: String?
        let isSectionHeader: Bool
        let futureSection: FutureSection?
    }

    private struct StructuredPair {
        let cell: AXUIElement
        let titleElement: AXUIElement
        let creditElement: AXUIElement
        let values: [String]
        let metadata: QueueTrackMetadata

        func isSameEvidence(as other: StructuredPair) -> Bool {
            CFEqual(cell, other.cell) && CFEqual(titleElement, other.titleElement)
                && CFEqual(creditElement, other.creditElement) && values == other.values
                && metadata == other.metadata
        }
    }

    private struct QueueContext {
        let table: AXUIElement
        let rows: [AXUIElement]
        let visible: [AXUIElement]
        let header: AXUIElement
        let headerIndex: Int
        let sectionEnd: Int
        let boundaryValues: [[String]]
        let section: FutureSection
    }

    private struct Candidate {
        let row: Row
        let context: QueueContext
    }

    func filter(processID: pid_t, rules: [BanRule],
                currentTrack: TrackSnapshot?, dryRun: Bool, maxRemovals: Int,
                captureDiagnostics: Bool, token: MusicQueueCancellation) -> Report {
        if attemptProcessID != processID {
            attemptGate.reset()
            attemptProcessID = processID
        }
        let ax = MusicQueueAXReadBudget(token: token)
        var report = scan(processID: processID, rules: rules, currentTrack: currentTrack,
                          dryRun: dryRun, maxRemovals: maxRemovals,
                          captureDiagnostics: captureDiagnostics, token: token, ax: ax)
        report.phase = ax.confirmationTrace.isEmpty
            ? ax.phase : "\(ax.phase)/observations=\(ax.confirmationTrace.count)"
        report.axCalls = ax.calls
        report.elapsedSeconds = ax.elapsedSeconds
        report.callLimitReached = ax.callLimitReached
        report.timeLimitReached = ax.timeLimitReached
        report.budgetExhausted = report.callLimitReached || report.timeLimitReached
        report.confirmationTrace = ax.confirmationTrace
        return report
    }

    private func scan(processID: pid_t, rules: [BanRule],
                      currentTrack: TrackSnapshot?, dryRun: Bool, maxRemovals: Int,
                      captureDiagnostics: Bool, token: MusicQueueCancellation,
                      ax: MusicQueueAXReadBudget) -> Report {
        guard !token.isCancelled else { return Report(status: .cancelled) }
        guard AXIsProcessTrusted() else { return Report(status: .accessibilityRequired) }
        guard isMusic(processID) else { return Report(status: .musicNotRunning) }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        ax.phase = "queueDiscovery"
        guard let table = queueTable(application, ax: ax) else {
            return Report(status: ax.exhausted ? .failed("Accessibility scan timed out") : .queueNotVisible)
        }
        var report = Report(status: .ready)
        ax.phase = "queueContext"
        guard let contexts = contexts(table: table, ax: ax, diagnostics: captureDiagnostics ? { report.diagnostics.append($0) } : nil),
              !contexts.isEmpty else {
            report.status = ax.exhausted ? .failed("Accessibility scan timed out") : .upcomingNotVisible
            return report
        }
        ax.phase = "candidates"
        var candidates: [Candidate] = []
        var hasUnreadableRows = false
        for context in contexts {
            for element in context.visible {
                guard let index = context.rows.firstIndex(where: { CFEqual($0, element) }),
                      index > context.headerIndex, index < context.sectionEnd else { continue }
                guard ax.string(element, kAXRoleAttribute) == kAXRowRole as String,
                      ax.belongs(element, to: context.table), ax.pid(element) == processID else {
                    hasUnreadableRows = true
                    continue
                }
                let row = readRow(element, ax: ax)
                if captureDiagnostics {
                    report.diagnostics.append(.init(rowIndex: index, values: row.values, actions: row.actions,
                                                    fields: row.fields, section: context.section))
                }
                guard let metadata = row.metadata else { hasUnreadableRows = true; continue }
                guard !isCurrent(metadata, currentTrack), ax.bool(element, kAXSelectedAttribute) != true else { continue }
                candidates.append(Candidate(row: row, context: context))
                report.candidates.append(metadata)
                if row.deletionElement != nil { report.observedDeletionActionNameString = row.deletionActionName }
            }
        }
        guard !token.isCancelled else { return Report(status: .cancelled) }
        if report.candidates.isEmpty {
            // A valid but empty section, or readable rows excluded because
            // they are selected/current, does not mean that the queue is hidden.
            report.status = hasUnreadableRows ? .metadataUnavailable : .ready
            return report
        }
        ax.phase = "matchRules"
        let matches = candidates.filter {
            $0.row.metadata?.matchingRule(in: rules) != nil
        }
        report.matching = matches.compactMap { $0.row.metadata }
        guard !dryRun, maxRemovals > 0, !matches.isEmpty else { return report }
        // Current metadata is an additional exclusion guard, never a substitute
        // for re-reading the upcoming section boundary before each action.
        guard currentTrack != nil else { report.status = .metadataUnavailable; return report }

        let now = ProcessInfo.processInfo.systemUptime
        var attempts = 0
        for match in matches {
            let candidate = match.row
            let context = match.context
            guard attempts < maxRemovals, ax.permitted, !token.isCancelled else { break }
            guard isMusic(processID) else { report.status = .musicNotRunning; break }
            guard AXIsProcessTrusted() else { report.status = .accessibilityRequired; break }
            guard let metadata = candidate.metadata else { continue }
            let attemptKey = "\(processID):" + metadata.trackSnapshot.identity
            guard attemptGate.allows(attemptKey, at: now) else { continue }
            // Re-locate the same queue, then re-read its ordered and visible rows.
            ax.phase = "queueRevalidation"
            ax.invalidateReadCache()
            guard let freshTable = queueTable(application, ax: ax), CFEqual(freshTable, context.table),
                  let freshContexts = self.contexts(table: freshTable, ax: ax, diagnostics: nil),
                  let fresh = freshContexts.first(where: {
                      CFEqual($0.header, context.header) && $0.headerIndex == context.headerIndex
                          && $0.section == context.section
                  }),
                  CFEqual(fresh.header, context.header), fresh.headerIndex == context.headerIndex,
                  fresh.boundaryValues == context.boundaryValues,
                  let index = fresh.rows.firstIndex(where: { CFEqual($0, candidate.element) }),
                  index > fresh.headerIndex, index < fresh.sectionEnd,
                  fresh.visible.contains(where: { CFEqual($0, candidate.element) }),
                  ax.belongs(candidate.element, to: freshTable), ax.pid(candidate.element) == processID,
                  ax.bool(candidate.element, kAXSelectedAttribute) != true else {
                report.status = .failed("The queue changed during inspection")
                break
            }
            // The broad scan above is a discovery pass. Renew the final proof
            // without caching any attributes, including row membership/order.
            ax.phase = "finalVerification"
            ax.beginUncachedVerification()
            let proofStarted = ProcessInfo.processInfo.systemUptime
            guard let finalRows = ax.elements(freshTable, kAXRowsAttribute, limit: 512),
                  let finalVisible = ax.elements(freshTable, kAXVisibleRowsAttribute, limit: 80),
                  finalRows.count == fresh.rows.count,
                  zip(finalRows, fresh.rows).allSatisfy({ CFEqual($0, $1) }),
                  finalVisible.contains(where: { CFEqual($0, fresh.header) }),
                  finalVisible.contains(where: { CFEqual($0, candidate.element) }),
                  readRow(fresh.header, ax: ax).futureSection == fresh.section,
                  let candidateIndex = finalRows.firstIndex(where: { CFEqual($0, candidate.element) }),
                  candidateIndex > fresh.headerIndex,
                  !(fresh.headerIndex + 1..<candidateIndex).contains(where: { readRow(finalRows[$0], ax: ax).isSectionHeader }),
                  ax.belongs(candidate.element, to: freshTable),
                  ax.bool(candidate.element, kAXSelectedAttribute) == false else {
                report.status = .failed("The queue changed before removal")
                break
            }
            // Read the complete visible prefix during the same uncached proof.
            // AX row objects may be reused for different songs after deletion.
            guard let headerPosition = ax.point(fresh.header, kAXPositionAttribute),
                  let before = visiblePrefix(rows: finalRows, visible: finalVisible,
                                             headerIndex: fresh.headerIndex, ax: ax),
                  before.indices.contains(candidateIndex - fresh.headerIndex - 1),
                  before[candidateIndex - fresh.headerIndex - 1] == metadata,
                  let firstVisibleIndex = firstVisibleIndex(rows: finalRows, visible: finalVisible),
                  case .unchanged = QueueRemovalConfirmation.evaluate(
                    before: before, targetIndex: candidateIndex - fresh.headerIndex - 1,
                    after: before, beforeComplete: true, afterComplete: true) else {
                report.status = .failed("A complete queue removal witness is unavailable")
                break
            }
            let reread = readRow(candidate.element, ax: ax)
            guard reread.metadata == metadata, !isCurrent(metadata, currentTrack),
                  reread.structuredPairs.count == candidate.structuredPairs.count,
                  zip(reread.structuredPairs, candidate.structuredPairs).allSatisfy({ $0.isSameEvidence(as: $1) }),
                  let target = reread.deletionElement,
                  let originalTarget = candidate.deletionElement, CFEqual(target, originalTarget),
                  let action = reread.deletionActionName, action == candidate.deletionActionName,
                  ax.belongs(target, to: freshTable), ax.pid(target) == processID,
                  ax.actions(target).contains(action),
                  let proofRows = ax.elements(freshTable, kAXRowsAttribute, limit: 512),
                  sameElements(proofRows, finalRows),
                  let proofVisible = ax.elements(freshTable, kAXVisibleRowsAttribute, limit: 80),
                  sameElements(proofVisible, finalVisible),
                  ax.point(fresh.header, kAXPositionAttribute) == headerPosition,
                  ax.permitted, !token.isCancelled,
                  ProcessInfo.processInfo.systemUptime - proofStarted < 0.5 else {
                report.status = .failed("A verified queue removal action is unavailable")
                break
            }
            // An AX action cannot be revoked once sent. Do not retry an ambiguous
            // timeout, and never substitute a keyboard or generic press action.
            attemptGate.begin(attemptKey, at: ProcessInfo.processInfo.systemUptime)
            attempts += 1
            report.removalAttempts += 1
            ax.phase = "removalAction"
            let result = AXUIElementPerformAction(target, action as CFString)
            ax.invalidateReadCache()
            guard result == .success else {
                report.status = .failed("Music did not confirm the removal action")
                break
            }
            ax.phase = "removalConfirmation"
            ax.allowConfirmationReads()
            guard confirmRemoval(before: before,
                                 targetIndex: candidateIndex - fresh.headerIndex - 1,
                                 context: fresh, firstVisibleIndex: firstVisibleIndex,
                                 headerPosition: headerPosition, application: application,
                                 processID: processID, ax: ax, token: token) else {
                report.status = .failed("The queue change could not be confirmed")
                break
            }
            attemptGate.confirm(attemptKey)
            report.removed.append(metadata)
        }
        if token.isCancelled { report.status = .cancelled; return report }
        if ax.exhausted, report.status == .ready { report.status = .failed("Accessibility scan timed out") }
        return report
    }

    /// A complete, contiguous visible prefix, not a compacted list that could
    /// silently omit an unreadable song. A later section ends this witness.
    private func visiblePrefix(rows: [AXUIElement], visible: [AXUIElement],
                               headerIndex: Int, ax: MusicQueueAXReadBudget) -> [QueueTrackMetadata]? {
        guard rows.indices.contains(headerIndex),
              visible.contains(where: { CFEqual($0, rows[headerIndex]) }),
              let last = rows.indices.last(where: { index in visible.contains(where: { CFEqual($0, rows[index]) }) }) else { return nil }
        var metadata: [QueueTrackMetadata] = []
        guard last > headerIndex else { return metadata }
        for index in (headerIndex + 1)...last {
            guard ax.permitted, visible.contains(where: { CFEqual($0, rows[index]) }) else { return nil }
            let row = readRow(rows[index], ax: ax)
            if row.isSectionHeader { break }
            guard let item = row.metadata else { return nil }
            metadata.append(item)
        }
        return metadata
    }

    private func firstVisibleIndex(rows: [AXUIElement], visible: [AXUIElement]) -> Int? {
        rows.indices.first { index in visible.contains(where: { CFEqual($0, rows[index]) }) }
    }

    private func sameElements(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CFEqual($0, $1) }
    }

    /// One delete, followed only by bounded fresh reads. Success requires the
    /// old ordered metadata minus the target, even if Music reuses AX objects.
    private func confirmRemoval(before: [QueueTrackMetadata], targetIndex: Int,
                                context: QueueContext, firstVisibleIndex: Int,
                                headerPosition: CGPoint, application: AXUIElement,
                                processID: pid_t, ax: MusicQueueAXReadBudget,
                                token: MusicQueueCancellation) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        for (attempt, offset) in [0.0, 0.12, 0.32, 0.70].enumerated() {
            let callsAtStart = ax.calls
            func record(_ outcome: String, afterCount: Int? = nil) {
                let elapsed = String(format: "%.3f", ax.elapsedSeconds)
                ax.confirmationTrace.append("attempt=\(attempt + 1) outcome=\(outcome) calls=\(ax.calls - callsAtStart) before=\(before.count) after=\(afterCount.map(String.init) ?? "unknown") elapsed=\(elapsed)")
            }
            let delay = started + offset - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard ax.permitted else {
                ax.phase = ax.exhausted ? "removalConfirmationBudget" : "removalConfirmationCancelled"
                record(ax.exhausted ? "budget" : "cancelled")
                return false
            }
            guard ProcessInfo.processInfo.systemUptime - started < 1 else {
                ax.phase = "removalConfirmationDeadline"
                record("confirmationDeadline")
                return false
            }
            guard isMusic(processID) else {
                ax.phase = "removalConfirmationMusicStopped"
                record("musicStopped")
                return false
            }
            // Caching is allowed only inside this new observation. Nothing
            // from discovery, the action, or a previous observation survives.
            ax.beginConfirmationRead()
            ax.phase = "removalConfirmationAnchors"
            guard ax.pid(context.table) == processID,
                  ax.belongs(context.table, to: application),
                  let rows = ax.elements(context.table, kAXRowsAttribute, limit: 512),
                  let visible = ax.elements(context.table, kAXVisibleRowsAttribute, limit: 80),
                  rows.indices.contains(context.headerIndex),
                  CFEqual(rows[context.headerIndex], context.header),
                  self.firstVisibleIndex(rows: rows, visible: visible) == firstVisibleIndex,
                  visible.contains(where: { CFEqual($0, context.header) }),
                  let position = ax.point(context.header, kAXPositionAttribute),
                  abs(position.x - headerPosition.x) <= 0.5,
                  abs(position.y - headerPosition.y) <= 0.5,
                  readRow(context.header, ax: ax).futureSection == context.section else {
                ax.phase = ax.exhausted ? "removalConfirmationBudget" : "removalConfirmationAnchorsChanged"
                record(ax.exhausted ? "budgetAtAnchors" : "anchorsChanged")
                return false
            }
            let boundary = (max(0, context.headerIndex - 1)...context.headerIndex)
                .map { readRow(rows[$0], ax: ax).values }
            guard boundary == context.boundaryValues else {
                ax.phase = ax.exhausted ? "removalConfirmationBudget" : "removalConfirmationBoundaryChanged"
                record(ax.exhausted ? "budgetAtBoundary" : "boundaryChanged")
                return false
            }
            ax.phase = "removalConfirmationMetadata"
            guard let after = visiblePrefix(rows: rows, visible: visible,
                                            headerIndex: context.headerIndex, ax: ax) else {
                // Music can briefly expose an incomplete row while refreshing.
                ax.phase = ax.exhausted ? "removalConfirmationBudget" : "removalConfirmationIncomplete"
                record(ax.exhausted ? "budgetAtMetadata" : "incomplete")
                if !ax.permitted { return false }
                continue
            }
            // Reject a snapshot assembled while rows or the viewport moved.
            // These final reads must not reuse this observation's cache.
            ax.beginUncachedVerification()
            ax.phase = "removalConfirmationConsistency"
            guard let checkedRows = ax.elements(context.table, kAXRowsAttribute, limit: 512),
                  let checkedVisible = ax.elements(context.table, kAXVisibleRowsAttribute, limit: 80),
                  sameElements(checkedRows, rows), sameElements(checkedVisible, visible),
                  ax.point(context.header, kAXPositionAttribute) == position else {
                ax.phase = ax.exhausted ? "removalConfirmationBudget" : "removalConfirmationUnstable"
                record(ax.exhausted ? "budgetAtConsistency" : "unstable", afterCount: after.count)
                if !ax.permitted { return false }
                continue
            }
            switch QueueRemovalConfirmation.evaluate(before: before, targetIndex: targetIndex,
                                                       after: after, beforeComplete: true, afterComplete: true) {
            case .confirmed:
                guard ax.permitted else {
                    ax.phase = ax.exhausted ? "removalConfirmationBudget" : "removalConfirmationCancelled"
                    record(ax.exhausted ? "budgetAtResult" : "cancelled", afterCount: after.count)
                    return false
                }
                ax.phase = "removalConfirmed"
                record("confirmed", afterCount: after.count)
                return true
            case .unchanged:
                ax.phase = "removalConfirmationUnchanged"
                record("unchanged", afterCount: after.count)
                continue
            case .unverifiable(let reason):
                ax.phase = "removalConfirmation:" + reason.rawValue
                record("unverifiable:" + reason.rawValue, afterCount: after.count)
                return false
            }
        }
        return false
    }

    private func isMusic(_ pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return false }
        return application.bundleIdentifier == "com.apple.Music"
    }

    private func isCurrent(_ item: QueueTrackMetadata, _ current: TrackSnapshot?) -> Bool {
        guard let current else { return false }
        return normalizedMusicText(item.title) == normalizedMusicText(current.title)
            && normalizedMusicText(item.artist) == normalizedMusicText(current.artist)
    }

    private func queueTable(_ application: AXUIElement, ax: MusicQueueAXReadBudget) -> AXUIElement? {
        guard let windows = ax.elements(application, kAXWindowsAttribute, limit: 8) else { return nil }
        let headers = windows.filter { ax.bool($0, kAXMinimizedAttribute) != true }.flatMap { window in
            ax.descendants(window, depth: 8, nodes: 220) {
                ax.string($0, kAXIdentifierAttribute) == "headerContainer"
            }
        }
        guard headers.count == 1 else { return nil }
        let scrollAreas = ax.descendants(headers[0], depth: 3, nodes: 32) {
            ax.string($0, kAXRoleAttribute) == kAXScrollAreaRole as String
        }
        guard scrollAreas.count == 1 else { return nil }
        let tables = ax.descendants(scrollAreas[0], depth: 2, nodes: 24) {
            ax.string($0, kAXRoleAttribute) == kAXTableRole as String
        }
        return tables.count == 1 ? tables[0] : nil
    }

    private func contexts(table: AXUIElement, ax: MusicQueueAXReadBudget,
                          diagnostics: ((MusicQueueController.Diagnostic) -> Void)?) -> [QueueContext]? {
        guard let rows = ax.elements(table, kAXRowsAttribute, limit: 512),
              let visible = ax.elements(table, kAXVisibleRowsAttribute, limit: 80), !visible.isEmpty else { return nil }
        let visibleIndices = rows.indices.filter { index in
            visible.contains(where: { CFEqual($0, rows[index]) })
        }
        guard let lastVisible = visibleIndices.last else { return nil }
        // The header must be visible. Do not scan offscreen history for a
        // heading that could never authorize a candidate in this pass.
        var contexts: [QueueContext] = []
        for index in visibleIndices {
            guard ax.permitted else { return nil }
            let row = readRow(rows[index], ax: ax)
            diagnostics?(.init(rowIndex: index, values: row.values, actions: row.actions,
                               fields: row.fields, section: row.futureSection))
            guard let section = row.futureSection,
                  visible.contains(where: { CFEqual($0, rows[index]) }),
                  ax.string(rows[index], kAXRoleAttribute) == kAXRowRole as String,
                  ax.belongs(rows[index], to: table) else { continue }
            let boundary = (max(0, index - 1)...index).map { readRow(rows[$0], ax: ax).values }
            var sectionEnd = lastVisible + 1
            if index < lastVisible {
                // Include every intervening row, even if AXVisibleRows omits
                // it, so a different section still terminates this one.
                for next in (index + 1)...lastVisible {
                    guard ax.permitted else { return nil }
                    if readRow(rows[next], ax: ax).isSectionHeader {
                        sectionEnd = next
                        break
                    }
                }
            }
            contexts.append(QueueContext(table: table, rows: rows, visible: visible,
                                         header: rows[index], headerIndex: index, sectionEnd: sectionEnd,
                                         boundaryValues: boundary, section: section))
        }
        return contexts
    }

    private func readRow(_ element: AXUIElement, ax: MusicQueueAXReadBudget) -> Row {
        var fields = ax.textFields(element, path: "row")
        var actions = ax.actions(element)
        var deletionActionName = deletionActions.first(where: actions.contains)
        var deletionElement: AXUIElement? = deletionActionName != nil ? element : nil
        var sectionTitles: [String] = []
        var hasClearHeaderStructure = false
        var hasContinuationStructure = false
        var structuredPairs: [StructuredPair] = []
        let cells = (ax.elements(element, kAXChildrenAttribute, limit: 8) ?? [])
            .filter { ax.string($0, kAXRoleAttribute) == kAXCellRole as String }
        for (cellIndex, cell) in cells.prefix(2).enumerated() {
            let cellFields = ax.textFields(cell, path: "cell\(cellIndex)")
            fields += cellFields
            let cellActions = ax.actions(cell)
            actions += cellActions
            if deletionElement == nil, let action = deletionActions.first(where: cellActions.contains) {
                deletionElement = cell
                deletionActionName = action
            }
            let texts = ax.descendants(cell, depth: 2, nodes: 8) {
                let role = ax.string($0, kAXRoleAttribute)
                return role == kAXStaticTextRole as String || role == kAXTextAreaRole as String
            }
            var separateFields: [[MusicQueueController.DiagnosticField]] = []
            for (textIndex, text) in texts.enumerated() {
                let textFields = ax.textFields(text, path: "cell\(cellIndex).text\(textIndex)")
                separateFields.append(textFields)
                fields += textFields
                if ax.string(text, kAXIdentifierAttribute) == "title" { sectionTitles += textFields.map(\.value) }
            }
            // Observed continuation heading: one anonymous static text, paired
            // with the queue's Clear button in the same cell. The button is
            // structural evidence only; no action is ever sent to it.
            let cellChildren = ax.elements(cell, kAXChildrenAttribute, limit: 8) ?? []
            if cellFields.isEmpty, texts.count == 1, separateFields.count == 1,
               separateFields[0].count == 1,
               separateFields[0][0].attribute == kAXValueAttribute,
               separateFields[0][0].role == kAXStaticTextRole as String,
               (separateFields[0][0].identifier?.isEmpty ?? true),
               !separateFields[0][0].value.contains(where: \.isNewline),
               cellChildren.contains(where: { CFEqual($0, texts[0]) }),
               ax.belongs(cell, to: element),
               let textParent = ax.parent(texts[0]),
               (CFEqual(textParent, cell)
                    || (ax.string(textParent, kAXRoleAttribute) == kAXScrollAreaRole as String
                        && ax.string(textParent, kAXIdentifierAttribute) == "scroller"
                        && ax.belongs(element, to: textParent))) {
                // Music exposes these direct cell children with AXParent set
                // to either their cell or the queue scroller. Verify the child
                // list and the shared parent rather than accepting any ancestor.
                let buttons = cellChildren.filter {
                    ax.string($0, kAXRoleAttribute) == kAXButtonRole as String
                }
                for (buttonIndex, button) in buttons.enumerated() {
                    let buttonFields = ax.textFields(button, path: "cell\(cellIndex).button\(buttonIndex)")
                    fields += buttonFields
                    guard ax.string(button, kAXIdentifierAttribute) == "action",
                          let buttonParent = ax.parent(button), CFEqual(buttonParent, textParent),
                          buttonFields.contains(where: {
                              ($0.attribute == kAXTitleAttribute || $0.attribute == kAXDescriptionAttribute)
                                  && ["effacer", "clear"].contains(normalizedMusicText($0.value))
                          }) else { continue }
                    // Other structurally identical headings terminate a future
                    // section; only the exact continuation name authorizes one.
                    hasClearHeaderStructure = true
                    if QueueSectionParser.futureSection(separateFields[0][0].value) == .continuation {
                        hasContinuationStructure = true
                    }
                }
            }
            // Observed Music format: one cell, exactly two anonymous static
            // texts, each exposing only AXValue (title, then artist — album).
            // Do not join aggregated row values, cells, or alternate attributes.
            if cellFields.isEmpty, texts.count == 2, separateFields.count == 2,
               separateFields.allSatisfy({ fields in
                   fields.count == 1 && fields[0].attribute == kAXValueAttribute
                       && fields[0].role == kAXStaticTextRole as String
                       && (fields[0].identifier?.isEmpty ?? true)
               }),
               ax.belongs(texts[0], to: cell), ax.belongs(texts[1], to: cell),
               ax.belongs(cell, to: element) {
                let pairValues = separateFields.map { $0[0].value }
                if let parsed = QueueTrackMetadata.parse(lines: pairValues) {
                    structuredPairs.append(StructuredPair(cell: cell, titleElement: texts[0],
                                                          creditElement: texts[1], values: pairValues,
                                                          metadata: parsed))
                }
            }
        }
        let values = fields.map(\.value).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let parsed = values.compactMap { QueueTrackMetadata(accessibilityValue: $0) }
            + structuredPairs.map(\.metadata)
        let metadata = parsed.first.flatMap { first in parsed.allSatisfy { $0 == first } ? first : nil }
        // A track with a section's name is not a heading. Require the dedicated
        // title structure, complete AutoPlay hint, or verified Clear-button pair.
        let completeHeading = values.contains { value in
            let lines = value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            return lines.count == 2 && QueueSectionParser.isAutoplayHeader(lines[0])
                && ["des morceaux similaires seront lus.", "similar songs will play."]
                    .contains(normalizedMusicText(lines[1]))
        }
        let section = metadata == nil && deletionElement == nil
            && (!sectionTitles.isEmpty || (actions.isEmpty && completeHeading) || hasClearHeaderStructure)
        let autoplay = section && (sectionTitles.contains(where: QueueSectionParser.isAutoplayHeader)
                                    || (actions.isEmpty && completeHeading))
        let continuation = section && hasContinuationStructure
        let futureSection: FutureSection? = autoplay != continuation
            ? (autoplay ? .autoplay : .continuation) : nil
        return Row(element: element, values: values, actions: Array(Set(actions)).sorted(),
                   fields: fields, metadata: metadata, structuredPairs: structuredPairs,
                   deletionElement: deletionElement,
                   deletionActionName: deletionActionName,
                   isSectionHeader: section, futureSection: futureSection)
    }
}

private final class MusicQueueAXReadBudget {
    private struct CacheKey: Hashable {
        let element: AXUIElement
        let attribute: String
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.attribute == rhs.attribute && CFEqual(lhs.element, rhs.element)
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(CFHash(element))
            hasher.combine(attribute)
        }
    }
    private enum Cached {
        case missing
        case value(CFTypeRef)
        case elements([AXUIElement])
        case actions([String])
    }
    private let token: MusicQueueCancellation
    private let started = ProcessInfo.processInfo.systemUptime
    private(set) var calls = 0
    var phase = "preflight"
    var confirmationTrace: [String] = []
    private var callLimit = 2_400
    private var cache: [CacheKey: Cached] = [:]
    private var uncachedVerification = false
    init(token: MusicQueueCancellation) { self.token = token }
    var elapsedSeconds: TimeInterval { ProcessInfo.processInfo.systemUptime - started }
    var callLimitReached: Bool { calls >= callLimit }
    var timeLimitReached: Bool { elapsedSeconds >= 4 }
    var exhausted: Bool { callLimitReached || timeLimitReached }
    var permitted: Bool { !token.isCancelled && !exhausted }
    /// Cache only within a single read phase. Every mutation validation starts
    /// fresh, and post-action confirmation must never use pre-action arrays.
    func invalidateReadCache() { cache.removeAll(keepingCapacity: true) }
    func beginUncachedVerification() {
        invalidateReadCache()
        uncachedVerification = true
    }
    /// Reserve up to 1,000 AX calls for each of the four confirmation snapshots.
    /// The previous 1,600-call allowance could not cover a visible playlist.
    /// The total remains finite and keeps the same four-second deadline;
    /// pre-action scans still have their original 2,400-call limit.
    func allowConfirmationReads() { callLimit = min(6_400, calls + 4_000) }
    func beginConfirmationRead() {
        invalidateReadCache()
        uncachedVerification = false
    }
    private func consume() -> Bool {
        guard permitted else { return false }
        calls += 1
        return true
    }

    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard permitted else { return nil }
        let key = CacheKey(element: element, attribute: "value:" + attribute)
        if !uncachedVerification, let cached = cache[key] {
            if case .value(let value) = cached { return value }
            return nil
        }
        guard consume() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { cache[key] = .missing; return nil }
        cache[key] = .value(value)
        return value
    }

    func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = value(element, attribute) else { return nil }
        if let value = value as? String { return value }
        if let value = value as? NSAttributedString { return value.string }
        return nil
    }

    func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    func parent(_ element: AXUIElement) -> AXUIElement? {
        guard let value = value(element, kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func pid(_ element: AXUIElement) -> pid_t? {
        guard consume() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func elements(_ element: AXUIElement, _ attribute: String, limit: Int) -> [AXUIElement]? {
        guard permitted else { return nil }
        let key = CacheKey(element: element, attribute: "elements:" + attribute)
        if !uncachedVerification, let cached = cache[key] {
            if case .elements(let values) = cached { return values.count <= limit ? values : nil }
            return nil
        }
        guard consume() else { return nil }
        var count = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success else {
            cache[key] = .missing; return nil
        }
        guard count >= 0, count <= limit else { return nil }
        guard count > 0 else { cache[key] = .elements([]); return [] }
        guard consume() else { return nil }
        var array: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &array) == .success,
              let array else { cache[key] = .missing; return nil }
        var elements: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            elements.append(unsafeBitCast(object, to: AXUIElement.self))
        }
        cache[key] = .elements(elements)
        return elements
    }

    func actions(_ element: AXUIElement) -> [String] {
        guard permitted else { return [] }
        let key = CacheKey(element: element, attribute: "actions")
        if !uncachedVerification, case .actions(let names) = cache[key] { return names }
        guard consume() else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let values = names as? [String], values.count <= 32 else { cache[key] = .actions([]); return [] }
        cache[key] = .actions(values)
        return values
    }

    func textFields(_ element: AXUIElement, path: String) -> [MusicQueueController.DiagnosticField] {
        let identifier = string(element, kAXIdentifierAttribute)
        let role = string(element, kAXRoleAttribute)
        return [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute in
            guard let value = string(element, attribute), !value.isEmpty, value.utf8.count <= 4_096 else { return nil }
            return .init(path: path, attribute: attribute, identifier: identifier, role: role, value: value)
        }
    }

    func belongs(_ element: AXUIElement, to ancestor: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<8 {
            if CFEqual(current, ancestor) { return true }
            guard let parent = value(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }

    func descendants(_ root: AXUIElement, depth: Int, nodes: Int,
                     matches: (AXUIElement) -> Bool) -> [AXUIElement] {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var found: [AXUIElement] = []
        var visited = 0
        while !pending.isEmpty, visited < nodes, permitted {
            let (element, level) = pending.removeFirst()
            visited += 1
            if matches(element) { found.append(element); continue }
            guard level < depth else { continue }
            let role = string(element, kAXRoleAttribute)
            // Queue contents and library tables are never searched for a pane.
            guard role != kAXTableRole as String, role != kAXOutlineRole as String,
                  role != kAXButtonRole as String else { continue }
            for child in elements(element, kAXChildrenAttribute, limit: 128) ?? [] {
                pending.append((child, level + 1))
            }
        }
        return pending.isEmpty ? found : []
    }
}
