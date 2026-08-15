import { useEffect, useState } from "react";
import { sendNativeMessage, subscribeNativeMessage } from "./nativeBridge";

interface ConversationMessage {
  roleName: "user" | "assistant";
  contentText: string;
}

interface ServiceProviderOption {
  optionIdentifier: string;
  displayName: string;
}

interface AIInputState {
  promptText: string;
  promptComposition: string;
  pendingPromptText: string;
  conversationMessageList: ConversationMessage[];
  pendingAssistantText: string;
  pendingState: "none" | "loading" | "error";
  serviceProviderIdentifier: string;
  serviceProviderList: ServiceProviderOption[];
  isPromptInputEnabled: boolean;
  isExpandedLayout: boolean;
  canCommitResult: boolean;
}

const emptyAIInputState: AIInputState = {
  promptText: "",
  promptComposition: "",
  pendingPromptText: "",
  conversationMessageList: [],
  pendingAssistantText: "",
  pendingState: "none",
  serviceProviderIdentifier: "deepseek",
  serviceProviderList: [],
  isPromptInputEnabled: true,
  isExpandedLayout: false,
  canCommitResult: false,
};

export default function AIInputApp() {
  const [inputState, setInputState] = useState(emptyAIInputState);
  const [providerMenuOpen, setProviderMenuOpen] = useState(false);

  useEffect(() => {
    const unsubscribeHandler = subscribeNativeMessage((nativeMessage) => {
      if (nativeMessage.messageType === "aiInputState") {
        setInputState(nativeMessage.messageData as AIInputState);
      }
    });
    sendNativeMessage("webViewReady", { viewName: "ai-input" });
    return unsubscribeHandler;
  }, []);

  const selectedProvider = inputState.serviceProviderList.find(
    (providerItem) =>
      providerItem.optionIdentifier === inputState.serviceProviderIdentifier,
  );
  const displayedPromptText = inputState.promptText + inputState.promptComposition;

  return (
    <main className={inputState.isExpandedLayout ? "ai-shell ai-expanded" : "ai-shell ai-compact"}>
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
              {inputState.serviceProviderList.map((providerItem) => (
                <button
                  className={
                    providerItem.optionIdentifier === inputState.serviceProviderIdentifier
                      ? "provider-menu-item provider-menu-item-active"
                      : "provider-menu-item"
                  }
                  key={providerItem.optionIdentifier}
                  type="button"
                  onClick={() => {
                    setProviderMenuOpen(false);
                    sendNativeMessage("aiInputAction", {
                      actionName: "setServiceProvider",
                      fieldValue: providerItem.optionIdentifier,
                    });
                    sendNativeMessage("aiInputAction", {
                      actionName: "focusPromptInput",
                      fieldValue: "",
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

      {inputState.isExpandedLayout ? (
        <section className="chat-transcript">
          {inputState.conversationMessageList.map((messageItem, messageIndex) => (
            <div
              className={messageItem.roleName === "user" ? "message-row message-user" : "message-row message-assistant"}
              key={`${messageItem.roleName}-${messageIndex}`}
            >
              <div className="message-role">{messageItem.roleName === "user" ? "你" : "AI"}</div>
              <div className="message-bubble">{messageItem.contentText}</div>
            </div>
          ))}
          {inputState.pendingPromptText ? (
            <div className="message-row message-user">
              <div className="message-role">你</div>
              <div className="message-bubble">{inputState.pendingPromptText}</div>
            </div>
          ) : null}
          {inputState.pendingState !== "none" ? (
            <div className="message-row message-assistant">
              <div className="message-role">AI</div>
              <div
                className={
                  inputState.pendingState === "error"
                    ? "message-bubble message-error"
                    : "message-bubble message-pending"
                }
              >
                {inputState.pendingState === "loading" ? (
                  <span className="loading-dots" aria-label="正在生成">
                    <i />
                    <i />
                    <i />
                  </span>
                ) : (
                  inputState.pendingAssistantText
                )}
              </div>
            </div>
          ) : null}
        </section>
      ) : null}

      <button
        className={
          inputState.isPromptInputEnabled
            ? "prompt-surface prompt-enabled"
            : "prompt-surface prompt-disabled"
        }
        type="button"
        onClick={() =>
          sendNativeMessage("aiInputAction", {
            actionName: "focusPromptInput",
            fieldValue: "",
          })
        }
      >
        {displayedPromptText ? (
          <span className="prompt-text">
            {inputState.promptText}
            {inputState.promptComposition ? (
              <span className="prompt-composition">{inputState.promptComposition}</span>
            ) : null}
            {inputState.isPromptInputEnabled ? <span className="prompt-caret" /> : null}
          </span>
        ) : (
          <span className="prompt-placeholder">输入你想让 AI 处理的内容</span>
        )}
        <span className="prompt-shortcut">↩ 发送</span>
      </button>

      {inputState.canCommitResult ? (
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
