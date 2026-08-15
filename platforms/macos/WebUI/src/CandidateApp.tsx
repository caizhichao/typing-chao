import { useEffect, useState } from "react";
import { sendNativeMessage, subscribeNativeMessage } from "./nativeBridge";

interface CandidateItem {
  labelText: string;
  textValue: string;
  commentText: string;
  widthPoint: number;
}

interface CandidateState {
  candidateList: CandidateItem[];
  highlightedIndex: number;
  isAIInputTriggerVisible: boolean;
  hasPageControls: boolean;
  pageText: string;
  isPreviousPageEnabled: boolean;
  isNextPageEnabled: boolean;
}

const emptyCandidateState: CandidateState = {
  candidateList: [],
  highlightedIndex: -1,
  isAIInputTriggerVisible: false,
  hasPageControls: false,
  pageText: "",
  isPreviousPageEnabled: false,
  isNextPageEnabled: false,
};

// 候选视觉和悬停交给 Tailwind 页面处理，点击只回传索引让 Swift 执行真实 librime 动作。
export default function CandidateApp() {
  const [candidateState, setCandidateState] = useState(emptyCandidateState);

  useEffect(() => {
    const unsubscribeHandler = subscribeNativeMessage((nativeMessage) => {
      if (nativeMessage.messageType === "candidateState") {
        setCandidateState(nativeMessage.messageData as CandidateState);
      }
    });
    sendNativeMessage("webViewReady", { viewName: "candidate" });
    return unsubscribeHandler;
  }, []);

  return (
    <main className="candidate-shell">
      <div className="candidate-list">
        {candidateState.candidateList.map((candidateItem, candidateIndex) => {
          const isHighlighted = candidateIndex === candidateState.highlightedIndex;
          const candidateClassName = isHighlighted
            ? "candidate-item candidate-item-highlighted"
            : "candidate-item";
          return (
            <button
              className={candidateClassName}
              key={`${candidateItem.labelText}-${candidateItem.textValue}-${candidateIndex}`}
              style={{ width: `${candidateItem.widthPoint}px` }}
              type="button"
              onClick={() =>
                sendNativeMessage("candidateAction", {
                  actionName: "selectCandidate",
                  candidateIndex,
                })
              }
            >
              {candidateState.isAIInputTriggerVisible && candidateIndex === 0 ? (
                <>
                  <span className="candidate-label">1</span>
                  <span className="candidate-ai-mark">✦</span>
                  <span className="candidate-text">AI</span>
                </>
              ) : (
                <>
                  <span className="candidate-label">{candidateItem.labelText}</span>
                  <span className="candidate-text">{candidateItem.textValue}</span>
                  {candidateItem.commentText ? (
                    <span className="candidate-comment">{candidateItem.commentText}</span>
                  ) : null}
                </>
              )}
            </button>
          );
        })}
      </div>

      <div className="candidate-trailing">
        {candidateState.hasPageControls ? (
          <div className="candidate-page-group">
            <span className="candidate-page-indicator">{candidateState.pageText}</span>
            <button
              aria-label="上一页候选"
              className="candidate-page-button"
              disabled={!candidateState.isPreviousPageEnabled}
              type="button"
              onClick={() =>
                sendNativeMessage("candidateAction", {
                  actionName: "changePage",
                  pageBackward: true,
                })
              }
            >
              ‹
            </button>
            <button
              aria-label="下一页候选"
              className="candidate-page-button"
              disabled={!candidateState.isNextPageEnabled}
              type="button"
              onClick={() =>
                sendNativeMessage("candidateAction", {
                  actionName: "changePage",
                  pageBackward: false,
                })
              }
            >
              ›
            </button>
          </div>
        ) : null}
        <span className="candidate-trailing-separator" />
        <button
          aria-label="打开 Typing Chao 设置"
          className="candidate-settings-button"
          title="打开设置"
          type="button"
          onClick={() => sendNativeMessage("candidateAction", { actionName: "openSettings" })}
        >
          ⚙
        </button>
      </div>
    </main>
  );
}
