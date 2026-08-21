import * as React from "react";
import { cn } from "../../lib/utils";
export function Alert({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div role="alert" className={cn("rounded-md border border-[var(--border)] bg-[var(--surface)] p-3 text-sm", className)} {...props} />;
}
export function AlertDescription({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("text-[11.5px] text-[var(--text-secondary)]", className)} {...props} />;
}
