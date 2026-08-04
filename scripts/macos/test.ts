#!/usr/bin/env bun

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const buildRoot = join(projectRoot, "build");
const proxyAccessTokenPath = join(homedir(), ".config", "typing-dongnanya", "access-token");
const vendorRoot = join(projectRoot, "vendor", "librime");
const sdkPath = runText("xcrun", ["--show-sdk-path"]);
const architecture = runText("arch", []);
const smokeDirectory = join(buildRoot, "test-rime-data");
const outputPath = join(buildRoot, "RimeSmoke");

run("bun", ["run", "scripts/macos/build.ts"]);
verifyStableDevelopmentCodeRequirement();
verifyBundledTranslationEndpoint();
verifyTranslationPromptContract();
verifyInputControllerLifecycleContract();
verifyInputLatencyContract();
verifyClipboardOnlyTranslationContract();
verifyEscapeClearContract();
verifyDirectSymbolContract();
verifyKnownPassThroughContract();
verifyNoExternalPermissionContract();
verifyCandidateSettingsContract();
mkdirSync(smokeDirectory, { recursive: true });
run("clang++", [
  "-std=c++17",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-isysroot",
  sdkPath,
  "-I",
  join(vendorRoot, "src"),
  "-I",
  join(vendorRoot, "include"),
  join(projectRoot, "Tests", "RimeSmoke.cc"),
  join(vendorRoot, "build", "lib", "librime.a"),
  "-L",
  join(vendorRoot, "lib"),
  "-lglog",
  "-lyaml-cpp",
  "-lleveldb",
  "-lmarisa",
  "-lopencc",
  "/opt/homebrew/opt/boost/lib/libboost_regex.a",
  "/opt/homebrew/opt/boost/lib/libboost_locale.a",
  "/opt/homebrew/opt/boost/lib/libboost_filesystem.a",
  "/opt/homebrew/opt/boost/lib/libboost_thread.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicuuc.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicui18n.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicudata.a",
  "-lc++",
  "-o",
  outputPath,
]);
run(outputPath, [
  join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", "RimeData"),
  smokeDirectory,
]);

const editorSnapshotSmokeOutputPath = join(
  buildRoot,
  "TranslationEditorSnapshotSmoke",
);
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(
    projectRoot,
    "Sources",
    "TypingDongnanyaInputMethod",
    "TranslationDraft.swift",
  ),
  join(projectRoot, "Tests", "TranslationEditorSnapshotSmoke.swift"),
  "-o",
  editorSnapshotSmokeOutputPath,
]);
run(editorSnapshotSmokeOutputPath, []);

const settingsSmokeOutputPath = join(buildRoot, "InputMethodSettingsSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(
    projectRoot,
    "Sources",
    "TypingDongnanyaInputMethod",
    "InputMethodSettings.swift",
  ),
  join(projectRoot, "Tests", "InputMethodSettingsSmoke.swift"),
  "-o",
  settingsSmokeOutputPath,
]);
run(settingsSmokeOutputPath, []);

const rimeInputPolicySmokeOutputPath = join(buildRoot, "RimeInputPolicySmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "RimeSnapshot.swift"),
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "RimeInputPolicy.swift"),
  join(projectRoot, "Tests", "RimeInputPolicySmoke.swift"),
  "-o",
  rimeInputPolicySmokeOutputPath,
]);
run(rimeInputPolicySmokeOutputPath, []);

const inputModeStatusSmokeOutputPath = join(buildRoot, "InputModeStatusOverlaySmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "RimeSnapshot.swift"),
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "OverlayLayout.swift"),
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "InputModeStatusOverlay.swift"),
  join(projectRoot, "Tests", "InputModeStatusOverlaySmoke.swift"),
  "-framework",
  "AppKit",
  "-framework",
  "InputMethodKit",
  "-framework",
  "Carbon",
  "-o",
  inputModeStatusSmokeOutputPath,
]);
run(inputModeStatusSmokeOutputPath, []);

const candidateBarLayoutSmokeOutputPath = join(buildRoot, "CandidateBarLayoutSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "RimeSnapshot.swift"),
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "OverlayLayout.swift"),
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "CandidateOverlay.swift"),
  join(projectRoot, "Tests", "CandidateBarLayoutSmoke.swift"),
  "-framework",
  "AppKit",
  "-framework",
  "InputMethodKit",
  "-framework",
  "Carbon",
  "-o",
  candidateBarLayoutSmokeOutputPath,
]);
run(candidateBarLayoutSmokeOutputPath, []);

