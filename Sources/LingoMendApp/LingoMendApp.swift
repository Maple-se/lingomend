import AppKit
import ApplicationServices
import CoachCore
import LearningCore
import MVPFlow
import PlatformBridge

@main
enum LingoMendApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = LingoMendDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class LingoMendDelegate: NSObject, NSApplicationDelegate {
    private let reader = MacOSAccessibilityTextReader()
    private let provider = DemoCoachingProvider()
    private let learningJournal = LocalLearningJournal()
    private let reviewPanel = ReviewPanel()
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LM"

        let menu = NSMenu()
        let hint = NSMenuItem(title: "捕获当前输入：⌃⌥L", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let demo = NSMenuItem(
            title: "打开演示预览",
            action: #selector(showDemoPreview),
            keyEquivalent: ""
        )
        demo.target = self
        menu.addItem(demo)
        menu.addItem(NSMenuItem.separator())
        let permission = NSMenuItem(
            title: "开启辅助功能权限…",
            action: #selector(requestAccessibility),
            keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)
        let quit = NSMenuItem(title: "退出 LingoMend", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        let shortcut = GlobalHotKey { [weak self] in
            self?.captureFocusedText()
        }
        hotKey = shortcut
        if !shortcut.register() {
            showAlert("快捷键不可用", "⌃⌥L 注册失败；请检查是否被其他应用占用。")
        }
    }

    @objc private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func showDemoPreview() {
        Task { @MainActor in
            let source = "This works 轻载条件下."
            do {
                let response = try await provider.suggest(CoachRequest(sourceText: source))
                reviewPanel.show(source: source, response: response)
            } catch {
                showAlert("演示不可用", "无法生成本地演示建议。")
            }
        }
    }

    private func captureFocusedText() {
        Task { @MainActor in
            do {
                let flow = CapturePreviewService(reader: reader, provider: provider)
                let session = try await flow.capture()
                let independentUses: [LearningCore.Expression]
                let learningUnavailable: Bool
                do {
                    independentUses = try await learningJournal.observeIndependentUse(
                        in: session.scope.text
                    )
                    learningUnavailable = false
                } catch {
                    independentUses = []
                    learningUnavailable = true
                }
                reviewPanel.show(
                    source: session.scope.text,
                    response: session.response,
                    independentUses: independentUses,
                    learningUnavailable: learningUnavailable,
                    onSave: { [learningJournal] point in
                        _ = try await learningJournal.save(point)
                    }
                )
            } catch AccessibilityCaptureError.permissionRequired {
                showAlert("需要辅助功能权限", "请从菜单栏 LingoMend 菜单开启权限，然后重试。")
            } catch CapturePreviewError.noUsableScope {
                showAlert("未找到可处理文本", "请把光标放在文本中，或选中要改写的部分。")
            } catch {
                showAlert("暂时无法读取此输入框", "LingoMend 没有修改原文或剪贴板。请换一个文本输入框重试。")
            }
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
