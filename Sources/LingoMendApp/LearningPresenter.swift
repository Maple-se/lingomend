import CoachCore
import Foundation
import LearningCore
import MVPFlow

@MainActor
final class LearningPresenter {
    private let panel = ReviewPanel()
    private let journal = LocalLearningJournal()
    private var task: Task<Void, Never>?
    private var epoch = UUID()

    func cancel() {
        epoch = UUID(); task?.cancel(); task = nil; panel.close()
    }

    func show(_ proposal: InlineProposal, service: ExpressionService) {
        cancel()
        guard let request = InlineProposal.request(for: proposal.placeholder, context: service.preferences.context,
                    correctionLevel: service.preferences.correctionLevel) else { return }
        let token = epoch
        panel.showLoading(modeLabel: service.modeLabel) { [weak self] in
            self?.epoch = UUID(); self?.task?.cancel(); self?.task = nil
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let point = try await service.explain(request, replacement: proposal.replacement)
                try Task.checkCancellation()
                guard epoch == token else { return }
                let save: (@MainActor (LearningPoint) async throws -> Void)?
                if service.preferences.learningEnabled {
                    save = { [journal] point in _ = try await journal.save(point) }
                } else { save = nil }
                panel.show(source: proposal.placeholder.context.text, response: proposal.explainedResponse(point),
                           modeLabel: service.modeLabel, onSave: save)
            } catch is CancellationError { }
            catch {
                guard epoch == token else { return }
                panel.showFailure(providerMessage(error))
            }
        }
    }
}
