import Foundation

@main
struct InputSourceRegistrationSmoke {
    static func main() {
        let expectedSelection = InputSourceRegistration.currentKeyboardInputSourceID ==
            InputSourceRegistration.inputSourceID
        guard InputSourceRegistration.isSelected == expectedSelection else {
            fatalError("selection status must come from TISCopyCurrentKeyboardInputSource")
        }
        let statusDescription = InputSourceRegistration.statusDescription()
        guard statusDescription.contains(
            "当前键盘输入源：\(InputSourceRegistration.currentKeyboardInputSourceID)"
        ), statusDescription.contains("当前选中：\(expectedSelection)") else {
            fatalError("status output must expose the real current keyboard input source")
        }
        print(
            "Input source registration smoke test passed: current=\(InputSourceRegistration.currentKeyboardInputSourceID), selected=\(expectedSelection)"
        )
    }
}
