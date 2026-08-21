// 供 ai-elements 组件使用的 tailwind 合并工具
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputList: ClassValue[]): string {
  return twMerge(clsx(inputList));
}
