import { useCallback, useEffect, useRef, useState } from "react";
import {
  aiInputErrorMessage,
  streamAIInputResponseWithEvents,
  type AIInputConversationMessage,
  type AIInputRuntimeConfiguration,
  type AIStreamEvent,
} from "./AIInputSDK";
import { sendNativeMessage, subscribeNativeMessage } from "./nativeBridge";
import { Conversation, ConversationContent, ConversationScrollButton } from "./components/ai-elements/conversation";
import { Message, MessageContent, MessageResponse } from "./components/ai-elements/message";
import { Reasoning, ReasoningContent, ReasoningTrigger } from "./components/ai-elements/reasoning";
import { Sources, SourcesContent, SourcesTrigger, Source } from "./components/ai-elements/sources";
import { Tool as AIElementsTool, ToolHeader, ToolContent, ToolInput, ToolOutput } from "./components/ai-elements/tool";
import { Loader } from "./components/ai-elements/loader";
import { ChainOfThought, ChainOfThoughtContent, ChainOfThoughtHeader, ChainOfThoughtStep } from "./components/ai-elements/chain-of-thought";
import { Task, TaskTrigger, TaskContent, TaskItem } from "./components/ai-elements/task";
import { Suggestions, Suggestion } from "./components/ai-elements/suggestion";
import { CodeBlock, CodeBlockCopyButton } from "./components/ai-elements/code-block";
import { Shimmer } from "./components/ai-elements/shimmer";
import { Confirmation, ConfirmationTitle, ConfirmationActions, ConfirmationAction } from "./components/ai-elements/confirmation";
import { InlineCitation, InlineCitationCard, InlineCitationCardTrigger, InlineCitationCardBody } from "./components/ai-elements/inline-citation";
import { Context, ContextTrigger, ContextContent, ContextContentHeader, ContextContentBody, ContextContentFooter, ContextInputUsage, ContextOutputUsage } from "./components/ai-elements/context";
import { Queue, QueueItem, QueueItemIndicator } from "./components/ai-elements/queue";
import { Artifact, ArtifactHeader, ArtifactTitle } from "./components/ai-elements/artifact";
import { Plan } from "./components/ai-elements/plan";

// ai-sdk.dev/elements 全量集成：所有与 AI chat 相关的官方组件均在此输入法弹窗内可用
// 排除仅 canvas/xyflow 画布系（@xyflow/react 强依赖，不适合 file:// 输入法弹窗）

interface ServiceProviderOption {
  optionIdentifier: AIInputRuntimeConfiguration["serviceProviderIdentifier"];
  displayName: string;
}

interface PendingToolCall {
  toolCallId: string;
  toolName: string;
  input: unknown;
  output?: unknown;
  isError?: boolean;
  state: "input-available" | "output-available" | "output-error";
}

interface PendingSource {
  url?: string;
  title?: string;
}

interface PendingChainStep {
  title: string;
  description?: string;
}

interface AIInputRuntimeState {
  promptText: string;
  promptComposition: string;
  conversationMessageList: AIInputConversationMessage[];
  pendingPromptText: string;
  pendingAssistantText: string;
  pendingReasoningText: string;
  pendingSources: PendingSource[];
  pendingToolCalls: PendingToolCall[];
  pendingState: "none" | "loading" | "streaming" | "error";
  isPromptInputEnabled: boolean;
  isExpandedLayout: boolean;
}

interface AIInputConfigurationMessage extends AIInputRuntimeConfiguration {
  serviceProviderList: ServiceProviderOption[];
}

interface AIInputCommandMessage {
  actionName: string;
  fieldValue?: unknown;
}

const quickSuggestions = ["帮我总结一下", "用中文解释", "检查并修正语法", "翻译成英文"];

