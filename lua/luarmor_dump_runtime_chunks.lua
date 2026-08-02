-- Dump the already-instantiated superflow bytecode strings without decoding them.

local OUTPUT_ROOT = "rba_luarmor_trace/vm_object/runtime_chunks"
local chunks = rawget(getgenv(), "__RBA_LUARMOR_BYTECODE_CHUNKS")
assert(type(chunks) == "table", "runtime bytecode chunks are unavailable")

pcall(makefolder, "rba_luarmor_trace/vm_object")
pcall(makefolder, OUTPUT_ROOT)

local manifest = {
    version = 1,
    decoded = false,
    executed = false,
    chunkCount = #chunks,
    totalBytes = 0,
    chunks = {},
}

for index, value in ipairs(chunks) do
    assert(type(value) == "string", "runtime chunk is not a string")
    local path = string.format("%s/chunk_%02d.bin", OUTPUT_ROOT, index)
    writefile(path, value)
    manifest.totalBytes = manifest.totalBytes + #value
    manifest.chunks[#manifest.chunks + 1] = {
        index = index,
        bytes = #value,
        path = path,
        prefixBase64 = crypt.base64.encode(string.sub(value, 1, math.min(#value, 64))),
    }
end

local json = game:GetService("HttpService"):JSONEncode(manifest)
writefile(OUTPUT_ROOT .. "/manifest.json", json)

return {
    ok = true,
    executed = false,
    chunkCount = manifest.chunkCount,
    totalBytes = manifest.totalBytes,
    outputRoot = OUTPUT_ROOT,
}
