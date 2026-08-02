-- Recursive, non-executing ProtoProxy inspection for an authorized payload.

local ROOT = "rba_luarmor_trace"
local SOURCE_PATH = ROOT .. "/Fetched_20260801_183646.lua"
local OUTPUT_PATH = ROOT .. "/compile_capture/proto_manifest.json"
local MAX_PROTOS = 10000

assert(type(readfile) == "function", "readfile is unavailable")
assert(type(writefile) == "function", "writefile is unavailable")
assert(type(loadstring) == "function", "loadstring is unavailable")
assert(type(debug) == "table", "debug library is unavailable")
assert(type(debug.getprotos) == "function", "debug.getprotos is unavailable")
assert(type(debug.getconstants) == "function", "debug.getconstants is unavailable")
assert(type(debug.getinfo) == "function", "debug.getinfo is unavailable")

local HttpService = game:GetService("HttpService")
local source = readfile(SOURCE_PATH)
local root, compileError = loadstring(source, "authorized_luarmor_proto_manifest")
assert(root, compileError)

local entries = {}
local truncated = false

local function serializeConstant(value)
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
    if kind == "boolean" then
        return { type = kind, value = value }
    end
    if value == nil then
        return { type = "nil" }
    end
    return { type = kind, value = tostring(value) }
end

local function inspectProto(proto, path, depth)
    if #entries >= MAX_PROTOS then
        truncated = true
        return
    end

    local entry = {
        path = path,
        depth = depth,
        kind = typeof(proto),
    }

    local hashOk, codeHash = pcall(function()
        return proto.CodeHash
    end)
    if hashOk then
        entry.codeHash = codeHash
    end

    local infoOk, info = pcall(debug.getinfo, proto)
    if infoOk and type(info) == "table" then
        entry.info = {}
        for _, key in ipairs({ "name", "source", "short_src", "what", "numparams", "nups", "currentline", "linedefined" }) do
            local value = info[key]
            if value ~= nil then
                entry.info[key] = value
            end
        end
    else
        entry.infoError = tostring(info)
    end

    local constantsOk, constants = pcall(debug.getconstants, proto)
    if constantsOk and type(constants) == "table" then
        entry.constants = {}
        for index, value in ipairs(constants) do
            local serialized = serializeConstant(value)
            serialized.index = index
            entry.constants[#entry.constants + 1] = serialized
        end
    else
        entry.constantsError = tostring(constants)
    end

    local childrenOk, children = pcall(debug.getprotos, proto)
    if childrenOk and type(children) == "table" then
        entry.childCount = #children
    else
        entry.childCount = 0
        entry.childrenError = tostring(children)
        children = {}
    end

    entries[#entries + 1] = entry

    for index, child in ipairs(children) do
        inspectProto(child, path .. "." .. index, depth + 1)
        if truncated then
            break
        end
    end
end

inspectProto(root, "root", 0)

local manifest = {
    version = 1,
    executed = false,
    sourceBytes = #source,
    entryCount = #entries,
    truncated = truncated,
    entries = entries,
}

local json = HttpService:JSONEncode(manifest)
writefile(OUTPUT_PATH, json)

return {
    ok = true,
    executed = false,
    entryCount = #entries,
    truncated = truncated,
    jsonBytes = #json,
    outputPath = OUTPUT_PATH,
}
