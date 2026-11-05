// Entry point for Paperclip's MCP server on the agents VM.
//
// Paperclip refuses an agent's changes without the id of the run they belong
// to (X-Paperclip-Run-Id). The upstream server reads that id from
// PAPERCLIP_RUN_ID once, when it starts, but Hermes starts one server per
// agent and keeps it across runs. So every tool here also takes the run id
// as an argument, and that call's requests carry it. Calls from different
// runs can overlap, so the id travels with the call, not in shared state.
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
    return call.getStore() ?? fromEnv.runId;
  },
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
    call.run(paperclipRunId, () => tool.execute(input)),
  );
}

try {
  await server.connect(new StdioServerTransport());
} catch (error) {
  console.error("Failed to start Paperclip MCP server:", error);
  process.exit(1);
}
