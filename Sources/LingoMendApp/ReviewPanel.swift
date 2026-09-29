import AppKit
import CoachCore
import LearningCore
import SwiftUI

@MainActor
final class ReviewPanel {
    private var panel: NSPanel?

    func show(
        source: String,
        response: CoachResponse,
        independentUses: [LearningCore.Expression] = [],
        learningUnavailable: Bool = false,
        onSave: (@MainActor (LearningPoint) async throws -> Void)? = nil
    ) {
        panel?.close()

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "LingoMend · 预览"
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        newPanel.contentView = NSHostingView(
            rootView: ReviewView(
                source: source,
                response: response,
                independentUses: independentUses,
                learningUnavailable: learningUnavailable,
                onSave: onSave,
                onCopy: { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response.naturalText, forType: .string)
                    self?.panel?.close()
                },
                onClose: { [weak self] in self?.panel?.close() }
            )
        )
        newPanel.center()
        newPanel.orderFrontRegardless()
        panel = newPanel
    }
}

private struct ReviewView: View {
    let source: String
    let response: CoachResponse
    let independentUses: [LearningCore.Expression]
    let learningUnavailable: Bool
    let onSave: (@MainActor (LearningPoint) async throws -> Void)?
    let onCopy: () -> Void
    let onClose: () -> Void
    @State private var saved = false
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write what you can. Learn what you can't.")
                .font(.headline)
            Text("原文")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(source).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 72)

            Text("建议")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(response.naturalText).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 88)

            if let point = response.learningPoints.first {
                Text("\(point.source) → \(point.target) · \(point.explanation)")
                    .font(.callout)
            }
            if let warning = response.warnings.first {
                Text(warning).font(.callout).foregroundStyle(.secondary)
            }
            if let expression = independentUses.first {
                Text("你已独立使用：\(expression.canonicalTarget) · \(stateLabel(expression.state))")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            if learningUnavailable {
                Text("本地学习记录暂不可用；预览和复制仍可使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if saveFailed {
                Text("保存失败；原文和剪贴板未受影响。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
            HStack {
                Text("本地演示 · 不发送文本到网络")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭", action: onClose)
                Button("复制建议", action: onCopy)
                    .disabled(response.naturalText == source)
                if let point = response.learningPoints.first, let onSave {
                    Button(saved ? "已保存" : "保存表达") {
                        Task { @MainActor in
                            do {
                                try await onSave(point)
                                saved = true
                                saveFailed = false
                            } catch {
                                saveFailed = true
                            }
                        }
                    }
                    .disabled(saved)
                }
                Button("替换（待安全验证）") {}
                    .disabled(true)
            }
        }
        .padding(20)
        .frame(width: 540, height: 400)
    }

    private func stateLabel(_ state: ExpressionState) -> String {
        switch state {
        case .new: "新表达"
        case .practicing: "练习中"
        case .familiar: "逐渐熟悉"
        case .mastered: "已掌握"
        }
    }
}
