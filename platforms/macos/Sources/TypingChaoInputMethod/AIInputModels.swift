import Foundation

// 与 WebUI AIInputSDK 的 AIStreamEvent 一一对应，便于 InputMethodController 与 Swift 计算侧复用同一事件契约。
enum AIStreamEvent {
    case textDelta(String)
    case reasoningStart
    case reasoningDelta(String)
    case reasoningEnd
    case source(url: String?, title: String?)
    case toolCall(toolCallId: String, toolName: String, input: Any?)
    case toolInputDelta(toolCallId: String, toolName: String, inputTextDelta: String)
    case toolResult(toolCallId: String, toolName: String, output: Any?, isError: Bool)
    case finishStep(finishReason: String?)
    case finish(finishReason: String?)
}

enum AIToolCallState: String {
    case inputStreaming = "input-streaming"
    case inputAvailable = "input-available"
    case approvalRequested = "approval-requested"
    case approvalResponded = "approval-responded"
    case outputAvailable = "output-available"
    case outputError = "output-error"
    case outputDenied = "output-denied"
}

struct AIToolCall: Identifiable, Equatable {
    let id: String
    var toolName: String
    var input: Any?
    var output: Any?
    var isError: Bool
    var state: AIToolCallState

    static func == (lhs: AIToolCall, rhs: AIToolCall) -> Bool {
        lhs.id == rhs.id && lhs.toolName == rhs.toolName && lhs.state == rhs.state && lhs.isError == rhs.isError
    }
}

struct AISource: Equatable, Identifiable {
    var id: String { url ?? title ?? UUID().uuidString }
    var url: String?
    var title: String?
}

struct AIConversationMessage: Equatable {
    var role: AIRole
    var content: String
}

enum AIRole: String {
    case user
    case assistant
}

struct AIInputRuntimeConfiguration {
    var serviceProviderIdentifier: String // "deepseek" | "codex-responses"
    var baseURL: String
    var modelName: String
    var apiKey: String
    var systemPromptText: String
    var serviceProviderList: [AIServiceProviderOption] = []
}

struct AIServiceProviderOption: Equatable {
    var identifier: String
    var displayName: String
}

// 对齐 ai-elements 的 Conversation/Message/Tool/Reasoning 等在 Swift 侧的 UI 状态。
struct AIInputState {
    var promptText: String = ""
    var promptComposition: String = ""
    var conversationMessages: [AIConversationMessage] = []
    var pendingPromptText: String = ""
    var pendingAssistantText: String = ""
    var pendingReasoningText: String = ""
    var pendingSources: [AISource] = []
    var pendingToolCalls: [AIToolCall] = []
    var pendingState: AIPendingState = .none
    var isPromptInputEnabled: Bool = true
    var isExpandedLayout: Bool = true
}

enum AIPendingState: String {
    case none
    case loading
    case streaming
    case error
}

// 输入法进程内本地 shell（复刻 TS 的 requestNativeLocalShell + AIInputLocalShellConstants）。
struct AILocalShellAction {
    var commands: [String]
    var timeoutMs: Int?
    var maxOutputLength: Int?
}

struct AILocalShellResult {
    struct Entry {
        var stdout: String
        var stderr: String
        var outcome: Outcome
        enum Outcome {
            case timeout
            case exit(code: Int)
        }
    }
    var output: [Entry]
}
