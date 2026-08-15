#!/usr/bin/env bun

import { existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const macOSRoot = join(projectRoot, "platforms", "macos");
const sourceRoot = join(macOSRoot, "Sources", "TypingChaoInputMethod");
const testRoot = join(macOSRoot, "Tests");
const macOSInfoPath = join(macOSRoot, "Info.plist");
const buildRoot = join(macOSRoot, "build");
const testBuildRoot = join(buildRoot, "tests");
const testBinaryRoot = join(testBuildRoot, "bin");
const testDataRoot = join(testBuildRoot, "data");
const swiftModuleCacheRoot = join(tmpdir(), "typingchao-swift-module-cache");
const vendorRoot = join(projectRoot, "vendor", "librime");
const defaultSDKPath = runText("xcrun", ["--show-sdk-path"]);
const compatibleSDKPath = join(dirname(defaultSDKPath), "MacOSX15.4.sdk");
// 当前 CLT 的 Swift 与 26.5 SDK 内部构建号不匹配，测试需与构建使用同一兼容 SDK。
const sdkPath = existsSync(compatibleSDKPath) ? compatibleSDKPath : defaultSDKPath;
const architecture = runText("arch", []);
const smokeDirectory = join(testDataRoot, "rime");
const outputPath = join(testBinaryRoot, "RimeSmoke");

run("bun", ["run", "scripts/macos/build.ts"]);
run("bunx", ["tsc", "--project", "platforms/macos/WebUI/tsconfig.json", "--noEmit"]);
verifyWebUIContract();
verifyCommercialRimeDataContract();
verifyStableDevelopmentCodeRequirement();
verifyBundledTranslationEndpoint();
verifyTranslationPromptContract();
verifyAIInputContract();
verifyAPIKeyPasteContract();
verifyInputControllerLifecycleContract();
verifyInputLatencyContract();
verifyClipboardOnlyTranslationContract();
verifyEscapeClearContract();
verifyDirectSymbolContract();
verifyKnownPassThroughContract();
verifyShiftKeyContract();
verifyNoExternalPermissionContract();
verifyCandidateSettingsContract();
mkdirSync(testBinaryRoot, { recursive: true });
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
  join(testRoot, "RimeSmoke.cc"),
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
  join(buildRoot, "TypingChao.app", "Contents", "Resources", "RimeData"),
  smokeDirectory,
]);

const editorSnapshotSmokeOutputPath = join(
  testBinaryRoot,
  "TranslationEditorSnapshotSmoke",
);
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot,
    "TranslationDraft.swift",
  ),
  join(testRoot, "TranslationEditorSnapshotSmoke.swift"),
  "-o",
  editorSnapshotSmokeOutputPath,
]);
run(editorSnapshotSmokeOutputPath, []);

const settingsSmokeOutputPath = join(testBinaryRoot, "InputMethodSettingsSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot,
    "InputMethodSettings.swift",
  ),
  join(testRoot, "InputMethodSettingsSmoke.swift"),
  "-o",
  settingsSmokeOutputPath,
]);
run(settingsSmokeOutputPath, []);

const localResponsesAPIKey = process.env.TYPINGCHAO_LOCAL_AI_KEY;
const translationServiceSmokeOutputPath = join(testBinaryRoot, "TranslationServiceSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot, "InputMethodSettings.swift"),
  join(sourceRoot, "TranslationService.swift"),
  join(testRoot, "TranslationServiceSmoke.swift"),
  "-o",
  translationServiceSmokeOutputPath,
]);
if (localResponsesAPIKey) {
  runWithEnvironment(
    translationServiceSmokeOutputPath,
    [],
    { TYPINGCHAO_LOCAL_AI_KEY: localResponsesAPIKey },
  );
} else {
  console.log("跳过本地 Codex Responses 网络冒烟：未设置 TYPINGCHAO_LOCAL_AI_KEY");
}

const rimeInputPolicySmokeOutputPath = join(testBinaryRoot, "RimeInputPolicySmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot, "RimeSnapshot.swift"),
  join(sourceRoot, "RimeInputPolicy.swift"),
  join(testRoot, "RimeInputPolicySmoke.swift"),
  "-o",
  rimeInputPolicySmokeOutputPath,
]);
run(rimeInputPolicySmokeOutputPath, []);

const inputModeStatusSmokeOutputPath = join(testBinaryRoot, "InputModeStatusOverlaySmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot, "RimeSnapshot.swift"),
  join(sourceRoot, "OverlayLayout.swift"),
  join(sourceRoot, "InputModeStatusOverlay.swift"),
  join(testRoot, "InputModeStatusOverlaySmoke.swift"),
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

const candidateBarLayoutSmokeOutputPath = join(testBinaryRoot, "CandidateBarLayoutSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot, "RimeSnapshot.swift"),
  join(sourceRoot, "OverlayLayout.swift"),
  join(sourceRoot, "TypingChaoWebView.swift"),
  join(sourceRoot, "CandidateOverlay.swift"),
  join(testRoot, "CandidateBarLayoutSmoke.swift"),
  "-framework",
  "AppKit",
  "-framework",
  "InputMethodKit",
  "-framework",
  "Carbon",
  "-framework",
  "WebKit",
  "-o",
  candidateBarLayoutSmokeOutputPath,
]);
run(candidateBarLayoutSmokeOutputPath, []);

const inputSourceRegistrationSmokeOutputPath = join(testBinaryRoot, "InputSourceRegistrationSmoke");
run("swiftc", [
  "-parse-as-library",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot,
    "InputSourceRegistration.swift",
  ),
  join(testRoot, "InputSourceRegistrationSmoke.swift"),
  "-framework",
  "Carbon",
  "-o",
  inputSourceRegistrationSmokeOutputPath,
]);
run(inputSourceRegistrationSmokeOutputPath, []);

