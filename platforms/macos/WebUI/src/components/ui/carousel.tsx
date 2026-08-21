// 最小占位：当前 ai-elements 的 carousel 仅在部分 example 中使用，chat 主链不依赖
import * as React from "react";
export function Carousel({ children, setApi, ...props }: React.HTMLAttributes<HTMLDivElement> & { setApi?: (api: unknown) => void }) { void setApi; return <div {...props}>{children}</div>; }
export function CarouselContent({ children, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div {...props}>{children}</div>; }
export function CarouselItem({ children, ...props }: React.HTMLAttributes<HTMLDivElement>) { return <div {...props}>{children}</div>; }
export function CarouselPrevious(props: React.ButtonHTMLAttributes<HTMLButtonElement>) { return <button {...props} />; }
export function CarouselNext(props: React.ButtonHTMLAttributes<HTMLButtonElement>) { return <button {...props} />; }
