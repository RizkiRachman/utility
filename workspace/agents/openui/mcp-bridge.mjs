#!/usr/bin/env node
// openui MCP bridge - stdio MCP server proxying the containerized OpenUI chat app.
// Zero deps (node 22). Tools: generate_ui (prompt -> OpenUI Lang text), preview_url.
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

const BASE = (process.env.OPENUI_URL || "http://openui:3000").replace(/\/+$/, "");
const MODEL = process.env.OPENUI_MODEL || "glm-5.3-flash";
const PUBLIC_URL = process.env.OPENUI_PUBLIC_URL || "http://localhost:8102";
const SERVER = { name: "openui-bridge", version: "0.1.0" };

function send(msg) { process.stdout.write(JSON.stringify(msg) + "\n"); }
function result(id, r) { send({ jsonrpc: "2.0", id, result: r }); }
function protoError(id, code, message) { send({ jsonrpc: "2.0", id, error: { code, message } }); }

const TOOLS = [
  {
    name: "generate_ui",
    description: "Generate live UI via the OpenUI app (OpenUI Lang rendered from the app component library). Returns the generated OpenUI Lang text.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "What to build, e.g. 'Dashboard card: build success rate donut chart, 87% pass'" },
        model: { type: "string", description: "Optional model id (default " + MODEL + ")" }
      },
      required: ["prompt"]
    }
  },
  {
    name: "preview_url",
    description: "Return the browser URL of the OpenUI chat app for human preview.",
    inputSchema: { type: "object", properties: {} }
  }
];

function textOf(chunk) {
  if (!chunk) return "";
  const c = chunk.content !== undefined ? chunk.content : (chunk.delta && chunk.delta.content);
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.map(function (b) { return (b && (b.text || b.content)) || ""; }).join("");
  return "";
}

async function aggregateSSE(res) {
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "", out = "";
  for (;;) {
    const step = await reader.read();
    if (step.done) break;
    buf += dec.decode(step.value, { stream: true });
    let idx;
    while ((idx = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (line.indexOf("data:") !== 0) continue;
      const data = line.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      try {
        const j = JSON.parse(data);
        if (Array.isArray(j)) out += textOf(j[0]);
        else if (j.choices) out += textOf(j.choices[0] && j.choices[0].delta);
        else out += textOf(j);
      } catch {}
    }
  }
  return out;
}

async function generate(args) {
  const body = {
    messages: [{ role: "user", content: String(args.prompt || "").trim() }],
    threadId: "mcp-" + randomUUID(),
    model: args.model || MODEL
  };
  const res = await fetch(BASE + "/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  if (!res.ok) throw new Error("openui HTTP " + res.status + ": " + (await res.text()).slice(0, 300));
  return await aggregateSSE(res);
}

const rl = createInterface({ input: process.stdin, terminal: false });
rl.on("line", function (line) {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (!msg || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") return;
  if (msg.method.indexOf("notifications/") === 0) return;
  const id = msg.id;
  (async function () {
    try {
      if (msg.method === "initialize") {
        result(id, { protocolVersion: (msg.params && msg.params.protocolVersion) || "2025-06-18", capabilities: { tools: {} }, serverInfo: SERVER });
      } else if (msg.method === "ping") {
        result(id, {});
      } else if (msg.method === "tools/list") {
        result(id, { tools: TOOLS });
      } else if (msg.method === "tools/call") {
        const name = msg.params && msg.params.name;
        const args = (msg.params && msg.params.arguments) || {};
        try {
          let text;
          if (name === "generate_ui") text = await generate(args);
          else if (name === "preview_url") text = PUBLIC_URL;
          else throw new Error("unknown tool: " + name);
          result(id, { content: [{ type: "text", text: String(text).slice(0, 200000) || "(empty response)" }], isError: false });
        } catch (err) {
          result(id, { content: [{ type: "text", text: String((err && err.message) || err).slice(0, 1000) }], isError: true });
        }
      } else if (id !== undefined) {
        protoError(id, -32601, "method not found: " + msg.method);
      }
    } catch (err) {
      if (id !== undefined) protoError(id, -32603, String((err && err.message) || err));
    }
  })();
});

