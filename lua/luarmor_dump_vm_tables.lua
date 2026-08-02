-- Dump non-function VM tables without invoking decoder or interpreter methods.

local OUTPUT_PATH = "rba_luarmor_trace/vm_object/internal_tables.json"
local TABLE_NAMES = { "D", "_", "h", "l" }
local vmObject = rawget(getgenv(), "__RBA_LUARMOR_VM_OBJECT")
assert(type(vmObject) == "table", "VM object is not present")

local function summarize(value, depth, seen)
    local kind = typeof(value)
    if kind == "string" then
        return {
            type = kind,
            byteLength = #value,
            valueBase64 = crypt.base64.encode(value),
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
    if kind == "function" then
        local infoOk, info = pcall(debug.getinfo, value)
        local result = { type = kind, value = tostring(value) }
        if infoOk and type(info) == "table" then
            result.numparams = info.numparams
            result.nups = info.nups
            result.source = info.source
            result.linedefined = info.linedefined
        end
        local constantsOk, constants = pcall(debug.getconstants, value)
        if constantsOk and type(constants) == "table" then
            result.constantCount = #constants
        end
        return result
    end
    if kind ~= "table" then
        return { type = kind, value = tostring(value) }
    end
    if seen[value] then
        return { type = kind, cycle = true }
    end
    seen[value] = true

    local result = { type = kind, itemCount = 0, items = {} }
    if depth <= 0 then
        result.truncatedDepth = true
        return result
    end
    for key, item in pairs(value) do
        result.itemCount = result.itemCount + 1
        if #result.items < 5000 then
            result.items[#result.items + 1] = {
                key = summarize(key, 0, seen),
                value = summarize(item, depth - 1, seen),
            }
        else
            result.truncatedItems = true
        end
    end
    return result
end

local tables = {}
for _, name in ipairs(TABLE_NAMES) do
    tables[name] = summarize(rawget(vmObject, name), 8, {})
end

local manifest = {
    version = 1,
    executed = false,
    tables = tables,
}
local json = game:GetService("HttpService"):JSONEncode(manifest)
writefile(OUTPUT_PATH, json)

return {
    ok = true,
    executed = false,
    jsonBytes = #json,
    outputPath = OUTPUT_PATH,
}
