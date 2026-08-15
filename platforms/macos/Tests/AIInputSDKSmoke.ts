import {
  streamAIInputResponse,
  type AIInputConversationMessage,
} from "../WebUI/src/AIInputSDK";

const localAPIKey = process.env.TYPINGCHAO_LOCAL_AI_KEY;
if (!localAPIKey) {
  throw new Error("TYPINGCHAO_LOCAL_AI_KEY is required for the direct AI SDK smoke test");
}

const conversationMessageList: AIInputConversationMessage[] = [
  {
    roleName: "user",
    contentText: "请记住暗号是 DIRECT_AI_SDK_CONTEXT_OK。",
  },
  {
    roleName: "assistant",
    contentText: "已记住暗号。",
  },
];
const abortController = new AbortController();
const textDeltaList: string[] = [];
const resultText = await streamAIInputResponse(
  {
    serviceProviderIdentifier: "codex-responses",
    baseURL: "http://127.0.0.1:8317/v1",
    modelName: "gpt-5.6-luna",
    apiKey: localAPIKey,
  },
  "上一条回复中的暗号是什么？只输出暗号。",
  conversationMessageList,
  abortController.signal,
  (textDelta) => textDeltaList.push(textDelta),
);
if (!resultText.includes("DIRECT_AI_SDK_CONTEXT_OK") || textDeltaList.length === 0) {
  throw new Error(`direct AI SDK result mismatch: ${resultText}`);
}
console.log("Direct AI SDK smoke test passed: Responses streaming and local conversation context");
