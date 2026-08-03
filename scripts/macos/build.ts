#!/usr/bin/env bun

import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const sourceRoot = join(projectRoot, "Sources", "TypingDongnanyaInputMethod");
const vendorRoot = join(projectRoot, "vendor", "librime");
const buildRoot = join(projectRoot, "build");
const appRoot = join(buildRoot, "TypingDongnanya.app");
const contentsRoot = join(appRoot, "Contents");
const resourcesRoot = join(contentsRoot, "Resources");
const rimeDataRoot = join(resourcesRoot, "RimeData");
const executablePath = join(contentsRoot, "MacOS", "TypingDongnanya");
const bundleInfoPath = join(contentsRoot, "Info.plist");
const proxyAccessTokenPath = join(homedir(), ".config", "typing-dongnanya", "access-token");
const proxyAccessToken = readProxyAccessToken();
const sdkPath = runText("xcrun", ["--show-sdk-path"]);
const boostRoot = "/opt/homebrew/opt/boost";
const architecture = runText("arch", []);

rmSync(buildRoot, { recursive: true, force: true });
mkdirSync(join(buildRoot, "obj"), { recursive: true });
mkdirSync(join(contentsRoot, "MacOS"), { recursive: true });
mkdirSync(resourcesRoot, { recursive: true });

const librimeLibrary = join(vendorRoot, "build", "lib", "librime.a");
if (!existsSync(librimeLibrary)) {
  run("make", ["deps"], vendorRoot);
  run("make", ["librime-static", `BOOST_ROOT=${boostRoot}`], vendorRoot);
}

copyRimeData();

const bridgeObject = join(buildRoot, "obj", "RimeBridge.o");
run("clang++", [
  "-std=c++17",
  "-fobjc-arc",
  "-target", `${architecture}-apple-macosx13.0`,
  "-isysroot", sdkPath,
  "-I", join(vendorRoot, "src"),
  "-I", join(vendorRoot, "include"),
  "-c", join(sourceRoot, "RimeBridge.mm"),
  "-o", bridgeObject,
]);

const swiftFiles = [
  join(sourceRoot, "RimeSnapshot.swift"),
  join(sourceRoot, "InputMethodSettings.swift"),
  join(sourceRoot, "InputMethodMenu.swift"),
  join(sourceRoot, "CandidateOverlay.swift"),
  join(sourceRoot, "TranslationDraft.swift"),
  join(sourceRoot, "TranslationSentenceBoundary.swift"),
  join(sourceRoot, "InputMethodController.swift"),
  join(sourceRoot, "InputSourceRegistration.swift"),
  join(sourceRoot, "OverlayLayout.swift"),
  join(sourceRoot, "TranslationOverlay.swift"),
  join(sourceRoot, "TranslationService.swift"),
  join(sourceRoot, "main.swift"),
];
const libRoot = join(vendorRoot, "lib");
const linkArguments = [
  "-target", `${architecture}-apple-macosx13.0`,
  "-sdk", sdkPath,
  "-O",
  "-module-name", "TypingDongnanya",
  "-import-objc-header", join(sourceRoot, "RimeBridge.h"),
  ...swiftFiles,
  bridgeObject,
  librimeLibrary,
  "-L", libRoot,
  "-l", "glog",
  "-l", "yaml-cpp",
  "-l", "leveldb",
  "-l", "marisa",
  "-l", "opencc",
  join(boostRoot, "lib", "libboost_regex.a"),
  join(boostRoot, "lib", "libboost_locale.a"),
  join(boostRoot, "lib", "libboost_filesystem.a"),
  join(boostRoot, "lib", "libboost_thread.a"),
  "/opt/homebrew/opt/icu4c@78/lib/libicuuc.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicui18n.a",
  "/opt/homebrew/opt/icu4c@78/lib/libicudata.a",
  "-lc++",
  "-framework", "AppKit",
  "-framework", "Carbon",
  "-framework", "InputMethodKit",
  "-o", executablePath,
];
run("swiftc", linkArguments);

