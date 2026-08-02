import assert from "node:assert/strict";
import { integrationCatalog, integrationDescriptor } from "../dist/integrations/catalog.js";

assert.equal(integrationCatalog.length, 5);
assert.equal(new Set(integrationCatalog.map((entry) => entry.id)).size, integrationCatalog.length);

const companion = integrationDescriptor("roblox-instance-manager");
assert.equal(companion.source.commit, "3a2456a871e1e1330790e964b17826518deabc80");
assert.equal(companion.source.release, "v1.0.1 (Minor-Changes)");
assert.match(companion.source.repository, /^https:\/\/github\.com\//);
assert.ok(companion.setup.length >= 3);

console.log("Integration catalog checks passed.");
