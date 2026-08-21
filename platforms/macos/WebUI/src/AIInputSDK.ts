import { APICallError, stepCountIs, streamText, tool } from "ai";
import { createOpenAI } from "@ai-sdk/openai";
import { z } from "zod";

// AI 输入的本地 shell 必须经由输入法宿主进程执行，WKWebView 的 JS 上下文无法直接 spawn。
// 这里通过 WKScriptMessageHandler 与 Swift 侧的 Process 桥接，返回结果再交由 AI SDK 继续多步推理。
let LOCAL_SHELL_TIMEOUT_MILLISECONDS = 30_000;
let LOCAL_SHELL_MAX_OUTPUT_LENGTH = 8_000;

// 描述 AI 面板在运行时从原生配置读取的直连服务参数，避免将 Key 写入包内静态资源。
export interface AIInputRuntimeConfiguration {
  serviceProviderIdentifier: "deepseek" | "codex-responses";
  baseURL: string;
  modelName: string;
  apiKey: string;
  // 设置页保存的输入法运行场景会随当前会话配置进入 AI 请求。
  systemPromptText: string;
}

// React 维护 AI 面板已完成的会话消息，下一次请求显式重传以保持服务端无状态。
export interface AIInputConversationMessage {
  roleName: "user" | "assistant";
  contentText: string;
}

const AI_REQUEST_TIMEOUT_MILLISECONDS = 60_000;
const AI_MAX_OUTPUT_TOKENS = 1_024;

// AI 输入统一使用 Responses 协议；只有 Codex Responses 服务声明联网与本地 shell 工具。
// 复刻 codex 本地直调：shell 不走 Responses 内置 `shell`（需上游/代理白名单校验，会 400 not supported），
// 而用普通 function tool `shell` 直连 `Swift Process(/bin/zsh) + WK 桥接`，不经 8317 工具校验，模型吐 tool_call 即本地执行。
type LocalShellAction = {
  commands: string[];
  timeoutMs?: number;
  maxOutputLength?: number;
};

type LocalShellOutput = {
  output: Array<{
    stdout: string;
    stderr: string;
    outcome: { type: "timeout" } | { type: "exit"; exitCode: number };
  }>;
};

function hasNativeShellBridge(): boolean {
  return Boolean(
    typeof window !== "undefined" &&
      window.webkit?.messageHandlers?.typingChao,
  );
}

function truncateToLength(textValue: string, maxLength: number): string {
  if (textValue.length <= maxLength) {
    return textValue;
  }
  return textValue.slice(0, maxLength);
}