const inputSourceRegistrationSmokeOutputPath = join(buildRoot, "InputSourceRegistrationSmoke");
run("swiftc", [
  "-parse-as-library",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(
    projectRoot,
    "Sources",
    "TypingDongnanyaInputMethod",
    "InputSourceRegistration.swift",
  ),
  join(projectRoot, "Tests", "InputSourceRegistrationSmoke.swift"),
  "-framework",
  "Carbon",
  "-o",
  inputSourceRegistrationSmokeOutputPath,
]);
run(inputSourceRegistrationSmokeOutputPath, []);

const overlayLayoutSmokeOutputPath = join(buildRoot, "OverlayLayoutSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(
    projectRoot,
    "Sources",
    "TypingDongnanyaInputMethod",
    "OverlayLayout.swift",
  ),
  join(projectRoot, "Tests", "OverlayLayoutSmoke.swift"),
  "-framework",
  "AppKit",
  "-framework",
  "InputMethodKit",
  "-framework",
  "Carbon",
  "-o",
  overlayLayoutSmokeOutputPath,
]);
run(overlayLayoutSmokeOutputPath, []);

const translationOverlaySmokeOutputPath = join(buildRoot, "TranslationOverlaySmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(
    projectRoot,
    "Sources",
    "TypingDongnanyaInputMethod",
    "OverlayLayout.swift",
  ),
  join(
    projectRoot,
    "Sources",
    "TypingDongnanyaInputMethod",
    "TranslationOverlay.swift",
  ),
  join(projectRoot, "Tests", "TranslationOverlaySmoke.swift"),
  "-framework",
  "AppKit",
  "-framework",
  "InputMethodKit",
  "-framework",
  "Carbon",
  "-o",
  translationOverlaySmokeOutputPath,
]);
run(translationOverlaySmokeOutputPath, []);

const menuIconSmokeOutputPath = join(buildRoot, "MenuIconSmoke");
run("swiftc", [
  "-parse-as-library",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(projectRoot, "Tests", "MenuIconSmoke.swift"),
  "-framework",
  "AppKit",
  "-o",
  menuIconSmokeOutputPath,
]);
run(menuIconSmokeOutputPath, [
  join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", "TypingDongnanyaMenuIconV4.pdf"),
]);

const appIconSmokeOutputPath = join(buildRoot, "AppIconSmoke");
run("swiftc", [
  "-parse-as-library",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(projectRoot, "Tests", "AppIconSmoke.swift"),
  "-framework",
  "AppKit",
  "-o",
  appIconSmokeOutputPath,
]);
run(appIconSmokeOutputPath, [
  join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", "TypingDongnanyaAppIcon.pdf"),
]);

const bridgeSmokeDirectory = join(buildRoot, "test-rime-bridge-data");
const bridgeSmokeOutputPath = join(buildRoot, "RimeBridgeSmoke");
mkdirSync(bridgeSmokeDirectory, { recursive: true });
run("clang++", [
  "-std=c++17",
  "-fobjc-arc",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-isysroot",
  sdkPath,
  "-I",
  join(projectRoot, "Sources", "TypingDongnanyaInputMethod"),
  "-I",
  join(vendorRoot, "src"),
  "-I",
  join(vendorRoot, "include"),
  join(projectRoot, "Tests", "RimeBridgeSmoke.mm"),
  join(buildRoot, "obj", "RimeBridge.o"),
  join(vendorRoot, "build", "lib", "librime.a"),
  "-L",
  join(vendorRoot, "lib"),
  "-lglog",
  "-lyaml-cpp",
  "-lleveldb",
  "-lmarisa",
  "-lopencc",
  "/opt/homebrew/opt/boost/lib/libboost_regex.a",
  "/opt/homebrew/opt/boost/lib/libboost_locale.a",
  "/opt/homebrew/opt/boost/lib/libboost_filesystem.a",
  "/opt/homebrew/opt/boost/lib/libboost_thread.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicuuc.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicui18n.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicudata.a",
  "-lc++",
  "-framework",
  "Foundation",
  "-o",
  bridgeSmokeOutputPath,
]);
run(bridgeSmokeOutputPath, [
  join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", "RimeData"),
  bridgeSmokeDirectory,
]);

