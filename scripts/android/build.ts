#!/usr/bin/env bun

import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const androidRoot = join(projectRoot, "platforms", "android");
const javaHome = "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home";
const androidSdkRoot = "/opt/homebrew/share/android-commandlinetools";
const gradleWrapperPath = join(androidRoot, "gradlew");
const debugApkPath = join(androidRoot, "app", "build", "outputs", "apk", "debug", "app-debug.apk");

for (const requiredPath of [javaHome, androidSdkRoot, gradleWrapperPath]) {
  if (!existsSync(requiredPath)) {
    throw new Error(`Android 构建工具缺失：${requiredPath}`);
  }
}

run("bun", ["run", "scripts/rime/generate-aosp-pinyin-dictionary.ts"], projectRoot);
run("bun", ["run", "scripts/rime/generate-wubi86-dictionary.ts"], projectRoot);
run("bun", ["run", "scripts/android/prepare-handwriting-assets.ts"], projectRoot);
run(gradleWrapperPath, ["--no-daemon", "assembleDebug"], androidRoot);
if (!existsSync(debugApkPath)) {
  throw new Error("Android Debug APK 构建完成后未找到预期产物");
}
console.log(`已构建 Android 输入法：${debugApkPath}`);

// Android 构建固定使用项目锁定的 JDK 17 与 Homebrew SDK 根目录，不依赖当前终端环境变量。
function run(command: string, args: string[], cwd: string) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, {
    cwd,
    stdio: "inherit",
    env: {
      ...process.env,
      JAVA_HOME: javaHome,
      ANDROID_HOME: androidSdkRoot,
      ANDROID_SDK_ROOT: androidSdkRoot,
      PATH: `${join(javaHome, "bin")}:${join(androidSdkRoot, "platform-tools")}:${process.env.PATH ?? ""}`,
    },
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}
