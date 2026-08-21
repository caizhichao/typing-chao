import * as React from "react";
import { cn } from "../../lib/utils";
export function InputGroup({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div className={cn("flex items-center gap-1 rounded-md border bg-[var(--surface-strong)] p-1", className)} {...props} />; }
export function InputGroupAddon({ align, className, ...props }: React.HTMLAttributes<HTMLDivElement> & { align?: string }) { void align; return <div className={cn("flex items-center gap-1", className)} {...props} />; }
export function InputGroupButton({ variant, size, className, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: string; size?: string }) { void variant; void size; return <button className={cn("rounded px-2 py-1 text-xs hover:bg-[var(--surface-hover)]", className)} {...props} />; }
export function InputGroupTextarea({ className, ...props }: React.TextareaHTMLAttributes<HTMLTextAreaElement>) { return <textarea className={cn("min-h-10 w-full resize-none bg-transparent px-2 py-1.5 text-xs outline-none", className)} {...props} />; }