// hidePalettes 只收口当前浮层；输入源真正停用时才释放活动会话。
function verifyInputControllerLifecycleContract() {
  const controllerSource = readFileSync(
    join(
      projectRoot,
      "Sources",
      "TypingDongnanyaInputMethod",
      "InputMethodController.swift",
    ),
    "utf8",
  );
  const initializerBody = swiftMethodBody(controllerSource, "override init(server:");
  const hidePalettesBody = swiftMethodBody(controllerSource, "override func hidePalettes()");
  const activateServerBody = swiftMethodBody(controllerSource, "override func activateServer");
  const deactivateServerBody = swiftMethodBody(controllerSource, "override func deactivateServer");
  if (!initializerBody.includes("sessionClient = inputClient as? IMKTextInput")) {
    throw new Error("输入控制器必须保留初始化阶段的 IMK 客户端，不能只依赖后续按键回调");
  }
  if (!activateServerBody.includes("var inputClient = sessionClient")) {
    throw new Error("输入源激活时必须优先恢复初始化阶段保存的 IMK 客户端");
  }
  if (!activateServerBody.includes("activeOverlayController = self")) {
    throw new Error("输入源激活时必须先建立进程级活动会话所有权，不能依赖宿主后续转发按键");
  }
  if (hidePalettesBody.includes("activeOverlayController = nil")) {
    throw new Error("hidePalettes 不得解除仍激活的输入会话资格");
  }
  if (!deactivateServerBody.includes("activeOverlayController = nil")) {
    throw new Error("输入源真正停用时必须释放当前输入会话所有权");
  }
  if (deactivateServerBody.includes("sessionClient = nil")) {
    throw new Error("普通停用不得丢弃控制器初始化时绑定的会话客户端");
  }
}

// 输入按键主路径不得启动跨进程监听、读取宿主正文或执行常驻轮询。
function verifyInputLatencyContract() {
  const controllerSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "InputMethodController.swift"),
    "utf8",
  );
  const draftSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "TranslationDraft.swift"),
    "utf8",
  );
  const forbiddenTokenList = [
    "TranslationAccessibility",
    "TranslationPasteShortcut",
    "AXUIElement",
    "AXIsProcessTrusted",
    "CGEvent",
    "addGlobalMonitorForEvents",
    "client.length()",
    "observeHostDocumentMutation",
  ];
  for (const forbiddenToken of forbiddenTokenList) {
    if (controllerSource.includes(forbiddenToken) || draftSource.includes(forbiddenToken)) {
      throw new Error(`剪贴板简化链不得保留跨进程监听或宿主正文读取：${forbiddenToken}`);
    }
  }
  const activateServerBody = swiftMethodBody(controllerSource, "override func activateServer");
  if (
    activateServerBody.includes("Timer") ||
    activateServerBody.includes("Monitor") ||
    activateServerBody.includes("Observer")
  ) {
    throw new Error("输入源激活时只能绑定 IMK 会话，不得启动外部监听或轮询");
  }
}

