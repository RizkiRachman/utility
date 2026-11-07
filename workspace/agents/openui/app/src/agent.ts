import { tool } from "@langchain/core/tools";
import { StateSchema } from "@langchain/langgraph";
import { ChatOpenAI } from "@langchain/openai";
import { generateSystemPrompt } from "@openuidev/lang-core";
import { createAgent, createMiddleware } from "langchain";
import { z } from "zod";
import librarySpec from "./generated/spec.json";
import { requiredEnv, envOr } from "./lib/env";
import { DEFAULT_MODEL } from "./lib/models";
import { executeGetWeather, getWeatherTool } from "./lib/tools/get-weather";

// The generated spec carries the library and its prompt options; generateSystemPrompt takes them separately.
const { promptOptions, ...library } = librarySpec;

const getWeather = tool(
  async ({ location }, config) =>
    executeGetWeather(JSON.stringify({ location }), { signal: config.signal }),
  {
    name: "get_weather",
    description: getWeatherTool.description,
    schema: z.object({
      location: z.string().trim().min(1).describe("City or place name, e.g. Berlin."),
    }),
  },
);

const CloudAgentState = new StateSchema({
  conversationId: z.string(),
  turnStart: z.number().int().nonnegative(),
  model: z.string().default(DEFAULT_MODEL),
});

function cloudModel(model: string) {
  return new ChatOpenAI({
    model,
    apiKey: envOr("SUMOPOD_API_KEY", "unset-at-build-time"),  // real key applied per-request by selectedModel middleware
    streaming: true,
    useResponsesApi: false,
    configuration: { baseURL: envOr("SUMOPOD_BASE_URL", "https://ai.sumopod.com/v1") },
  });
}

const selectedModel = createMiddleware({
  name: "OpenUICloudModel",
  stateSchema: CloudAgentState,
  wrapModelCall: async (request, handler) => {
    const { model } = request.state as unknown as { model: string };
    return handler({ ...request, model: cloudModel(model) });
  },
});

/** LangGraph owns the tool loop; OpenUI Cloud provides Chat Completions. */
export const graph = createAgent({
  model: cloudModel(DEFAULT_MODEL),
  tools: [getWeather],
  systemPrompt: generateSystemPrompt({ cloud: false, library, promptOptions }),
  stateSchema: CloudAgentState,
  middleware: [selectedModel],
});
