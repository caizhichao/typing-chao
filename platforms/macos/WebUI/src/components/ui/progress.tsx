import * as React from "react";
import { cn } from "../../lib/utils";
export function Progress({ value = 0, className, ...props }: React.HTMLAttributes<HTMLDivElement> & { value?: number }) {
  return (
    <div className={cn("h-1.5 w-full overflow-hidden rounded-full bg-[var(--surface-muted)]", className)} {...props}>
      <div className="h-full bg-[var(--accent)] transition-all" style={{ width: `${Math.max(0, Math.min(100, value))}%` }} />
    </div>
  );
}
