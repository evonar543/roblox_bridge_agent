-- Compile-only inspection for an authorized Luarmor payload.
-- IMPORTANT: the compiled closure is never invoked.

local ROOT = "rba_luarmor_trace"
local SOURCE_PATH = ROOT .. "/Fetched_20260801_183646.lua"
local OUTPUT_PATH = ROOT .. "/compile_capture"

assert(type(readfile) == "function", "readfile is unavailable")
assert(type(writefile) == "function", "writefile is unavailable")
assert(type(loadstring) == "function", "loadstring is unavailable")
assert(type(getfunctionbytecode) == "function", "getfunctionbytecode is unavailable")

pcall(makefolder, ROOT)
pcall(makefolder, OUTPUT_PATH)

local source = readfile(SOURCE_PATH)
local closure, compileError = loadstring(source, "authorized_luarmor_compile_only")
assert(closure, compileError)

-- Do not call closure(). Its VM entrypoint is intentionally left dormant.
local bytecode = getfunctionbytecode(closure)
writefile(OUTPUT_PATH .. "/main.luau-bytecode", bytecode)

local metadata = {
    "source_bytes=" .. tostring(#source),
    "bytecode_bytes=" .. tostring(#bytecode),
    "closure_type=" .. tostring(type(closure)),
}

local function captureCount(label, callback)
    local ok, values = pcall(callback)
    if ok and type(values) == "table" then
        metadata[#metadata + 1] = label .. "=" .. tostring(#values)
    else
        metadata[#metadata + 1] = label .. "_error=" .. tostring(values)
    end
end

captureCount("constant_count", function()
    return debug.getconstants(closure)
end)

captureCount("proto_count", function()
    return debug.getprotos(closure)
end)

captureCount("upvalue_count", function()
    return debug.getupvalues(closure)
end)

local infoOk, info = pcall(debug.getinfo, closure)
if infoOk and type(info) == "table" then
    for _, key in ipairs({ "name", "source", "short_src", "what", "numparams", "nups" }) do
        metadata[#metadata + 1] = "info_" .. key .. "=" .. tostring(info[key])
    end
else
    metadata[#metadata + 1] = "info_error=" .. tostring(info)
end

writefile(OUTPUT_PATH .. "/metadata.txt", table.concat(metadata, "\n") .. "\n")

return {
    ok = true,
    executed = false,
    sourceBytes = #source,
    bytecodeBytes = #bytecode,
    outputPath = OUTPUT_PATH,
    metadata = metadata,
}