// 通过 WK 桥接请求 Swift 侧执行受控本地 shell，单次调用在输入法进程内顺序执行 commands。
async function requestNativeLocalShell(
  action: LocalShellAction,
): Promise<LocalShellOutput> {
  const timeoutMs = action.timeoutMs ?? LOCAL_SHELL_TIMEOUT_MILLISECONDS;
  const maxOutputLength = action.maxOutputLength ?? LOCAL_SHELL_MAX_OUTPUT_LENGTH;
  const commands = action.commands;
  if (!hasNativeShellBridge()) {
    // 非输入法宿主环境（例如单测或浏览器预览）直接返回可解释错误，避免挂起 AI 多步循环。
    return {
      output: commands.map(() => ({
        stdout: "",
        stderr: "本地 shell 仅在输入法宿主环境可用",
        outcome: { type: "exit", exitCode: 1 } as const,
      })),
    };
  }
  const callIdentifier = `shell-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  return await new Promise<LocalShellOutput>((resolve) => {
    let didResolve = false;
    const finishOnce = (output: LocalShellOutput) => {
      if (didResolve) {
        return;
      }
      didResolve = true;
      window.clearTimeout(timeoutIdentifier);
      window.removeEventListener("typingchao-native-message", responseHandler);
      resolve(output);
    };
    const responseHandler = (eventValue: Event) => {
      const nativeEvent = eventValue as CustomEvent<{
        messageType: string;
        messageData?: unknown;
      }>;
      const nativeMessage = nativeEvent.detail;
      if (nativeMessage.messageType !== "aiInputShellResult") {
        return;
      }
      const messageData = nativeMessage.messageData as
        | { callId?: string; output?: LocalShellOutput["output"] }
        | undefined;
      if (!messageData || messageData.callId !== callIdentifier) {
        return;
      }
      const normalizedOutput = Array.isArray(messageData.output)
        ? messageData.output.map((item) => ({
            stdout: truncateToLength(String(item.stdout ?? ""), maxOutputLength),
            stderr: truncateToLength(String(item.stderr ?? ""), maxOutputLength),
            outcome:
              item.outcome?.type === "timeout"
                ? ({ type: "timeout" } as const)
                : {
                    type: "exit" as const,
                    exitCode:
                      typeof item.outcome?.exitCode === "number"
                        ? item.outcome.exitCode
                        : 0,
                  },
          }))
        : commands.map(() => ({
            stdout: "",
            stderr: "本地 shell 未返回可用输出",
            outcome: { type: "exit", exitCode: 1 } as const,
          }));
      finishOnce({ output: normalizedOutput });
    };
    window.addEventListener("typingchao-native-message", responseHandler);
    window.webkit?.messageHandlers?.typingChao?.postMessage({
      messageType: "aiInputShellExecute",
      messageData: {
        callId: callIdentifier,
        commands,
        timeoutMs,
        maxOutputLength,
      },
    });
    const timeoutIdentifier = window.setTimeout(() => {
      finishOnce({
        output: commands.map(() => ({
          stdout: "",
          stderr: `本地 shell 执行超时（>${timeoutMs}ms）`,
          outcome: { type: "timeout" } as const,
        })),
      });
    }, timeoutMs + 1_500);
  });
}

async function executeLocalShell(action: LocalShellAction): Promise<LocalShellOutput> {
  // 单测环境没有 WK 桥接时由 requestNativeLocalShell 直接返回错误结果，不抛出以免中断 AI SDK 的工具循环。
  return await requestNativeLocalShell(action);
}

export async function streamAIInputResponse(
  runtimeConfiguration: AIInputRuntimeConfiguration,
  promptText: string,
  conversationMessageList: AIInputConversationMessage[],
  abortSignal: AbortSignal,
  onTextDelta: (textDelta: string) => void,
): Promise<string> {
  const serviceProvider = createOpenAI({
    apiKey: runtimeConfiguration.apiKey,
    baseURL: runtimeConfiguration.baseURL,
  });
  const messageList = conversationMessageList.map((messageItem) => ({
    role: messageItem.roleName,
    content: messageItem.contentText,
  }));
  messageList.push({
    role: "user",
    content: `<user_request>\n${promptText}\n</user_request>`,
  });

  const isCodexResponses = runtimeConfiguration.serviceProviderIdentifier === "codex-responses";

  let shellCallCount = 0;
  const streamResult = streamText({
    model: serviceProvider.responses(runtimeConfiguration.modelName),
    system: systemPromptForAIInput(runtimeConfiguration),
    messages: messageList,
    // DeepSeek 不声明工具；Codex Responses 声明 web_search + 本地 function shell（不经 8317 内置校验，直接本地调度，复刻 codex）。
    tools: isCodexResponses
      ? {
          web_search: serviceProvider.tools.webSearch(),
          shell: tool({
            description: "在本地执行 shell 命令并返回 stdout/stderr，仅在输入法宿主环境可用，执行载体为 Process(/bin/zsh -lc)。",
            inputSchema: z.object({
              commands: z.array(z.string()).min(1).describe("要按序执行的 shell 命令列表"),
              timeoutMs: z.number().int().min(1000).max(120000).optional().describe("单条命令超时毫秒，默认 30000"),
              maxOutputLength: z.number().int().min(512).max(16384).optional().describe("单条输出截断长度，默认 8000"),
            }),
            execute: async ({ commands, timeoutMs, maxOutputLength }: { commands: string[]; timeoutMs?: number; maxOutputLength?: number }) => {
              shellCallCount += 1;
              try {
                console.log(`[TypingChao AI] shell #${shellCallCount} commands=${truncateToLength(JSON.stringify(commands), 500)} timeoutMs=${timeoutMs ?? LOCAL_SHELL_TIMEOUT_MILLISECONDS}`);
              } catch {}
              const resultValue = await executeLocalShell({ commands, timeoutMs, maxOutputLength });
              try {
                const previewText = resultValue.output.map((item) => truncateToLength((item.stdout || item.stderr || "").trim(), 300)).join(" | ");
                console.log(`[TypingChao AI] shell #${shellCallCount} done preview=${previewText || "<empty>"} outcome=${resultValue.output.map((item) => item.outcome.type).join(",")}`);
              } catch {}
              return resultValue;
            },
          }),
        }
      : undefined,
    stopWhen: stepCountIs(8),
    onStepFinish: async (stepResult) => {
      try {
        console.log(`[TypingChao AI] step ${String((stepResult as unknown as { stepType?: unknown }).stepType ?? "")} finishReason=${String(stepResult.finishReason ?? "")} textLen=${(stepResult.text ?? "").length} toolCalls=${(stepResult.toolCalls ?? []).length} usage=${truncateToLength(JSON.stringify(stepResult.usage ?? {}), 400)}`);
      } catch {}
    },
    onFinish: async (finishResult) => {
      try {
        console.log(`[TypingChao AI] finish reason=${String(finishResult.finishReason ?? "")} steps=${finishResult.steps?.length ?? 0} shellCalls=${shellCallCount} totalUsage=${truncateToLength(JSON.stringify(finishResult.totalUsage ?? finishResult.usage ?? {}), 500)}`);
      } catch {}
    },
    abortSignal,
    timeout: AI_REQUEST_TIMEOUT_MILLISECONDS,
    maxOutputTokens: AI_MAX_OUTPUT_TOKENS,
    providerOptions: isCodexResponses
      ? {
          openai: {
            store: false,
          },
        }
      : undefined,
  });
  try {
    return await collectAIResultWithDiagnosis(streamResult, onTextDelta);
  } catch (errorValue) {
    // 空响应或流式网络错误在此处已无 APICallError 的 url，补上本次请求的 url/model 便于直接定位“哪个服务地址”失败
    if (errorValue instanceof Error && !String(errorValue.message).includes("url=")) {
      const requestContextText = `url=${truncateToLength(runtimeConfiguration.baseURL, 180)} model=${truncateToLength(runtimeConfiguration.modelName, 80)} provider=${runtimeConfiguration.serviceProviderIdentifier}`;
      errorValue.message = `${errorValue.message} | ${requestContextText}`;
    }
    throw errorValue;
  }
}

