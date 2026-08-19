import { Fragment, useEffect, useState } from "react";
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
  isSpecialInputExpansionVisible: boolean;
  specialInputExpansionTitle: string;
  isSpecialInputExpansionTriggerVisible: boolean;
  specialInputExpansionTriggerInsertIndex: number;
  specialInputExpansionTriggerLabelText: string;
  specialInputExpansionTriggerText: string;
  specialInputExpansionTriggerWidthPoint: number;
  hasPageControls: boolean;
  pageText: string;
  isPreviousPageEnabled: boolean;
  isNextPageEnabled: boolean;
}

const emptyCandidateState: CandidateState = {
  candidateList: [],
  highlightedIndex: -1,
  isAIInputTriggerVisible: false,
  isSpecialInputExpansionVisible: false,
  specialInputExpansionTitle: "",
  isSpecialInputExpansionTriggerVisible: false,
  specialInputExpansionTriggerInsertIndex: -1,
  specialInputExpansionTriggerLabelText: "",
  specialInputExpansionTriggerText: "",
  specialInputExpansionTriggerWidthPoint: 0,
  hasPageControls: false,
  pageText: "",
  isPreviousPageEnabled: false,
  isNextPageEnabled: false,
};

function selectCandidate(candidateIndex: number) {
  sendNativeMessage("candidateAction", {
    actionName: "selectCandidate",
    candidateIndex,
  });
}

function selectSpecialInputExpansion() {
  sendNativeMessage("candidateAction", {
    actionName: "selectSpecialInputExpansion",
  });
}

// 日期和时间扩展使用独立候选布局，普通 Rime 候选仍保持原有横向候选条。
function SpecialInputExpansionList({ candidateState }: { candidateState: CandidateState }) {
  return (
    <main className="candidate-shell candidate-shell-special-expansion">
      <div className="candidate-special-expansion-list" role="listbox" aria-label={`${candidateState.specialInputExpansionTitle}格式`}>
        {candidateState.candidateList.map((candidateItem, candidateIndex) => {
          const isHighlighted = candidateIndex === candidateState.highlightedIndex;
          const candidateClassName = isHighlighted
            ? "candidate-special-expansion-item candidate-special-expansion-item-highlighted"
            : "candidate-special-expansion-item";
          return (
            <button
              aria-selected={isHighlighted}
              className={candidateClassName}
              key={`${candidateItem.labelText}-${candidateItem.textValue}-${candidateIndex}`}
              type="button"
              onClick={() => selectCandidate(candidateIndex)}
            >
              <span className="candidate-special-expansion-label">{candidateItem.labelText}</span>
              <span className="candidate-special-expansion-text">{candidateItem.textValue}</span>
            </button>
          );
        })}
      </div>
    </main>
  );
}

// 候选视觉交给 React 页面处理，点击只回传索引让 Swift 执行真实输入动作。
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

  if (candidateState.isSpecialInputExpansionVisible) {
    return <SpecialInputExpansionList candidateState={candidateState} />;
  }

  return (
    <main className="candidate-shell">
      <div className="candidate-list">
        {candidateState.candidateList.map((candidateItem, candidateIndex) => {
          const isHighlighted = candidateIndex === candidateState.highlightedIndex;
          const isAIInputTrigger = candidateState.isAIInputTriggerVisible && candidateIndex === 0;
          let candidateClassName = "candidate-item";
          if (isHighlighted) {
            candidateClassName += " candidate-item-highlighted";
          }
          if (isAIInputTrigger) {
            candidateClassName += " candidate-item-ai-trigger";
          }
          return (
            <Fragment key={`${candidateItem.labelText}-${candidateItem.textValue}-${candidateIndex}`}>
              <button
                className={candidateClassName}
                style={{ width: `${candidateItem.widthPoint}px` }}
                type="button"
                onClick={() => selectCandidate(candidateIndex)}
              >
                {isAIInputTrigger ? (
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
              {candidateState.isSpecialInputExpansionTriggerVisible &&
              candidateIndex === candidateState.specialInputExpansionTriggerInsertIndex ? (
                <button
                  aria-label={`展开${candidateState.specialInputExpansionTriggerText}格式`}
                  className="candidate-item candidate-item-special-trigger"
                  style={{ width: `${candidateState.specialInputExpansionTriggerWidthPoint}px` }}
                  type="button"
                  onClick={selectSpecialInputExpansion}
                >
                  <span className="candidate-label">{candidateState.specialInputExpansionTriggerLabelText}</span>
                  <span className="candidate-special-trigger-icon">▦</span>
                  <span className="candidate-text">{candidateState.specialInputExpansionTriggerText}</span>
                </button>
              ) : null}
            </Fragment>
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
