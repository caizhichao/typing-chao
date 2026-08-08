#!/usr/bin/env bun

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const androidRoot = join(projectRoot, "platforms", "android");
const androidSdkRoot = "/opt/homebrew/share/android-commandlinetools";
const javaHome = "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home";
const buildScriptPath = join(projectRoot, "scripts", "android", "build.ts");
const gradleWrapperPath = join(androidRoot, "gradlew");
const debugApkPath = join(androidRoot, "app", "build", "outputs", "apk", "debug", "app-debug.apk");
const aaptPath = join(androidSdkRoot, "build-tools", "36.0.0", "aapt2");
const apkSignerPath = join(androidSdkRoot, "build-tools", "36.0.0", "apksigner");
const inputMethodServicePath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "ime", "TypingChaoInputMethodService.kt");
const keyboardViewPath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "ui", "TypingKeyboardView.kt");
const settingsActivityPath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "settings", "SettingsActivity.kt");
const settingsStorePath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "settings", "SettingsStore.kt");
const translationClientPath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "translation", "TranslationClient.kt");
const inputSchemaPath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "settings", "InputSchema.kt");
const keyboardUiStatePath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "ui", "KeyboardUiState.kt");
const handwritingCanvasPath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "ui", "HandwritingCanvasView.kt");
const handwritingRecognizerPath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "handwriting", "HandwritingRecognizer.kt");
const handwritingDecoderPath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "handwriting", "HandwritingCtcDecoder.kt");
const keyboardInputModePath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "settings", "KeyboardInputMode.kt");
const rimeNativePath = join(androidRoot, "app", "src", "main", "kotlin", "com", "caizhichao", "typingchao", "rime", "RimeNative.kt");
const rimeJniPath = join(androidRoot, "app", "src", "main", "cpp", "rime_jni.cpp");

run(process.execPath, [buildScriptPath], projectRoot);
run(gradleWrapperPath, ["--no-daemon", "lintDebug"], androidRoot);
for (const requiredPath of [debugApkPath, aaptPath, apkSignerPath]) {
  if (!existsSync(requiredPath)) {
    throw new Error(`Android 验证文件缺失：${requiredPath}`);
  }
}

const badgingText = runText(aaptPath, ["dump", "badging", debugApkPath]);
assertIncludes(badgingText, "package: name='com.caizhichao.typingchao'");
assertIncludes(badgingText, "versionCode='9' versionName='0.3.3'");
assertIncludes(badgingText, "application-label:'Typing Chao'");
assertIncludes(badgingText, "minSdkVersion:'26'");
assertIncludes(badgingText, "targetSdkVersion:'36'");
assertIncludes(badgingText, "provides-component:'ime'");
assertIncludes(badgingText, "launchable-activity: name='com.caizhichao.typingchao.settings.SettingsActivity'");

const entryList = runText("unzip", ["-Z1", debugApkPath]).split("\n").filter(Boolean);
const nativeEntryList = entryList.filter((entryValue) => entryValue.startsWith("lib/"));
const expectedNativeEntryList = [
  "lib/arm64-v8a/libc++_shared.so",
  "lib/arm64-v8a/libonnxruntime.so",
  "lib/arm64-v8a/libonnxruntime4j_jni.so",
  "lib/arm64-v8a/libtyping_chao_rime.so",
];
if (nativeEntryList.join("\n") !== expectedNativeEntryList.join("\n")) {
  throw new Error(`APK 原生库或 ABI 不符合 arm64-v8a 单架构约束：\n${nativeEntryList.join("\n")}`);
}
for (const requiredEntry of [
  "assets/rime/default.yaml",
  "assets/rime/typing_pinyin.schema.yaml",
  "assets/rime/typing_pinyin.dict.yaml",
  "assets/rime/typing_double_pinyin_natural.schema.yaml",
  "assets/rime/typing_double_pinyin_flypy.schema.yaml",
  "assets/rime/typing_pinyin_t9.schema.yaml",
  "assets/rime/typing_wubi86.schema.yaml",
  "assets/rime/typing_wubi86.dict.yaml",
  "assets/rime/rime-data-version.txt",
  "assets/rime/opencc/s2t.json",
  "assets/handwriting/inference.onnx",
  "assets/handwriting/characters.txt",
  "assets/licenses/aosp-pinyinime.NOTICE",
  "assets/licenses/aosp-pinyinime.SOURCE.json",
  "assets/licenses/wubimb.LICENSE",
  "assets/licenses/wubimb.SOURCE.json",
  "assets/licenses/paddleocr.LICENSE",
  "assets/licenses/paddleocr-handwriting.SOURCE.json",
  "assets/licenses/onnxruntime.LICENSE",
  "assets/licenses/librime.LICENSE",
  "assets/licenses/opencc.LICENSE",
  "assets/licenses/boost.LICENSE",
]) {
  if (!entryList.includes(requiredEntry)) {
    throw new Error(`APK 缺少运行资源或许可证：${requiredEntry}`);
  }
}

