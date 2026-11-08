// Entry point for Paperclip's MCP server on the agents VM.
//
// Paperclip refuses an agent's changes without the id of the run they belong
// to (X-Paperclip-Run-Id). The upstream server reads that id from
// PAPERCLIP_RUN_ID once, when it starts, but Hermes starts one server per
// agent and keeps it across runs. So every tool here also takes the run id
// as an argument, and that call's requests carry it. Calls from different
// runs can overlap, so the id travels with the call, not in shared state.
//
// Local models leave that argument out now and then, though the wake prompt
// gives them the id. A change without one goes out under the agent's own run
// in progress, when it has exactly one. With none or several it goes out
// without, and Paperclip refuses it as it always did. The agent's key can
// list its own runs anyway, so this finds nothing the agent couldn't.
import { AsyncLocalStorage } from "node:async_hooks";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createPaperclipMcpServer } from "@paperclipai/mcp-server";
import { z } from "zod";

const call = new AsyncLocalStorage();

// Upstream's tools and the client they call; its own server is left unused.
const { tools, client } = createPaperclipMcpServer();
const fromEnv = client.config;
client.config = {
  ...fromEnv,
  get runId() {
    return call.getStore()?.runId ?? fromEnv.runId;
  },
};

const request = client.requestJson.bind(client);
let me;

// The agent's one run in progress, or null.
async function liveRun() {
  me ??= await request("GET", "/agents/me");
  const query = new URLSearchParams({ agentId: me.id, limit: "20" });
  const runs = await request("GET", `/companies/${encodeURIComponent(me.companyId)}/heartbeat-runs?${query}`);
  const running = (Array.isArray(runs) ? runs : []).filter((run) => run?.status === "running");
  return running.length === 1 && typeof running[0].id === "string" ? running[0].id : null;
}

client.requestJson = async (method, path, options = {}) => {
  const store = call.getStore();
  const writes = options.includeRunId ?? !["GET", "HEAD"].includes(method.toUpperCase());
  if (writes && store && !store.runId && !fromEnv.runId) {
    try {
      store.runId = await liveRun();
    } catch {
      // Left out; Paperclip's refusal says why.
    }
  }
  return request(method, path, options);
};

const runIdShape = {
  paperclipRunId: z
    .string()
    .guid()
    .optional()
    .describe(
      "The Run ID under \"Paperclip runtime identity\" in your wake prompt. " +
        "Paperclip refuses changes without it, so pass it on every call that changes something.",
    ),
};

const server = new McpServer({ name: "paperclip", version: "0.1.0" });
for (const tool of tools) {
  server.tool(tool.name, tool.description, { ...tool.schema.shape, ...runIdShape }, ({ paperclipRunId, ...input }) =>
    call.run({ runId: paperclipRunId }, () => tool.execute(input)),
  );
}

try {
  await server.connect(new StdioServerTransport());
} catch (error) {
  console.error("Failed to start Paperclip MCP server:", error);
  process.exit(1);
}
