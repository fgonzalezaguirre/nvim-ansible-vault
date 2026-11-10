local h = require("helpers")

local tests = {}

-- Simulate lazy-loading after startup: in a fresh nvim that is already past
-- VimEnter (`-l` scripts run with vim_did_enter == 1), sourcing the plugin
-- file must register the autocmds even though setup() is never called.
function tests.late_load_bootstraps_without_setup()
  local script = h.tmpdir() .. "/probe.lua"
  h.write_file(
    script,
    [[
vim.cmd.runtime("plugin/ansible-vault.lua")
local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "ansible_vault" })
print(ok and #autocmds > 0 and "bootstrapped" or "missing")
os.exit(0)
]]
  )
  local code, out, err = h.sys({
    "nvim",
    "--headless",
    "--clean",
    "--cmd",
    "set rtp+=" .. h.root,
    "-l",
    script,
  })
  h.assert_eq(code, 0, err)
  -- nested nvim -l scripts print to stderr
  h.assert_true((out .. err):match("bootstrapped") ~= nil, "autocmds registered without setup() after startup")
end

return tests
