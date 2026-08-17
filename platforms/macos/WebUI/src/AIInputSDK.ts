import { APICallError, streamText } from "ai";
import { createOpenAI } from "@ai-sdk/openai";

// 描述 AI 面板在运行时从原生配置读取的直连服务参数，避免将 Key 写入包内静态资源。
export interface AIInputRuntimeConfiguration {
  serviceProviderIdentifier: "deepseek" | "codex-responses";
  baseURL: string;
  modelName: string;
  apiKey: string;
  // 设置页保存的输入法运行场景会随当前会话配置进入 AI 请求。
  systemPromptText: string;
}

// React 维护 AI 面板已完成的会话消息，下一次请求显式重传以保持服务端无状态。
export interface AIInputConversationMessage {
  roleName: "user" | "assistant";
  contentText: string;
}

const AI_REQUEST_TIMEOUT_MILLISECONDS = 60_000;
const AI_MAX_OUTPUT_TOKENS = 1_024;

// AI 输入需要把实时信息问题和普通生成统一在同一条直连请求中处理，Codex 时才声明联网工具。
export async function streamAIInputResponse(
  runtimeConfiguration: AIInputRuntimeConfiguration,
  promptText: string,
  conversationMessageList: AIInputConversationMessage[],
  abortSignal: AbortSignal,
  onTextDelta: (textDelta: string) => void,
): Promise<string> {
  const serviceProvider = createOpenAI({
    apiKey: runtimeConfiguration.apiKey,
    baseURL: runtimeConfiguration.baseURL,
  });
  const messageList = conversationMessageList.map((messageItem) => ({
    role: messageItem.roleName,
    content: messageItem.contentText,
  }));
  messageList.push({
    role: "user",
    content: `<user_request>\n${promptText}\n</user_request>`,
  });

  if (runtimeConfiguration.serviceProviderIdentifier === "codex-responses") {
    const streamResult = streamText({
      model: serviceProvider.responses(runtimeConfiguration.modelName),
      system: systemPromptForAIInput(runtimeConfiguration),
      messages: messageList,
      tools: {
        web_search: serviceProvider.tools.webSearch(),
      },
      abortSignal,
      timeout: AI_REQUEST_TIMEOUT_MILLISECONDS,
      maxOutputTokens: AI_MAX_OUTPUT_TOKENS,
      providerOptions: {
        openai: {
          store: false,
        },
      },
    });
    return await collectAIResult(streamResult.textStream, onTextDelta);
  }

  const streamResult = streamText({
    model: serviceProvider.chat(runtimeConfiguration.modelName),
    system: systemPromptForAIInput(runtimeConfiguration),
    messages: messageList,
    abortSignal,
    timeout: AI_REQUEST_TIMEOUT_MILLISECONDS,
    maxOutputTokens: AI_MAX_OUTPUT_TOKENS,
  });
  return await collectAIResult(streamResult.textStream, onTextDelta);
}

// 流式文本先在 React 内累积并呈现，只有完整结果才回传 Swift 用于宿主上屏。
async function collectAIResult(
  textStream: AsyncIterable<string>,
  onTextDelta: (textDelta: string) => void,
): Promise<string> {
  let resultText = "";
  for await (const textDelta of textStream) {
    resultText += textDelta;
    onTextDelta(textDelta);
  }
  const cleanedResultText = cleanAIInputResult(resultText);
  if (!cleanedResultText) {
    throw new Error("AI 服务未返回可用内容");
  }
  return cleanedResultText;
}

// 设置页下发可编辑的输入法场景提示词，Codex 的联网工具约束仍由当前服务能力追加。
function systemPromptForAIInput(runtimeConfiguration: AIInputRuntimeConfiguration): string {
  const systemPromptText = runtimeConfiguration.systemPromptText.trim();
  let webSearchRequirementText = "";
  if (runtimeConfiguration.serviceProviderIdentifier === "codex-responses") {
    webSearchRequirementText = `

当前请求已提供 web_search 工具。凡用户明确要求搜索、查询或查证，或问题涉及当前、今天、最新、实时、近期、天气、新闻、价格、汇率、赛事、政策、人物职务等可能变化的信息，必须先实际调用 web_search，再根据搜索结果回答；即使模型记忆中已有答案也不能跳过搜索，不得声称没有搜索工具。
`;
  }
  return `${systemPromptText}${webSearchRequirementText}`;
}

// AI SDK 的错误对象可读取稳定状态码，页面只展示可行动文案而不泄露请求头、Key 或响应正文。
export function aiInputErrorMessage(errorValue: unknown, didTimeout: boolean): string {
  if (didTimeout) {
    return "AI 服务响应超时，请稍后继续输入";
  }
  if (errorValue instanceof DOMException && errorValue.name === "AbortError") {
    return "";
  }
  if (APICallError.isInstance(errorValue)) {
    switch (errorValue.statusCode) {
      case 401:
        return "AI 服务 Key 错误或无权限，请在输入法设置中更新";
      case 403:
        return "AI 服务当前无权访问所选模型，请在设置中更换模型或 Key";
      case 404:
        return "AI 服务地址或模型不存在，请在输入法设置中检查";
      case 408:
        return "AI 服务响应超时，请稍后继续输入";
      case 429:
        return "AI 服务请求过于频繁，请稍后继续输入";
      default:
        if (errorValue.statusCode && errorValue.statusCode >= 500) {
          return "AI 服务暂时不可用，请稍后继续输入";
        }
        return "AI 服务请求失败，请检查设置后重试";
    }
  }
  if (errorValue instanceof TypeError) {
    return "暂时无法连接 AI 服务，请检查网络或服务地址";
  }
  return "AI 服务网络异常，请稍后继续输入";
}

function cleanAIInputResult(rawResultText: string): string {
  let resultText = rawResultText.trim();
  if (resultText.startsWith("```")) {
    const lineList = resultText.split("\n");
    lineList.shift();
    if (lineList.at(-1)?.trim() === "```") {
      lineList.pop();
    }
    resultText = lineList.join("\n").trim();
  }
  return resultText;
}
