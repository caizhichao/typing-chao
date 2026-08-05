#!/usr/bin/env bun

import { accessSync, constants, existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const sourceApp = join(projectRoot, "platforms", "macos", "build", "TypingDongnanya.app");
const userInputMethodsRoot = join(homedir(), "Library", "Input Methods");
const oldUserApp = join(userInputMethodsRoot, "TypingDongnanya.app");
const systemInputMethodsRoot = "/Library/Input Methods";
const destinationApp = join(systemInputMethodsRoot, "TypingDongnanya.app");

if (!existsSync(sourceApp)) {
  console.error("找不到 platforms/macos/build/TypingDongnanya.app，请先执行 bun run build:macos");
  process.exit(1);
}

if (existsSync(oldUserApp)) {
  // TIS 没有公开的注销 API；先移除本项目旧的用户级测试包，再由系统级包重新注册同一来源 ID。
  rmSync(oldUserApp, { recursive: true, force: true });
}

const systemExecutable = join(destinationApp, "Contents", "MacOS", "TypingDongnanya");
const installCommand = [
  `/bin/mkdir -p ${shellQuote(systemInputMethodsRoot)}`,
  `/usr/bin/rsync -a --delete ${shellQuote(`${sourceApp}/`)} ${shellQuote(`${destinationApp}/`)}`,
  `${shellQuote(systemExecutable)} --register-input-source`,
].join(" && ");
if (isWritableExistingInstallation()) {
  run("/usr/bin/rsync", ["-a", "--delete", `${sourceApp}/`, `${destinationApp}/`]);
  run(systemExecutable, ["--register-input-source"]);
} else {
  runAdministratorCommand(installCommand);
}
restartInstalledInputMethod();
restartTextInputMenuAgent();
run(systemExecutable, ["--input-source-status"]);

console.log(`已安装到系统输入法目录：${destinationApp}`);
console.log("已请求退出旧的输入法进程；请切换到其它输入法后再切回 Typing 东南亚，以启动新版本。");
console.log("当前版本由输入法内部 marked draft 持有完整原文；使用译文或上屏原文后才一次性提交，不扫描宿主正文，也不申请辅助功能或输入监控权限。");
console.log("请在系统设置 -> 键盘 -> 文本输入 -> 编辑 -> + 中搜索“中文”或“Chinese”，再在中文输入法列表选择 Typing 东南亚；不要搜索产品名“东南亚”。");

// 已有系统包归当前用户且可写时直接原位更新，首次安装或受保护包才请求管理员授权。
function isWritableExistingInstallation() {
  if (!existsSync(destinationApp)) return false;
  try {
    accessSync(destinationApp, constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

function run(command: string, args: string[]) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function runAdministratorCommand(command: string) {
  const appleScript = `do shell script ${appleScriptString(command)} with administrator privileges`;
  const result = spawnSync("/usr/bin/osascript", ["-e", appleScript], { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function restartInstalledInputMethod() {
  // 安装只替换磁盘包；已运行的 InputMethodKit 进程仍会映射旧二进制，须由用户切换输入源后重启。
  const result = spawnSync("/usr/bin/pgrep", ["-f", `^${systemExecutable}$`], { encoding: "utf8" });
  if (result.status !== 0) return;
  for (const pid of String(result.stdout ?? "").trim().split("\n")) {
    if (!pid) continue;
    try {
      process.kill(Number(pid), "SIGTERM");
    } catch {
      // 进程已退出或系统拒绝结束时不阻断安装；用户可手动切换输入源触发新进程。
    }
  }
}

// 输入源图标由 TextInputMenuAgent 缓存，安装新资源后仅重启该用户级菜单进程使其重新读取 TIS 图标 URL。
function restartTextInputMenuAgent() {
  const result = spawnSync("/usr/bin/killall", ["TextInputMenuAgent"], { stdio: "ignore" });
  if (result.status !== 0 && result.status !== 1) {
    console.error("无法刷新输入源菜单图标缓存，请重新登录后再检查图标。");
  }
}

function shellQuote(value: string) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function appleScriptString(value: string) {
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}