// 剪贴板和键盘确认文本都必须先进入输入法内部 marked draft，再由用户一次性提交。
function verifyClipboardOnlyTranslationContract() {
  const controllerSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "InputMethodController.swift"),
    "utf8",
  );
  const draftSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "TranslationDraft.swift"),
    "utf8",
  );
  const mainSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "main.swift"),
    "utf8",
  );
  const clipboardBody = swiftMethodBody(
    controllerSource,
    "private func activateClipboardTranslationDraft(",
  );
  const handleBody = swiftMethodBody(controllerSource, "override func handle(_ event:");
  const inputTextBody = swiftMethodBody(
    controllerSource,
    "override func inputText(_ string: String!, client sender: Any!)",
  );
  const keyedInputTextBody = swiftMethodBody(
    controllerSource,
    "override func inputText(_ string: String!, key keyCode:",
  );
  const prepareClientBody = swiftMethodBody(
    controllerSource,
    "private func prepareClient(_ client:",
  );
  const scheduleBody = swiftMethodBody(
    controllerSource,
    "private func scheduleTranslation(",
  );
  const translatedCommitBody = swiftMethodBody(
    controllerSource,
    "private func commitDisplayedTranslation()",
  );
  const originalCommitBody = swiftMethodBody(
    controllerSource,
    "private func commitOriginalTranslationDraft(",
  );
  const markedTextBody = swiftMethodBody(
    controllerSource,
    "private func markedText(for snapshot:",
  );
  if (
    !clipboardBody.includes("NSPasteboard.general.string(forType: .string)") ||
    !clipboardBody.includes("normalizedExpectedText == normalizedClipboardText") ||
    !clipboardBody.includes("synchronizeClipboardText") ||
    !clipboardBody.includes("refreshMarkedText") ||
    !clipboardBody.includes("return true")
  ) {
    throw new Error("粘贴翻译必须把已核对的剪贴板正文接管为内部 marked draft");
  }
  if (
    !handleBody.includes("activateClipboardTranslationDraft") ||
    !inputTextBody.includes("expectedText: string") ||
    !keyedInputTextBody.includes("activateClipboardTranslationDraft")
  ) {
    throw new Error("Command-V、手动翻译和多字符输入必须共用剪贴板草稿入口");
  }
  if (
    !scheduleBody.includes("stableInputDelayMilliseconds") ||
    !scheduleBody.includes("showTranslationDraftWaiting") ||
    !scheduleBody.includes("showLoading") ||
    !scheduleBody.includes("translationGeneration == requestGeneration") ||
    !scheduleBody.includes("resolvedSnapshot") ||
    !scheduleBody.includes("isActiveOverlayController") ||
    !scheduleBody.includes("!self.currentRimeSnapshot.isComposing")
  ) {
    throw new Error("翻译请求必须保留一秒稳定期、等待/加载状态和精确草稿代次校验");
  }
  if (
    scheduleBody.includes("clientMatches(") ||
    controllerSource.includes("private func clientMatches(")
  ) {
    throw new Error("异步翻译不得用会抖动的 IMK 客户端代理标识误杀有效请求");
  }
  if (
    !controllerSource.includes("private let translationSessionIdentifier") ||
    !controllerSource.includes("clientIdentifier: currentTranslationSessionIdentifier()") ||
    prepareClientBody.includes("overlayClientIdentifier(client)") ||
    prepareClientBody.includes("resetTranslationContext()")
  ) {
    throw new Error("翻译草稿必须绑定控制器生命周期，不能因 IMK 代理抖动而清空");
  }
  for (const inputBody of [handleBody, inputTextBody, keyedInputTextBody]) {
    if (
      !inputBody.includes("handleTranslationDraftEditingKey") ||
      !inputBody.includes("TranslationPolicy.shouldPassThroughHostEditingKey")
    ) {
      throw new Error("三个输入入口必须先处理内部草稿编辑，再决定是否交还宿主");
    }
  }
  if (
    mainSource.includes("startPasteShortcutMonitoring") ||
    draftSource.includes("InputMethodKit")
  ) {
    throw new Error("翻译草稿不得注册全局 Command-V，也不得依赖 InputMethodKit 类型");
  }
  if (
    !controllerSource.includes("setActionHandler") ||
    !translatedCommitBody.includes("displayedTranslation.translatedText") ||
    !translatedCommitBody.includes("resolvedSnapshot") ||
    !translatedCommitBody.includes("replacementRange: NSRange(location: NSNotFound") ||
    !originalCommitBody.includes("translationDraft.textValue") ||
    !originalCommitBody.includes("replacementRange: NSRange(location: NSNotFound") ||
    !markedTextBody.includes("draftText + snapshot.preeditText") ||
    controllerSource.includes("attributedSubstring(from:") ||
    controllerSource.includes("TranslationReplacementPolicy")
  ) {
    throw new Error("译文与原文必须从内部 marked draft 一次性提交，禁止继续追溯替换宿主正文");
  }
}

