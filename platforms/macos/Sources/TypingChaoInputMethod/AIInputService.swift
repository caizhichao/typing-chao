import Foundation

// 与 WebUI AIInputSDK 的 streamAIInputResponseWithEvents 等价的 Swift 侧实现。
// Codex Responses 走 /v1/responses 流式（SSE），DeepSeek 走 /v1/chat/completions 流式；两条链路统一产出 AIStreamEvent。
final class AIInputService: @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 60
    private static let maxOutputTokens = 1024
    private static let maxSteps = 8
    private static let perCommandTimeout: TimeInterval = 30
    private static let maxTotalOutputLength = 8_000

    // 发起一次完整 AI 请求，期间按 fullStream 顺序回调 eventHandler（text/reasoning/tool-call/tool-result/source/finish）。
    // shell 工具在 Codex Responses 时声明，执行载体为本输入法进程的 Process(/bin/zsh -lc)，与 TS 的 Process 桥接一致。
    func streamWithEvents(
        configuration: AIInputRuntimeConfiguration,
        promptText: String,
        conversationMessages: [AIConversationMessage],
        onEvent: @escaping (AIStreamEvent) -> Void
    ) async throws -> String {
        let isCodex = configuration.serviceProviderIdentifier == "codex-responses"
        // 构造消息列表，与 TS 的 <user_request> 包装保持一致。
        var messages: [[String: Any]] = conversationMessages.map { m in
            ["role": m.role == .user ? "user" : "assistant", "content": m.content]
        }
        messages.append(["role": "user", "content": "<user_request>\n\(promptText)\n</user_request>"])
        let systemPrompt = systemPrompt(for: configuration)

        if isCodex {
            return try await streamCodexResponses(
                configuration: configuration,
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        } else {
            return try await streamDeepSeekChat(
                configuration: configuration,
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        }
    }

    // 深拷贝 TS 的系统提示词 web_search 约束，确保搜旧逻辑一致。
    private func systemPrompt(for configuration: AIInputRuntimeConfiguration) -> String {
        let base = configuration.systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.serviceProviderIdentifier == "codex-responses" else { return base }
        let webSearchRequirement = "\n\n当前请求已提供 web_search 工具。凡用户明确要求搜索、查询或查证，或问题涉及当前、今天、最新、实时、近期、天气、新闻、价格、汇率、赛事、政策、人物职务等可能变化的信息，必须先实际调用 web_search，再根据搜索结果回答；即使模型记忆中已有答案也不能跳过搜索，不得声称没有搜索工具。\n"
        return base + webSearchRequirement
    }

    // MARK: - Codex Responses (/v1/responses) 流式

    private func streamCodexResponses(
        configuration: AIInputRuntimeConfiguration,
        systemPrompt: String,
        messages: [[String: Any]],
        onEvent: @escaping (AIStreamEvent) -> Void
    ) async throws -> String {
        var resultText = ""
        var stepCount = 0
        var pendingToolCallMap: [String: AIToolCall] = [:]
        var currentMessages = messages

        while stepCount < Self.maxSteps {
            stepCount += 1
            let (partialResult, toolCalls) = try await singleResponsesStep(
                configuration: configuration,
                systemPrompt: systemPrompt,
                messages: currentMessages,
                onEvent: onEvent,
                resultAccumulator: &resultText
            )
            if toolCalls.isEmpty {
                resultText += partialResult
                onEvent(.finish(finishReason: "stop"))
                break
            }
            // 有 tool_calls：先存为 input-available，执行 shell/web_search 后再续一轮。
            for tc in toolCalls {
                pendingToolCallMap[tc.id] = tc
                onEvent(.toolCall(toolCallId: tc.id, toolName: tc.toolName, input: tc.input))
            }
            var toolResultsForNextRequest: [[String: Any]] = []
            for tc in toolCalls {
                let output: Any?
                let isError: Bool
                if tc.toolName == "shell" {
                    let shellResult = await executeLocalShell(toolCall: tc)
                    let entries = shellResult.output.map { e -> [String: Any] in
                        let outcome: [String: Any] = {
                            switch e.outcome {
                            case .timeout: return ["type": "timeout"]
                            case .exit(let code): return ["type": "exit", "exitCode": code]
                            }
                        }()
                        return ["stdout": e.stdout, "stderr": e.stderr, "outcome": outcome]
                    }
                    output = ["output": entries]
                    isError = false
                    onEvent(.toolResult(toolCallId: tc.id, toolName: tc.toolName, output: output, isError: false))
                } else if tc.toolName == "web_search" {
                    // Responses 的 web_search 由模型侧执行，无需本地二次调度；仅透传占位。
                    output = tc.input
                    isError = false
                    onEvent(.toolResult(toolCallId: tc.id, toolName: tc.toolName, output: output, isError: false))
                } else {
                    output = ["error": "unknown tool \(tc.toolName)"]
                    isError = true
                    onEvent(.toolResult(toolCallId: tc.id, toolName: tc.toolName, output: output, isError: true))
                }
                _ = isError
                toolResultsForNextRequest.append([
                    "tool_call_id": tc.id,
                    "type": tc.toolName,
                    "output": output ?? NSNull(),
                ])
            }
            // 追加 assistant 的 tool_calls 与 tool 结果，准备下一轮 step。
            currentMessages.append([
                "role": "assistant",
                "content": partialResult,
                "tool_calls": toolCalls.map { tc in
                    ["id": tc.id, "type": "function", "function": ["name": tc.toolName, "arguments": tc.input ?? ""] ]
                }
            ])
            for r in toolResultsForNextRequest {
                currentMessages.append(["role": "tool", "content": (r["output"] as? String) ?? "\(r["output"] ?? "")", "tool_call_id": r["tool_call_id"] ?? ""])
            }
            onEvent(.finishStep(finishReason: "tool_calls"))
        }
        let cleaned = cleanedResult(resultText)
        guard !cleaned.isEmpty else { throw NSError(domain: "AIInputService", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI 服务未返回可用内容"]) }
        return cleaned
    }

    private func singleResponsesStep(
        configuration: AIInputRuntimeConfiguration,
        systemPrompt: String,
        messages: [[String: Any]],
        onEvent: @escaping (AIStreamEvent) -> Void,
        resultAccumulator: inout String
    ) async throws -> (String, [AIToolCall]) {
        let url = URL(string: configuration.baseURL)?.appendingPathComponent("responses")
            ?? URL(string: "http://127.0.0.1:8317/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // 复刻 TS 的 providerOptions: store:false 与 tools 声明（web_search + shell local）。
        let tools: [[String: Any]] = [
            ["type": "web_search"],
            ["type": "function", "name": "shell", "description": "在本地执行 shell 命令并返回 stdout/stderr，仅在输入法宿主环境可用，执行载体为 Process(/bin/zsh -lc)。",
             "parameters": ["type": "object", "properties": [
                "commands": ["type": "array", "items": ["type": "string"], "description": "要按序执行的 shell 命令列表"],
                "timeoutMs": ["type": "integer", "description": "单条命令超时毫秒，默认 30000"],
                "maxOutputLength": ["type": "integer", "description": "单条输出截断长度，默认 8000"]
             ], "required": ["commands"]]]
        ]
        let body: [String: Any] = [
            "model": configuration.modelName,
            "input": messages.map { m in ["role": m["role"] ?? "user", "content": [["type": "input_text", "text": m["content"] as? String ?? ""]]] },
            "instructions": systemPrompt,
            "tools": tools,
            "stream": true,
            "store": false,
            "max_output_tokens": Self.maxOutputTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "AIInputService", code: code, userInfo: [NSLocalizedDescriptionKey: "AI 服务请求失败 (\(code))"])
        }
        var partial = ""
        var toolCalls: [AIToolCall] = []
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let jsonText = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if jsonText == "[DONE]" { break }
            guard let data = jsonText.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = obj["delta"] as? String { partial += delta; onEvent(.textDelta(delta)) }
            case "response.reasoning.delta":
                if let d = obj["delta"] as? String { onEvent(.reasoningDelta(d)) }
            case "response.reasoning_summary_text.delta":
                if let d = obj["delta"] as? String { onEvent(.reasoningDelta(d)) }
            case "response.output_item.added":
                if let item = obj["item"] as? [String: Any], let t = item["type"] as? String {
                    if t == "tool_call" || t == "function_call" {
                        let id = (item["id"] as? String) ?? (item["call_id"] as? String) ?? "tool-\(toolCalls.count)"
                        let name = (item["name"] as? String) ?? (item["function"] as? [String: Any])?["name"] as? String ?? "tool"
                        let rawArg: Any? = item["arguments"] ?? item["input"]
                        let parsedInput: Any? = {
                            if let s = rawArg as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { return o }
                            return rawArg
                        }()
                        toolCalls.append(AIToolCall(id: id, toolName: name, input: parsedInput, output: nil, isError: false, state: .inputAvailable))
                    }
                }
            case "response.function_call_arguments.delta":
                if let d = obj["delta"] as? String, let last = toolCalls.indices.last {
                    let prev = (toolCalls[last].input as? String) ?? ""
                    toolCalls[last].input = prev + d
                    onEvent(.toolInputDelta(toolCallId: toolCalls[last].id, toolName: toolCalls[last].toolName, inputTextDelta: d))
                }
            default:
                if let t = obj["type"] as? String, t.contains("text") {
                    if let d = obj["delta"] as? String { partial += d; onEvent(.textDelta(d)) }
                }
            }
        }
        return (partial, toolCalls)
    }

    // MARK: - DeepSeek chat (/v1/chat/completions) 流式

    private func streamDeepSeekChat(
        configuration: AIInputRuntimeConfiguration,
        systemPrompt: String,
        messages: [[String: Any]],
        onEvent: @escaping (AIStreamEvent) -> Void
    ) async throws -> String {
        var requestMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        requestMessages.append(contentsOf: messages)
        let url = URL(string: configuration.baseURL)?.appendingPathComponent("chat/completions")
            ?? URL(string: "https://api.deepseek.com/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": configuration.modelName,
            "messages": requestMessages,
            "stream": true,
            "max_tokens": Self.maxOutputTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "AIInputService", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "AI 服务请求失败"])
        }
        var result = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if text == "[DONE]" { break }
            guard let d = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            result += content
            onEvent(.textDelta(content))
        }
        let cleaned = cleanedResult(result)
        guard !cleaned.isEmpty else { throw NSError(domain: "AIInputService", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI 服务未返回可用内容"]) }
        onEvent(.finish(finishReason: "stop"))
        return cleaned
    }

    // MARK: - 本地 shell（与 TS/Overlay 的 Process 保持一致）

    func executeLocalShell(toolCall: AIToolCall) async -> AILocalShellResult {
        if let rawInput = toolCall.input as? String, let d = rawInput.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let commands = (obj["commands"] as? [String]) ?? []
            let timeout = (obj["timeoutMs"] as? Int).map { Double($0)/1000.0 } ?? Self.perCommandTimeout
            let maxLen = (obj["maxOutputLength"] as? Int) ?? Self.maxTotalOutputLength
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    var entries: [AILocalShellResult.Entry] = []
                    for cmd in commands {
                        let t = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { entries.append(.init(stdout: "", stderr: "skip", outcome: .exit(code: 1))); continue }
                        let (out, err, code, timedOut) = self.runSingleShell(commandText: t, timeout: max(1, min(timeout, 120)))
                        let ml = max(512, min(maxLen, 16384))
                        if timedOut { entries.append(.init(stdout: String(out.prefix(ml)), stderr: err.isEmpty ? "timeout" : String(err.prefix(ml)), outcome: .timeout)) }
                        else { entries.append(.init(stdout: String(out.prefix(ml)), stderr: String(err.prefix(ml)), outcome: .exit(code: code))) }
                    }
                    cont.resume(returning: AILocalShellResult(output: entries))
                }
            }
        }
        let dict = toolCall.input as? [String: Any]
        let commands = (dict?["commands"] as? [String]) ?? []
        let timeout = (dict?["timeoutMs"] as? Int).map { Double($0)/1000.0 } ?? Self.perCommandTimeout
        let maxLen = (dict?["maxOutputLength"] as? Int) ?? Self.maxTotalOutputLength
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var entries: [AILocalShellResult.Entry] = []
                for cmd in commands {
                    let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        entries.append(.init(stdout: "", stderr: "空命令已跳过", outcome: .exit(code: 1)))
                        continue
                    }
                    let (out, err, code, timedOut) = self.runSingleShell(commandText: trimmed, timeout: max(1, min(timeout, 120)))
                    let maxL = max(512, min(maxLen, 16384))
                    if timedOut {
                        entries.append(.init(stdout: String(out.prefix(maxL)), stderr: err.isEmpty ? "命令执行超时" : String(err.prefix(maxL)), outcome: .timeout))
                    } else {
                        entries.append(.init(stdout: String(out.prefix(maxL)), stderr: String(err.prefix(maxL)), outcome: .exit(code: code)))
                    }
                }
                cont.resume(returning: AILocalShellResult(output: entries))
            }
        }
    }

    private func runSingleShell(commandText: String, timeout: TimeInterval) -> (String, String, Int, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", commandText]
        process.environment = ProcessInfo.processInfo.environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do { try process.run() } catch { return ("", "无法启动本地 shell：\(error.localizedDescription)", 1, false) }
        let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
        process.waitUntilExit()
        item.cancel()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, Int(process.terminationStatus), !item.isCancelled)
    }

    private func cleanedResult(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}
