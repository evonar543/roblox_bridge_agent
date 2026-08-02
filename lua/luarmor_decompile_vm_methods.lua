-- Decompile selected instantiated VM methods without calling any method.

local OUTPUT_ROOT = "rba_luarmor_trace/vm_object/methods"
local SELECTED = {
    "A", "z3", "u3", "Vm", "T3", "C", "F3", "H3", "O3", "Q3",
    "U5", "vm", "X", "y3", "Y3", "w3", "Mm", "Nm", "Qm", "Sm",
}

assert(type(writefile) == "function", "writefile is unavailable")
assert(type(getfunctionbytecode) == "function", "getfunctionbytecode is unavailable")
assert(type(decompile) == "function", "decompile is unavailable")

local vmObject = rawget(getgenv(), "__RBA_LUARMOR_VM_OBJECT")
assert(type(vmObject) == "table", "VM object is not present; run luarmor_capture_vm_object.lua first")

pcall(makefolder, "rba_luarmor_trace/vm_object")
pcall(makefolder, OUTPUT_ROOT)

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

local results = {}
for _, name in ipairs(SELECTED) do
    local closure = rawget(vmObject, name)
    local result = { name = name, found = type(closure) == "function" }

    if result.found then
        local bytecodeOk, bytecode = pcall(getfunctionbytecode, closure)
        result.bytecodeOk = bytecodeOk
        if bytecodeOk then
            result.bytecodeBytes = #bytecode
            writefile(OUTPUT_ROOT .. "/" .. name .. ".luau-bytecode", bytecode)

            local decompileOk, sourceOrError = pcall(decompile, bytecode, options)
            result.decompileOk = decompileOk
            result.decompiledBytes = type(sourceOrError) == "string" and #sourceOrError or 0
            writefile(
                OUTPUT_ROOT .. "/" .. name .. ".decompiled.luau",
                decompileOk and sourceOrError or ("-- Decompile error: " .. tostring(sourceOrError) .. "\n")
            )
        else
            result.bytecodeError = tostring(bytecode)
        end
    end

    results[#results + 1] = result
end

return {
    ok = true,
    protectedEntrypointExecuted = false,
    outputRoot = OUTPUT_ROOT,
    results = results,
}
