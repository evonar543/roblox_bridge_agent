-- Controlled dynamic tracer for an authorized Luarmor-protected Roblox script.
-- The original files remain outside the RBA workspace and are never modified.

local INPUT_ROOT = "rba_luarmor_trace"
local OUTPUT_ROOT = INPUT_ROOT .. "/dynamic"
local BOOTSTRAP_PATH = INPUT_ROOT .. "/obsfucated..lua"
local PAYLOAD_PATH = INPUT_ROOT .. "/Fetched_20260801_183646.lua"
local EXPECTED_URL = "https://cdn.luarmor.net/v4_init_marbeg.lua"

local native = {
    loadstring = loadstring,
    readfile = readfile,
    writefile = writefile,
    makefolder = makefolder,
    getgenv = getgenv,
    getfenv = getfenv,
    setfenv = setfenv,
}

assert(type(native.loadstring) == "function", "loadstring is unavailable")
assert(type(native.readfile) == "function", "readfile is unavailable")
assert(type(native.writefile) == "function", "writefile is unavailable")

pcall(native.makefolder, INPUT_ROOT)
pcall(native.makefolder, OUTPUT_ROOT)

local trace = {}
local dumps = {}

local function describe(value)
    local kind = type(value)
    if kind == "string" then
        return string.format("string[%d]", #value)
    end
    return kind .. ":" .. tostring(value)
end

local function record(event, detail)
    trace[#trace + 1] = string.format("%04d | %s | %s", #trace + 1, event, tostring(detail or ""))
end

local payload = native.readfile(PAYLOAD_PATH)
local bootstrap = native.readfile(BOOTSTRAP_PATH)
record("input", "bootstrap_bytes=" .. #bootstrap .. " payload_bytes=" .. #payload)

local base = native.getgenv and native.getgenv() or _G
local sandbox = {}

setmetatable(sandbox, {
    __index = base,
    __newindex = function(target, key, value)
        record("global_write", tostring(key) .. "=" .. describe(value))
        rawset(target, key, value)
    end,
})

sandbox._G = sandbox
sandbox.getgenv = function()
    record("getgenv", "sandbox")
    return sandbox
end
sandbox.getfenv = function(level)
    record("getfenv", tostring(level))
    if level == nil or level == 0 or level == 1 then
        return sandbox
    end
    return native.getfenv(level)
end

sandbox.readfile = function(path)
    record("readfile_blocked", path)
    error("sandbox cache miss", 0)
end
sandbox.isfile = function(path)
    record("isfile", path)
    return false
end
sandbox.makefolder = function(path)
    record("makefolder_blocked", path)
end
sandbox.writefile = function(path, data)
    record("writefile_blocked", tostring(path) .. " bytes=" .. tostring(type(data) == "string" and #data or -1))
end
sandbox.appendfile = function(path, data)
    record("appendfile_blocked", tostring(path) .. " bytes=" .. tostring(type(data) == "string" and #data or -1))
end
sandbox.delfile = function(path)
    record("delfile_blocked", path)
end
sandbox.listfiles = function(path)
    record("listfiles_blocked", path)
    return {}
end
sandbox.setclipboard = function(value)
    record("clipboard_blocked", describe(value))
end
sandbox.queue_on_teleport = function(value)
    record("queue_on_teleport_blocked", describe(value))
end
sandbox.queueonteleport = sandbox.queue_on_teleport

local gameProxy = {}
setmetatable(gameProxy, {
    __index = function(_, key)
        if key == "HttpGet" or key == "HttpGetAsync" then
            return function(_, url)
                record("http_get", url)
                if string.sub(url, 1, #EXPECTED_URL) == EXPECTED_URL then
                    return payload
                end
                error("sandbox blocked HTTP GET: " .. tostring(url), 0)
            end
        end
        if key == "Shutdown" then
            return function()
                record("shutdown_blocked", "")
            end
        end
        return game[key]
    end,
})
sandbox.game = gameProxy

local compileCount = 0
sandbox.loadstring = function(source, chunkName)
    compileCount = compileCount + 1
    local name = chunkName or ("dynamic_stage_" .. compileCount)
    record("loadstring", name .. " bytes=" .. tostring(type(source) == "string" and #source or -1))

    if type(source) == "string" then
        dumps[#dumps + 1] = { name = name, source = source }
    end

    local fn, compileError = native.loadstring(source, name)
    if not fn then
        record("compile_error", compileError)
        return nil, compileError
    end

    if native.setfenv then
        native.setfenv(fn, sandbox)
    end
    return fn
end

local runner, compileError = sandbox.loadstring(bootstrap, "authorized_bootstrap")
assert(runner, compileError)

local ok, result = xpcall(runner, function(message)
    local traceback = debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
    record("runtime_error", traceback)
    return traceback
end)
record("result", "ok=" .. tostring(ok) .. " value=" .. describe(result))

for index, dump in ipairs(dumps) do
    local safeName = tostring(dump.name):gsub("[^%w_.-]", "_")
    local path = string.format("%s/stage_%02d_%s.lua", OUTPUT_ROOT, index, safeName)
    local wrote, writeError = pcall(native.writefile, path, dump.source)
    record("dump", path .. " ok=" .. tostring(wrote) .. (writeError and (" error=" .. tostring(writeError)) or ""))
end

local tracePath = OUTPUT_ROOT .. "/trace.log"
native.writefile(tracePath, table.concat(trace, "\n") .. "\n")

return {
    ok = ok,
    result = describe(result),
    tracePath = tracePath,
    eventCount = #trace,
    dumpCount = #dumps,
    compileCount = compileCount,
}
