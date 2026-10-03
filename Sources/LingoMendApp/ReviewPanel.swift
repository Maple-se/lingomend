import AppKit
import CoachCore
import LearningCore
import SwiftUI

@MainActor
final class ReviewPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var onClose: (@MainActor () -> Void)?

    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        panel = nil
        let callback = onClose; onClose = nil; callback?()
    }

    func showLoading(modeLabel: String, onClose: @escaping @MainActor () -> Void) {
        close()
        self.onClose = onClose
        let panel = preparePanel()
        panel.contentView = NSHostingView(rootView: VStack(spacing: 16) {
            ProgressView()
            Text("正在生成按需解释…")
            Text(modeLabel).font(.caption).foregroundStyle(.secondary)
            Button("取消") { [weak self] in self?.close() }
        }.frame(width: 540, height: 400))
        panel.orderFrontRegardless()
    }

    func showFailure(_ message: String) {
        let panel = preparePanel()
        panel.contentView = NSHostingView(rootView: VStack(spacing: 16) {
            Text(message).padding()
            Text("原文未被修改；不会自动重试。候选和解释仍需你判断。").font(.caption)
            Button("关闭") { [weak self] in self?.close() }
        }.frame(width: 540, height: 400))
        panel.orderFrontRegardless()
    }

    func show(
        source: String,
        response: CoachResponse,
        independentUses: [LearningCore.Expression] = [],
        learningUnavailable: Bool = false,
        modeLabel: String = "本地演示 · 不发送文本到网络",
        onSave: (@MainActor (LearningPoint) async throws -> Void)? = nil
    ) {
        let newPanel = preparePanel()
        newPanel.contentView = NSHostingView(
            rootView: ReviewView(
                source: source, response: response, independentUses: independentUses,
                learningUnavailable: learningUnavailable, modeLabel: modeLabel, onSave: onSave,
                onCopy: { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response.naturalText, forType: .string)
                    self?.close()
                }, onClose: { [weak self] in self?.close() }
            )
        )
        newPanel.orderFrontRegardless()
    }

    private func preparePanel() -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "LingoMend · 按需学习"
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false; newPanel.delegate = self
        newPanel.center()
        panel = newPanel
        return newPanel
    }
}

private struct ReviewView: View {
    let source: String
    let response: CoachResponse
    let independentUses: [LearningCore.Expression]
    let learningUnavailable: Bool
    let modeLabel: String
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
                Text(modeLabel)
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