// 流式文本先在 React 内累积并呈现，只有完整结果才回传 Swift 用于宿主上屏。
async function collectAIResult(
  textStream: AsyncIterable<string>,
  onTextDelta: (textDelta: string) => void,
): Promise<string> {
  let resultText = "";
  for await (const textDelta of textStream) {
    resultText += textDelta;
    onTextDelta(textDelta);
  }
  const cleanedResultText = cleanAIInputResult(resultText);
  if (!cleanedResultText) {
    throw new Error("AI 服务未返回可用内容");
  }
  return cleanedResultText;
}

// 空响应时附带可排查诊断：原始长度、finish、url/model 等，避免只剩“未返回可用内容”且不含网络线索。
async function collectAIResultWithDiagnosis(
  streamResult: unknown & { textStream: AsyncIterable<string> },
  onTextDelta: (textDelta: string) => void,
): Promise<string> {
  let resultText = "";
  try {
    for await (const textDelta of streamResult.textStream) {
      resultText += textDelta;
      onTextDelta(textDelta);
    }
  } catch (errorValue) {
    // 工具声明被拒等会在此直接抛 APICallError，保留 resultText 以便上层拼接 url
    try {
      console.error("[TypingChao AI] stream error", errorValue);
    } catch {}
    throw errorValue;
  }
  const cleanedResultText = cleanAIInputResult(resultText);
  if (cleanedResultText) {
    return cleanedResultText;
  }
  // streamText 的 finishReason/usage/warnings 等均为 PromiseLike，需 await 否则会打印 [object Promise]
  let diagnosisText = `rawLength=${resultText.length}`;
  const rawTrimmedLength = resultText.trim().length;
  if (rawTrimmedLength !== resultText.length) {
    diagnosisText += ` trimLength=${rawTrimmedLength}`;
  }
  try {
    const finishReasonValue = await (streamResult as unknown as { finishReason?: Promise<unknown> }).finishReason;
    if (finishReasonValue !== undefined && finishReasonValue !== null && String(finishReasonValue)) {
      diagnosisText += ` finishReason=${truncateToLength(String(finishReasonValue), 120)}`;
    }
  } catch {}
  try {
    const usageValue = await (streamResult as unknown as { usage?: Promise<unknown>; totalUsage?: Promise<unknown> }).usage;
    const fallbackUsageValue = usageValue ?? (await (streamResult as unknown as { totalUsage?: Promise<unknown> }).totalUsage);
    if (fallbackUsageValue) {
      diagnosisText += ` usage=${truncateToLength(JSON.stringify(fallbackUsageValue), 400)}`;
    }
  } catch {}
  try {
    const warningsValue = await (streamResult as unknown as { warnings?: Promise<unknown> }).warnings;
    if (warningsValue) {
      diagnosisText += ` warnings=${truncateToLength(JSON.stringify(warningsValue), 600)}`;
    }
  } catch {}
  try {
    const responseValue = await (streamResult as unknown as { response?: Promise<{ headers?: unknown; id?: unknown; modelId?: unknown }> }).response;
    if (responseValue) {
      const headerEntries = responseValue.headers && typeof responseValue.headers === "object" ? Object.entries(responseValue.headers as Record<string, unknown>).slice(0, 4) : [];
      if (headerEntries.length > 0) {
        diagnosisText += ` responseHeaders=${truncateToLength(headerEntries.map(([keyName, valueText]) => `${keyName}: ${valueText}`).join(" | "), 400)}`;
      }
      if (responseValue.modelId) {
        diagnosisText += ` responseModel=${truncateToLength(String(responseValue.modelId), 120)}`;
      }
    }
  } catch {}
  try {
    const finalStepValue = await (streamResult as unknown as { finalStep?: Promise<{ finishReason?: unknown; text?: unknown; warnings?: unknown }> }).finalStep;
    if (finalStepValue) {
      if (finalStepValue.finishReason) {
        diagnosisText += ` finalStep.finishReason=${truncateToLength(String(finalStepValue.finishReason), 120)}`;
      }
      if (typeof finalStepValue.text === "string" && finalStepValue.text) {
        diagnosisText += ` finalStep.textPreview=${truncateToLength(JSON.stringify(finalStepValue.text), 500)}`;
      }
    }
  } catch {}
  if (resultText) {
    diagnosisText += ` rawPreview=${truncateToLength(JSON.stringify(resultText), 600)}`;
  } else {
    diagnosisText += " rawPreview=<empty>";
  }
  // 控制台保留完整结果便于本地复现
  try {
    console.error("[TypingChao AI] empty response", { resultText, diagnosisText, streamResult });
  } catch {}
  throw new Error(`AI 服务未返回可用内容 (${diagnosisText})`);
}


