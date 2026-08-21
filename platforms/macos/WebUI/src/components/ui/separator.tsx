import * as React from "react";
import { cn } from "../../lib/utils";
export function Separator({ orientation = "horizontal", className, ...props }: React.HTMLAttributes<HTMLDivElement> & { orientation?: "horizontal" | "vertical" }) {
  return <div className={cn(orientation === "horizontal" ? "h-px w-full bg-[var(--border)]" : "h-full w-px bg-[var(--border)]", className)} {...props} />;
}
