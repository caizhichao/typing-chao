#!/usr/bin/env bun

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const webUIRoot = join(projectRoot, "platforms", "macos", "WebUI");
const outputRoot = join(projectRoot, "platforms", "macos", "build", "web-ui");
const viteCLIPath = join(projectRoot, "node_modules", "vite", "bin", "vite.js");

// Web UI 只生成包内静态资源，不把 Node 或 Bun 运行时带入输入法安装包。
if (!existsSync(viteCLIPath)) {
  throw new Error("缺少 Web UI 依赖，请先在项目根目录执行 bun install");
}
rmSync(outputRoot, { recursive: true, force: true });
mkdirSync(outputRoot, { recursive: true });
run("bun", [viteCLIPath, "build", "--config", join(webUIRoot, "vite.config.mts"), "--outDir", outputRoot, "--emptyOutDir"], webUIRoot);
inlineWebUIAssets();

// WKWebView 的 file:// 页面不会执行 Vite 外部 ES module，构建后内联资源并把脚本放到 root 节点之后。
function inlineWebUIAssets() {
  const indexPath = join(outputRoot, "index.html");
  let indexSource = readFileSync(indexPath, "utf8");
  const scriptMatch = indexSource.match(/<script\b[^>]*\bsrc="([^"]+\.js)"[^>]*><\/script>/);
  const styleMatch = indexSource.match(/<link\b[^>]*\bhref="([^"]+\.css)"[^>]*>/);
  if (!scriptMatch || !styleMatch) {
    throw new Error("Web UI 构建产物缺少可内联的脚本或样式");
  }

  const scriptSource = readGeneratedAsset(scriptMatch[1]).replace(/<\/script/gi, "<\\/script");
  const styleSource = readGeneratedAsset(styleMatch[1]).replace(/<\/style/gi, "<\\/style");
  indexSource = indexSource
    .replace(scriptMatch[0], "")
    .replace(styleMatch[0], () => `<style>${styleSource}</style>`)
    .replace("</body>", () => `<script>${scriptSource}</script>\n  </body>`);
  writeFileSync(indexPath, indexSource);
}

function readGeneratedAsset(assetReference: string) {
  const assetPath = join(outputRoot, assetReference.replace(/^\.\//, ""));
  if (!existsSync(assetPath)) {
    throw new Error(`Web UI 构建资源不存在：${assetReference}`);
  }
  return readFileSync(assetPath, "utf8");
}

function run(command: string, args: string[], cwd: string) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, { cwd, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}
