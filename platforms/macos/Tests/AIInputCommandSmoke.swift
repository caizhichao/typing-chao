@main
struct AIInputCommandSmoke {
    static func main() {
        var commandState = AIInputCommandState()
        guard commandState.activateTrigger(keyName: "=", isPlainKey: true),
              commandState.isTriggerReady else {
            fatalError("a single plain equals must prepare the first AI candidate")
        }

        guard !commandState.activateTrigger(keyName: "=", isPlainKey: true),
              commandState.isTriggerReady else {
            fatalError("a second equals must not create another command prefix")
        }

        commandState.reset()
        guard !commandState.activateTrigger(keyName: "a", isPlainKey: true),
              !commandState.activateTrigger(keyName: "+", isPlainKey: true),
              !commandState.activateTrigger(keyName: "=", isPlainKey: false),
              !commandState.isPending else {
            fatalError("only one unmodified equals may enter the AI candidate state; plus remains candidate paging")
        }
        print("AI input command smoke test passed: one plain equals only")
    }
}
