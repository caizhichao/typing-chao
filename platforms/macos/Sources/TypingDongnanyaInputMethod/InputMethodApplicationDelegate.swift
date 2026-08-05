import AppKit

// 统一管理输入法进程的 AppKit 生命周期和唯一设置窗口，避免候选浮层自行拼装窗口显示逻辑。
final class TypingDongnanyaApplicationDelegate: NSObject, NSApplicationDelegate {
    static let shared = TypingDongnanyaApplicationDelegate()

    private override init() {
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // 候选条和输入法菜单都只打开或前置同一个设置窗口。
    func showSettings(
        inputController: TypingDongnanyaInputController,
        snapshot: RimeSnapshot,
        schemaList: [RimeSchemaItem]
    ) {
        InputMethodSettingsWindowController.shared.show(
            inputController: inputController,
            snapshot: snapshot,
            schemaList: schemaList
        )
    }
}
