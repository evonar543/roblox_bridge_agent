-- Decompile bytecode captured by luarmor_compile_capture.lua.
-- This never invokes the protected closure or its VM entrypoint.

local ROOT = "rba_luarmor_trace/compile_capture"
local BYTECODE_PATH = ROOT .. "/main.luau-bytecode"
local OUTPUT_PATH = ROOT .. "/main_decompiled.luau"

assert(type(readfile) == "function", "readfile is unavailable")
assert(type(writefile) == "function", "writefile is unavailable")
assert(type(decompile) == "function", "decompile is unavailable")

local bytecode = readfile(BYTECODE_PATH)
local options = DecompilerOptions and DecompilerOptions.new and DecompilerOptions.new() or nil

if options then
    options.SmartVariableRenamer = true
    options.FunctionDeclarations = true
    options.GuardClauses = true
    options.ConstantFolding = true
    options.ConditionalStructurer = true
    options.DoBlockInsertionThreshold = 0
    if options.Formatter then
        options.Formatter.IndentWidth = 4
        options.Formatter.ColumnLimit = 120
        options.Formatter.FunctionMetadataEnabled = true
    end
end

local source = decompile(bytecode, options)
writefile(OUTPUT_PATH, source)

return {
    ok = true,
    executed = false,
    bytecodeBytes = #bytecode,
    decompiledBytes = #source,
    outputPath = OUTPUT_PATH,
}