const handwritingModelValue = runBuffer("unzip", ["-p", debugApkPath, "assets/handwriting/inference.onnx"]);
const handwritingModelHash = createHash("sha256").update(handwritingModelValue).digest("hex");
if (handwritingModelHash !== "9ef676d6ed3c88256a2d92c640c44f25b0c40947e111b14b8be8f594091563e6") {
  throw new Error(`APK 手写模型哈希不匹配：${handwritingModelHash}`);
}
const handwritingCharacterValue = runBuffer("unzip", ["-p", debugApkPath, "assets/handwriting/characters.txt"]);
const handwritingCharacterHash = createHash("sha256").update(handwritingCharacterValue).digest("hex");
if (handwritingCharacterHash !== "a295ab9d9a1e00aa86873a06230989f90c019291d1e7eaf026693ca136437abe") {
  throw new Error(`APK 手写字符表哈希不匹配：${handwritingCharacterHash}`);
}
for (const forbiddenEntryToken of [
  "luna_pinyin",
  "rime-prelude",
  "rime-luna-pinyin",
  "rime-essay",
  "essay.txt",
]) {
  const forbiddenEntry = entryList.find((entryValue) => entryValue.toLowerCase().includes(forbiddenEntryToken));
  if (forbiddenEntry) {
    throw new Error(`APK 混入禁止交付的旧 Rime 数据：${forbiddenEntry}`);
  }
}
const inspectableEntryList = entryList.filter((entryValue) =>
  entryValue.startsWith("assets/rime/") || entryValue.startsWith("assets/licenses/"),
).filter((entryValue) =>
  entryValue.endsWith(".yaml") ||
  entryValue.endsWith(".json") ||
  entryValue.endsWith(".txt") ||
  entryValue.endsWith(".NOTICE") ||
  entryValue.endsWith(".LICENSE"),
);
for (const inspectableEntry of inspectableEntryList) {
  const entryText = runText("unzip", ["-p", debugApkPath, inspectableEntry]).toLowerCase();
  for (const forbiddenEntryToken of [
    "luna_pinyin",
    "rime-prelude",
    "rime-luna-pinyin",
    "rime-essay",
    "essay.txt",
  ]) {
    if (entryText.includes(forbiddenEntryToken)) {
      throw new Error(`APK 文本资源仍引用禁止交付的旧 Rime 数据：${inspectableEntry}`);
    }
  }
}