// AI Elements 需要结构化的流事件以渲染 Tool / Reasoning / Sources / Context / Task 等
export type AIStreamEvent =
  | { kind: "text-delta"; textDelta: string }
  | { kind: "reasoning-delta"; reasoningDelta: string }
  | { kind: "reasoning-start" }
  | { kind: "reasoning-end" }
  | { kind: "source"; sourceType: string; title?: string; url?: string }
  | { kind: "tool-call"; toolCallId: string; toolName: string; input: unknown }
  | { kind: "tool-result"; toolCallId: string; toolName: string; output: unknown; isError?: boolean }
  | { kind: "tool-input-delta"; toolCallId: string; toolName: string; inputTextDelta: string }
  | { kind: "finish-step"; finishReason?: string }
  | { kind: "finish"; finishReason?: string };

export async function streamAIInputResponseWithEvents(
  runtimeConfiguration: AIInputRuntimeConfiguration,
  promptText: string,
  conversationMessageList: AIInputConversationMessage[],
  abortSignal: AbortSignal,
  onEvent: (eventValue: AIStreamEvent) => void,
): Promise<string> {
  const serviceProvider = createOpenAI({
    apiKey: runtimeConfiguration.apiKey,
    baseURL: runtimeConfiguration.baseURL,
  });
  const messageList = conversationMessageList.map((messageItem) => ({
    role: messageItem.roleName,
    content: messageItem.contentText,
  }));
  messageList.push({
    role: "user",
    content: `<user_request>\n\${promptText}\n</user_request>`,
  });
  const isCodexResponses = runtimeConfiguration.serviceProviderIdentifier === "codex-responses";
  let shellCallCount = 0;
  const streamResult = streamText({
    model: serviceProvider.responses(runtimeConfiguration.modelName),
    system: systemPromptForAIInput(runtimeConfiguration),
    messages: messageList,
    tools: isCodexResponses
      ? {
          web_search: serviceProvider.tools.webSearch(),
          shell: tool({
            description: "在本地执行 shell 命令并返回 stdout/stderr，仅在输入法宿主环境可用，执行载体为 Process(/bin/zsh -lc)。",
            inputSchema: z.object({
              commands: z.array(z.string()).min(1).describe("要按序执行的 shell 命令列表"),
              timeoutMs: z.number().int().min(1000).max(120000).optional().describe("单条命令超时毫秒，默认 30000"),
              maxOutputLength: z.number().int().min(512).max(16384).optional().describe("单条输出截断长度，默认 8000"),
            }),
            execute: async ({ commands, timeoutMs, maxOutputLength }: { commands: string[]; timeoutMs?: number; maxOutputLength?: number }) => {
              shellCallCount += 1;
              try {
                console.log(`[TypingChao AI] shell #\${shellCallCount} commands=\${truncateToLength(JSON.stringify(commands), 500)} timeoutMs=\${timeoutMs ?? LOCAL_SHELL_TIMEOUT_MILLISECONDS}`);
              } catch {}
              const resultValue = await executeLocalShell({ commands, timeoutMs, maxOutputLength });
              try {
                const previewText = resultValue.output.map((item) => truncateToLength((item.stdout || item.stderr || "").trim(), 300)).join(" | ");
                console.log(`[TypingChao AI] shell #\${shellCallCount} done preview=\${previewText || "<empty>"} outcome=\${resultValue.output.map((item) => item.outcome.type).join(",")}`);
              } catch {}
              return resultValue;
            },
          }),
        }
      : undefined,
    stopWhen: stepCountIs(8),
    onStepFinish: async (stepResult) => {
      try {
        console.log(`[TypingChao AI] step \${String((stepResult as unknown as { stepType?: unknown }).stepType ?? "")} finishReason=\${String(stepResult.finishReason ?? "")} textLen=\${(stepResult.text ?? "").length} toolCalls=\${(stepResult.toolCalls ?? []).length} usage=\${truncateToLength(JSON.stringify(stepResult.usage ?? {}), 400)}`);
      } catch {}
      try { onEvent({ kind: "finish-step", finishReason: String(stepResult.finishReason ?? "") }); } catch {}
    },
    onFinish: async (finishResult) => {
      try {
        console.log(`[TypingChao AI] finish reason=\${String(finishResult.finishReason ?? "")} steps=\${finishResult.steps?.length ?? 0} shellCalls=\${shellCallCount} totalUsage=\${truncateToLength(JSON.stringify(finishResult.totalUsage ?? finishResult.usage ?? {}), 500)}`);
      } catch {}
      try { onEvent({ kind: "finish", finishReason: String(finishResult.finishReason ?? "") }); } catch {}
    },
    abortSignal,
    timeout: AI_REQUEST_TIMEOUT_MILLISECONDS,
    maxOutputTokens: AI_MAX_OUTPUT_TOKENS,
    providerOptions: isCodexResponses
      ? { openai: { store: false } }
      : undefined,
  });
  // fullStream 包含 text/reasoning/source/tool-call/tool-result 等全量事件，Elements 据此渲染
  const fullStream = (streamResult as unknown as { fullStream: AsyncIterable<Record<string, unknown>> }).fullStream;
  let resultText = "";
  try {
    for await (const part of fullStream) {
      const partType = String((part as { type?: unknown }).type ?? "");
      if (partType === "text-delta") {
        const textDelta = String((part as { text?: unknown }).text ?? (part as { delta?: unknown }).delta ?? "");
        if (textDelta) {
          resultText += textDelta;
          try { onEvent({ kind: "text-delta", textDelta }); } catch {}
        }
      } else if (partType === "reasoning-delta") {
        const reasoningDelta = String((part as { text?: unknown }).text ?? (part as { delta?: unknown }).delta ?? "");
        if (reasoningDelta) { try { onEvent({ kind: "reasoning-delta", reasoningDelta }); } catch {} }
      } else if (partType === "reasoning-start") {
        try { onEvent({ kind: "reasoning-start" }); } catch {}
      } else if (partType === "reasoning-end") {
        try { onEvent({ kind: "reasoning-end" }); } catch {}
      } else if (partType === "source" || partType === "source-url" || partType === "source_url") {
        const urlValue = (part as { url?: unknown }).url;
        const titleValue = (part as { title?: unknown }).title ?? (part as { source?: { title?: unknown } }).source?.title;
        try { onEvent({ kind: "source", sourceType: "url", title: titleValue ? String(titleValue) : undefined, url: urlValue ? String(urlValue) : undefined }); } catch {}
      } else if (partType === "tool-call" || partType === "tool_call") {
        const toolCallId = String((part as { toolCallId?: unknown }).toolCallId ?? "");
        const toolName = String((part as { toolName?: unknown }).toolName ?? "");
        const inputValue = (part as { input?: unknown }).input ?? (part as { args?: unknown }).args;
        try { onEvent({ kind: "tool-call", toolCallId, toolName, input: inputValue }); } catch {}
      } else if (partType === "tool-result" || partType === "tool_result") {
        const toolCallId = String((part as { toolCallId?: unknown }).toolCallId ?? "");
        const toolName = String((part as { toolName?: unknown }).toolName ?? "");
        const outputValue = (part as { output?: unknown }).output ?? (part as { result?: unknown }).result;
        const isError = Boolean((part as { isError?: unknown }).isError);
        try { onEvent({ kind: "tool-result", toolCallId, toolName, output: outputValue, isError }); } catch {}
      } else if (partType === "tool-input-delta" || partType === "tool_input_delta") {
        const toolCallId = String((part as { toolCallId?: unknown }).toolCallId ?? "");
        const toolName = String((part as { toolName?: unknown }).toolName ?? "");
        const inputTextDelta = String((part as { inputTextDelta?: unknown }).inputTextDelta ?? (part as { delta?: unknown }).delta ?? "");
        if (inputTextDelta) { try { onEvent({ kind: "tool-input-delta", toolCallId, toolName, inputTextDelta }); } catch {} }
      }
    }
  } catch (errorValue) {
    try { console.error("[TypingChao AI] fullStream error", errorValue); } catch {}
    throw errorValue;
  }
  // 若 fullStream 未产出可用文本，补充诊断并抛出（复用空响应诊断逻辑的简化版）
  const cleanedResultText = cleanAIInputResult(resultText);
  if (cleanedResultText) {
    return cleanedResultText;
  }
  // 尝试读取 streamResult 的 finish/usage 附加诊断
  let diagnosisText = `rawLength=\${resultText.length}`;
  try {
    const finishReasonValue = await (streamResult as unknown as { finishReason?: Promise<unknown> }).finishReason;
    if (finishReasonValue) diagnosisText += ` finishReason=\${truncateToLength(String(finishReasonValue), 120)}`;
  } catch {}
  if (resultText) diagnosisText += ` rawPreview=\${truncateToLength(JSON.stringify(resultText), 600)}`;
  else diagnosisText += " rawPreview=<empty>";
  throw new Error(`AI 服务未返回可用内容 (\${diagnosisText})`);
}

