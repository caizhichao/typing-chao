#!/usr/bin/env bun

import { chmodSync, cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const macOSRoot = join(projectRoot, "platforms", "macos");
const sourceRoot = join(macOSRoot, "Sources", "TypingChaoInputMethod");
const sourceResourcesRoot = join(macOSRoot, "Resources");
const macOSRimeDataRoot = join(sourceResourcesRoot, "RimeData");
const sharedRimeDataRoot = join(projectRoot, "shared", "RimeData");
const sourceInfoPath = join(macOSRoot, "Info.plist");
const vendorRoot = join(projectRoot, "vendor", "librime");
const buildRoot = join(macOSRoot, "build");
const swiftModuleCacheRoot = join(tmpdir(), "typingchao-swift-module-cache");
const appRoot = join(buildRoot, "TypingChao.app");
const contentsRoot = join(appRoot, "Contents");
const resourcesRoot = join(contentsRoot, "Resources");
const rimeDataRoot = join(resourcesRoot, "RimeData");
const executablePath = join(contentsRoot, "MacOS", "TypingChao");
const bundleInfoPath = join(contentsRoot, "Info.plist");
const inputMethodBundleIdentifier = "com.caizhichao.typingchao.inputmethod.TypingChao";
const localDesignatedRequirement = `=designated => identifier "${inputMethodBundleIdentifier}"`;
const defaultSDKPath = runText("xcrun", ["--show-sdk-path"]);
const compatibleSDKPath = join(dirname(defaultSDKPath), "MacOSX15.4.sdk");
// 当前 CLT 的 Swift 与 26.5 SDK 内部构建号不匹配，优先使用仍兼容 macOS 13 目标的本机 15.4 SDK。
const sdkPath = existsSync(compatibleSDKPath) ? compatibleSDKPath : defaultSDKPath;
const boostRoot = "/opt/homebrew/opt/boost";
const architecture = runText("arch", []);
// 本地调试默认关闭全模块优化，只有显式 release 构建才启用优化。
let swiftOptimizationLevel = "-Onone";
if (process.argv.includes("--release")) {
  swiftOptimizationLevel = "-O";
}

rmSync(buildRoot, { recursive: true, force: true });
mkdirSync(join(buildRoot, "obj"), { recursive: true });
mkdirSync(swiftModuleCacheRoot, { recursive: true });
mkdirSync(join(contentsRoot, "MacOS"), { recursive: true });
mkdirSync(resourcesRoot, { recursive: true });

const librimeLibrary = join(vendorRoot, "build", "lib", "librime.a");
if (!existsSync(librimeLibrary)) {
  run("make", ["deps"], vendorRoot);
  run("make", ["librime-static", `BOOST_ROOT=${boostRoot}`], vendorRoot);
}

run("bun", ["run", "scripts/rime/generate-aosp-pinyin-dictionary.ts"], projectRoot);
run("bun", ["run", "scripts/rime/generate-wubi86-dictionary.ts"], projectRoot);
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
  join(sourceRoot, "RimeInputPolicy.swift"),
  join(sourceRoot, "AIInputCommand.swift"),
  join(sourceRoot, "InputMethodSettings.swift"),
  join(sourceRoot, "InputMethodSettingsWindow.swift"),
  join(sourceRoot, "InputMethodApplicationDelegate.swift"),
  join(sourceRoot, "InputMethodMenu.swift"),
  join(sourceRoot, "CandidateOverlay.swift"),
  join(sourceRoot, "InputModeStatusOverlay.swift"),
  join(sourceRoot, "TranslationDraft.swift"),
  join(sourceRoot, "InputMethodController.swift"),
  join(sourceRoot, "InputSourceRegistration.swift"),
  join(sourceRoot, "OverlayLayout.swift"),
  join(sourceRoot, "TranslationOverlay.swift"),
  join(sourceRoot, "AIInputOverlay.swift"),
  join(sourceRoot, "TranslationService.swift"),
  join(sourceRoot, "main.swift"),
];
const libRoot = join(vendorRoot, "lib");
const linkArguments = [
  "-module-cache-path", swiftModuleCacheRoot,
  "-target", `${architecture}-apple-macosx13.0`,
  "-sdk", sdkPath,
  swiftOptimizationLevel,
  "-module-name", "TypingChao",
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

cpSync(sourceInfoPath, bundleInfoPath);
run("/usr/bin/codesign", [
  "--force",
  "--deep",
  "--sign",
  "-",
  "--requirements",
  localDesignatedRequirement,
  appRoot,
]);
chmodSync(executablePath, 0o755);
console.log(`已构建隔离输入法包：${appRoot}`);

function copyRimeData() {
  cpSync(join(sourceResourcesRoot, "TypingChaoAppIcon.pdf"), join(resourcesRoot, "TypingChaoAppIcon.pdf"));
  cpSync(join(sourceResourcesRoot, "TypingChaoAppIcon.icns"), join(resourcesRoot, "TypingChaoAppIcon.icns"));
  cpSync(join(sourceResourcesRoot, "TypingChaoMenuIconV4.pdf"), join(resourcesRoot, "TypingChaoMenuIconV4.pdf"));
  for (const localizationName of ["en.lproj", "zh-Hans.lproj", "zh_CN.lproj"]) {
    cpSync(join(sourceResourcesRoot, localizationName), join(resourcesRoot, localizationName), { recursive: true });
  }
  mkdirSync(rimeDataRoot, { recursive: true });
  for (const fileName of readdirSync(sharedRimeDataRoot)) {
    cpSync(join(sharedRimeDataRoot, fileName), join(rimeDataRoot, fileName), { recursive: true });
  }
  if (existsSync(macOSRimeDataRoot)) {
    for (const fileName of readdirSync(macOSRimeDataRoot)) {
      cpSync(join(macOSRimeDataRoot, fileName), join(rimeDataRoot, fileName), { recursive: true });
    }
  }
  const aospPinyinDataRoot = join(projectRoot, "vendor", "aosp-pinyinime-data");
  cpSync(join(aospPinyinDataRoot, "NOTICE"), join(rimeDataRoot, "aosp-pinyinime.NOTICE"));
  cpSync(join(aospPinyinDataRoot, "SOURCE.json"), join(rimeDataRoot, "aosp-pinyinime.SOURCE.json"));
  const wubiDataRoot = join(projectRoot, "vendor", "wubimb-data");
  cpSync(join(wubiDataRoot, "LICENSE"), join(rimeDataRoot, "wubimb.LICENSE"));
  cpSync(join(wubiDataRoot, "SOURCE.json"), join(rimeDataRoot, "wubimb.SOURCE.json"));
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
