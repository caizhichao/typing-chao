#!/usr/bin/env bun

import { existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const destinationApp = join(homedir(), "Library", "Input Methods", "TypingChao.app");
if (!existsSync(destinationApp)) {
  console.log("Typing Chao 尚未安装。");
  process.exit(0);
}
rmSync(destinationApp, { recursive: true, force: true });
console.log("已清理 Typing Chao 自己的安装目录；其它输入法未修改。");
