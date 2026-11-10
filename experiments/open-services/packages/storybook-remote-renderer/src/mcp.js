// An MCP endpoint that exposes every registered toolset, core and
// third-party alike, and turns `data.image` into MCP image content.
// `@storybook/addon-mcp` can't do either today: its tool list is hard-coded
// and toolset outcomes are text only. Stateless JSON-RPC over HTTP POST.
import { toJsonSchema } from '@valibot/to-json-schema';
import { getService } from 'storybook/internal/core-server';
import { getRegisteredToolsets, invokeToolsetMethod, toMcpToolName } from 'storybook/open-service';

const PROTOCOL_VERSION = '2025-06-18';

function listTools() {
  const tools = new Map();
  for (const toolset of getRegisteredToolsets()) {
    for (const [methodName, method] of Object.entries(toolset.methods)) {
      tools.set(toMcpToolName(`${toolset.id}.${methodName}`), { toolset, methodName, method });
    }
  }
  return tools;
}

function schemaOf(schema) {
  if (schema?.['~standard']?.vendor !== 'valibot') return { type: 'object' };
  try {
    const { $schema, ...rest } = toJsonSchema(schema, { errorMode: 'ignore' });
    return rest;
  } catch {
    return { type: 'object' };
  }
}

async function callTool(tool, args, origin) {
  const parsed = await tool.method.input['~standard'].validate(args ?? {});
  if (parsed.issues) {
    return { content: [{ type: 'text', text: parsed.issues.map((i) => i.message).join('\n') }], isError: true };
  }
  try {
    const outcome = await invokeToolsetMethod(tool.toolset, tool.methodName, parsed.value, {
      transport: 'mcp',
      origin,
      getService: (id, options) => getService(id, options),
    });
    const { image, ...data } = outcome.data ?? {};
    const blocks = Array.isArray(outcome.markdown) ? outcome.markdown : [outcome.markdown];
    return {
      content: [
        ...blocks.map((text) => ({ type: 'text', text })),
        ...(image ? [{ type: 'image', mimeType: image.mimeType, data: image.data }] : []),
      ],
      structuredContent: data,
      ...(outcome.ok ? {} : { isError: true }),
    };
  } catch (error) {
    return { content: [{ type: 'text', text: String(error?.message ?? error) }], isError: true };
  }
}

async function handle(message, origin) {
  const { id, method, params } = message;
  const reply = (result) => ({ jsonrpc: '2.0', id, result });
  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: params?.protocolVersion ?? PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: 'storybook-remote-renderer', version: '0.0.0' },
      });
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({
        tools: [...listTools()].map(([name, { toolset, method }]) => ({
          name,
          title: method.title,
          description: typeof method.description === 'function' ? method.description({ transport: 'mcp', origin }) : method.description,
          inputSchema: schemaOf(method.input),
          annotations: { toolset: toolset.id },
        })),
      });
    case 'tools/call': {
      const tool = listTools().get(params?.name);
      if (!tool) return { jsonrpc: '2.0', id, error: { code: -32602, message: `Unknown tool ${params?.name}` } };
      return reply(await callTool(tool, params.arguments, origin));
    }
    default:
      if (id === undefined) return undefined; // notification
      return { jsonrpc: '2.0', id, error: { code: -32601, message: `Unknown method ${method}` } };
  }
}

export function mountMcp(app, { path, origin }) {
  app.post(path, async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    let message;
    try {
      message = JSON.parse(body);
    } catch {
      res.statusCode = 400;
      return res.end('Invalid JSON');
    }
    const result = Array.isArray(message)
      ? (await Promise.all(message.map((m) => handle(m, origin)))).filter(Boolean)
      : await handle(message, origin);
    if (result === undefined || (Array.isArray(result) && result.length === 0)) {
      res.statusCode = 202;
      return res.end();
    }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify(result));
  });
}
