-- Run Luarmor setup through u3, then stop at U5 before the interpreter.

local OUTPUT_PATH = "rba_luarmor_trace/vm_object/checkpoint_before_u5.json"
local vmObject = rawget(getgenv(), "__RBA_LUARMOR_VM_OBJECT")
assert(type(vmObject) == "table", "VM object is not present")
assert(type(vmObject.A) == "function", "VM A entry method is absent")
assert(type(vmObject.U5) == "function", "VM U5 boundary method is absent")

local function summarize(value, depth, seen)
    local kind = typeof(value)
    if kind == "string" then
        local prefixLength = math.min(#value, 128)
        return {
            type = kind,
            byteLength = #value,
            prefixBase64 = crypt.base64.encode(string.sub(value, 1, prefixLength)),
            prefixBytes = prefixLength,
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
        if #result.items < 1000 then
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

local captured
local originalU5 = vmObject.U5
vmObject.U5 = function(self, state, context, cursor)
    captured = {
        state = state,
        context = context,
        cursor = cursor,
    }
    -- A assigns these to y, J, B and exits when y == -2.
    return -2, nil, { checkpoint = "before_U5" }
end

local ok, result = pcall(vmObject.A, vmObject)
vmObject.U5 = originalU5

assert(captured, "A did not reach the U5 checkpoint: " .. tostring(result))
getgenv().__RBA_LUARMOR_U5_CHECKPOINT = captured

local manifest = {
    version = 1,
    protectedInterpreterExecuted = false,
    checkpoint = "before_U5",
    callOk = ok,
    callResult = summarize(result, 2, {}),
    state = summarize(captured.state, 4, {}),
    context = summarize(captured.context, 4, {}),
    cursor = summarize(captured.cursor, 4, {}),
}

local json = game:GetService("HttpService"):JSONEncode(manifest)
writefile(OUTPUT_PATH, json)

return {
    ok = ok,
    protectedInterpreterExecuted = false,
    checkpointReached = true,
    manifestBytes = #json,
    outputPath = OUTPUT_PATH,
}
