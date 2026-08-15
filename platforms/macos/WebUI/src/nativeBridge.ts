export type WebViewName = "candidate" | "settings" | "ai-input";

export interface NativeMessage {
  messageType: string;
  messageData?: unknown;
}

declare global {
  interface Window {
    typingChaoViewName?: WebViewName;
    typingChaoReceive?: (nativeMessage: NativeMessage) => void;
    webkit?: {
      messageHandlers?: {
        typingChao?: {
          postMessage: (nativeMessage: NativeMessage) => void;
        };
      };
    };
  }
}

export function sendNativeMessage(messageType: string, messageData?: unknown) {
  const messageHandler = window.webkit?.messageHandlers?.typingChao;
  if (!messageHandler) {
    console.error("Typing Chao native message handler is unavailable", messageType);
    return;
  }
  messageHandler.postMessage({ messageType, messageData });
}

export function subscribeNativeMessage(
  messageHandler: (nativeMessage: NativeMessage) => void,
) {
  const eventHandler = (eventValue: Event) => {
    const nativeEvent = eventValue as CustomEvent<NativeMessage>;
    messageHandler(nativeEvent.detail);
  };
  window.addEventListener("typingchao-native-message", eventHandler);
  return () => window.removeEventListener("typingchao-native-message", eventHandler);
}

window.typingChaoReceive = (nativeMessage: NativeMessage) => {
  window.dispatchEvent(
    new CustomEvent("typingchao-native-message", { detail: nativeMessage }),
  );
};
