#!/usr/bin/env bun

import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const projectRoot = resolve(import.meta.dir, "../..");
const sourceRoot = join(projectRoot, "vendor", "paddleocr-handwriting");
const modelRoot = join(sourceRoot, "PP-OCRv6_tiny_rec");
const modelPath = join(modelRoot, "inference.onnx");
const configPath = join(modelRoot, "inference.yml");
const metadataPath = join(sourceRoot, "SOURCE.json");
const outputRoot = join(projectRoot, "platforms", "android", "app", "build", "generated", "handwritingAssets", "handwriting");
const expectedCharacterCount = 6_904;

interface SourceMetadata {
  modelSha256: string;
  configSha256: string;
}

// Android 手写资源必须由锁定的 Apache-2.0 模型生成，避免模型或字符表静默漂移。
function prepareHandwritingAssets(): void {
  const sourceMetadata = JSON.parse(readFileSync(metadataPath, "utf8")) as SourceMetadata;
  verifyHash(modelPath, sourceMetadata.modelSha256, "手写 ONNX 模型");
  verifyHash(configPath, sourceMetadata.configSha256, "手写模型配置");
  const characterList = extractCharacterList(readFileSync(configPath, "utf8"));
  if (characterList.length !== expectedCharacterCount) {
    throw new Error(`手写字符表数量异常：${characterList.length}`);
  }
  if (characterList.at(-1) !== " ") characterList.push(" ");

  mkdirSync(outputRoot, { recursive: true });
  copyFileSync(modelPath, join(outputRoot, "inference.onnx"));
  writeFileSync(join(outputRoot, "characters.txt"), `${characterList.join("\n")}\n`);
  console.log(`已准备离线手写模型与 ${characterList.length} 个识别字符：${outputRoot}`);
}

function verifyHash(filePath: string, expectedHash: string, displayName: string): void {
  const actualHash = createHash("sha256").update(readFileSync(filePath)).digest("hex");
  if (actualHash !== expectedHash) {
    throw new Error(`${displayName}哈希不匹配：${actualHash}`);
  }
}

function extractCharacterList(configText: string): string[] {
  const lineList = configText.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  const dictionaryLineIndex = lineList.findIndex((lineText) => lineText.trim() === "character_dict:");
  if (dictionaryLineIndex < 0) throw new Error("手写模型配置缺少 character_dict");
  const dictionaryIndent = leadingSpaceCount(lineList[dictionaryLineIndex]);
  const characterList: string[] = [];
  for (let lineIndex = dictionaryLineIndex + 1; lineIndex < lineList.length; lineIndex += 1) {
    const lineText = lineList[lineIndex];
    const trimmedText = lineText.trim();
    if (!trimmedText || trimmedText.startsWith("#")) continue;
    const indentation = leadingSpaceCount(lineText);
    const listItemText = lineText.slice(indentation);
    if (!listItemText.startsWith("-")) {
      if (indentation <= dictionaryIndent) break;
      continue;
    }
    characterList.push(parseYamlScalar(listItemText.slice(1).trimStart()));
  }
  return characterList;
}

function leadingSpaceCount(lineText: string): number {
  const nonSpaceIndex = lineText.search(/[^ ]/);
  return nonSpaceIndex < 0 ? lineText.length : nonSpaceIndex;
}

function parseYamlScalar(rawValue: string): string {
  if (rawValue.length >= 2 && rawValue.startsWith("'") && rawValue.endsWith("'")) {
    return rawValue.slice(1, -1).replaceAll("''", "'");
  }
  if (rawValue.length >= 2 && rawValue.startsWith('"') && rawValue.endsWith('"')) {
    return JSON.parse(rawValue) as string;
  }
  return rawValue;
}

prepareHandwritingAssets();
