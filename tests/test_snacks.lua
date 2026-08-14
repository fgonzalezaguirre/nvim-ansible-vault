---Smoke tests against a real snacks.nvim checkout. Skipped unless
---NEOANSIBLE_VAULT_SNACKS points at a snacks.nvim repo, e.g.:
---  NEOANSIBLE_VAULT_SNACKS=/path/to/snacks.nvim make test
local picker = require("neoansible-vault.picker")
local h = require("helpers")

local tests = {}

---@return boolean available
local function load_snacks()
  local dir = vim.env.NEOANSIBLE_VAULT_SNACKS
  if not dir or vim.fn.isdirectory(dir) == 0 then
    return false
  end
  vim.opt.runtimepath:append(dir)
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks ~= nil and snacks.picker ~= nil and snacks.win ~= nil
end

function tests.edit_float_uses_snacks_win()
  if not load_snacks() then
    print("  (skipped: NEOANSIBLE_VAULT_SNACKS not set)")
    return
  end
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block = h.vault_encrypt_string("snacks-secret", "db_password", passfile)
  local path = dir .. "/vars.yml"
  h.write_file(path, block)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  require("neoansible-vault").edit_inline()
  local win, fbuf = nil, nil
  h.assert_true(
    h.wait_for(function()
      win, fbuf = h.find_win("ansible%-vault://db_password")
      return win ~= nil
    end),
    "edit float did not open"
  )
  h.assert_eq(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), { "snacks-secret" })
  h.assert_true(vim.api.nvim_win_get_config(win).relative ~= "", "float is floating")

  -- no extra windows (e.g. a backdrop pane) may be created
  local floats = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      floats = floats + 1
    end
  end
  h.assert_eq(floats, 1, "exactly one floating window (no backdrop pane)")

  pcall(vim.api.nvim_win_close, win, true)
  vim.cmd.bwipeout({ bang = true })
end

function tests.snacks_sources_produce_items()
  if not load_snacks() then
    print("  (skipped: NEOANSIBLE_VAULT_SNACKS not set)")
    return
  end
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block = h.vault_encrypt_string("s3cr3t", "db_password", passfile)
  local path = dir .. "/vars.yml"
  h.write_file(path, block)
  vim.cmd.edit(vim.fn.fnameescape(path))

  local sources = picker.snacks_sources()
  h.assert_true(sources.ansible_vault_secrets ~= nil)
  h.assert_true(sources.ansible_vault_files ~= nil)

  local items = sources.ansible_vault_secrets.finder()
  h.assert_eq(#items, 1)
  h.assert_eq(items[1].entry.key, "db_password")
  h.assert_eq(items[1].file, path, "file set for the preview pane")

  vim.cmd.bwipeout({ bang = true })
end

return tests
