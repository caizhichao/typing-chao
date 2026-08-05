#!/usr/bin/env bun

import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const sshAlias = "tencent-cloud";
const publicIPAddress = "114.132.185.123";
const remoteReleaseRoot = "/opt/typing-dongnanya-download/releases";
const localApkPath = join(projectRoot, "platforms/android/app/build/outputs/apk/debug/app-debug.apk");
const localDownloadPathConfig = join(homedir(), ".config", "typing-dongnanya", "apk-download-path");
const stableDownloadPath = readStableDownloadPath(localDownloadPathConfig);
const stablePathPartList = stableDownloadPath.split("/");
const releaseName = stablePathPartList[0];
const apkFileName = stablePathPartList[2];
const remoteApkPath = `${remoteReleaseRoot}/${stableDownloadPath}`;
const publicDownloadURL = `https://${publicIPAddress}/typing-dongnanya-download/${stableDownloadPath}`;
const invalidDownloadURL = `https://${publicIPAddress}/typing-dongnanya-download/${releaseName}/${randomBytes(36).toString("base64url")}/${apkFileName}`;
const localApk = readFileSync(localApkPath);
const localApkSha256 = sha256(localApk);

if (localApk.length === 0) throw new Error(`APK 为空：${localApkPath}`);

// 绿盾会改变原生 scp/rsync 读取的构建产物，统一由 Bun 读取后通过 SSH 标准输入传输。
uploadRemoteFile("/tmp/typing-dongnanya-android.apk", localApk);
runRemoteScript(`
set -euo pipefail
remote_apk_path='${remoteApkPath}'
remote_apk_directory=$(dirname "$remote_apk_path")
previous_apk_path=/tmp/typing-dongnanya-previous.apk
sudo mkdir -p "$remote_apk_directory"
sudo find /tmp -maxdepth 1 -type f -name 'typing-dongnanya-previous.apk' -delete
if sudo test -f "$remote_apk_path"; then
  sudo cp -a "$remote_apk_path" "$previous_apk_path"
fi
sudo install -o root -g root -m 644 /tmp/typing-dongnanya-android.apk "$remote_apk_path.new"
remote_apk_sha256=$(sha256sum "$remote_apk_path.new" | awk '{print $1}')
test "$remote_apk_sha256" = '${localApkSha256}'
sudo mv "$remote_apk_path.new" "$remote_apk_path"
sudo find /tmp -maxdepth 1 -type f -name 'typing-dongnanya-android.apk' -delete
sudo nginx -t
systemctl is-active --quiet nginx.service
systemctl is-active --quiet typing-dongnanya-api.service
printf 'path=%s\nsha256=%s\n' "$remote_apk_path" "$remote_apk_sha256"
`);

try {
  verifyPublicDownload();
  run("curl", [
    "--fail",
    "--silent",
    "--show-error",
    "--max-time",
    "10",
    `https://${publicIPAddress}/typing-dongnanya-api/healthz`,
  ]);
} catch (errorValue) {
  runRemoteScript(`
set -euo pipefail
remote_apk_path='${remoteApkPath}'
previous_apk_path=/tmp/typing-dongnanya-previous.apk
if sudo test -f "$previous_apk_path"; then
  sudo install -o root -g root -m 644 "$previous_apk_path" "$remote_apk_path"
fi
sudo find /tmp -maxdepth 1 -type f -name 'typing-dongnanya-previous.apk' -delete
`);
  throw errorValue;
}

runRemoteScript(`
set -euo pipefail
remote_apk_path='${remoteApkPath}'
sudo find '${remoteReleaseRoot}' -type f -name '*.apk' ! -path "$remote_apk_path" -delete
sudo find '${remoteReleaseRoot}' -depth -type d -empty -delete
sudo find /tmp -maxdepth 1 -type f -name 'typing-dongnanya-previous.apk' -delete
apk_count=$(sudo find '${remoteReleaseRoot}' -type f -name '*.apk' | wc -l | tr -d ' ')
test "$apk_count" = 1
test "$(sha256sum "$remote_apk_path" | awk '{print $1}')" = '${localApkSha256}'
systemctl is-active --quiet nginx.service
systemctl is-active --quiet typing-dongnanya-api.service
sudo nginx -t
printf 'apk_count=%s\n' "$apk_count"
`);

