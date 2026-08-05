#!/usr/bin/env bun

import { Buffer } from "node:buffer";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const pdfPath = resolve(
  process.argv[2] ?? `${projectRoot}/platforms/macos/Resources/TypingDongnanyaAppIcon.pdf`,
);
const icnsPath = resolve(
  process.argv[3] ?? `${projectRoot}/platforms/macos/Resources/TypingDongnanyaAppIcon.icns`,
);

// 注册页图标采用独立彩色应用图标；菜单仍使用透明单色模板，二者不可再复用同一资源。
const content = [
  "q",
  "0.12 0.39 0.94 rg",
  "64 10 m",
  "192 10 l",
  "222 10 246 34 246 64 c",
  "246 192 l",
  "246 222 222 246 192 246 c",
  "64 246 l",
  "34 246 10 222 10 192 c",
  "10 64 l",
  "10 34 34 10 64 10 c",
  "f",
  "0.03 0.72 0.58 rg",
  "154 34 m",
  "204 34 l",
  "224 34 240 50 240 70 c",
  "240 116 l",
  "240 136 224 152 204 152 c",
  "188 152 l",
  "166 172 l",
  "169 152 l",
  "154 152 l",
  "134 152 118 136 118 116 c",
  "118 70 l",
  "118 50 134 34 154 34 c",
  "f",
  "1 1 1 RG",
  "15 w",
  "1 J",
  "1 j",
  "52 166 m",
  "184 166 l",
  "S",
  "158 192 m",
  "188 166 l",
  "158 140 l",
  "S",
  "204 96 m",
  "72 96 l",
  "S",
  "98 70 m",
  "68 96 l",
  "98 122 l",
  "S",
  "Q",
  "",
].join("\n");

const objectList = [
  "<< /Type /Catalog /Pages 2 0 R >>",
  "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
  "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 256 256] /Resources << /ProcSet [/PDF] >> /Contents 4 0 R >>",
  `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}endstream`,
];

let pdf = "%PDF-1.4\n% typing-dongnanya-app-icon-v1\n";
const offsetList = [0];
for (const [index, object] of objectList.entries()) {
  offsetList.push(Buffer.byteLength(pdf));
  pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
}
const xrefOffset = Buffer.byteLength(pdf);
pdf += `xref\n0 ${objectList.length + 1}\n`;
pdf += "0000000000 65535 f \n";
for (const offset of offsetList.slice(1)) {
  pdf += `${String(offset).padStart(10, "0")} 00000 n \n`;
}
pdf += `trailer\n<< /Size ${objectList.length + 1} /Root 1 0 R >>\n`;
pdf += `startxref\n${xrefOffset}\n%%EOF\n`;

mkdirSync(dirname(pdfPath), { recursive: true });
mkdirSync(dirname(icnsPath), { recursive: true });
writeFileSync(pdfPath, pdf);

const temporaryRoot = mkdtempSync(join(tmpdir(), "typing-dongnanya-icon-"));
const iconsetPath = join(temporaryRoot, "TypingDongnanyaAppIcon.iconset");
mkdirSync(iconsetPath, { recursive: true });
const iconSizeList = [
  [16, "icon_16x16.png"],
  [32, "icon_16x16@2x.png"],
  [32, "icon_32x32.png"],
  [64, "icon_32x32@2x.png"],
  [128, "icon_128x128.png"],
  [256, "icon_128x128@2x.png"],
  [256, "icon_256x256.png"],
  [512, "icon_256x256@2x.png"],
  [512, "icon_512x512.png"],
  [1024, "icon_512x512@2x.png"],
] as const;

try {
  for (const [iconSize, fileName] of iconSizeList) {
    run("/usr/bin/sips", [
      "-s", "format", "png",
      "-z", String(iconSize), String(iconSize),
      pdfPath,
      "--out", join(iconsetPath, fileName),
    ]);
  }
  run("/usr/bin/iconutil", ["-c", "icns", iconsetPath, "-o", icnsPath]);
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true });
}

console.log(`已生成注册页应用图标：${pdfPath}`);
console.log(`已生成应用图标包：${icnsPath}`);

function run(command: string, args: string[]) {
  const result = spawnSync(command, args, { stdio: "ignore" });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed`);
  }
}
