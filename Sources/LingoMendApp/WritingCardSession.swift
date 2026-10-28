import AppKit
import Combine
import CoachCore
import MVPFlow

/// Presentation only. Edit authority stays in the delegate and native paste transaction.
@MainActor
final class WritingCardSession: ObservableObject {
    enum Phase: Equatable { case hidden, loading, candidate, accepting, accepted }

    @Published private(set) var phase: Phase = .hidden
    private(set) var proposal: SentenceProposal?
    private(set) var explanation: WritingExplanationController?
    private(set) var message = ""
    private var onAccept: (@MainActor () -> Void)?
    private var onDismiss: (@MainActor () -> Void)?

    var canAccept: Bool { phase == .candidate && proposal?.advice.status == .suggest }

    func start(onDismiss: @escaping @MainActor () -> Void) {
        clearCandidate()
        self.onDismiss = onDismiss
        message = "正在识别当前表达…"
        phase = .loading
    }

    func show(_ proposal: SentenceProposal, onAccept: @escaping @MainActor () -> Void,
              onExplain: @escaping @MainActor () async throws -> WritingExplanation?) {
        guard phase == .loading else { return }
        self.proposal = proposal
        self.explanation = WritingExplanationController(action: onExplain)
        self.onAccept = onAccept
        phase = .candidate
    }

    func accept() {
        guard canAccept else { return }
        onAccept?()
    }

    @discardableResult
    func beginAcceptance() -> Bool {
        guard canAccept else { return false }
        clearCandidate()
        message = "正在接受建议…"
        phase = .accepting
        return true
    }

    func completeAcceptance(message: String) {
        guard phase == .accepting else { return }
        self.message = message
        phase = .accepted
    }

    func dismiss() {
        // Once paste starts, it must finish verification and clipboard cleanup.
        guard phase != .accepting else { return }
        let action = onDismiss
        hide()
        action?()
    }

    func hide() {
        clearCandidate()
        onDismiss = nil
        message = ""
        phase = .hidden
    }

    private func clearCandidate() {
        explanation?.cancel()
        explanation = nil
        proposal = nil
        onAccept = nil
    }
}

/// Reserve space for the result before showing the compact request. Keep the
/// same edge attached to the text as the card grows, including at screen edges.
struct WritingCardPlacement {
    let expanded: NSRect
    let growsDownward: Bool

    init(expanded: NSRect, anchor: CGRect, primaryTop: CGFloat) {
        self.expanded = expanded
        let anchorBottom = primaryTop - anchor.maxY
        growsDownward = expanded.maxY <= anchorBottom
    }

    func frame(compact: Bool) -> NSRect {
        guard compact else { return expanded }
        let height = min(120, expanded.height)
        return NSRect(x: expanded.minX,
            y: growsDownward ? expanded.maxY - height : expanded.minY,
            width: expanded.width, height: height)
    }
}

enum WritingCardMotion {
    static func duration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.18 }
}