// Esc 清理当前 Rime 组合、请求和浮层，但必须保留输入法内部 marked draft。
function verifyEscapeClearContract() {
  const controllerSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "InputMethodController.swift"),
    "utf8",
  );
  const handleBody = swiftMethodBody(controllerSource, "override func handle(_ event:");
  const inputTextBody = swiftMethodBody(
    controllerSource,
    "override func inputText(_ string: String!, client sender: Any!)",
  );
  const keyedInputTextBody = swiftMethodBody(
    controllerSource,
    "override func inputText(_ string: String!, key keyCode:",
  );
  const clearBody = swiftMethodBody(
    controllerSource,
    "private func clearInputCache(client: IMKTextInput)",
  );
  if (
    !handleBody.includes('keyName == "Escape"') ||
    !handleBody.includes("clearInputCache(client: client)") ||
    !inputTextBody.includes('string == "\\u{1b}"') ||
    !inputTextBody.includes("clearInputCache(client: client)") ||
    !keyedInputTextBody.includes('resolvedKeyName == "Escape"') ||
    !keyedInputTextBody.includes("clearInputCache(client: client)")
  ) {
    throw new Error("三个 InputMethodKit 输入入口都必须把 Esc 收口到统一缓存清理入口");
  }
  for (const requiredToken of [
    "cancelTranslationPresentationPreservingDraft()",
    "rimeSession?.clearComposition()",
    "refreshMarkedText(client: client",
    "candidateOverlay.hide()",
    "inputModeStatusOverlay.hide()",
    "overlayAnchorCache.reset()",
  ]) {
    if (!clearBody.includes(requiredToken)) {
      throw new Error(`Esc 缓存清理缺少必要动作：${requiredToken}`);
    }
  }
  if (
    clearBody.includes("resetTranslationContext()") ||
    clearBody.includes("translationDraft.reset()")
  ) {
    throw new Error("Esc 只能取消当前组字和浮层，不能清空仍由 marked text 持有的完整草稿");
  }
}

// 首符号和拼音后的多选标点必须在候选 UI 刷新前直接确认，三个 IMK 入口共用同一处理链。
function verifyDirectSymbolContract() {
  const controllerSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "InputMethodController.swift"),
    "utf8",
  );
  const handleBody = swiftMethodBody(controllerSource, "override func handle(_ event:");
  const inputTextBody = swiftMethodBody(
    controllerSource,
    "override func inputText(_ string: String!, client sender: Any!)",
  );
  const keyedInputTextBody = swiftMethodBody(
    controllerSource,
    "override func inputText(_ string: String!, key keyCode:",
  );
  const processBody = swiftMethodBody(
    controllerSource,
    "private func processRimeKey(_ keyName: String, modifiers:",
  );
  for (const inputBody of [handleBody, inputTextBody, keyedInputTextBody]) {
    if (!inputBody.includes("processRimeKey(")) {
      throw new Error("三个 InputMethodKit 输入入口必须共用直接符号处理链");
    }
  }
  if (
    !processBody.includes("RimeInputPolicy.directSymbolCandidateIndex") ||
    !processBody.includes("rimeSession.selectCandidate") ||
    !processBody.includes("committedSnapshot.handled")
  ) {
    throw new Error("多选符号必须在候选窗刷新前由 librime 直接确认，失败时保留原快照");
  }
}

// Rime 未处理的空格和可打印字符必须进入内部草稿，未知动作先上屏原文再交还宿主。
function verifyKnownPassThroughContract() {
  const controllerSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "InputMethodController.swift"),
    "utf8",
  );
  const handleBody = swiftMethodBody(
    controllerSource,
    "private func handleUnhandledKey(_ keyName: String, client:",
  );
  if (
    !handleBody.includes("TranslationPolicy.passThroughText(for: keyName)") ||
    !handleBody.includes("translationDraft.appendConfirmedText") ||
    !handleBody.includes("refreshMarkedText(client: client") ||
    !handleBody.includes("return true") ||
    !handleBody.includes("commitOriginalTranslationDraft(client: client)")
  ) {
    throw new Error("已知直通文本必须进入内部 marked draft，未知键必须先确认原文");
  }
  for (const callText of [
    "handleUnhandledKey(keyName, client: client)",
    "handleUnhandledKey(resolvedKeyName, client: client)",
  ]) {
    if (!controllerSource.includes(callText)) {
      throw new Error("三个 InputMethodKit 输入入口必须把客户端交给直通文本处理链");
    }
  }
}

