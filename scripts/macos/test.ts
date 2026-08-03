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
verifyBundledTranslationEndpoint();
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

const sentenceSmokeOutputPath = join(
  buildRoot,
  "TranslationSentenceBoundarySmoke",
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
    "TranslationSentenceBoundary.swift",
  ),
  join(
    projectRoot,
    "Sources",
    "TypingDongnanyaInputMethod",
    "TranslationDraft.swift",
  ),
  join(projectRoot, "Tests", "TranslationSentenceBoundarySmoke.swift"),
  "-o",
  sentenceSmokeOutputPath,
]);
run(sentenceSmokeOutputPath, []);

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

  const iconFileName = "TypingDongnanyaMenuIconV4.pdf";
  const modeInfo = bundledInfo.ComponentInputModeDict?.tsInputModeListKey?.[
    "com.caizhichao.typing-dongnanya.inputmethod.TypingDongnanya.Pinyin"
  ];
  if (
    bundledInfo.tsInputMethodIconFileKey !== iconFileName ||
    modeInfo?.tsInputModeMenuIconFileKey !== iconFileName ||
    modeInfo?.tsInputModePaletteIconFileKey !== iconFileName ||
    modeInfo?.tsInputModeAlternateMenuIconFileKey !== iconFileName ||
    !existsSync(join(buildRoot, "TypingDongnanya.app", "Contents", "Resources", iconFileName))
  ) {
    throw new Error("输入源必须打包当前版本的 PDF 菜单图标并在根与模式元数据中统一引用");
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
