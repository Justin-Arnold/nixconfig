// Runs run-id.mjs, as Hermes does, against a fake Paperclip, and checks
// which run each change goes out under.
//
// usage: node test.mjs <run-id.mjs>   (with the package's node_modules beside it)
import { createServer } from "node:http";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const [script] = process.argv.slice(2);
const KEY = "pcp_" + "5a".repeat(24);
const PASSED = "11111111-1111-4111-8111-111111111111";
const LIVE = "22222222-2222-4222-8222-222222222222";
const OTHER = "33333333-3333-4333-8333-333333333333";

const state = { runs: [] };
const seen = [];
const fake = createServer((req, res) => {
  const url = new URL(req.url, "http://fake");
  seen.push({ method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams),
              runId: req.headers["x-paperclip-run-id"] ?? null, auth: req.headers.authorization });
  const reply = (code, body) => {
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  };
  if (req.headers.authorization !== `Bearer ${KEY}`) return reply(401, { error: "Unauthorized" });
  if (req.method === "GET" && url.pathname === "/api/agents/me") return reply(200, { id: "a1", companyId: "c1" });
  if (req.method === "GET" && url.pathname === "/api/companies/c1/heartbeat-runs") return reply(200, state.runs);
  if (url.pathname === "/api/issues/i1") {
    if (req.method === "GET") return reply(200, { id: "i1", status: "in_progress" });
    if (!req.headers["x-paperclip-run-id"]) return reply(401, { error: "Agent run id required" });
    return reply(200, { id: "i1", status: "done" });
  }
  reply(404, { error: "not found" });
});
await new Promise((resolve) => fake.listen(0, "127.0.0.1", resolve));

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [script],
  env: { PATH: process.env.PATH ?? "", PAPERCLIP_API_URL: `http://127.0.0.1:${fake.address().port}`, PAPERCLIP_API_KEY: KEY },
  stderr: "pipe",
});
const mcp = new Client({ name: "test", version: "0" });
await mcp.connect(transport);

let failures = 0;
function check(what, ok) {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}`);
  if (!ok) failures += 1;
}

async function run(name, args) {
  seen.length = 0;
  const result = await mcp.callTool({ name, arguments: args });
  const text = result.content?.map((c) => c.text).join("") ?? "";
  // Upstream answers a refusal as the tool's text, not as an MCP error.
  return { text, refused: Boolean(result.isError) || / failed with \d{3}/.test(text), seen: [...seen] };
}

const patches = (r) => r.seen.filter((s) => s.method === "PATCH");
const lookups = (r) => r.seen.filter((s) => s.path.endsWith("/heartbeat-runs"));

const tools = (await mcp.listTools()).tools;
check("every tool takes paperclipRunId", tools.length > 20 && tools.every((t) => t.inputSchema?.properties?.paperclipRunId));

state.runs = [{ id: LIVE, status: "running" }, { id: OTHER, status: "succeeded" }];
let r = await run("paperclipUpdateIssue", { issueId: "i1", status: "done", paperclipRunId: PASSED });
check("a change that names its run goes out under it, and nothing is looked up",
      patches(r)[0]?.runId === PASSED && lookups(r).length === 0 && !r.refused);

r = await run("paperclipUpdateIssue", { issueId: "i1", status: "done" });
check("one that doesn't goes out under the agent's one run in progress", patches(r)[0]?.runId === LIVE && !r.refused);
check("  ...found among the agent's own runs", lookups(r)[0]?.query.agentId === "a1" && lookups(r)[0]?.query.limit === "20");
check("  ...and the lookups carry no run id themselves", r.seen.filter((s) => s.method === "GET").every((s) => s.runId === null));

r = await run("paperclipUpdateIssue", { issueId: "i1", status: "done" });
check("who the agent is is asked once, then kept", !r.seen.some((s) => s.path === "/api/agents/me"));

r = await run("paperclipGetIssue", { issueId: "i1" });
check("a read looks nothing up and carries no run id", lookups(r).length === 0 && r.seen.every((s) => s.runId === null));

state.runs = [{ id: LIVE, status: "running" }, { id: OTHER, status: "running" }];
r = await run("paperclipUpdateIssue", { issueId: "i1", status: "done" });
check("with two runs in progress it guesses neither, and Paperclip refuses it",
      patches(r)[0]?.runId === null && r.refused && r.text.includes("Agent run id required"));

state.runs = [{ id: OTHER, status: "succeeded" }];
r = await run("paperclipUpdateIssue", { issueId: "i1", status: "done" });
check("with none in progress it goes out without, as before", patches(r)[0]?.runId === null && r.refused);

check("the key never reaches a result", ![r.text].some((t) => t.includes(KEY)));

await mcp.close();
fake.close();
if (failures) {
  console.log(`${failures} check(s) failed`);
  process.exit(1);
}
console.log("all checks passed");