// 客户端不再声明辅助功能用途，设置页和命令行也不得继续请求系统隐私权限。
function verifyNoExternalPermissionContract() {
  const infoSource = readFileSync(join(projectRoot, "Info.plist"), "utf8");
  const mainSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "main.swift"),
    "utf8",
  );
  const settingsWindowSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "InputMethodSettingsWindow.swift"),
    "utf8",
  );
  const buildSource = readFileSync(
    join(projectRoot, "scripts", "macos", "build.ts"),
    "utf8",
  );
  for (const forbiddenToken of [
    "NSAccessibilityUsageDescription",
    "--request-accessibility",
    "--accessibility-status",
    "TranslationAccessibility.swift",
    "openAccessibilitySettings",
    "permissionRefreshTimer",
    "ApplicationServices",
  ]) {
    if (
      infoSource.includes(forbiddenToken) ||
      mainSource.includes(forbiddenToken) ||
      settingsWindowSource.includes(forbiddenToken) ||
      buildSource.includes(forbiddenToken)
    ) {
      throw new Error(`已删除的辅助功能链仍有残留：${forbiddenToken}`);
    }
  }
}

// 候选条只能有一个真实设置按钮，点击后由统一 AppKit 生命周期打开唯一设置窗口。
function verifyCandidateSettingsContract() {
  const candidateSource = readFileSync(
    join(
      projectRoot,
      "Sources",
      "TypingDongnanyaInputMethod",
      "CandidateOverlay.swift",
    ),
    "utf8",
  );
  const mainSource = readFileSync(
    join(projectRoot, "Sources", "TypingDongnanyaInputMethod", "main.swift"),
    "utf8",
  );
  const settingsSource = readFileSync(
    join(
      projectRoot,
      "Sources",
      "TypingDongnanyaInputMethod",
      "InputMethodSettingsWindow.swift",
    ),
    "utf8",
  );
  const inputModeStatusSource = readFileSync(
    join(
      projectRoot,
      "Sources",
      "TypingDongnanyaInputMethod",
      "InputModeStatusOverlay.swift",
    ),
    "utf8",
  );
  const controllerSource = readFileSync(
    join(
      projectRoot,
      "Sources",
      "TypingDongnanyaInputMethod",
      "InputMethodController.swift",
    ),
    "utf8",
  );
  if (
    !candidateSource.includes("CandidateSettingsButton") ||
    !candidateSource.includes('systemSymbolName: "gearshape"') ||
    candidateSource.includes('NSString(string: "⌄")') ||
    candidateSource.includes('NSString(string: "⚙︎")')
  ) {
    throw new Error("候选条尾部必须只保留一个可点击的系统齿轮按钮");
  }
  if (!mainSource.includes("TypingDongnanyaApplicationDelegate.shared")) {
    throw new Error("输入法进程必须由统一 AppKit delegate 管理设置窗口生命周期");
  }
  if (
    !settingsSource.includes("字符宽度") ||
    !settingsSource.includes("标点样式") ||
    !settingsSource.includes("Shift + Space")
  ) {
    throw new Error("设置页必须把半/全角、标点样式和快捷切换分开说明");
  }
  if (
    !candidateSource.includes("CandidateBarTrailingLayout") ||
    !candidateSource.includes("drawTrailingSeparator()")
  ) {
    throw new Error("候选条分页区与设置区必须使用独立布局和可见分隔");
  }
  if (
    !settingsSource.includes("window?.level = .normal") ||
    settingsSource.includes("window?.orderFrontRegardless()")
  ) {
    throw new Error("设置窗口必须使用标准窗口层级，不能永久悬浮在其它应用上方");
  }
  if (!settingsSource.includes("InputMethodSettings.shared.persistRimeOptionStateList(optionStateList)")) {
    throw new Error("设置窗口失去当前输入控制器时仍必须保存 Rime 选项供下次会话恢复");
  }
  if (!inputModeStatusSource.includes("translationOrigin(for: panelSize, candidateFrame: candidateFrame)")) {
    throw new Error("半/全角状态提示必须避开当前候选条，不能复用同一候选位置");
  }
  if (!controllerSource.includes("candidateFrame: translationOverlay.visibleFrame")) {
    throw new Error("非组字状态提示必须同时避让已有译文卡");
  }
  const persistOptionBody = swiftMethodBody(
    controllerSource,
    "private func persistChangedCharacterOptionState(",
  );
  if (
    !persistOptionBody.includes(".fullShape") ||
    !persistOptionBody.includes(".asciiPunctuation") ||
    !persistOptionBody.includes("persistRimeOptionStateList")
  ) {
    throw new Error("Shift-Space 与 Control-Period 的 Rime 状态变化必须持久化");
  }
}

