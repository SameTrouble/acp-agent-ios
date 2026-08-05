import { AcpClient } from "./acp";
import { loadConfig } from "./config";
import { CompanionServer } from "./server";

function log(level: string, message: string): void {
  console.log(`[${new Date().toISOString()}] ${level}: ${message}`);
}

async function main(): Promise<void> {
  const configArg = process.argv[2];
  const config = loadConfig(configArg);

  log("info", "spawning agent subprocess");
  const acp = AcpClient.spawn(config.agent, {
    stderr: (line) => log("agent", line),
  });

  try {
    const agentInfo = await acp.initialize();
    log("info", `agent initialized: ${JSON.stringify(agentInfo.agentInfo)}`);

    if (agentInfo.authMethods && agentInfo.authMethods.length > 0) {
      const method = agentInfo.authMethods[0]!;
      log("info", `authenticating with agent method ${method.id}`);
      await acp.request("authenticate", { methodId: method.id });
      log("info", "agent authentication succeeded");
    }

    const server = new CompanionServer({ config, acp, agentInfo });
    await server.listen();
    log("info", `companion listening on ${server.url} with ${config.tokens.length} token(s)`);

    const shutdown = async (signal: string): Promise<void> => {
      log("info", `received ${signal}, shutting down`);
      await server.stop();
      await acp.close();
      process.exit(0);
    };
    process.on("SIGINT", () => void shutdown("SIGINT"));
    process.on("SIGTERM", () => void shutdown("SIGTERM"));
  } catch (err) {
    log("error", `failed to start: ${(err as Error).message}`);
    await acp.close();
    process.exit(1);
  }
}

void main();