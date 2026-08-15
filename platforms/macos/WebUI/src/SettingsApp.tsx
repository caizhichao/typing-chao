import { useEffect, useMemo, useState } from "react";
import { sendNativeMessage, subscribeNativeMessage } from "./nativeBridge";

interface SelectOption {
  optionIdentifier: string;
  displayName: string;
}

interface ServiceProviderOption extends SelectOption {
  apiKeyDisplayName: string;
  defaultBaseURL: string;
}

interface SettingsState {
  versionText: string;
  translationEnabled: boolean;
  targetLanguageIdentifier: string;
  targetLanguageList: SelectOption[];
  serviceProviderIdentifier: string;
  serviceProviderList: ServiceProviderOption[];
  apiKeyConfigured: boolean;
  customBaseURL: string;
  modelName: string;
  modelNameList: string[];
  schemaIdentifier: string;
  schemaList: SelectOption[];
  inputModeIdentifier: string;
  characterFormIdentifier: string;
  punctuationModeIdentifier: string;
  characterWidthIdentifier: string;
}

interface SettingsActionResult {
  actionName: string;
  isSuccess: boolean;
  messageText: string;
}

const emptySettingsState: SettingsState = {
  versionText: "",
  translationEnabled: false,
  targetLanguageIdentifier: "English",
  targetLanguageList: [],
  serviceProviderIdentifier: "deepseek",
  serviceProviderList: [],
  apiKeyConfigured: false,
  customBaseURL: "",
  modelName: "",
  modelNameList: [],
  schemaIdentifier: "",
  schemaList: [],
  inputModeIdentifier: "chinese",
  characterFormIdentifier: "simplified",
  punctuationModeIdentifier: "chinese",
  characterWidthIdentifier: "half",
};

function SelectControl({
  selectedIdentifier,
  optionList,
  onChange,
}: {
  selectedIdentifier: string;
  optionList: SelectOption[];
  onChange: (optionIdentifier: string) => void;
}) {
  return (
    <select
      className="form-control select-control"
      value={selectedIdentifier}
      onChange={(eventValue) => onChange(eventValue.target.value)}
    >
      {optionList.map((optionItem) => (
        <option key={optionItem.optionIdentifier} value={optionItem.optionIdentifier}>
          {optionItem.displayName}
        </option>
      ))}
    </select>
  );
}

function SegmentControl({
  selectedIdentifier,
  optionList,
  onChange,
}: {
  selectedIdentifier: string;
  optionList: SelectOption[];
  onChange: (optionIdentifier: string) => void;
}) {
  return (
    <div className="segment-control">
      {optionList.map((optionItem) => (
        <button
          className={
            selectedIdentifier === optionItem.optionIdentifier
              ? "segment-button segment-button-active"
              : "segment-button"
          }
          key={optionItem.optionIdentifier}
          type="button"
          onClick={() => onChange(optionItem.optionIdentifier)}
        >
          {optionItem.displayName}
        </button>
      ))}
    </div>
  );
}

function SettingsRow({
  titleText,
  subtitleText,
  children,
}: {
  titleText: string;
  subtitleText: string;
  children: React.ReactNode;
}) {
  return (
    <div className="settings-row">
      <div className="min-w-0 pr-5">
        <div className="text-[13px] font-semibold text-[var(--text-primary)]">
          {titleText}
        </div>
        <div className="mt-1 text-[11.5px] leading-[1.45] text-[var(--text-secondary)]">
          {subtitleText}
        </div>
      </div>
      <div className="settings-control">{children}</div>
    </div>
  );
}

