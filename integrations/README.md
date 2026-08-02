# RBA integrations

RBA keeps companion projects separate and records exactly which upstream revision it supports.

## Roblox Instance Manager

`roblox-instance-manager-src/` is a Git submodule of
[`Muhammad-Tanvirul-Islam-Shayeem/Roblox-MCP`](https://github.com/Muhammad-Tanvirul-Islam-Shayeem/Roblox-MCP),
pinned to commit `3a2456a871e1e1330790e964b17826518deabc80` from release `v1.0.1`
(`Minor-Changes`). Its upstream license and history remain intact inside the submodule.

Initialize it after cloning RBA:

```powershell
git submodule update --init --recursive
```

Runtime loader snapshots saved by `rba_save_instance_manager_loader` go under
`integrations/runtime/` and are intentionally ignored by Git.