// 设置页下发可编辑的输入法场景提示词，Codex 的联网工具约束仍由当前服务能力追加。
function systemPromptForAIInput(runtimeConfiguration: AIInputRuntimeConfiguration): string {
  const systemPromptText = runtimeConfiguration.systemPromptText.trim();
  let webSearchRequirementText = "";
  if (runtimeConfiguration.serviceProviderIdentifier === "codex-responses") {
    webSearchRequirementText = `

当前请求已提供 web_search 工具。凡用户明确要求搜索、查询或查证，或问题涉及当前、今天、最新、实时、近期、天气、新闻、价格、汇率、赛事、政策、人物职务等可能变化的信息，必须先实际调用 web_search，再根据搜索结果回答；即使模型记忆中已有答案也不能跳过搜索，不得声称没有搜索工具。
`;
  }
  return `${systemPromptText}${webSearchRequirementText}`;
}

// 打印原始错误便于排查；页面仍保留可行动提示，原始明细以“原始错误”附加展示与控制台输出（不暴露 Key/请求头）。
function rawAIErrorDetail(errorValue: unknown): string {
  const detailParts: string[] = [];
  if (APICallError.isInstance(errorValue)) {
    if (typeof errorValue.statusCode === "number") {
      detailParts.push(`status=${errorValue.statusCode}`);
    }
    if (errorValue.url) {
      detailParts.push(`url=${truncateToLength(errorValue.url, 180)}`);
    }
    if (errorValue.message) {
      detailParts.push(truncateToLength(errorValue.message, 400));
    }
    if (errorValue.responseBody) {
      detailParts.push(`body=${truncateToLength(errorValue.responseBody, 800)}`);
    }
    if (errorValue.data !== undefined) {
      try {
        detailParts.push(`data=${truncateToLength(JSON.stringify(errorValue.data), 800)}`);
      } catch {
        detailParts.push(`data=${truncateToLength(String(errorValue.data), 800)}`);
      }
    }
    if (errorValue.responseHeaders && Object.keys(errorValue.responseHeaders).length > 0) {
      const headerText = Object.entries(errorValue.responseHeaders)
        .slice(0, 6)
        .map(([keyName, valueText]) => `${keyName}: ${valueText}`)
        .join(" | ");
      if (headerText) {
        detailParts.push(`headers=${truncateToLength(headerText, 500)}`);
      }
    }
    if (errorValue.cause instanceof Error && errorValue.cause.message) {
      detailParts.push(`cause=${truncateToLength(errorValue.cause.message, 400)}`);
    } else if (errorValue.cause) {
      detailParts.push(`cause=${truncateToLength(String(errorValue.cause), 400)}`);
    }
    // APICallError 的 name 固定，需至少返回 message+status，否则界面仍只剩“网络异常”兜底
    const joinedText = detailParts.join(" | ").trim();
    if (joinedText) {
      return joinedText;
    }
  }
  if (errorValue instanceof Error) {
    const errorNameText = errorValue.name ? `${errorValue.name}: ` : "";
    const messageText = errorValue.message || String(errorValue);
    const causeText =
      errorValue.cause instanceof Error && errorValue.cause.message
        ? ` | cause=${truncateToLength(errorValue.cause.message, 400)}`
        : errorValue.cause
          ? ` | cause=${truncateToLength(String(errorValue.cause), 400)}`
          : "";
    return truncateToLength(`${errorNameText}${messageText}${causeText}`, 1200);
  }
  try {
    const jsonText = JSON.stringify(errorValue);
    if (jsonText && jsonText !== "{}" && jsonText !== "null") {
      return truncateToLength(jsonText, 1200);
    }
  } catch {}
  return truncateToLength(String(errorValue), 1200);
}