const inputMethodServiceText = readFileSync(inputMethodServicePath, "utf8");
const translationCommitBody = sourceFunctionBody(inputMethodServiceText, "override fun onUseTranslation()");
if (translationCommitBody.includes("finishComposingText")) {
  throw new Error("使用译文前不能 finishComposingText，否则原文会先上屏并与译文重复");
}
assertIncludes(translationCommitBody, "inputConnection.commitText(translatedText, 1)");
const originalCommitBody = sourceFunctionBody(inputMethodServiceText, "private fun commitOriginalDraft()");
assertIncludes(originalCommitBody, "inputConnection?.commitText(draftState.textValue, 1)");
if (/finishComposingText\(\)[\s\S]*commitText\(draftState\.textValue/.test(originalCommitBody)) {
  throw new Error("原文上屏前不能结束 composing text，否则原文会重复提交");
}
const pasteButtonBody = sourceFunctionBody(inputMethodServiceText, "override fun onPasteClipboard()");
assertIncludes(pasteButtonBody, "appendClipboardText(clipboardText)");
const hostPasteBody = sourceFunctionBody(inputMethodServiceText, "private fun captureHostPastedText(");
for (const hostPasteContract of [
  "newSelStart != replacedSelectionStart + clipboardText.length",
  "getTextBeforeCursor(clipboardText.length, 0)",
  "textBeforeCursor != clipboardText",
  "setComposingRegion(replacedSelectionStart, newSelStart)",
  "refreshTranslationForCurrentDraft()",
]) {
  assertIncludes(hostPasteBody, hostPasteContract);
}
const clearDraftBody = sourceFunctionBody(inputMethodServiceText, "override fun onClearDraft()");
assertIncludes(clearDraftBody, 'currentInputConnection?.commitText("", 1)');
const updateComposingBody = sourceFunctionBody(inputMethodServiceText, "private fun updateHostComposingText()");
assertIncludes(updateComposingBody, 'inputConnection.setComposingText("", 1)');
assertIncludes(updateComposingBody, "inputConnection.finishComposingText()");
const keyboardViewText = readFileSync(keyboardViewPath, "utf8");
const keyboardInitBody = sourceFunctionBody(keyboardViewText, "init");
if (keyboardInitBody.includes("addView(buildTranslationCard())")) {
  throw new Error("翻译卡不能作为独立高度插入键盘根布局");
}
const candidateBarBody = sourceFunctionBody(keyboardViewText, "private fun buildCandidateBar()");
for (const fixedTranslationBarContract of [
  "candidateBar.addView(buildTranslationCard(), LayoutParams(0, dp(48), 1f))",
  "candidateBar.addView(candidateScrollView, LayoutParams(0, dp(48), 1f))",
  "LayoutParams(LayoutParams.MATCH_PARENT, dp(48))",
]) {
  assertIncludes(candidateBarBody, fixedTranslationBarContract);
}
const keyboardRenderBody = sourceFunctionBody(keyboardViewText, "fun render(stateValue: KeyboardUiState)");
for (const stableHeightContract of [
  "candidateScrollView.visibility",
  "translationCard.visibility",
  "译文将在这里显示",
]) {
  assertIncludes(keyboardRenderBody, stableHeightContract);
}
const translationCardBody = sourceFunctionBody(keyboardViewText, "private fun buildTranslationCard()");
assertIncludes(translationCardBody, "maxLines = 2");
assertIncludes(translationCardBody, "ellipsize = TextUtils.TruncateAt.END");
for (const repeatedDeleteContract of [
  "MotionEvent.ACTION_DOWN",
  "repeatedAction()",
  "postDelayed(repeatedActionRunnable, backspaceRepeatInitialDelayMilliseconds)",
  "MotionEvent.ACTION_MOVE",
  "backspaceClearSwipeDistanceDp",
  'text = "清空"',
  "clearAction()",
  "MotionEvent.ACTION_UP",
  "MotionEvent.ACTION_CANCEL",
  "removeCallbacks(repeatedActionRunnable)",
  "customView = backspaceButton",
  'KeySpec("粘贴"',
]) {
  assertIncludes(keyboardViewText, repeatedDeleteContract);
}
const nineKeyKeyboardBody = sourceFunctionBody(keyboardViewText, "private fun buildNineKeyKeyboardRows()");
for (const nineKeyLayoutContract of [
  'KeySpec("，", 1f)',
  'KeySpec("。", 1f)',
  'KeySpec("？", 1f)',
  'KeySpec("！", 1f)',
  'stackedKeyView("1", "符号")',
  'stackedKeyView("2", "ABC")',
  'stackedKeyView("9", "WXYZ")',
  'KeySpec("重输", 1f) { actionListener.onClearComposition() }',
  'stackedKeyView("0", "空格")',
  'LayoutParams(LayoutParams.MATCH_PARENT, dp(54))',
]) {
  assertIncludes(nineKeyKeyboardBody, nineKeyLayoutContract);
}
if (nineKeyKeyboardBody.includes("\\n")) {
  throw new Error("九键数字与功能说明不能继续使用原始换行标签");
}
const clearCompositionBody = sourceFunctionBody(inputMethodServiceText, "override fun onClearComposition()");
assertIncludes(clearCompositionBody, "clearCompositionAndTranslation()");
if (clearCompositionBody.includes("onClearDraft")) {
  throw new Error("九键重输不能清除整段翻译草稿");
}

const settingsActivityText = readFileSync(settingsActivityPath, "utf8");
const settingsStoreText = readFileSync(settingsStorePath, "utf8");
const translationClientText = readFileSync(translationClientPath, "utf8");
const inputSchemaText = readFileSync(inputSchemaPath, "utf8");
const keyboardUiStateText = readFileSync(keyboardUiStatePath, "utf8");
const rimeNativeText = readFileSync(rimeNativePath, "utf8");
const rimeJniText = readFileSync(rimeJniPath, "utf8");
for (const schemaContract of [
  "InputSchema.entries.map { it.displayName }",
  "settingsStore.inputSchema = selectedSchema",
]) {
  assertIncludes(settingsActivityText, schemaContract);
}
assertIncludes(settingsStoreText, 'const val inputSchemaIdentifierKey = "input_schema_identifier"');
assertIncludes(settingsStoreText, 'const val keyboardInputModeKey = "keyboard_input_mode"');
assertIncludes(settingsStoreText, 'const val deepSeekAPIKeyKey = "deepseek_api_key"');
assertIncludes(settingsActivityText, "deepSeekAPIKeyInput");
assertIncludes(translationClientText, 'private const val deepSeekEndpoint = "https://api.deepseek.com/chat/completions"');
assertIncludes(translationClientText, 'setRequestProperty("Authorization", "Bearer $configuredAPIKey")');
assertIncludes(inputSchemaText, 'NINE_KEY_PINYIN("typing_pinyin_t9", "中文九键")');
assertIncludes(inputSchemaText, 'WUBI_86("typing_wubi86", "五笔 86")');
assertIncludes(keyboardUiStateText, "val isNineKeyLayout: Boolean");
assertIncludes(keyboardUiStateText, "val isWubiLayout: Boolean");
assertIncludes(keyboardUiStateText, "val isHandwritingMode: Boolean");
assertIncludes(keyboardViewText, "private fun buildNineKeyKeyboardRows()");
assertIncludes(keyboardViewText, '"q" to "金"');
assertIncludes(keyboardViewText, '"w" to "人"');
assertIncludes(keyboardViewText, '"v" to "女"');
assertIncludes(keyboardViewText, "private fun buildHandwritingRows()");
assertIncludes(keyboardViewText, "addView(handwritingCanvasView, LayoutParams(LayoutParams.MATCH_PARENT, dp(162))");
assertIncludes(keyboardViewText, 'KeySpec("手写"');
assertIncludes(keyboardViewText, "(keyView.parent as? ViewGroup)?.removeView(keyView)");
assertIncludes(rimeNativeText, "external fun selectSchema(sessionIdentifier: Long, schemaIdentifier: String): RimeSnapshot");
assertIncludes(rimeJniText, "RimeNative_selectSchema");
assertIncludes(inputMethodServiceText, "settingsStore.inputSchema.schemaIdentifier");
assertIncludes(inputMethodServiceText, "private fun applyStoredInputSchema()");
assertIncludes(inputMethodServiceText, "!rimeSnapshot.isAsciiMode");

const handwritingCanvasText = readFileSync(handwritingCanvasPath, "utf8");
const handwritingRecognizerText = readFileSync(handwritingRecognizerPath, "utf8");
const handwritingDecoderText = readFileSync(handwritingDecoderPath, "utf8");
const keyboardInputModeText = readFileSync(keyboardInputModePath, "utf8");
for (const handwritingModeContract of [
  'HANDWRITING("handwriting")',
  "settingsStore.keyboardInputMode = nextMode",
  "private val handwritingExecutor = Executors.newSingleThreadExecutor()",
  "handwritingRecognitionDelayMilliseconds = 420L",
  "requestGeneration != handwritingGenerationValue",
  "handwritingRecognizer.recognize(bitmapValue)",
  "draftState.append(selectedCandidate.textValue)",
  "refreshTranslationForCurrentDraft()",
]) {
  assertIncludes(`${keyboardInputModeText}\n${inputMethodServiceText}`, handwritingModeContract);
}
for (const handwritingCanvasContract of [
  "MotionEvent.ACTION_UP",
  "strokeChangedAction(hasInk)",
  "fun undoLastStroke()",
  "fun clearStrokes(",
  "fun createRecognitionBitmap()",
]) {
  assertIncludes(handwritingCanvasText, handwritingCanvasContract);
}
for (const handwritingRecognizerContract of [
  'const val modelAssetPath = "handwriting/inference.onnx"',
  'const val characterAssetPath = "handwriting/characters.txt"',
  "longArrayOf(1, channelCount.toLong(), inputHeight.toLong(), inputWidth.toLong())",
  "channelValue / 127.5f - 1f",
  "outputTensor.floatBuffer.get(scoreList)",
]) {
  assertIncludes(handwritingRecognizerText, handwritingRecognizerContract);
}
for (const handwritingDecoderContract of [
  "classCount == characterList.size + 1",
  "buildSegmentList(topClassList)",
  "topAlternativeList(scoreList, classCount, segmentValue)",
]) {
  assertIncludes(handwritingDecoderText, handwritingDecoderContract);
}

const unpackedApkValue = runBuffer("unzip", ["-p", debugApkPath]);
const unpackedApkText = unpackedApkValue.toString("latin1");
if (/sk-[A-Za-z0-9_-]{12,}/.test(unpackedApkText)) {
  throw new Error("APK 中检测到上游 sk 凭据模式");
}
if (!unpackedApkText.includes("api.deepseek.com")) {
  throw new Error("APK 中缺少 DeepSeek 官方翻译地址");
}
if (unpackedApkText.includes("114.132.185.123") || unpackedApkText.includes("typingchao-api")) {
  throw new Error("APK 中不应包含已下线的翻译代理地址");
}

const signatureText = runText(apkSignerPath, ["verify", "--verbose", "--print-certs", debugApkPath], {
  JAVA_HOME: javaHome,
});
assertIncludes(signatureText, "Verifies");
assertIncludes(signatureText, "Verified using v2 scheme (APK Signature Scheme v2): true");

const apkHash = createHash("sha256").update(readFileSync(debugApkPath)).digest("hex");
console.log("Android APK 验证通过：包名、IME/设置入口、arm64 原生库、Rime/OpenCC 数据、第三方许可证、DeepSeek 直连与本地 Key 配置边界均符合约束。");
console.log(`APK SHA-256：${apkHash}`);

function run(command: string, args: string[], cwd: string) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, {
    cwd,
    stdio: "inherit",
    env: androidEnvironment(),
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function runText(command: string, args: string[], extraEnvironment: Record<string, string> = {}) {
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    env: androidEnvironment(extraEnvironment),
  });
  if (result.status !== 0) {
    throw new Error(`${command} 执行失败：${result.stderr}`);
  }
  return result.stdout.trim();
}

