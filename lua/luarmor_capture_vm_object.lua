-- Instantiate only the Luarmor VM method table without invoking its A entrypoint.

local ROOT = "rba_luarmor_trace"
local BOOTSTRAP_PATH = ROOT .. "/obsfucated..lua"
local SOURCE_PATH = ROOT .. "/Fetched_20260801_183646.lua"
local OUTPUT_PATH = ROOT .. "/vm_object"
local MANIFEST_PATH = OUTPUT_PATH .. "/manifest.json"

assert(type(readfile) == "function", "readfile is unavailable")
assert(type(writefile) == "function", "writefile is unavailable")
assert(type(loadstring) == "function", "loadstring is unavailable")

pcall(makefolder, ROOT)
pcall(makefolder, OUTPUT_PATH)

local bootstrap = readfile(BOOTSTRAP_PATH)
local metadataAssignment = bootstrap:match("_bsdata0%s*=%s*%b{}%s*;")
assert(metadataAssignment, "could not isolate _bsdata0 metadata assignment")

local metadataChunk, metadataError = loadstring(metadataAssignment, "authorized_bsdata0_only")
assert(metadataChunk, metadataError)
metadataChunk()
assert(type(_bsdata0) == "table", "_bsdata0 metadata was not initialized")

local source = readfile(SOURCE_PATH)
local modified, replacementCount = source:gsub("%}%):A%(%)%(%.%.%.%);%s*$", "});")
assert(replacementCount == 1, "expected exactly one VM entrypoint suffix")

local chunk, compileError = loadstring(modified, "authorized_luarmor_vm_object_only")
assert(chunk, compileError)
local chunkEnvironment = getfenv(chunk)

-- The modified chunk evaluates its data/table literals and returns the method
-- table. It cannot call :A(), because that expression was removed in memory.
local vmObject = chunk()
assert(type(vmObject) == "table", "modified chunk did not return the VM table")

local function jsonSafe(value)
    local kind = typeof(value)
    if kind == "string" then
        return {
            type = kind,
            encoding = "base64",
            byteLength = #value,
            value = crypt.base64.encode(value),
        }
    end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return { type = kind, value = tostring(value) }
        end
        return { type = kind, value = value }
    end
    if kind == "boolean" or kind == "nil" then
        return { type = kind, value = value }
    end
    return { type = kind, value = tostring(value) }
end

local members = {}
local functionCount = 0
for key, value in pairs(vmObject) do
    local member = {
        key = jsonSafe(key),
        value = jsonSafe(value),
    }
    if type(value) == "function" then
        functionCount = functionCount + 1
        local infoOk, info = pcall(debug.getinfo, value)
        if infoOk and type(info) == "table" then
            member.info = {}
            for _, name in ipairs({ "name", "source", "short_src", "what", "numparams", "nups", "linedefined" }) do
                if info[name] ~= nil then
                    member.info[name] = info[name]
                end
            end
        end

        local constantsOk, constants = pcall(debug.getconstants, value)
        if constantsOk and type(constants) == "table" then
            member.constantCount = #constants
        end

        local protosOk, protos = pcall(debug.getprotos, value)
        if protosOk and type(protos) == "table" then
            member.protoCount = #protos
        end
    end
    members[#members + 1] = member
end

local bytecodeChunks = rawget(chunkEnvironment, "superflow_bytecode")
local chunkCount = type(bytecodeChunks) == "table" and #bytecodeChunks or 0
local encodedBytes = 0
if type(bytecodeChunks) == "table" then
    for _, value in ipairs(bytecodeChunks) do
        if type(value) == "string" then
            encodedBytes = encodedBytes + #value
        end
    end
end

local manifest = {
    version = 1,
    protectedEntrypointExecuted = false,
    replacementCount = replacementCount,
    metadataFieldCount = #_bsdata0,
    sourceBytes = #source,
    modifiedBytes = #modified,
    memberCount = #members,
    functionCount = functionCount,
    superflowChunkCount = chunkCount,
    superflowEncodedBytes = encodedBytes,
    members = members,
}

local json = game:GetService("HttpService"):JSONEncode(manifest)
writefile(MANIFEST_PATH, json)

-- Keep the instantiated object available only for later inspection scripts.
getgenv().__RBA_LUARMOR_VM_OBJECT = vmObject
getgenv().__RBA_LUARMOR_BYTECODE_CHUNKS = bytecodeChunks

return {
    ok = true,
    protectedEntrypointExecuted = false,
    replacementCount = replacementCount,
    metadataFieldCount = #_bsdata0,
    memberCount = #members,
    functionCount = functionCount,
    superflowChunkCount = chunkCount,
    superflowEncodedBytes = encodedBytes,
    manifestBytes = #json,
    manifestPath = MANIFEST_PATH,
}