const overlayLayoutSmokeOutputPath = join(testBinaryRoot, "OverlayLayoutSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot,
    "OverlayLayout.swift",
  ),
  join(testRoot, "OverlayLayoutSmoke.swift"),
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

const translationOverlaySmokeOutputPath = join(testBinaryRoot, "TranslationOverlaySmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot,
    "OverlayLayout.swift",
  ),
  join(sourceRoot,
    "TranslationOverlay.swift",
  ),
  join(testRoot, "TranslationOverlaySmoke.swift"),
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

const aiInputOverlaySmokeOutputPath = join(testBinaryRoot, "AIInputOverlaySmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot, "OverlayLayout.swift"),
  join(sourceRoot, "InputMethodSettings.swift"),
  join(sourceRoot, "TranslationService.swift"),
  join(sourceRoot, "TypingChaoWebView.swift"),
  join(sourceRoot, "AIInputOverlay.swift"),
  join(testRoot, "AIInputOverlaySmoke.swift"),
  "-framework",
  "AppKit",
  "-framework",
  "InputMethodKit",
  "-framework",
  "Carbon",
  "-framework",
  "WebKit",
  "-o",
  aiInputOverlaySmokeOutputPath,
]);
run(aiInputOverlaySmokeOutputPath, []);

const aiInputSelectionSmokeOutputPath = join(testBinaryRoot, "AIInputSelectionSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot, "AIInputSelection.swift"),
  join(testRoot, "AIInputSelectionSmoke.swift"),
  "-o",
  aiInputSelectionSmokeOutputPath,
]);
run(aiInputSelectionSmokeOutputPath, []);

const aiInputCommandSmokeOutputPath = join(testBinaryRoot, "AIInputCommandSmoke");
run("swiftc", [
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(sourceRoot, "AIInputCommand.swift"),
  join(testRoot, "AIInputCommandSmoke.swift"),
  "-o",
  aiInputCommandSmokeOutputPath,
]);
run(aiInputCommandSmokeOutputPath, []);

const menuIconSmokeOutputPath = join(testBinaryRoot, "MenuIconSmoke");
run("swiftc", [
  "-parse-as-library",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(testRoot, "MenuIconSmoke.swift"),
  "-framework",
  "AppKit",
  "-o",
  menuIconSmokeOutputPath,
]);
run(menuIconSmokeOutputPath, [
  join(buildRoot, "TypingChao.app", "Contents", "Resources", "TypingChaoMenuIconV4.pdf"),
]);

const appIconSmokeOutputPath = join(testBinaryRoot, "AppIconSmoke");
run("swiftc", [
  "-parse-as-library",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-sdk",
  sdkPath,
  join(testRoot, "AppIconSmoke.swift"),
  "-framework",
  "AppKit",
  "-o",
  appIconSmokeOutputPath,
]);
run(appIconSmokeOutputPath, [
  join(buildRoot, "TypingChao.app", "Contents", "Resources", "TypingChaoAppIcon.pdf"),
]);

const bridgeSmokeDirectory = join(testDataRoot, "rime-bridge");
const bridgeSmokeOutputPath = join(testBinaryRoot, "RimeBridgeSmoke");
mkdirSync(bridgeSmokeDirectory, { recursive: true });
run("clang++", [
  "-std=c++17",
  "-fobjc-arc",
  "-target",
  `${architecture}-apple-macosx13.0`,
  "-isysroot",
  sdkPath,
  "-I",
  sourceRoot,
  "-I",
  join(vendorRoot, "src"),
  "-I",
  join(vendorRoot, "include"),
  join(testRoot, "RimeBridgeSmoke.mm"),
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
  join(buildRoot, "TypingChao.app", "Contents", "Resources", "RimeData"),
  bridgeSmokeDirectory,
]);