writeBundledInfoPlist();
run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appRoot]);
chmodSync(executablePath, 0o755);
console.log(`已构建隔离输入法包：${appRoot}`);

function copyRimeData() {
  cpSync(join(projectRoot, "Resources", "TypingDongnanyaMenuIconV4.pdf"), join(resourcesRoot, "TypingDongnanyaMenuIconV4.pdf"));
  for (const localizationName of ["en.lproj", "zh-Hans.lproj", "zh_CN.lproj"]) {
    cpSync(join(projectRoot, "Resources", localizationName), join(resourcesRoot, localizationName), { recursive: true });
  }
  const preludeRoot = join(projectRoot, "vendor", "rime-prelude");
  const lunaRoot = join(projectRoot, "vendor", "rime-luna-pinyin");
  for (const sourcePath of [preludeRoot, lunaRoot]) {
    for (const fileName of readdir(sourcePath)) {
      if (!fileName.endsWith(".yaml") && !fileName.endsWith(".dict.yaml")) continue;
      cpSync(join(sourcePath, fileName), join(rimeDataRoot, fileName));
    }
  }
  for (const fileName of ["default.custom.yaml", "luna_pinyin.custom.yaml", "rime-data-version.txt"]) {
    cpSync(join(projectRoot, "Resources", "RimeData", fileName), join(rimeDataRoot, fileName));
  }
  cpSync(join(preludeRoot, "LICENSE"), join(rimeDataRoot, "rime-prelude.LICENSE"));
  cpSync(join(lunaRoot, "LICENSE"), join(rimeDataRoot, "rime-luna-pinyin.LICENSE"));
  const essayRoot = join(projectRoot, "vendor", "rime-essay");
  cpSync(join(essayRoot, "essay.txt"), join(rimeDataRoot, "essay.txt"));
  cpSync(join(essayRoot, "LICENSE"), join(rimeDataRoot, "rime-essay.LICENSE"));
}

// 将服务器部署时生成的受限路径 capability 写入包内，桌面端绝不保存上游 AI Key。
function writeBundledInfoPlist() {
  const sourceInfoText = readFileSync(join(projectRoot, "Info.plist"), "utf8");
  const baseEndpointMatch = sourceInfoText.match(
    /<key>TypingDongnanyaAPIBaseEndpoint<\/key>\s*<string>([^<]+)<\/string>/
  );
  if (!baseEndpointMatch) {
    throw new Error("Info.plist 缺少翻译代理基础地址");
  }
  const bundledEndpoint = baseEndpointMatch[1].replace(/\/+$/, "") + "/" + proxyAccessToken;
  const bundledInfoText = sourceInfoText.replace(
    baseEndpointMatch[0],
    "<key>TypingDongnanyaAPIEndpoint</key>\n\t<string>" + bundledEndpoint + "</string>"
  );
  if (bundledInfoText === sourceInfoText) {
    throw new Error("无法将翻译代理 capability 写入输入法包");
  }
  writeFileSync(bundleInfoPath, bundledInfoText);
}

// 本机构建只读取部署脚本生成的 48 位 capability 文件，不读取环境变量。
function readProxyAccessToken() {
  if (!existsSync(proxyAccessTokenPath)) {
    throw new Error("找不到翻译代理 capability；请先部署服务器生成本机配置");
  }
  const accessToken = readFileSync(proxyAccessTokenPath, "utf8").trim();
  if (!/^[a-f0-9]{48}$/i.test(accessToken)) {
    throw new Error("翻译代理 capability 格式无效，请重新部署服务器");
  }
  return accessToken;
}

function readdir(directoryPath: string) {
  return Array.from(new Bun.Glob("*").scanSync({ cwd: directoryPath, onlyFiles: true }));
}

function run(command: string, args: string[], cwd = projectRoot) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, { cwd, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function runText(command: string, args: string[]) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`${command} failed: ${result.stderr}`);
  }
  return result.stdout.trim();
}
