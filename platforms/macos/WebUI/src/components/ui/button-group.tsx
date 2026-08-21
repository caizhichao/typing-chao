import * as React from "react";
import { cn } from "../../lib/utils";
export function ButtonGroup({ orientation, className, ...props }: React.HTMLAttributes<HTMLDivElement> & { orientation?: string }) { void orientation; return <div className={cn("inline-flex items-center gap-1", className)} {...props} />; }
export function ButtonGroupText({ className, ...props }: React.HTMLAttributes<HTMLSpanElement>) { return <span className={cn("text-xs text-[var(--text-tertiary)]", className)} {...props} />; }
