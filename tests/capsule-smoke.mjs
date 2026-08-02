import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverPath = path.join(repoRoot, "dist", "index.js");
const testRoot = await fs.mkdtemp(path.join(tmpdir(), "rba-capsule-smoke-"));
const scriptPath = path.join(testRoot, "lua", "example.lua");

let child;
let stderr = "";
let stdoutBuffer = "";
let nextRequestId = 1;
const pending = new Map();

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function request(method, params = {}) {
  const id = nextRequestId++;
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for ${method}.\n${stderr}`));
    }, 10_000);
    pending.set(id, {
      resolve(value) {
        clearTimeout(timeout);
        resolve(value);
      }
    });
  });
}

function toolPayload(response) {
  assert.equal(response?.result?.isError, undefined, "MCP tool call should not return an error");
  const text = response?.result?.content?.find((entry) => entry.type === "text")?.text;
  assert.equal(typeof text, "string", "MCP tool call should return JSON text content");
  return JSON.parse(text);
}

try {
  await fs.mkdir(path.dirname(scriptPath), { recursive: true });
  await fs.writeFile(scriptPath, "return { revision = 1 }\n", "utf8");

  child = spawn(process.execPath, [serverPath], {
    cwd: repoRoot,
    windowsHide: true,
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      RBA_ROOT: testRoot,
      RBA_AUTO_START_WS: "false",
      RBA_SYNC_AUTOEXEC: "false",
      RBA_AUTOEXEC_INCLUDE_DEFAULTS: "false"
    }
  });

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    for (;;) {
      const newline = stdoutBuffer.indexOf("\n");
      if (newline < 0) break;
      const line = stdoutBuffer.slice(0, newline).trim();
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      const waiter = pending.get(message.id);
      if (waiter) {
        pending.delete(message.id);
        waiter.resolve(message);
      }
    }
  });

  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "rba-capsule-smoke", version: "1.0.0" }
  });

  const listed = await request("tools/list");
  const toolNames = listed.result.tools.map((tool) => tool.name);
  for (const required of [
    "rba_create_script_capsule",
    "rba_capsule_snapshot",
    "rba_list_capsule_snapshots",
    "rba_rollback_script_capsule",
    "rba_run_script_capsule",
    "rba_git_status"
  ]) {
    assert.ok(toolNames.includes(required), `Expected MCP tool ${required}`);
  }

  const created = toolPayload(await request("tools/call", {
    name: "rba_create_script_capsule",
    arguments: { id: "smoke", name: "Smoke capsule", path: "lua/example.lua", permissions: [] }
  }));
  assert.equal(created.ok, true);

  const firstSnapshot = toolPayload(await request("tools/call", {
    name: "rba_capsule_snapshot",
    arguments: { id: "smoke", reason: "before_edit" }
  }));
  assert.equal(firstSnapshot.ok, true);
  assert.equal(typeof firstSnapshot.snapshotId, "string");

  await fs.writeFile(scriptPath, "return { revision = 2 }\n", "utf8");
  const rollback = toolPayload(await request("tools/call", {
    name: "rba_rollback_script_capsule",
    arguments: { id: "smoke", snapshotId: firstSnapshot.snapshotId }
  }));
  assert.equal(rollback.ok, true);
  assert.equal(await fs.readFile(scriptPath, "utf8"), "return { revision = 1 }\n");

  const snapshots = toolPayload(await request("tools/call", {
    name: "rba_list_capsule_snapshots",
    arguments: { id: "smoke" }
  }));
  assert.ok(Array.isArray(snapshots));
  assert.ok(snapshots.length >= 2, "Rollback should preserve a safety snapshot of the edited source");

  console.log("Script capsule smoke checks passed.");
} finally {
  if (child && child.exitCode === null) {
    child.kill();
    await Promise.race([once(child, "exit"), delay(3000)]);
  }
  await fs.rm(testRoot, { recursive: true, force: true });
}