// hidePalettes 只收口当前浮层；输入源真正停用时才释放活动会话。
function verifyInputControllerLifecycleContract() {
  const controllerSource = readFileSync(
    join(sourceRoot,
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
  if (!deactivateServerBody.includes("if isActiveAIInputController {")) {
    throw new Error("AI 面板内部会话不得停用原宿主输入法控制器");
  }
  if (deactivateServerBody.includes("sessionClient = nil")) {
    throw new Error("普通停用不得丢弃控制器初始化时绑定的会话客户端");
  }
}

// 输入按键主路径不得启动跨进程监听或读取宿主全文；仅允许读取用户当前明确选区。
function verifyInputLatencyContract() {
  const controllerSource = readFileSync(
    join(sourceRoot, "InputMethodController.swift"),
    "utf8",
  );
  const draftSource = readFileSync(
    join(sourceRoot, "TranslationDraft.swift"),
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
    !controllerSource.includes("override func handle(_ event: NSEvent!, client sender: Any!)") ||
    !controllerSource.includes("override func recognizedEvents(_ sender: Any!)") ||
    controllerSource.includes("inputText(_ string: String!, key keyCode:")
  ) {
    throw new Error("键盘必须只使用 InputMethodKit 原始事件入口，不能混用带键码输入入口");
  }
  if (
    activateServerBody.includes("Timer") ||
    activateServerBody.includes("Monitor") ||
    activateServerBody.includes("Observer")
  ) {
    throw new Error("输入源激活时只能绑定 IMK 会话，不得启动外部监听或轮询");
  }
}

// 剪贴板和键盘确认文本都必须先进入输入法内部 marked draft，再由用户一次性提交；AI 仅允许读取明确选区。
function verifyClipboardOnlyTranslationContract() {
  const controllerSource = readFileSync(
    join(sourceRoot, "InputMethodController.swift"),
    "utf8",
  );
  const draftSource = readFileSync(
    join(sourceRoot, "TranslationDraft.swift"),
    "utf8",
  );
  const mainSource = readFileSync(
    join(sourceRoot, "main.swift"),
    "utf8",
  );
  const clipboardBody = swiftMethodBody(
    controllerSource,
    "private func activateClipboardTranslationDraft(",
  );
  const handleBody = swiftMethodBody(
    controllerSource,
    "override func handle(_ event: NSEvent!, client sender: Any!)",
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
  const selectedSelectionBody = swiftMethodBody(
    controllerSource,
    "private func selectedAIInputSelectionContext(from client:",
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
    !handleBody.includes("TranslationPolicy.commandRequestsClipboardTranslation") ||
    !handleBody.includes("activateClipboardTranslationDraft")
  ) {
    throw new Error("唯一原始事件入口必须让 Command-V 进入剪贴板草稿入口");
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
  if (
    !handleBody.includes("handleTranslationDraftEditingKey") ||
    !handleBody.includes("TranslationPolicy.shouldPassThroughHostEditingKey")
  ) {
    throw new Error("唯一原始事件入口必须先处理内部草稿编辑，再决定是否交还宿主");
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
    !selectedSelectionBody.includes("client.selectedRange()") ||
    !selectedSelectionBody.includes("client.attributedSubstring(from: selectedRange)") ||
    controllerSource.includes("TranslationReplacementPolicy")
  ) {
    throw new Error("译文与原文必须从内部 marked draft 一次性提交，禁止继续追溯替换宿主正文");
  }
}

// Esc 清理当前 Rime 组合、请求和浮层，但必须保留输入法内部 marked draft。
function verifyEscapeClearContract() {
  const controllerSource = readFileSync(
    join(sourceRoot, "InputMethodController.swift"),
    "utf8",
  );
  const handleBody = swiftMethodBody(
    controllerSource,
    "override func handle(_ event: NSEvent!, client sender: Any!)",
  );
  const clearBody = swiftMethodBody(
    controllerSource,
    "private func clearInputCache(client: IMKTextInput)",
  );
  if (
    !handleBody.includes('keyName == "Escape"') ||
    !handleBody.includes("clearInputCache(client: client)")
  ) {
    throw new Error("唯一原始事件入口必须把 Esc 收口到统一缓存清理入口");
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

// 首符号和拼音后的多选标点必须在候选 UI 刷新前由唯一键盘入口直接确认。
function verifyDirectSymbolContract() {
  const controllerSource = readFileSync(
    join(sourceRoot, "InputMethodController.swift"),
    "utf8",
  );
  const handleBody = swiftMethodBody(
    controllerSource,
    "override func handle(_ event: NSEvent!, client sender: Any!)",
  );
  const processBody = swiftMethodBody(
    controllerSource,
    "private func processRimeKey(_ keyName: String, modifiers:",
  );
  if (!handleBody.includes("processRimeKey(")) {
    throw new Error("唯一原始事件入口必须接入直接符号处理链");
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
    join(sourceRoot, "InputMethodController.swift"),
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
  if (!controllerSource.includes("handleUnhandledKey(keyName, client: client)")) {
    throw new Error("唯一原始事件入口必须把客户端交给直通文本处理链");
  }
}

// Shift 单键是 Rime 的明确空操作，不能因键码未映射而提前提交翻译草稿；Shift+Space 仍由 Rime 处理全半角切换。
function verifyShiftKeyContract() {
  const controllerSource = readFileSync(
    join(sourceRoot, "InputMethodController.swift"),
    "utf8",
  );
  const keyNameBody = swiftMethodBody(
    controllerSource,
    "private func keyName(for keyCode: Int)",
  );
  const unhandledKeyBody = swiftMethodBody(
    controllerSource,
    "private func handleUnhandledKey(_ keyName: String, client:",
  );
  if (
    !keyNameBody.includes('case 56: return "Shift_L"') ||
    !keyNameBody.includes('case 60: return "Shift_R"') ||
    !unhandledKeyBody.includes('if keyName == "Shift_L" || keyName == "Shift_R"') ||
    !unhandledKeyBody.includes("return false")
  ) {
    throw new Error("macOS Shift 键必须映射为 Rime 的 Shift_L/Shift_R 空操作，不能误提交翻译草稿");
  }
  const defaultRimeSource = readFileSync(
    join(projectRoot, "shared", "RimeData", "default.yaml"),
    "utf8",
  );
  if (!defaultRimeSource.includes("accept: Shift+space, toggle: full_shape")) {
    throw new Error("Shift+Space 必须保留为 Rime 全半角切换绑定");
  }
  const eventBody = swiftMethodBody(
    controllerSource,
    "override func handle(_ event: NSEvent!, client sender: Any!)",
  );
  const shiftedCharacterBody = swiftMethodBody(
    controllerSource,
    "private func shiftedCharacterKeyName(for event: NSEvent)",
  );
  if (
    !eventBody.includes("shiftedCharacterKeyName(for: event)") ||
    !eventBody.includes("modifiers: []") ||
    !shiftedCharacterBody.includes("event.characters") ||
    !shiftedCharacterBody.includes("event.charactersIgnoringModifiers") ||
    !shiftedCharacterBody.includes("CharacterSet.letters")
  ) {
    throw new Error("Shift 加字母或标点必须使用实际字符重新交给 Rime，不能丢失大写输入");
  }
}

// 客户端不再声明辅助功能用途，设置页和命令行也不得继续请求系统隐私权限。
function verifyNoExternalPermissionContract() {
  const infoSource = readFileSync(macOSInfoPath, "utf8");
  const mainSource = readFileSync(
    join(sourceRoot, "main.swift"),
    "utf8",
  );
  const settingsWindowSource = readFileSync(
    join(sourceRoot, "InputMethodSettingsWindow.swift"),
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

// React/Tailwind 只能构建包内静态页面，并通过系统 WebKit 的单一白名单桥接访问原生能力。
function verifyWebUIContract() {
  const webUIRoot = join(macOSRoot, "WebUI");
  const bundledWebUIRoot = join(
    buildRoot,
    "TypingChao.app",
    "Contents",
    "Resources",
    "WebUI",
  );
  const bundledAssetRoot = join(bundledWebUIRoot, "assets");
  const packageMetadata = JSON.parse(
    readFileSync(join(projectRoot, "package.json"), "utf8"),
  ) as {
    scripts?: Record<string, string>;
    dependencies?: Record<string, string>;
    devDependencies?: Record<string, string>;
  };
  const buildSource = readFileSync(join(projectRoot, "scripts", "macos", "build.ts"), "utf8");
  const webViewSource = readFileSync(join(sourceRoot, "TypingChaoWebView.swift"), "utf8");
  const candidateWebSource = readFileSync(join(webUIRoot, "src", "CandidateApp.tsx"), "utf8");
  const settingsWebSource = readFileSync(join(webUIRoot, "src", "SettingsApp.tsx"), "utf8");
  const aiInputWebSource = readFileSync(join(webUIRoot, "src", "AIInputApp.tsx"), "utf8");
  const bundledIndexSource = readFileSync(join(bundledWebUIRoot, "index.html"), "utf8");
  const bundledAssetNameList = existsSync(bundledAssetRoot)
    ? readdirSync(bundledAssetRoot)
    : [];

  if (
    packageMetadata.scripts?.["build:web-ui"] !== "bun run scripts/macos/build-web-ui.ts" ||
    packageMetadata.dependencies?.react == null ||
    packageMetadata.dependencies?.["react-dom"] == null ||
    packageMetadata.devDependencies?.tailwindcss == null ||
    packageMetadata.devDependencies?.vite == null
  ) {
    throw new Error("React/Tailwind Web UI 依赖和统一构建入口没有完整锁定");
  }
  if (
    !existsSync(join(bundledWebUIRoot, "index.html")) ||
    !bundledAssetNameList.some((fileName) => fileName.endsWith(".js")) ||
    !bundledAssetNameList.some((fileName) => fileName.endsWith(".css"))
  ) {
    throw new Error("macOS 输入法包缺少 React/Tailwind 静态资源");
  }
  if (
    /<script\b[^>]*\bsrc=/.test(bundledIndexSource) ||
    /<link\b[^>]*\bhref="[^"]+\.css"/.test(bundledIndexSource) ||
    bundledIndexSource.indexOf('<div id="root"></div>') >= bundledIndexSource.lastIndexOf("<script>")
  ) {
    throw new Error("WKWebView 页面必须内联 Web UI 资源，并在 root 节点之后执行 React 脚本");
  }
  if (
    !existsSync(join(
      buildRoot,
      "TypingChao.app",
      "Contents",
      "Resources",
      "ThirdPartyLicenses",
      "WebUI.txt",
    )) ||
    !buildSource.includes('run("bun", ["run", "build:web-ui"]') ||
    !buildSource.includes('"-framework", "WebKit"') ||
    !buildSource.includes('join(sourceRoot, "TypingChaoWebView.swift")')
  ) {
    throw new Error("Web UI 构建、WebKit 链接或第三方许可证没有进入正式包");
  }
  for (const requiredBridgeToken of [
    "WKScriptMessageHandler",
    "loadFileURL",
    "requestURL.isFileURL",
    "markPageReady",
    "JSONSerialization.isValidJSONObject",
  ]) {
    if (!webViewSource.includes(requiredBridgeToken)) {
      throw new Error("Web UI 原生桥接缺少本地资源或消息边界：" + requiredBridgeToken);
    }
  }
  if (
    !candidateWebSource.includes("candidateAction") ||
    !settingsWebSource.includes("sendNativeMessage") ||
    !settingsWebSource.includes("翻译与 AI") ||
    !aiInputWebSource.includes("sendNativeMessage") ||
    !aiInputWebSource.includes("AI 输入")
  ) {
    throw new Error("候选条、设置页和 AI 问答页必须都由 React 页面承载");
  }
}

// 商业构建只能包含项目自有和已核实宽松许可证的 Rime 数据，禁止旧 LGPL 词典重新混入。
function verifyCommercialRimeDataContract() {
  const rimeDataDirectory = join(buildRoot, "TypingChao.app", "Contents", "Resources", "RimeData");
  const bundledFileNameList = readdirSync(rimeDataDirectory);
  const requiredFileNameList = [
    "default.yaml",
    "typing_pinyin.schema.yaml",
    "typing_pinyin.dict.yaml",
    "typing_double_pinyin_natural.schema.yaml",
    "typing_double_pinyin_flypy.schema.yaml",
    "typing_pinyin_t9.schema.yaml",
    "typing_wubi86.schema.yaml",
    "typing_wubi86.dict.yaml",
    "aosp-pinyinime.NOTICE",
    "aosp-pinyinime.SOURCE.json",
    "wubimb.LICENSE",
    "wubimb.SOURCE.json",
  ];
  for (const requiredFileName of requiredFileNameList) {
    if (!bundledFileNameList.includes(requiredFileName)) {
      throw new Error(`macOS 输入法包缺少商用 Rime 数据或来源声明：${requiredFileName}`);
    }
  }
  const forbiddenIdentifierList = ["luna_pinyin", "rime-prelude", "rime-luna-pinyin", "rime-essay", "essay.txt"];
  for (const fileName of bundledFileNameList) {
    const lowerFileName = fileName.toLowerCase();
    if (forbiddenIdentifierList.some((identifierText) => lowerFileName.includes(identifierText))) {
      throw new Error(`macOS 输入法包混入禁止交付的旧 Rime 数据：${fileName}`);
    }
    if (!fileName.endsWith(".yaml") && !fileName.endsWith(".json")) continue;
    const fileText = readFileSync(join(rimeDataDirectory, fileName), "utf8");
    if (forbiddenIdentifierList.some((identifierText) => fileText.includes(identifierText))) {
      throw new Error(`macOS 输入法包配置仍引用禁止交付的旧 Rime 数据：${fileName}`);
    }
  }
}

// 本地测试包使用稳定的显式 designated requirement，避免每次 ad-hoc 构建都生成新的 TCC 身份。
function verifyStableDevelopmentCodeRequirement() {
  const appPath = join(buildRoot, "TypingChao.app");
  const result = spawnSync("/usr/bin/codesign", ["-dr", "-", appPath], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`无法读取本地测试包代码要求：${result.stderr}`);
  }
  const requirementOutput = `${result.stdout}${result.stderr}`;
  const expectedRequirement =
    'designated => identifier "com.caizhichao.typingchao.inputmethod.TypingChao"';
  if (
    !requirementOutput.includes(expectedRequirement) ||
    requirementOutput.includes("designated => cdhash")
  ) {
    throw new Error("本地测试包必须保持稳定 identifier 要求，不能退回随构建变化的 CDHash 身份");
  }
}

// 翻译客户端必须使用已确认的 DeepSeek 官方 HTTPS 或本机 Codex Responses 端点。
function verifyBundledTranslationEndpoint() {
  const bundleInfoPath = join(buildRoot, "TypingChao.app", "Contents", "Info.plist");
  const settingsSource = readFileSync(
    join(sourceRoot, "InputMethodSettings.swift"),
    "utf8",
  );
  const translationServiceSource = readFileSync(
    join(sourceRoot, "TranslationService.swift"),
    "utf8",
  );
  const bundledInfo = readInfoPlist(bundleInfoPath);
  const menuIconFileName = "TypingChaoMenuIconV4.pdf";
  const appIconFileName = "TypingChaoAppIcon.pdf";
  const appIconBundleName = "TypingChaoAppIcon.icns";
  const modeInfo = bundledInfo.ComponentInputModeDict?.tsInputModeListKey?.[
    "com.caizhichao.typingchao.inputmethod.TypingChao.Pinyin"
  ];
  if (
    !settingsSource.includes('https://api.deepseek.com') ||
    !settingsSource.includes('http://127.0.0.1:8317/v1') ||
    !settingsSource.includes('return ["chat", "completions"]') ||
    !settingsSource.includes('return ["responses"]') ||
    !translationServiceSource.includes("inputMethodSettings.requestURL(for: serviceProvider)") ||
    translationServiceSource.includes("proxyAccessToken") ||
    bundledInfo.NSAccessibilityUsageDescription !== undefined ||
    bundledInfo.CFBundleIconFile !== appIconBundleName ||
    bundledInfo.tsInputMethodIconFileKey !== appIconFileName ||
    modeInfo?.tsInputModeMenuIconFileKey !== menuIconFileName ||
    modeInfo?.tsInputModePaletteIconFileKey !== menuIconFileName ||
    modeInfo?.tsInputModeAlternateMenuIconFileKey !== menuIconFileName ||
    !existsSync(join(buildRoot, "TypingChao.app", "Contents", "Resources", appIconFileName)) ||
    !existsSync(join(buildRoot, "TypingChao.app", "Contents", "Resources", appIconBundleName)) ||
    !existsSync(join(buildRoot, "TypingChao.app", "Contents", "Resources", menuIconFileName))
  ) {
    throw new Error("输入法包必须保留 DeepSeek/Codex 默认 Base URL 和固定协议路径，并保持注册页和菜单模式图标分离");
  }
}

// 通用模型不得把重复句当成冗余内容压缩，翻译提示必须明确保持句数、顺序和重复次数。
function verifyTranslationPromptContract() {
  const translationServiceSource = readFileSync(
    join(sourceRoot, "TranslationService.swift"),
    "utf8",
  );
  if (
    translationServiceSource.includes("也不要重复任何句子") ||
    !translationServiceSource.includes("原文重复几次就翻译几次")
  ) {
    throw new Error("翻译提示必须逐句保留原文已有重复内容，不能把重复句压缩成一句");
  }
}

// 候选条必须由 React 统一绘制，尾部只保留设置入口，AI 继续由等号候选和输入法菜单进入。
function verifyCandidateSettingsContract() {
  const candidateSource = readFileSync(
    join(sourceRoot, "CandidateOverlay.swift"),
    "utf8",
  );
  const candidateWebSource = readFileSync(
    join(macOSRoot, "WebUI", "src", "CandidateApp.tsx"),
    "utf8",
  );
  const mainSource = readFileSync(
    join(sourceRoot, "main.swift"),
    "utf8",
  );
  const settingsSource = readFileSync(
    join(sourceRoot, "InputMethodSettingsWindow.swift"),
    "utf8",
  );
  const settingsWebSource = readFileSync(
    join(macOSRoot, "WebUI", "src", "SettingsApp.tsx"),
    "utf8",
  );
  const webStyleSource = readFileSync(
    join(macOSRoot, "WebUI", "src", "styles.css"),
    "utf8",
  );
  const inputModeStatusSource = readFileSync(
    join(sourceRoot, "InputModeStatusOverlay.swift"),
    "utf8",
  );
  const controllerSource = readFileSync(
    join(sourceRoot, "InputMethodController.swift"),
    "utf8",
  );
  const aiCandidateMethodStart = controllerSource.indexOf(
    "private func showAIInputCommandCandidate"
  );
  const aiCandidateMethodEnd = controllerSource.indexOf(
    "private func discardPendingAIInputCommand",
    aiCandidateMethodStart
  );
  const aiCandidateMethod = controllerSource.slice(
    aiCandidateMethodStart,
    aiCandidateMethodEnd
  );
  if (
    !aiCandidateMethod.includes("fallbackAnchor ??") ||
    !aiCandidateMethod.includes("allowsCachedAnchor: false")
  ) {
    throw new Error("AI 候选条必须优先使用本次等号输入前捕获的锚点");
  }

  if (!mainSource.includes("TypingChaoApplicationDelegate.shared")) {
    throw new Error("输入法进程必须由统一 AppKit delegate 管理设置窗口生命周期");
  }
  if (
    !settingsSource.includes("schemaHandler") ||
    !settingsWebSource.includes("拼音方案") ||
    !settingsWebSource.includes("字符宽度") ||
    !settingsWebSource.includes("标点样式") ||
    !settingsWebSource.includes("Shift") ||
    !settingsWebSource.includes("Space")
  ) {
    throw new Error("设置页必须把半/全角、标点样式和快捷切换分开说明");
  }
  if (
    !settingsWebSource.includes("通用 AI 输入法") ||
    !settingsSource.includes("CFBundleShortVersionString") ||
    !settingsSource.includes("CFBundleVersion")
  ) {
    throw new Error("设置侧栏必须显示产品能力和当前安装包版本");
  }
  if (
    !webStyleSource.includes("@media (prefers-color-scheme: dark)") ||
    !webStyleSource.includes("--window-bg") ||
    !webStyleSource.includes("--surface") ||
    !webStyleSource.includes("--text-primary")
  ) {
    throw new Error("React 设置页必须使用统一 token 适配系统明暗外观");
  }
  if (
    !candidateSource.includes("TypingChaoWebView(webViewName: .candidate") ||
    !candidateSource.includes('messageType: "candidateState"') ||
    !candidateSource.includes('messageType == "candidateAction"') ||
    candidateSource.includes("setAIInputHandler") ||
    candidateSource.includes("CandidateAIInputButton") ||
    !candidateWebSource.includes("candidate-settings-button") ||
    !candidateWebSource.includes("changePage") ||
    !candidateWebSource.includes("selectCandidate")
  ) {
    throw new Error("候选条必须由 React 负责候选、分页和设置入口，并移除尾部 AI 图标");
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
}

// AI 入口由候选条、菜单和输入法内部等号候选触发，不能依赖宿主可能截获的全局组合键。
function verifyAIInputContract() {
  const controllerSource = readFileSync(
    join(sourceRoot, "InputMethodController.swift"),
    "utf8",
  );
  const candidateSource = readFileSync(
    join(sourceRoot, "CandidateOverlay.swift"),
    "utf8",
  );
  const commandSource = readFileSync(
    join(sourceRoot, "AIInputCommand.swift"),
    "utf8",
  );
  const overlaySource = readFileSync(
    join(sourceRoot, "AIInputOverlay.swift"),
    "utf8",
  );
  const settingsSource = readFileSync(
    join(sourceRoot, "InputMethodSettings.swift"),
    "utf8",
  );
  const settingsWindowSource = readFileSync(
    join(sourceRoot, "InputMethodSettingsWindow.swift"),
    "utf8",
  );
  const menuSource = readFileSync(
    join(sourceRoot, "InputMethodMenu.swift"),
    "utf8",
  );
  const translationServiceSource = readFileSync(
    join(sourceRoot, "TranslationService.swift"),
    "utf8",
  );
  const aiInputWebSource = readFileSync(
    join(macOSRoot, "WebUI", "src", "AIInputApp.tsx"),
    "utf8",
  );
  const settingsWebSource = readFileSync(
    join(macOSRoot, "WebUI", "src", "SettingsApp.tsx"),
    "utf8",
  );
  const showAIInputBody = swiftMethodBody(controllerSource, "private func showAIInput(");
  const presentAIInputBody = swiftMethodBody(controllerSource, "private func presentAIInput(");
  const requestAIInputBody = swiftMethodBody(controllerSource, "private func requestAIInput(");
  const markedResultPreviewBody = swiftMethodBody(controllerSource, "private func updateAIInputMarkedResultPreview(");
  const commitAIInputResultBody = swiftMethodBody(controllerSource, "private func commitAIInputResult(");
  const closeAIInputBody = swiftMethodBody(controllerSource, "private func closeAIInput()");
  for (const requiredContract of [
    "AIInputSelectionContext",
    "prefilledPromptText:",
    "activeAIInputSelection",
    "AIInputCommandState",
    "aiInputCommandState.activateTrigger",
    "override func inputText",
    "inputKeyName == AIInputCommandState.triggerText",
    "if inputKeyName == \"Return\"",
    "suppressNextHostReturnAfterAICommand",
    "suppressNextInputTextEqualsCallback",
    "suppressNextKeyDownEqualsCallback",
    "keyName == AIInputCommandState.triggerText",
    "return false",
    "showAIInputCommandCandidate",
    "processStandaloneEquals",
    "markPendingAIInputEquals",
    "if aiInputOverlay.isVisible",
    "discardPendingAIInputCommand",
    "showAIInputTrigger",
    "isTriggerReady",
    'keyName == "1"',
    'keyName == "Return"',
    "showAIInput()",
    "private func requestAIInput(\n        promptText:",
    "commitAIInputResult(resultText:",
    "presentAIInput(",
    "selectionContext: resolvedSelectionContext",
    "aiInputOverlay.show(",
    "prefilledPromptText:",
    "conversationMessageList: [AIConversationMessage]",
    "activeAIInputController",
    "aiInputOverlay.isVisible",
    "isPresentingAIInput",
    "guard !isActiveAIInputController else",
    "handleAIInputKey(",
    "updateAIInputOverlay(client: client, snapshot: snapshot)",
    "aiInputOverlay.acceptsPromptInput",
    "aiInputOverlay.submitPrompt()",
    "aiInputOverlay.canCommitResult",
    "aiInputOverlay.commitResult()",
  ]) {
    if (!controllerSource.includes(requiredContract)) {
      throw new Error("macOS AI 输入缺少内部入口或会话收口契约：" + requiredContract);
    }
  }
  if (
    !candidateSource.includes("showAIInputTrigger") ||
    !candidateSource.includes('labelText: "1"') ||
    !candidateSource.includes("isAIInputTriggerVisible") ||
    candidateSource.includes("CandidateAIInputButton") ||
    !menuSource.includes('title: "AI 输入…"') ||
    !menuSource.includes('keyEquivalent: ""')
  ) {
    throw new Error("AI 输入必须保留等号候选和输入法菜单入口，候选尾部不得重复显示 AI 图标");
  }
  if (
    !commandSource.includes('static let triggerText = "="') ||
    !commandSource.includes("activateTrigger") ||
    !commandSource.includes("isTriggerReady") ||
    !commandSource.includes("mutating func reset")
  ) {
    throw new Error("AI 快速命令只能由单个普通等号触发");
  }
  const resultPreviewIndex = requestAIInputBody.indexOf("updateAIInputMarkedResultPreview(resultText)");
  const resultInsertIndex = commitAIInputResultBody.indexOf("lastClient.insertText(");
  const resultResetIndex = commitAIInputResultBody.indexOf("aiInputCommandState.reset()", resultInsertIndex);
  const resultCloseIndex = commitAIInputResultBody.indexOf("closeAIInput()", resultResetIndex);
  if (
    showAIInputBody.includes("discardPendingAIInputCommand") ||
    !presentAIInputBody.includes("if !aiInputCommandState.isPending") ||
    resultPreviewIndex < 0 ||
    !markedResultPreviewBody.includes("aiInputCommandState.isPending") ||
    !markedResultPreviewBody.includes("activeAIInputSelection == nil") ||
    !markedResultPreviewBody.includes("lastClient.setMarkedText(") ||
    !markedResultPreviewBody.includes("replacementRange: NSRange(location: NSNotFound, length: 0)") ||
    resultInsertIndex < 0 ||
    resultResetIndex <= resultInsertIndex ||
    resultCloseIndex <= resultResetIndex ||
    !closeAIInputBody.includes("discardPendingAIInputCommand(client: lastClient)")
  ) {
    throw new Error("AI 快速入口必须保留 marked 区域并同步结果预览，正式确认时才原位上屏");
  }
  for (const removedCommandToken of [
    "commitMarkedText",
    "flushPendingText",
    "deleteBackward",
    "updateMarkedText",
  ]) {
    if (commandSource.includes(removedCommandToken)) {
      throw new Error("AI 快速命令仍保留多字符前缀逻辑：" + removedCommandToken);
    }
  }
  for (const removedToken of [
    "AIInputGesturePolicy",
    "AIInputShortcut",
    "optionSpace",
    "TypingChaoAITrace",
    "typingchao-ai-trace.log",
  ]) {
    if (
      controllerSource.includes(removedToken) ||
      overlaySource.includes(removedToken) ||
      settingsSource.includes(removedToken) ||
      settingsWindowSource.includes(removedToken)
    ) {
      throw new Error("AI 输入不应保留失效快捷键或临时诊断：" + removedToken);
    }
  }
  if (
    !overlaySource.includes("panel.center()") ||
    !overlaySource.includes("panel.makeKeyAndOrderFront(nil)") ||
    !overlaySource.includes("override var canBecomeKey") ||
    !overlaySource.includes("final class AIInputKeyCaptureView") ||
    !overlaySource.includes("acceptsFirstResponder") ||
    !overlaySource.includes("TypingChaoWebView(webViewName: .aiInput, acceptsKeyboardFocus: false)") ||
    !overlaySource.includes("func focusPromptInput()") ||
    !overlaySource.includes("func setKeyHandler(_ handler: @escaping (NSEvent) -> Bool)") ||
    !overlaySource.includes("pendingPromptText") ||
    !overlaySource.includes("conversationMessageList") ||
    !overlaySource.includes("panelSize = NSSize(width: 520, height: 500)") ||
    !overlaySource.includes("func commitResult()") ||
    !overlaySource.includes("setServiceProviderHandler") ||
    !overlaySource.includes('messageType: "aiInputState"') ||
    !aiInputWebSource.includes("连续对话 · 当前会话保留上下文") ||
    !aiInputWebSource.includes("conversationMessageList.map") ||
    !aiInputWebSource.includes("promptComposition") ||
    !aiInputWebSource.includes("provider-menu") ||
    !aiInputWebSource.includes("上屏并退出") ||
    !translationServiceSource.includes("requestAIConversationResponse") ||
    !translationServiceSource.includes("ResponsesConversationRequest") ||
    !translationServiceSource.includes("inputMessageList")
  ) {
    throw new Error("AI 输入必须保留当前会话上下文，并由 React 页面显示、原生 IMK 入口接管键盘");
  }
  for (const removedHintText of [
    "Enter 重试 · Esc 关闭",
    "Enter 发送 · ⌘Enter 上屏 · Esc 关闭",
    'NSButton(title: "关闭"',
    'NSButton(title: "发送"',
    'NSButton(title: "上屏结果"',
    "commitButton",
    "commitAIInput",
    "configureActionButton",
  ]) {
    if (overlaySource.includes(removedHintText)) {
      throw new Error("AI 输入面板不应显示快捷键提示文案：" + removedHintText);
    }
  }
  for (const requiredServiceToken of [
    "AIServiceProvider",
    "codexResponses",
    "TypingChaoAIServiceProvider",
    "TypingChaoDeepSeekBaseURL",
    "TypingChaoCodexBaseURL",
    "TypingChaoDeepSeekModelName",
    "TypingChaoCodexModelName",
    "http://127.0.0.1:8317/v1",
    "ResponsesRequest",
    'ResponsesTool(typeName: "web_search")',
    'case toolList = "tools"',
    "outputItemList",
  ]) {
    if (
      !settingsSource.includes(requiredServiceToken) &&
      !translationServiceSource.includes(requiredServiceToken)
    ) {
      throw new Error("AI 服务切换缺少 Responses 契约：" + requiredServiceToken);
    }
  }
  for (const requiredSearchPrompt of [
    "当前请求已提供 web_search 工具",
    "必须先实际调用 web_search",
    "即使模型记忆中已有答案也不能跳过搜索",
    "不得声称没有搜索工具",
  ]) {
    if (!translationServiceSource.includes(requiredSearchPrompt)) {
      throw new Error("Codex AI 默认提示词必须强制实时信息任务实际联网：" + requiredSearchPrompt);
    }
  }
  if (
    !translationServiceSource.includes("Key 无法使用") ||
    !translationServiceSource.includes("Key 错误或无权限") ||
    !settingsWindowSource.includes('"apiKeyConfigured"') ||
    !settingsWindowSource.includes('"defaultBaseURL"') ||
    !settingsWindowSource.includes("fetchAIModelList") ||
    !settingsWindowSource.includes('messageType: "settingsModelList"') ||
    !settingsWebSource.includes('type="password"') ||
    !settingsWebSource.includes("modelNameList") ||
    !translationServiceSource.includes("fetchModelNameList") ||
    !settingsSource.includes("modelListURL(for serviceProvider: AIServiceProvider)")
  ) {
    throw new Error("AI 服务切换必须同步 Key/Base URL/模型状态，并支持拉取模型列表");
  }
  if (
    !controllerSource.includes("private func aiInputLiteralText(for event: NSEvent, keyName: String)") ||
    !controllerSource.includes("aiInputLiteralText(for: event, keyName: keyName)") ||
    !controllerSource.includes("aiInputOverlay.appendPromptText(literalText)") ||
    !controllerSource.includes("CharacterSet.decimalDigits")
  ) {
    throw new Error("AI 输入面板必须允许数字、符号和空格作为普通文本输入");
  }
  for (const forbiddenToken of [
    "addGlobalMonitorForEvents",
    "CGEvent.tapCreate",
    "CGEventSource.keyState",
    "AXUIElement",
  ]) {
    if (controllerSource.includes(forbiddenToken) || overlaySource.includes(forbiddenToken)) {
      throw new Error("AI 输入不得引入全局键盘或辅助功能监听：" + forbiddenToken);
    }
  }
}

// API Key 只能由用户在设置 WebView 中输入或主动粘贴，初始化状态不得把已保存明文送入页面。
function verifyAPIKeyPasteContract() {
  const settingsWindowSource = readFileSync(
    join(sourceRoot, "InputMethodSettingsWindow.swift"),
    "utf8",
  );
  const settingsWebSource = readFileSync(
    join(macOSRoot, "WebUI", "src", "SettingsApp.tsx"),
    "utf8",
  );
  const settingsStateBody = swiftMethodBody(settingsWindowSource, "private func sendSettingsState()");
  for (const requiredToken of [
    'TypingChaoWebView(webViewName: .settings, acceptsKeyboardFocus: true)',
    'case "pasteAPIKey"',
    'NSPasteboard.general.string(forType: .string)',
    'messageType: "settingsPastedAPIKey"',
    '"apiKeyConfigured"',
  ]) {
    if (!settingsWindowSource.includes(requiredToken)) {
      throw new Error("设置页 API Key 必须保留安全输入和用户主动粘贴入口：" + requiredToken);
    }
  }
  for (const requiredToken of [
    'type="password"',
    'sendSetting("pasteAPIKey", "")',
    'settingsPastedAPIKey',
  ]) {
    if (!settingsWebSource.includes(requiredToken)) {
      throw new Error("React 设置页必须保留密码输入和显式粘贴入口：" + requiredToken);
    }
  }
  if (settingsStateBody.includes("currentAPIKey")) {
    throw new Error("设置页初始化状态不得向 React 页面发送已保存 API Key 明文");
  }
}

// 打包元数据和输入源图标一起校验，避免已下线的代理配置重新进入交付包。
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
  CFBundleDisplayName?: string;
  CFBundleIconFile?: string;
  ComponentInputModeDict?: {
    tsInputModeListKey?: Record<string, {
      tsInputModeMenuIconFileKey?: string;
      tsInputModePaletteIconFileKey?: string;
      tsInputModeAlternateMenuIconFileKey?: string;
    }>;
  };
  tsInputMethodIconFileKey?: string;
  NSAccessibilityUsageDescription?: string;
};

function runWithEnvironment(
  command: string,
  args: string[],
  environmentOverrides: Record<string, string>,
) {
  let resolvedArguments = args;
  if (command === "swiftc") {
    resolvedArguments = ["-module-cache-path", swiftModuleCacheRoot, ...args];
  }
  console.log(`$ ${command} ${resolvedArguments.join(" ")} [环境变量已注入]`);
  const result = spawnSync(command, resolvedArguments, {
    cwd: projectRoot,
    stdio: "inherit",
    env: { ...process.env, ...environmentOverrides },
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function run(command: string, args: string[]) {
  let resolvedArguments = args;
  if (command === "swiftc") {
    resolvedArguments = ["-module-cache-path", swiftModuleCacheRoot, ...args];
  }
  console.log(`$ ${command} ${resolvedArguments.join(" ")}`);
  const result = spawnSync(command, resolvedArguments, { cwd: projectRoot, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function runText(command: string, args: string[]) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0)
    throw new Error(`${command} failed: ${result.stderr}`);
  return result.stdout.trim();
}