console.log(`APK 已覆盖原下载链接：${publicDownloadURL}`);
console.log(`SHA-256：${localApkSha256}`);
console.log("服务器 releases 目录仅保留当前一份 APK。");

// 稳定下载路径保存在本机 600 权限配置，不把可访问 URL 写入仓库。
function readStableDownloadPath(configPath: string) {
  const configuredPath = readFileSync(configPath, "utf8").trim();
  if (!/^[0-9]{17}\/[A-Za-z0-9_-]{48}\/[A-Za-z0-9._-]+\.apk$/.test(configuredPath)) {
    throw new Error(`APK 稳定下载路径无效：${configPath}`);
  }
  return configuredPath;
}

// 公网必须完整下载并核对哈希，错误随机路径仍应保持 404。
function verifyPublicDownload() {
  const responseHeaders = run("curl", [
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--max-time",
    "60",
    "--range",
    "0-0",
    "--dump-header",
    "-",
    "--output",
    "/dev/null",
    publicDownloadURL,
  ]);
  if (!/content-type:\s*application\/vnd\.android\.package-archive/im.test(responseHeaders)) {
    throw new Error(`下载响应 Content-Type 不正确：\n${responseHeaders}`);
  }
  if (!/content-disposition:\s*attachment/im.test(responseHeaders)) {
    throw new Error(`下载响应缺少 attachment：\n${responseHeaders}`);
  }

  const downloadedApk = runBuffer("curl", [
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--max-time",
    "180",
    publicDownloadURL,
  ]);
  const downloadedApkSha256 = sha256(downloadedApk);
  if (downloadedApkSha256 !== localApkSha256) {
    throw new Error(`公网下载 APK 哈希不一致：local=${localApkSha256}, remote=${downloadedApkSha256}`);
  }

  const invalidStatus = run("curl", [
    "--silent",
    "--show-error",
    "--output",
    "/dev/null",
    "--write-out",
    "%{http_code}",
    invalidDownloadURL,
  ]).trim();
  if (invalidStatus !== "404") throw new Error(`错误下载 Token 应返回 404，实际为 ${invalidStatus}`);
}

// 计算本地与公网下载内容的 SHA-256，确保绿盾和网络传输未改变 APK 字节。
function sha256(value: Buffer) {
  return createHash("sha256").update(value).digest("hex");
}

// 上传动作只接受 Bun 已读取的字节，禁止回退到原生 scp/rsync。
function uploadRemoteFile(remotePath: string, content: Buffer) {
  const result = spawnSync("ssh", [sshAlias, `umask 077; cat > ${shellQuote(remotePath)}`], {
    input: content,
    stdio: ["pipe", "inherit", "inherit"],
  });
  if (result.status !== 0) throw new Error(`上传远端文件失败：${remotePath}`);
}

// 远端替换、回滚和单 APK 清理由各自 shell 会话原子收口。
function runRemoteScript(script: string) {
  const result = spawnSync("ssh", [sshAlias, "bash", "-s"], {
    input: script,
    encoding: "utf8",
    stdio: ["pipe", "inherit", "inherit"],
  });
  if (result.status !== 0) throw new Error("远端 APK 发布命令执行失败");
}

// 执行本地命令并返回文本输出，失败时保留真实 stderr。
function run(command: string, args: string[]) {
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`${command} 执行失败：${result.stderr}`);
  }
  return result.stdout;
}

// 执行二进制下载命令并返回原始字节，避免文本编码改变 APK。
function runBuffer(command: string, args: string[]) {
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: "buffer",
    maxBuffer: 128 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`${command} 执行失败：${result.stderr.toString("utf8")}`);
  }
  return result.stdout;
}

// 所有远端路径进入 shell 前统一做单引号转义。
function shellQuote(value: string) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