// 测试只提取目标 Swift 方法体，避免同文件其它生命周期分支影响断言。
function swiftMethodBody(source: string, signature: string) {
  const signatureIndex = source.indexOf(signature);
  if (signatureIndex < 0) throw new Error(`找不到方法：${signature}`);
  const bodyStart = source.indexOf("{", signatureIndex);
  if (bodyStart < 0) throw new Error(`找不到方法体：${signature}`);
  var depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) return source.slice(bodyStart + 1, index);
  }
  throw new Error(`方法体未闭合：${signature}`);
}

function verifyBundledTranslationEndpoint() {
  const sourceInfoPath = join(projectRoot, "Info.plist");
  const bundleInfoPath = join(
    buildRoot,
    "TypingDongnanya.app",
    "Contents",
    "Info.plist",
  );
  const accessToken = readProxyAccessToken();
  const sourceInfoText = readFileSync(sourceInfoPath, "utf8");
  const sourceInfo = readInfoPlist(sourceInfoPath);
  const bundledInfo = readInfoPlist(bundleInfoPath);
  if (sourceInfoText.includes(accessToken)) {
    throw new Error("源 Info.plist 不得写入翻译代理 capability");
  }
  if (
    sourceInfo.TypingDongnanyaAPIEndpoint !== undefined ||
    typeof sourceInfo.TypingDongnanyaAPIBaseEndpoint !== "string" ||
    bundledInfo.TypingDongnanyaAPIBaseEndpoint !== undefined ||
    typeof bundledInfo.TypingDongnanyaAPIEndpoint !== "string"
  ) {
    throw new Error("翻译代理地址必须只在构建包内以 capability 完整路径出现");
  }

  const baseEndpointURL = new URL(sourceInfo.TypingDongnanyaAPIBaseEndpoint);
  const endpointURL = new URL(bundledInfo.TypingDongnanyaAPIEndpoint);
  const expectedPath = baseEndpointURL.pathname.replace(/\/+$/, "") + "/" + accessToken;
  if (
    !["http:", "https:"].includes(baseEndpointURL.protocol) ||
    !baseEndpointURL.hostname ||
    baseEndpointURL.username ||
    baseEndpointURL.password ||
    baseEndpointURL.search ||
    baseEndpointURL.hash ||
    !["http:", "https:"].includes(endpointURL.protocol) ||
    endpointURL.protocol !== baseEndpointURL.protocol ||
    endpointURL.hostname !== baseEndpointURL.hostname ||
    endpointURL.port !== baseEndpointURL.port ||
    endpointURL.username ||
    endpointURL.password ||
    endpointURL.search ||
    endpointURL.hash ||
    endpointURL.pathname !== expectedPath
  ) {
    throw new Error("输入法包必须使用固定代理基础地址和部署生成的 capability 路径");
  }

  const transportSecurity = bundledInfo.NSAppTransportSecurity;
  const exceptionDomains = transportSecurity?.NSExceptionDomains ?? {};
  const exceptionDomainNames = Object.keys(exceptionDomains);
  const endpointException = exceptionDomains[endpointURL.hostname];
  if (
    endpointURL.protocol === "http:" &&
    (exceptionDomainNames.length !== 1 ||
      exceptionDomainNames[0] !== endpointURL.hostname ||
      endpointException?.NSExceptionAllowsInsecureHTTPLoads !== true)
  ) {
    throw new Error("HTTP 翻译端点只能为目标主机声明唯一的 ATS 例外");
  }
  if (transportSecurity?.NSAllowsArbitraryLoads === true) {
    throw new Error("输入法包不得关闭全局 ATS 限制");
  }

  const menuIconFileName = "TypingDongnanyaMenuIconV4.pdf";
  const appIconFileName = "TypingDongnanyaAppIcon.pdf";
  const appIconBundleName = "TypingDongnanyaAppIcon.icns";
  const modeInfo = bundledInfo.ComponentInputModeDict?.tsInputModeListKey?.[
    "com.caizhichao.typing-dongnanya.inputmethod.TypingDongnanya.Pinyin"
  ];
  if (
    bundledInfo.NSAccessibilityUsageDescription !== undefined ||
    bundledInfo.CFBundleIconFile !== appIconBundleName ||
    bundledInfo.tsInputMethodIconFileKey !== appIconFileName ||
    modeInfo?.tsInputModeMenuIconFileKey !== menuIconFileName ||
    modeInfo?.tsInputModePaletteIconFileKey !== menuIconFileName ||
    modeInfo?.tsInputModeAlternateMenuIconFileKey !== menuIconFileName ||
    !existsSync(join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", appIconFileName)) ||
    !existsSync(join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", appIconBundleName)) ||
    !existsSync(join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", menuIconFileName))
  ) {
    throw new Error("输入法包不得声明辅助功能用途；注册页与菜单模式图标必须保持独立");
  }
}

// 本地测试包使用稳定的显式 designated requirement，避免每次 ad-hoc 构建都生成新的 TCC 身份。
function verifyStableDevelopmentCodeRequirement() {
  const appPath = join(buildRoot, "TypingDongnanya.app");
  const result = spawnSync("/usr/bin/codesign", ["-dr", "-", appPath], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`无法读取本地测试包代码要求：${result.stderr}`);
  }
  const requirementOutput = `${result.stdout}${result.stderr}`;
  const expectedRequirement =
    'designated => identifier "com.caizhichao.typing-dongnanya.inputmethod.TypingDongnanya"';
  if (
    !requirementOutput.includes(expectedRequirement) ||
    requirementOutput.includes("designated => cdhash")
  ) {
    throw new Error("本地测试包必须保持稳定 identifier 要求，不能退回随构建变化的 CDHash 身份");
  }
}

// 通用模型不得把重复句当成冗余内容压缩，翻译提示必须明确保持句数、顺序和重复次数。
function verifyTranslationPromptContract() {
  const translationServiceSource = readFileSync(
    join(
      projectRoot,
      "Sources",
      "TypingDongnanyaInputMethod",
      "TranslationService.swift",
    ),
    "utf8",
  );
  if (
    translationServiceSource.includes("也不要重复任何句子") ||
    !translationServiceSource.includes("原文重复几次就翻译几次")
  ) {
    throw new Error("翻译提示必须逐句保留原文已有重复内容，不能把重复句压缩成一句");
  }
}

// 构建与测试统一读取部署脚本生成的本机 capability，不能把上游 AI 凭据写进包内。
function readProxyAccessToken() {
  if (!existsSync(proxyAccessTokenPath)) {
    throw new Error("缺少本机翻译代理 capability 配置");
  }
  const accessToken = readFileSync(proxyAccessTokenPath, "utf8").trim();
  if (!/^[a-f0-9]{48}$/i.test(accessToken)) {
    throw new Error("本机翻译代理 capability 格式无效");
  }
  return accessToken;
}

// 打包元数据需要同时覆盖端点、ATS 和输入源图标，避免只验证其中一项而漏掉运行时断链。
function readInfoPlist(infoPath: string): BundledInfo {
  return JSON.parse(runText("plutil", [
    "-convert",
    "json",
    "-o",
    "-",
    infoPath,
  ])) as BundledInfo;
}

type BundledInfo = {
  CFBundleIconFile?: string;
  TypingDongnanyaAPIBaseEndpoint?: string;
  TypingDongnanyaAPIEndpoint?: string;
  ComponentInputModeDict?: {
    tsInputModeListKey?: Record<string, {
      tsInputModeMenuIconFileKey?: string;
      tsInputModePaletteIconFileKey?: string;
      tsInputModeAlternateMenuIconFileKey?: string;
    }>;
  };
  tsInputMethodIconFileKey?: string;
  NSAccessibilityUsageDescription?: string;
  NSAppTransportSecurity?: {
    NSAllowsArbitraryLoads?: boolean;
    NSExceptionDomains?: Record<string, {
      NSExceptionAllowsInsecureHTTPLoads?: boolean;
    }>;
  };
};

function run(command: string, args: string[]) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, { cwd: projectRoot, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function runText(command: string, args: string[]) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0)
    throw new Error(`${command} failed: ${result.stderr}`);
  return result.stdout.trim();
}
