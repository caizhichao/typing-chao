import * as React from "react";
import { cn } from "../../lib/utils";
export function Command({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div className={cn("rounded-md border bg-[var(--surface-strong)]", className)} {...props} />; }
export function CommandInput(props: React.InputHTMLAttributes<HTMLInputElement>) { return <input className="w-full bg-transparent px-2 py-1.5 text-xs outline-none" {...props} />; }
export function CommandList({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div className={cn("max-h-40 overflow-auto p-1", className)} {...props} />; }
export function CommandEmpty({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div className={cn("py-3 text-center text-xs text-[var(--text-tertiary)]", className)} {...props} />; }
export function CommandGroup({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div className={cn("p-1", className)} {...props} />; }
export function CommandItem({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div className={cn("rounded px-2 py-1.5 text-xs hover:bg-[var(--surface-hover)]", className)} {...props} />; }
export function CommandSeparator({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div className={cn("my-1 h-px bg-[var(--border)]", className)} {...props} />; }