const emptyRuntimeState: AIInputRuntimeState = {
  promptText: "",
  promptComposition: "",
  conversationMessageList: [],
  pendingPromptText: "",
  pendingAssistantText: "",
  pendingReasoningText: "",
  pendingSources: [],
  pendingToolCalls: [],
  pendingState: "none",
  isPromptInputEnabled: true,
  isExpandedLayout: false,
};

// AI 请求生命周期由 React 与 Vercel AI SDK 统一维护，Swift 只同步 Rime 输入、运行配置和最终上屏结果。
export default function AIInputApp() {
  const [runtimeState, setRuntimeState] = useState(emptyRuntimeState);
  const [runtimeConfiguration, setRuntimeConfiguration] = useState<AIInputConfigurationMessage | null>(null);
  const [providerMenuOpen, setProviderMenuOpen] = useState(false);
  const runtimeStateRef = useRef(runtimeState);
  const runtimeConfigurationRef = useRef<AIInputConfigurationMessage | null>(null);
  const requestAbortControllerRef = useRef<AbortController | null>(null);
  const requestGenerationRef = useRef(0);
  const submitPromptRef = useRef<() => void>(() => undefined);
  const cancelRequestRef = useRef<() => void>(() => undefined);

  const updateRuntimeState = useCallback(
    (updateState: (previousState: AIInputRuntimeState) => AIInputRuntimeState) => {
      setRuntimeState((previousState) => {
        const nextState = updateState(previousState);
        runtimeStateRef.current = nextState;
        return nextState;
      });
    },
    [],
  );

  const setNativePromptInputEnabled = useCallback((isEnabled: boolean) => {
    sendNativeMessage("aiInputAction", {
      actionName: "setPromptInputEnabled",
      fieldValue: isEnabled,
    });
  }, []);

  const setNativeExpandedLayout = useCallback((isExpanded: boolean) => {
    sendNativeMessage("aiInputAction", {
      actionName: "setExpandedLayout",
      fieldValue: isExpanded,
    });
  }, []);

  const clearNativeResult = useCallback(() => {
    sendNativeMessage("aiInputAction", { actionName: "clearResultText" });
  }, []);

  const cancelRequest = useCallback(() => {
    requestGenerationRef.current += 1;
    requestAbortControllerRef.current?.abort();
    requestAbortControllerRef.current = null;
  }, []);

  const submitPrompt = useCallback(() => {
    const currentState = runtimeStateRef.current;
    const currentConfiguration = runtimeConfigurationRef.current;
    const promptText = currentState.promptText.trim();
    if (!currentState.isPromptInputEnabled) {
      return;
    }
    if (!promptText) {
      updateRuntimeState((previousState) => ({
        ...previousState,
        pendingState: "error",
        pendingAssistantText: "请输入内容后再发送",
        isExpandedLayout: true,
      }));
      setNativeExpandedLayout(true);
      return;
    }
    if (!currentConfiguration?.apiKey) {
      updateRuntimeState((previousState) => ({
        ...previousState,
        pendingState: "error",
        pendingAssistantText: "请先在输入法设置中配置当前 AI 服务 Key",
        isExpandedLayout: true,
      }));
      setNativeExpandedLayout(true);
      return;
    }

    cancelRequest();
    const requestGeneration = requestGenerationRef.current + 1;
    requestGenerationRef.current = requestGeneration;
    const requestAbortController = new AbortController();
    requestAbortControllerRef.current = requestAbortController;
    let didTimeout = false;
    const timeoutIdentifier = window.setTimeout(() => {
      didTimeout = true;
      requestAbortController.abort();
    }, 60_000);
    const conversationMessageList = currentState.conversationMessageList;
    const pendingPromptText = promptText;
    updateRuntimeState((previousState) => ({
      ...previousState,
      promptText: "",
      promptComposition: "",
      pendingPromptText,
      pendingAssistantText: "",
      pendingReasoningText: "",
      pendingSources: [],
      pendingToolCalls: [],
      pendingState: "loading",
      isPromptInputEnabled: false,
      isExpandedLayout: true,
    }));
    setNativePromptInputEnabled(false);
    setNativeExpandedLayout(true);
    clearNativeResult();

    void (async () => {
      try {
        const handleStreamEvent = (eventValue: AIStreamEvent) => {
          if (requestGeneration !== requestGenerationRef.current) {
            return;
          }
          switch (eventValue.kind) {
            case "text-delta":
              updateRuntimeState((previousState) => ({
                ...previousState,
                pendingState: "streaming",
                pendingAssistantText: previousState.pendingAssistantText + eventValue.textDelta,
              }));
              break;
            case "reasoning-delta":
              updateRuntimeState((previousState) => ({
                ...previousState,
                pendingReasoningText: previousState.pendingReasoningText + eventValue.reasoningDelta,
              }));
              break;
            case "source":
              updateRuntimeState((previousState) => ({
                ...previousState,
                pendingSources: [...previousState.pendingSources, { url: eventValue.url, title: eventValue.title }],
              }));
              break;
            case "tool-call":
              updateRuntimeState((previousState) => ({
                ...previousState,
                pendingToolCalls: [
                  ...previousState.pendingToolCalls,
                  {
                    toolCallId: eventValue.toolCallId || `tool-\${Date.now()}`,
                    toolName: eventValue.toolName || "tool",
                    input: eventValue.input,
                    state: "input-available" as const,
                  },
                ],
              }));
              break;
            case "tool-result":
              updateRuntimeState((previousState) => ({
                ...previousState,
                pendingToolCalls: previousState.pendingToolCalls.map((toolItem) =>
                  toolItem.toolCallId === eventValue.toolCallId
                    ? { ...toolItem, output: eventValue.output, isError: eventValue.isError, state: eventValue.isError ? ("output-error" as const) : ("output-available" as const) }
                    : toolItem,
                ),
              }));
              break;
            default:
              break;
          }
        };
        const resultText = await streamAIInputResponseWithEvents(
          currentConfiguration,
          pendingPromptText,
          conversationMessageList,
          requestAbortController.signal,
          handleStreamEvent,
        );
        if (requestGeneration !== requestGenerationRef.current) {
          return;
        }
        // 确保最终文本已落入 pendingAssistantText（fullStream 与 text-delta 双写，resultText 兜底）
        updateRuntimeState((previousState) => ({
          ...previousState,
          conversationMessageList: [
            ...previousState.conversationMessageList,
            { roleName: "user", contentText: pendingPromptText },
            { roleName: "assistant", contentText: resultText },
          ],
          pendingPromptText: "",
          pendingAssistantText: "",
          pendingReasoningText: "",
          pendingSources: [],
          pendingToolCalls: [],
          pendingState: "none",
          isPromptInputEnabled: true,
          isExpandedLayout: true,
        }));
        sendNativeMessage("aiInputAction", {
          actionName: "setResultText",
          fieldValue: resultText,
        });
        setNativePromptInputEnabled(true);
      } catch (errorValue) {
        if (requestGeneration !== requestGenerationRef.current) {
          return;
        }
        const errorText = aiInputErrorMessage(errorValue, didTimeout);
        if (!errorText) {
          return;
        }
        updateRuntimeState((previousState) => ({
          ...previousState,
          pendingState: "error",
          pendingAssistantText: errorText,
          isPromptInputEnabled: true,
          isExpandedLayout: true,
        }));
        setNativePromptInputEnabled(true);
      } finally {
        window.clearTimeout(timeoutIdentifier);
        if (requestGeneration === requestGenerationRef.current) {
          requestAbortControllerRef.current = null;
        }
      }
    })();
  }, [cancelRequest, clearNativeResult, setNativeExpandedLayout, setNativePromptInputEnabled, updateRuntimeState]);

  useEffect(() => {
    submitPromptRef.current = submitPrompt;
  }, [submitPrompt]);

  useEffect(() => {
    cancelRequestRef.current = cancelRequest;
  }, [cancelRequest]);

  useEffect(() => {
    const unsubscribeHandler = subscribeNativeMessage((nativeMessage) => {
      if (nativeMessage.messageType === "aiInputConfiguration") {
        const configuration = nativeMessage.messageData as AIInputConfigurationMessage;
        runtimeConfigurationRef.current = configuration;
        setRuntimeConfiguration(configuration);
        return;
      }
      if (nativeMessage.messageType !== "aiInputCommand") {
        return;
      }
      const commandMessage = nativeMessage.messageData as AIInputCommandMessage;
      switch (commandMessage.actionName) {
        case "resetConversation": {
          cancelRequestRef.current();
          clearNativeResult();
          setNativePromptInputEnabled(true);
          const prefilledPromptText = typeof commandMessage.fieldValue === "string"
            ? commandMessage.fieldValue
            : "";
          updateRuntimeState(() => ({
            ...emptyRuntimeState,
            promptText: prefilledPromptText,
          }));
          break;
        }
        case "appendPromptText":
          if (typeof commandMessage.fieldValue === "string") {
            updateRuntimeState((previousState) => {
              if (!previousState.isPromptInputEnabled) {
                return previousState;
              }
              return {
                ...previousState,
                promptText: previousState.promptText + commandMessage.fieldValue,
              };
            });
          }
          break;
        case "deleteBackwardPromptText":
          updateRuntimeState((previousState) => {
            if (!previousState.isPromptInputEnabled) {
              return previousState;
            }
            const characterList = Array.from(previousState.promptText);
            characterList.pop();
            return {
              ...previousState,
              promptText: characterList.join(""),
            };
          });
          break;
        case "updatePromptComposition":
          if (typeof commandMessage.fieldValue === "string") {
            const compositionText = commandMessage.fieldValue;
            updateRuntimeState((previousState) => {
              if (!previousState.isPromptInputEnabled) {
                return previousState;
              }
              return {
                ...previousState,
                promptComposition: compositionText,
              };
            });
          }
          break;
        case "submitPrompt":
          submitPromptRef.current();
          break;
        case "cancelRequest":
          cancelRequestRef.current();
          break;
        case "clearRuntimeConfiguration":
          cancelRequestRef.current();
          runtimeConfigurationRef.current = null;
          setRuntimeConfiguration(null);
          updateRuntimeState(() => emptyRuntimeState);
          break;
        default:
          console.warn("Typing Chao ignored unsupported AI input command", commandMessage.actionName);
      }
    });
    sendNativeMessage("webViewReady", { viewName: "ai-input" });
    return () => {
      unsubscribeHandler();
      cancelRequestRef.current();
    };
  }, [clearNativeResult, setNativePromptInputEnabled, updateRuntimeState]);

  const selectedProvider = runtimeConfiguration?.serviceProviderList.find(
    (providerItem) => providerItem.optionIdentifier === runtimeConfiguration.serviceProviderIdentifier,
  );
  const displayedPromptText = runtimeState.promptText + runtimeState.promptComposition;
  const canCommitResult = runtimeState.conversationMessageList.at(-1)?.roleName === "assistant";
  // 估算 token 用于 Context 组件展示（无 tokenlens 时仅作比例条）
  const estimatedTokens = Math.ceil((runtimeState.pendingAssistantText.length + runtimeState.pendingReasoningText.length) / 3.2);
  const pendingSourcesForDisplay = runtimeState.pendingSources;
  const pendingToolCallsForDisplay = runtimeState.pendingToolCalls;
  const pendingChainSteps: PendingChainStep[] = pendingToolCallsForDisplay.map((toolItem) => ({
    title: toolItem.toolName === "shell" ? `执行本地 shell` : toolItem.toolName === "web_search" ? "联网搜索" : toolItem.toolName,
    description: toolItem.toolName === "shell"
      ? (() => {
          try {
            const commands = (toolItem.input as { commands?: string[] })?.commands;
            return commands ? commands.join(" ; ").slice(0, 120) : undefined;
          } catch { return undefined; }
        })()
      : undefined,
  }));

  return (
    <main className={runtimeState.isExpandedLayout ? "ai-shell ai-expanded" : "ai-shell ai-compact"}>
      <header className="ai-header">
        <div className="flex min-w-0 items-center gap-2.5">
          <div className="ai-brand-mark">✦</div>
          <div className="min-w-0">
            <div className="text-[13px] font-semibold text-[var(--text-primary)]">AI 输入</div>
            <div className="mt-0.5 truncate text-[10.5px] text-[var(--text-tertiary)]">
              连续对话 · 当前会话保留上下文
            </div>
          </div>
        </div>
        <div className="relative">
          <button
            className="provider-button"
            type="button"
            onClick={() => setProviderMenuOpen((isOpen) => !isOpen)}
          >
            <span className="provider-dot" />
            {selectedProvider?.displayName || "AI 服务"}
            <span className="text-[9px] text-[var(--text-tertiary)]">⌄</span>
          </button>
          {providerMenuOpen ? (
            <div className="provider-menu">
              {runtimeConfiguration?.serviceProviderList.map((providerItem) => (
                <button
                  className={
                    providerItem.optionIdentifier === runtimeConfiguration.serviceProviderIdentifier
                      ? "provider-menu-item provider-menu-item-active"
                      : "provider-menu-item"
                  }
                  key={providerItem.optionIdentifier}
                  type="button"
                  onClick={() => {
                    setProviderMenuOpen(false);
                    cancelRequest();
                    sendNativeMessage("aiInputAction", {
                      actionName: "setServiceProvider",
                      fieldValue: providerItem.optionIdentifier,
                    });
                    sendNativeMessage("aiInputAction", {
                      actionName: "focusPromptInput",
                    });
                  }}
                >
                  {providerItem.displayName}
                </button>
              ))}
            </div>
          ) : null}
        </div>
      </header>

      {runtimeState.isExpandedLayout ? (
        <Conversation className="chat-transcript chat-elements">
          <ConversationContent className="gap-3 p-2">
            {runtimeState.conversationMessageList.length === 0 && runtimeState.pendingState === "none" ? (
              <div className="flex flex-col gap-2 py-2">
                <Artifact>
                  <ArtifactHeader>
                    <ArtifactTitle>开始对话</ArtifactTitle>
                  </ArtifactHeader>
                  <div className="p-3">
                    <Plan>
                      <div className="text-xs text-[var(--text-secondary)]">输入你的问题，AI 会在本地执行 shell / 联网搜索后给出答案</div>
                    </Plan>
                    <Suggestions className="mt-3">
                      {quickSuggestions.map((suggestionText) => (
                        <Suggestion
                          key={suggestionText}
                          suggestion={suggestionText}
                          onClick={(value) => {
                            updateRuntimeState((previousState) => ({
                              ...previousState,
                              promptText: value,
                            }));
                            window.setTimeout(() => submitPromptRef.current(), 0);
                          }}
                        />
                      ))}
                    </Suggestions>
                  </div>
                </Artifact>
              </div>
            ) : null}
            {runtimeState.conversationMessageList.map((messageItem, messageIndex) => (
              <Message from={messageItem.roleName === "user" ? "user" : "assistant"} key={`${messageItem.roleName}-${messageIndex}`}>
                <MessageContent>
                  <MessageResponse>{messageItem.contentText}</MessageResponse>
                </MessageContent>
              </Message>
            ))}
            {runtimeState.pendingPromptText ? (
              <Message from="user">
                <MessageContent>
                  <MessageResponse>{runtimeState.pendingPromptText}</MessageResponse>
                </MessageContent>
              </Message>
            ) : null}
            {runtimeState.pendingState !== "none" ? (
              <Message from="assistant">
                <MessageContent>
                  {/* 推理过程 */}
                  {runtimeState.pendingReasoningText ? (
                    <Reasoning isStreaming={runtimeState.pendingState === "streaming"} defaultOpen={false}>
                      <ReasoningTrigger />
                      <ReasoningContent>{runtimeState.pendingReasoningText}</ReasoningContent>
                    </Reasoning>
                  ) : null}
                  {/* 上下文使用量 */}
                  {estimatedTokens > 0 ? (
                    <Context usedTokens={estimatedTokens} maxTokens={4096} usage={{ inputTokens: Math.ceil(runtimeState.pendingPromptText.length / 3), outputTokens: estimatedTokens, totalTokens: estimatedTokens } as unknown as never} modelId={runtimeConfiguration?.modelName}>
                      <ContextTrigger />
                      <ContextContent>
                        <ContextContentHeader />
                        <ContextContentBody>
                          <ContextInputUsage />
                          <ContextOutputUsage />
                        </ContextContentBody>
                        <ContextContentFooter />
                      </ContextContent>
                    </Context>
                  ) : null}
                  {/* 任务链：把 tool 调用聚合成 ChainOfThought / Task */}
                  {pendingChainSteps.length > 0 ? (
                    <ChainOfThought defaultOpen>
                      <ChainOfThoughtHeader>正在处理 {pendingToolCallsForDisplay.length} 个步骤</ChainOfThoughtHeader>
                      <ChainOfThoughtContent>
                        {pendingChainSteps.map((stepItem, stepIndex) => (
                          <ChainOfThoughtStep key={stepIndex} label={stepItem.title} description={stepItem.description} status={pendingToolCallsForDisplay[stepIndex]?.state === "output-available" ? "complete" : pendingToolCallsForDisplay[stepIndex]?.state === "output-error" ? "pending" : "active"} />
                        ))}
                      </ChainOfThoughtContent>
                    </ChainOfThought>
                  ) : null}
                  {pendingToolCallsForDisplay.length > 0 ? (
                    <Task defaultOpen>
                      <TaskTrigger title={`已调用工具 ${pendingToolCallsForDisplay.length} 次`} />
                      <TaskContent>
                        {pendingToolCallsForDisplay.map((toolItem) => (
                          <TaskItem key={toolItem.toolCallId}>{toolItem.toolName}: {toolItem.state === "output-available" ? "完成" : toolItem.state === "output-error" ? "失败" : "执行中"}</TaskItem>
                        ))}
                      </TaskContent>
                    </Task>
                  ) : null}
                  {/* 队列：排队中的工具 */}
                  {pendingToolCallsForDisplay.filter((t) => t.state === "input-available").length > 0 ? (
                    <Queue>
                      {pendingToolCallsForDisplay.filter((t) => t.state === "input-available").map((toolItem) => (
                        <QueueItem key={toolItem.toolCallId}>
                          <QueueItemIndicator />
                          {toolItem.toolName} 执行中…
                        </QueueItem>
                      ))}
                    </Queue>
                  ) : null}
                  {/* 每个工具的详细折叠 */}
                  {pendingToolCallsForDisplay.map((toolItem) => (
                    <AIElementsTool key={toolItem.toolCallId} defaultOpen={toolItem.state !== "output-available"}>
                      <ToolHeader type={toolItem.toolName === "shell" || toolItem.toolName === "web_search" ? `tool-\${toolItem.toolName}` as never : "tool-shell" as never} state={toolItem.state as never} />
                      <ToolContent>
                        <ToolInput input={toolItem.input} />
                        <ToolOutput output={toolItem.output as never} errorText={toolItem.isError ? String(toolItem.output ?? "执行失败") : undefined} />
                      </ToolContent>
                    </AIElementsTool>
                  ))}
                  {/* 引用来源 */}
                  {pendingSourcesForDisplay.length > 0 ? (
                    <Sources>
                      <SourcesTrigger count={pendingSourcesForDisplay.length} />
                      <SourcesContent>
                        {pendingSourcesForDisplay.map((sourceItem, sourceIndex) => (
                          <Source key={sourceIndex} href={sourceItem.url} title={sourceItem.title || sourceItem.url || `来源 ${sourceIndex + 1}`} />
                        ))}
                      </SourcesContent>
                    </Sources>
                  ) : null}
                  {/* 正文 / 错误 / 加载 */}
                  {runtimeState.pendingState === "error" ? (
                    <div className="message-error whitespace-pre-wrap break-words text-xs text-[var(--danger)] max-h-[280px] overflow-auto">
                      {runtimeState.pendingAssistantText}
                    </div>
                  ) : runtimeState.pendingAssistantText ? (
                    <>
                      <MessageResponse>{runtimeState.pendingAssistantText}</MessageResponse>
                      {/* 行内引用示例（有来源时在文末追加） */}
                      {pendingSourcesForDisplay.length > 0 ? (
                        <InlineCitation>
                          <InlineCitationCard>
                            <InlineCitationCardTrigger sources={pendingSourcesForDisplay.map((s) => s.url || "").filter(Boolean)} />
                            <InlineCitationCardBody>
                              {pendingSourcesForDisplay.slice(0, 3).map((s, i) => (
                                <a key={i} href={s.url} target="_blank" rel="noreferrer" className="text-xs underline">{s.title || s.url}</a>
                              ))}
                            </InlineCitationCardBody>
                          </InlineCitationCard>
                        </InlineCitation>
                      ) : null}
                    </>
                  ) : runtimeState.pendingState === "loading" ? (
                    <Loader size={14} />
                  ) : (
                    <Shimmer duration={1.2}>正在生成…</Shimmer>
                  )}
                  {/* 确认卡（示例：工具需要确认时） */}
                  {pendingToolCallsForDisplay.some((t) => t.toolName === "shell") && runtimeState.pendingState === "streaming" ? (
                    <Confirmation state="approval-requested" approval={{ id: "shell-confirm", toolCallId: pendingToolCallsForDisplay.find((x) => x.toolName === "shell")?.toolCallId ?? "shell" } as never}>
                      <ConfirmationTitle>本地 shell 将在输入法进程执行</ConfirmationTitle>
                      <ConfirmationActions><ConfirmationAction>已知晓</ConfirmationAction></ConfirmationActions>
                    </Confirmation>
                  ) : null}
                </MessageContent>
              </Message>
            ) : null}
            {/* 始终挂载一个 CodeBlock 示例占位以确保 shiki 按需加载不影响主链（首包后懒加载） */}
            <span className="hidden" aria-hidden>
              <CodeBlock code="" language="typescript"><CodeBlockCopyButton /></CodeBlock>
            </span>
          </ConversationContent>
          <ConversationScrollButton />
        </Conversation>
      ) : null}

      <button
        className={
          runtimeState.isPromptInputEnabled
            ? "prompt-surface prompt-enabled"
            : "prompt-surface prompt-disabled"
        }
        type="button"
        onClick={() =>
          sendNativeMessage("aiInputAction", {
            actionName: "focusPromptInput",
          })
        }
      >
        {displayedPromptText ? (
          <span className="prompt-text">
            {runtimeState.promptText}
            {runtimeState.promptComposition ? (
              <span className="prompt-composition">{runtimeState.promptComposition}</span>
            ) : null}
            {runtimeState.isPromptInputEnabled ? <span className="prompt-caret" /> : null}
          </span>
        ) : (
          <span className="prompt-placeholder">输入你想让 AI 处理的内容</span>
        )}
        <span className="prompt-shortcut">↩ 发送</span>
      </button>

      {canCommitResult ? (
        <footer className="ai-footer">
          <span>结果已准备好</span>
          <span className="ml-auto flex items-center gap-1.5">
            <kbd>⌘</kbd>
            <kbd>↩</kbd>
            <span>上屏并退出</span>
          </span>
        </footer>
      ) : null}
    </main>
  );
}