function runBuffer(command: string, args: string[]) {
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    maxBuffer: 256 * 1024 * 1024,
    env: androidEnvironment(),
  });
  if (result.status !== 0) {
    throw new Error(`${command} 执行失败：${result.stderr.toString("utf8")}`);
  }
  return result.stdout;
}

function androidEnvironment(extraEnvironment: Record<string, string> = {}) {
  return {
    ...process.env,
    JAVA_HOME: javaHome,
    ANDROID_HOME: androidSdkRoot,
    ANDROID_SDK_ROOT: androidSdkRoot,
    PATH: `${join(javaHome, "bin")}:${join(androidSdkRoot, "platform-tools")}:${process.env.PATH ?? ""}`,
    ...extraEnvironment,
  };
}

// 源码契约只截取指定函数，避免其它生命周期中的合法组合结束逻辑造成误报。
function sourceFunctionBody(sourceText: string, declarationText: string) {
  const declarationIndex = sourceText.indexOf(declarationText);
  if (declarationIndex < 0) throw new Error(`Android 输入法源码缺少函数：${declarationText}`);
  const bodyStartIndex = sourceText.indexOf("{", declarationIndex);
  if (bodyStartIndex < 0) throw new Error(`Android 输入法函数缺少函数体：${declarationText}`);
  var braceDepth = 0;
  for (let characterIndex = bodyStartIndex; characterIndex < sourceText.length; characterIndex += 1) {
    const characterValue = sourceText[characterIndex];
    if (characterValue === "{") braceDepth += 1;
    if (characterValue === "}") braceDepth -= 1;
    if (braceDepth === 0) return sourceText.slice(bodyStartIndex + 1, characterIndex);
  }
  throw new Error(`Android 输入法函数体未闭合：${declarationText}`);
}

function assertIncludes(sourceText: string, expectedText: string) {
  if (!sourceText.includes(expectedText)) {
    throw new Error(`Android 产物检查缺少预期内容：${expectedText}`);
  }
}