// AI SDK 的错误对象可读取稳定状态码，页面同时打印原始错误明细便于排查（控制台保留完整对象，界面附加精简原始信息）。
export function aiInputErrorMessage(errorValue: unknown, didTimeout: boolean): string {
  // 控制台保留完整错误对象，避免界面截断丢失堆栈。
  try {
    console.error("[TypingChao AI] request failed", errorValue);
  } catch {}
  const rawDetailText = rawAIErrorDetail(errorValue);
  const rawSuffixText = rawDetailText ? `\n原始错误: ${rawDetailText}` : "";
  if (didTimeout) {
    return `AI 服务响应超时，请稍后继续输入${rawSuffixText}`;
  }
  if (errorValue instanceof DOMException && errorValue.name === "AbortError") {
    return "";
  }
  if (APICallError.isInstance(errorValue)) {
    let baseMessageText = "";
    switch (errorValue.statusCode) {
      case 401:
        baseMessageText = "AI 服务 Key 错误或无权限，请在输入法设置中更新";
        break;
      case 403:
        baseMessageText = "AI 服务当前无权访问所选模型，请在设置中更换模型或 Key";
        break;
      case 404:
        baseMessageText = "AI 服务地址或模型不存在，请在输入法设置中检查";
        break;
      case 408:
        baseMessageText = "AI 服务响应超时，请稍后继续输入";
        break;
      case 429:
        baseMessageText = "AI 服务请求过于频繁，请稍后继续输入";
        break;
      default:
        if (errorValue.statusCode && errorValue.statusCode >= 500) {
          baseMessageText = "AI 服务暂时不可用，请稍后继续输入";
        } else {
          baseMessageText = "AI 服务请求失败，请检查设置后重试";
        }
        break;
    }
    return `${baseMessageText}${rawSuffixText}`;
  }
  if (errorValue instanceof TypeError) {
    return `暂时无法连接 AI 服务，请检查网络或服务地址${rawSuffixText}`;
  }
  return `AI 服务网络异常，请稍后继续输入${rawSuffixText}`;
}

function cleanAIInputResult(rawResultText: string): string {
  let resultText = rawResultText.trim();
  if (resultText.startsWith("```")) {
    const lineList = resultText.split("\n");
    lineList.shift();
    if (lineList.at(-1)?.trim() === "```") {
      lineList.pop();
    }
    resultText = lineList.join("\n").trim();
  }
  return resultText;
}
