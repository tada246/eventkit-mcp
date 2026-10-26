#!/usr/bin/env node
import { McpServer, fromJsonSchema } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { cliBin } from "./cli.js";
import { TOOLS, runTool, type ToolArgs } from "./tools.js";

const handle = serveStdio(() => {
  const server = new McpServer({ name: "eventkit-mcp", version: "2.0.0" });

  for (const tool of TOOLS) {
    server.registerTool(
      tool.name,
      {
        title: tool.title,
        description: tool.description,
        inputSchema: fromJsonSchema<ToolArgs>(tool.inputSchema),
        ...(tool.annotations ? { annotations: tool.annotations } : {}),
      },
      async (args) => runTool(tool, args as ToolArgs)
    );
  }

  return server;
});

process.on("SIGINT", () => void handle.close());
console.error(`eventkit-mcp listening on stdio (binary: ${cliBin()})`);
