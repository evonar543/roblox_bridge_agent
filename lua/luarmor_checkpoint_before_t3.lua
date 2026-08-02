-- Run Luarmor setup only until the T3 boundary, then force A's built-in exit.
-- U5 and vm cannot be reached while the checkpoint stub is installed.

local OUTPUT_PATH = "rba_luarmor_trace/vm_object/checkpoint_before_t3.json"
local vmObject = rawget(getgenv(), "__RBA_LUARMOR_VM_OBJECT")
assert(type(vmObject) == "table", "VM object is not present")
assert(type(vmObject.A) == "function", "VM A entry method is absent")
assert(type(vmObject.T3) == "function", "VM T3 boundary method is absent")

local function summarize(value, depth, seen)
    local kind = typeof(value)
    if kind == "string" then
        local prefixLength = math.min(#value, 96)
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
        if #result.items < 500 then
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
local originalT3 = vmObject.T3
vmObject.T3 = function(self, state, cursor, context)
    captured = {
        state = state,
        cursor = cursor,
        context = context,
    }
    -- A assigns these to y, J, B and exits when y == -2.
    return -2, nil, { checkpoint = "before_T3" }
end

local ok, result = pcall(vmObject.A, vmObject)
vmObject.T3 = originalT3

assert(captured, "A did not reach the T3 checkpoint: " .. tostring(result))
getgenv().__RBA_LUARMOR_T3_CHECKPOINT = captured

local manifest = {
    version = 1,
    protectedInterpreterExecuted = false,
    checkpoint = "before_T3",
    callOk = ok,
    callResult = summarize(result, 2, {}),
    state = summarize(captured.state, 3, {}),
    cursor = summarize(captured.cursor, 3, {}),
    context = summarize(captured.context, 3, {}),
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
