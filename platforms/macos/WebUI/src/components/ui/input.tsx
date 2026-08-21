import * as React from "react";
import { cn } from "../../lib/utils";
export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(({ className, ...props }, ref) => (
  <input ref={ref} className={cn("h-8 w-full rounded-md border border-[var(--border-strong)] bg-[var(--surface-strong)] px-2 text-[11.5px] outline-none", className)} {...props} />
));
Input.displayName = "Input";
