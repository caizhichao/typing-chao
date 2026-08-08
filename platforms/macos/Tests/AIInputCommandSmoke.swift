@main
struct AIInputCommandSmoke {
    static func main() {
        var commandState = AIInputCommandState()
        guard commandState.consume(keyName: "=", isPlainKey: true) == .updateMarkedText("="),
              commandState.isTriggerReady else {
            fatalError("a visible equals sign must immediately prepare the first AI candidate")
        }

        guard commandState.deleteBackward().isEmpty,
              !commandState.isPending else {
            fatalError("backspace must remove the visible equals command without committing it")
        }

        guard commandState.consume(keyName: "=", isPlainKey: true) == .updateMarkedText("="),
              commandState.consume(keyName: "x", isPlainKey: true) == .commitMarkedText("="),
              commandState.consume(keyName: "i", isPlainKey: true) == .passThrough else {
            fatalError("a non-candidate key must commit the visible equals sign before normal input continues")
        }

        guard commandState.consume(keyName: "=", isPlainKey: true) == .updateMarkedText("="),
              commandState.consume(keyName: "a", isPlainKey: false) == .commitMarkedText("="),
              !commandState.isPending else {
            fatalError("modified keys must commit the visible prefix without swallowing it")
        }
        print("AI input command smoke test passed: visible equals command, first-candidate readiness, backspace, and literal commit")
    }
}
