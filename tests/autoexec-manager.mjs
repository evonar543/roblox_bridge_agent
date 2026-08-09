import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const project = await readFile("tools/RbaAutoexecManager/RbaAutoexecManager.csproj", "utf8");
const service = await readFile("tools/RbaAutoexecManager/AutoexecService.cs", "utf8");
const form = await readFile("tools/RbaAutoexecManager/MainForm.cs", "utf8");
const commandLine = await readFile("tools/RbaAutoexecManager/CommandLine.cs", "utf8");
const svg = await readFile("tools/RbaAutoexecManager/assets/rba-autoexec-manager.svg", "utf8");
const loader = await readFile("lua/rba_autoloader.lua", "utf8");

assert.match(project, /EmbeddedResource Include="\.\.\\\.\.\\lua\\rba_autoloader\.lua"/);
assert.match(project, /PublishSingleFile>true/);
assert.match(project, /SelfContained>true/);
assert.match(service, /LoaderFileName = "rba_autoloader\.lua"/);
assert.match(service, /File\.Move\(status\.TargetPath, disabledPath\)/);
assert.match(service, /File\.Copy\(status\.TargetPath, backupPath/);
assert.match(form, /"Volt", "Potassium", "Custom"/);
assert.match(form, /Enabled and current/);
assert.match(commandLine, /--self-test/);
assert.match(commandLine, /LoaderState\.Outdated/);
assert.match(svg, /^<svg[\s\S]*<title[^>]*>RBA Autoexec Manager<\/title>[\s\S]*<\/svg>\s*$/);
assert.match(loader, /local LOADER_VERSION = "[^"]+"/);

console.log("RBA Autoexec Manager source checks passed");
