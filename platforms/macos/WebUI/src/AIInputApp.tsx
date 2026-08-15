import { useCallback, useEffect, useRef, useState } from "react";
import {
  aiInputErrorMessage,
  streamAIInputResponse,
  type AIInputConversationMessage,
  type AIInputRuntimeConfiguration,
} from "./AIInputSDK";
import { sendNativeMessage, subscribeNativeMessage } from "./nativeBridge";

interface ServiceProviderOption {
  optionIdentifier: AIInputRuntimeConfiguration["serviceProviderIdentifier"];
  displayName: string;
}

interface AIInputRuntimeState {
  promptText: string;
  promptComposition: string;
  conversationMessageList: AIInputConversationMessage[];
  pendingPromptText: string;
  pendingAssistantText: string;
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

const emptyRuntimeState: AIInputRuntimeState = {
  promptText: "",
  promptComposition: "",
  conversationMessageList: [],
  pendingPromptText: "",
  pendingAssistantText: "",
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
      pendingState: "loading",
      isPromptInputEnabled: false,
      isExpandedLayout: true,
    }));
    setNativePromptInputEnabled(false);
    setNativeExpandedLayout(true);
    clearNativeResult();

    void (async () => {
      try {
        const resultText = await streamAIInputResponse(
          currentConfiguration,
          pendingPromptText,
          conversationMessageList,
          requestAbortController.signal,
          (textDelta) => {
            if (requestGeneration !== requestGenerationRef.current) {
              return;
            }
            updateRuntimeState((previousState) => ({
              ...previousState,
              pendingState: "streaming",
              pendingAssistantText: previousState.pendingAssistantText + textDelta,
            }));
          },
        );
        if (requestGeneration !== requestGenerationRef.current) {
          return;
        }
        updateRuntimeState((previousState) => ({
          ...previousState,
          conversationMessageList: [
            ...previousState.conversationMessageList,
            { roleName: "user", contentText: pendingPromptText },
            { roleName: "assistant", contentText: resultText },
          ],
          pendingPromptText: "",
          pendingAssistantText: "",
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
        <section className="chat-transcript">
          {runtimeState.conversationMessageList.map((messageItem, messageIndex) => (
            <div
              className={messageItem.roleName === "user" ? "message-row message-user" : "message-row message-assistant"}
              key={`${messageItem.roleName}-${messageIndex}`}
            >
              <div className="message-role">{messageItem.roleName === "user" ? "你" : "AI"}</div>
              <div className="message-bubble">{messageItem.contentText}</div>
            </div>
          ))}
          {runtimeState.pendingPromptText ? (
            <div className="message-row message-user">
              <div className="message-role">你</div>
              <div className="message-bubble">{runtimeState.pendingPromptText}</div>
            </div>
          ) : null}
          {runtimeState.pendingState !== "none" ? (
            <div className="message-row message-assistant">
              <div className="message-role">AI</div>
              <div
                className={
                  runtimeState.pendingState === "error"
                    ? "message-bubble message-error"
                    : "message-bubble message-pending"
                }
              >
                {runtimeState.pendingState === "loading" ? (
                  <span className="loading-dots" aria-label="正在生成">
                    <i />
                    <i />
                    <i />
                  </span>
                ) : (
                  runtimeState.pendingAssistantText
                )}
              </div>
            </div>
          ) : null}
        </section>
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
