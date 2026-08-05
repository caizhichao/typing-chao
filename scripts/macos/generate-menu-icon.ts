#!/usr/bin/env bun

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const projectRoot = resolve(import.meta.dir, "../..");
const outputPath = resolve(
  process.argv[2] ?? `${projectRoot}/platforms/macos/Resources/TypingDongnanyaMenuIconV4.pdf`,
);

// 输入源菜单图标只绘制透明背景上的单色双向箭头，避免模板着色把背景渲染成实心方块。
const content = [
  "q",
  "0 G",
  "1.55 w",
  "1 J",
  "1 j",
  "3 10.75 m",
  "11.25 10.75 l",
  "S",
  "9 13 m",
  "11.5 10.75 l",
  "9 8.5 l",
  "S",
  "13 5.25 m",
  "4.75 5.25 l",
  "S",
  "7 3 m",
  "4.5 5.25 l",
  "7 7.5 l",
  "S",
  "Q",
  "",
].join("\n");

const objectList = [
  "<< /Type /Catalog /Pages 2 0 R >>",
  "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
  "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 16 16] /Resources << /ProcSet [/PDF] >> /Contents 4 0 R >>",
  `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}endstream`,
];

let pdf = "%PDF-1.4\n% typing-dongnanya-v4\n";
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

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, pdf);
console.log(`已生成透明单色输入源图标：${outputPath}`);
