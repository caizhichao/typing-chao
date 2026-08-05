#!/usr/bin/env bun

import { basename } from "node:path";
import { spawnSync } from "node:child_process";

const [configuredCompilerPath, ...compilerArguments] = process.argv.slice(2);
if (!configuredCompilerPath) {
  throw new Error("Apple Clang launcher 缺少 CMake 传入的原编译器路径");
}
const configuredCompilerName = basename(configuredCompilerPath);
const cxxCompilerValue = configuredCompilerName.includes("++") || compilerArguments.includes("-xc++");
const trustedCompilerPath = cxxCompilerValue ? "/usr/bin/clang++" : "/usr/bin/clang";
const trustedCompilerArguments = [...compilerArguments];
if (cxxCompilerValue && !trustedCompilerArguments.includes("-fno-sized-deallocation")) {
  trustedCompilerArguments.push("-fno-sized-deallocation");
}

// 本机绿盾只向系统 Apple Clang 提供源码明文；launcher 保留 NDK 的 target/sysroot 参数，仅替换编译前端。
const result = spawnSync(trustedCompilerPath, trustedCompilerArguments, { stdio: "inherit" });
process.exit(result.status ?? 1);
