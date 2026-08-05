#!/usr/bin/env bun

import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const androidRoot = join(projectRoot, "platforms", "android");
const androidSdkRoot = "/opt/homebrew/share/android-commandlinetools";
const adbPath = join(androidSdkRoot, "platform-tools", "adb");
const debugApkPath = join(androidRoot, "app", "build", "outputs", "apk", "debug", "app-debug.apk");
const applicationIdentifier = "com.caizhichao.typingdongnanya";

if (!existsSync(adbPath)) throw new Error("找不到 adb，请先安装 Android platform-tools");
if (!existsSync(debugApkPath)) throw new Error("找不到 Debug APK，请先运行 bun run scripts/android/build.ts");

const deviceList = runText(adbPath, ["devices"]).split("\n").slice(1).filter((lineValue) => lineValue.endsWith("\tdevice"));
if (deviceList.length !== 1) {
  throw new Error(`需要且只能连接一台已授权 Android 设备，当前数量：${deviceList.length}`);
}
run(adbPath, ["install", "-r", debugApkPath]);
run(adbPath, ["shell", "am", "start", "-n", `${applicationIdentifier}/.settings.SettingsActivity`]);
console.log("已安装并打开 Typing 东南亚设置页；请按页面引导启用并选择输入法。");

function run(command: string, args: string[]) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function runText(command: string, args: string[]) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`${command} 执行失败：${result.stderr}`);
  }
  return result.stdout.trim();
}