export default function SettingsApp() {
  const [activeSection, setActiveSection] = useState<"translation" | "input">(
    "translation",
  );
  const [settingsState, setSettingsState] = useState(emptySettingsState);
  const [apiKeyText, setAPIKeyText] = useState("");
  const [baseURLText, setBaseURLText] = useState("");
  const [isModelLoading, setIsModelLoading] = useState(false);
  const [actionResult, setActionResult] = useState<SettingsActionResult | null>(null);

  const serviceProvider = useMemo(
    () =>
      settingsState.serviceProviderList.find(
        (providerItem) =>
          providerItem.optionIdentifier === settingsState.serviceProviderIdentifier,
      ),
    [settingsState],
  );

  useEffect(() => {
    const unsubscribeHandler = subscribeNativeMessage((nativeMessage) => {
      if (nativeMessage.messageType === "settingsState") {
        const nextState = nativeMessage.messageData as SettingsState;
        setSettingsState(nextState);
        setBaseURLText(nextState.customBaseURL);
        setAPIKeyText("");
        setIsModelLoading(false);
        return;
      }
      if (nativeMessage.messageType === "settingsActionResult") {
        setActionResult(nativeMessage.messageData as SettingsActionResult);
        return;
      }
      if (nativeMessage.messageType === "settingsPastedAPIKey") {
        setAPIKeyText(String(nativeMessage.messageData || ""));
        return;
      }
      if (nativeMessage.messageType === "settingsModelLoading") {
        setIsModelLoading(Boolean(nativeMessage.messageData));
        return;
      }
      if (nativeMessage.messageType === "settingsModelList") {
        const messageData = nativeMessage.messageData as {
          modelName: string;
          modelNameList: string[];
        };
        setSettingsState((currentState) => ({
          ...currentState,
          modelName: messageData.modelName,
          modelNameList: messageData.modelNameList,
        }));
        setIsModelLoading(false);
      }
    });
    sendNativeMessage("webViewReady", { viewName: "settings" });
    return unsubscribeHandler;
  }, []);

  useEffect(() => {
    if (!actionResult) return;
    const timeoutIdentifier = window.setTimeout(() => setActionResult(null), 3200);
    return () => window.clearTimeout(timeoutIdentifier);
  }, [actionResult]);

  const sendSetting = (actionName: string, fieldValue: unknown) => {
    sendNativeMessage("settingsAction", { actionName, fieldValue });
  };

  return (
    <main className="settings-shell">
      <aside className="settings-sidebar">
        <div className="mb-6 px-2">
          <div className="flex items-center gap-2.5">
            <div className="brand-mark">T</div>
            <div>
              <div className="text-[15px] font-semibold tracking-[-0.01em] text-[var(--text-primary)]">
                Typing Chao
              </div>
              <div className="mt-0.5 text-[10px] text-[var(--text-tertiary)]">
                通用 AI 输入法
              </div>
            </div>
          </div>
          <div className="mt-3 rounded-full bg-[var(--surface-muted)] px-2.5 py-1 text-center text-[10px] text-[var(--text-tertiary)]">
            {settingsState.versionText || "正在读取版本…"}
          </div>
        </div>

        <nav className="space-y-1">
          <button
            className={activeSection === "translation" ? "nav-item nav-item-active" : "nav-item"}
            type="button"
            onClick={() => setActiveSection("translation")}
          >
            <span className="nav-icon">译</span>
            翻译与 AI
          </button>
          <button
            className={activeSection === "input" ? "nav-item nav-item-active" : "nav-item"}
            type="button"
            onClick={() => setActiveSection("input")}
          >
            <span className="nav-icon">⌨</span>
            输入
          </button>
        </nav>

        <div className="mt-auto px-2 text-[10px] leading-5 text-[var(--text-tertiary)]">
          设置只保存在本机
          <br />
          不修改系统输入源
        </div>
      </aside>

      <section className="settings-page">
        {activeSection === "translation" ? (
          <>
            <header className="page-header">
              <div>
                <h1>翻译与 AI</h1>
                <p>管理边写边译、AI 问答服务和本机凭据。</p>
              </div>
              <span className="status-pill">
                <span className="status-dot" /> 本机直连
              </span>
            </header>

            <div className="settings-card">
              <SettingsRow
                titleText="边写边译"
                subtitleText="拼音提交后稳定等待 1 秒；粘贴时只处理剪贴板文本"
              >
                <button
                  aria-pressed={settingsState.translationEnabled}
                  className={settingsState.translationEnabled ? "switch-control switch-active" : "switch-control"}
                  type="button"
                  onClick={() =>
                    sendSetting("setTranslationEnabled", !settingsState.translationEnabled)
                  }
                >
                  <span />
                </button>
              </SettingsRow>
              <SettingsRow titleText="目标语言" subtitleText="译文会按这里选择的语言生成">
                <SelectControl
                  selectedIdentifier={settingsState.targetLanguageIdentifier}
                  optionList={settingsState.targetLanguageList}
                  onChange={(fieldValue) => sendSetting("setTargetLanguage", fieldValue)}
                />
              </SettingsRow>
              <SettingsRow titleText="AI 服务" subtitleText="翻译和 AI 问答共用此请求协议">
                <SelectControl
                  selectedIdentifier={settingsState.serviceProviderIdentifier}
                  optionList={settingsState.serviceProviderList}
                  onChange={(fieldValue) => sendSetting("setServiceProvider", fieldValue)}
                />
              </SettingsRow>
            </div>

            <div className="settings-card mt-3">
              <SettingsRow
                titleText={serviceProvider?.apiKeyDisplayName || "API Key"}
                subtitleText="只缓存在本机设置，不会进入 Web UI 状态或写入输入法包"
              >
                <div className="field-actions">
                  <input
                    className="form-control min-w-0 flex-1"
                    type="password"
                    value={apiKeyText}
                    placeholder={
                      settingsState.apiKeyConfigured
                        ? "已配置，输入新 Key 可覆盖"
                        : `输入 ${serviceProvider?.apiKeyDisplayName || "API Key"}`
                    }
                    onChange={(eventValue) => setAPIKeyText(eventValue.target.value)}
                  />
                  <button
                    className="ghost-button"
                    type="button"
                    onClick={() => sendSetting("pasteAPIKey", "")}
                  >
                    粘贴
                  </button>
                  <button
                    className="secondary-button"
                    type="button"
                    onClick={() => {
                      sendSetting("saveAPIKey", apiKeyText);
                      setAPIKeyText("");
                    }}
                  >
                    保存
                  </button>
                  <button
                    className="ghost-button"
                    type="button"
                    onClick={() => sendSetting("clearAPIKey", "")}
                  >
                    清除
                  </button>
                </div>
              </SettingsRow>
              <SettingsRow
                titleText="Base URL"
                subtitleText={`留空使用 ${serviceProvider?.defaultBaseURL || "当前服务默认地址"}`}
              >
                <div className="field-actions">
                  <input
                    className="form-control min-w-0 flex-1"
                    type="url"
                    value={baseURLText}
                    placeholder={serviceProvider?.defaultBaseURL || "https://api.example.com"}
                    onChange={(eventValue) => setBaseURLText(eventValue.target.value)}
                  />
                  <button
                    className="secondary-button"
                    type="button"
                    onClick={() => sendSetting("saveBaseURL", baseURLText)}
                  >
                    保存
                  </button>
                  <button
                    className="ghost-button"
                    type="button"
                    onClick={() => sendSetting("clearBaseURL", "")}
                  >
                    清除
                  </button>
                </div>
              </SettingsRow>
              <SettingsRow titleText="模型" subtitleText="拉取当前服务模型列表后选择实际使用的模型">
                <div className="field-actions">
                  <select
                    className="form-control select-control min-w-0 flex-1"
                    value={settingsState.modelName}
                    onChange={(eventValue) => sendSetting("setModelName", eventValue.target.value)}
                  >
                    {settingsState.modelNameList.map((modelName) => (
                      <option key={modelName} value={modelName}>
                        {modelName}
                      </option>
                    ))}
                  </select>
                  <button
                    className="secondary-button min-w-[64px]"
                    disabled={isModelLoading}
                    type="button"
                    onClick={() => sendSetting("fetchModelList", "")}
                  >
                    {isModelLoading ? "拉取中…" : "拉取"}
                  </button>
                </div>
              </SettingsRow>
            </div>

            <div className="info-card mt-3">
              <div className="info-icon">AI</div>
              <div>
                <div className="text-[12px] font-semibold text-[var(--text-primary)]">AI 快速输入</div>
                <div className="mt-1 text-[11px] leading-5 text-[var(--text-secondary)]">
                  输入 <kbd>=</kbd> 后按 <kbd>1</kbd> 或回车，也可从输入法菜单打开 AI 输入。
                </div>
              </div>
            </div>
          </>
        ) : (
          <>
            <header className="page-header">
              <div>
                <h1>输入</h1>
                <p>当前输入会话的方案、字形和标点设置。</p>
              </div>
            </header>

            <div className="settings-card">
              <SettingsRow titleText="拼音方案" subtitleText="可选择全拼、自然码双拼、小鹤双拼、九键或五笔">
                <SelectControl
                  selectedIdentifier={settingsState.schemaIdentifier}
                  optionList={settingsState.schemaList}
                  onChange={(fieldValue) => sendSetting("setSchema", fieldValue)}
                />
              </SettingsRow>
              <SettingsRow titleText="输入模式" subtitleText="在当前输入法内切换中文或英文">
                <SegmentControl
                  selectedIdentifier={settingsState.inputModeIdentifier}
                  optionList={[
                    { optionIdentifier: "chinese", displayName: "中文" },
                    { optionIdentifier: "english", displayName: "英文" },
                  ]}
                  onChange={(fieldValue) => sendSetting("setInputMode", fieldValue)}
                />
              </SettingsRow>
              <SettingsRow titleText="汉字" subtitleText="默认使用简体中文">
                <SegmentControl
                  selectedIdentifier={settingsState.characterFormIdentifier}
                  optionList={[
                    { optionIdentifier: "simplified", displayName: "简体" },
                    { optionIdentifier: "traditional", displayName: "繁体" },
                  ]}
                  onChange={(fieldValue) => sendSetting("setCharacterForm", fieldValue)}
                />
              </SettingsRow>
              <SettingsRow titleText="标点样式" subtitleText="中文或西文标点独立设置，不与字符宽度混为同一状态">
                <SegmentControl
                  selectedIdentifier={settingsState.punctuationModeIdentifier}
                  optionList={[
                    { optionIdentifier: "chinese", displayName: "中文" },
                    { optionIdentifier: "western", displayName: "西文" },
                  ]}
                  onChange={(fieldValue) => sendSetting("setPunctuationMode", fieldValue)}
                />
              </SettingsRow>
              <SettingsRow titleText="字符宽度" subtitleText="半角使用常规字符；全角转换拉丁字母、数字和空格宽度">
                <SegmentControl
                  selectedIdentifier={settingsState.characterWidthIdentifier}
                  optionList={[
                    { optionIdentifier: "half", displayName: "半角" },
                    { optionIdentifier: "full", displayName: "全角" },
                  ]}
                  onChange={(fieldValue) => sendSetting("setCharacterWidth", fieldValue)}
                />
              </SettingsRow>
              <SettingsRow titleText="快捷切换" subtitleText="输入时切换半角与全角，切换后显示当前状态">
                <div className="flex items-center justify-end gap-1.5">
                  <kbd>Shift</kbd>
                  <span className="text-[10px] text-[var(--text-tertiary)]">+</span>
                  <kbd>Space</kbd>
                </div>
              </SettingsRow>
            </div>

            <div className="info-card mt-3">
              <div className="info-icon">隐</div>
              <div>
                <div className="text-[12px] font-semibold text-[var(--text-primary)]">安全输入保护</div>
                <div className="mt-1 text-[11px] leading-5 text-[var(--text-secondary)]">
                  密码框和系统安全输入期间不会发送远程翻译或 AI 请求；这些设置只影响 Typing Chao，不会修改其它 macOS 输入法。
                </div>
              </div>
            </div>
          </>
        )}
      </section>

      {actionResult ? (
        <div className={actionResult.isSuccess ? "toast toast-success" : "toast toast-error"}>
          {actionResult.messageText}
        </div>
      ) : null}
    </main>
  );
}
