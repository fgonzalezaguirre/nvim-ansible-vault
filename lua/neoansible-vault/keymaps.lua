---Buffer-local keymap registration: the plugin's keymaps only exist in
---buffers whose filetype is in `keymap_filetypes`, so they cannot clash
---with mappings in unrelated buffers.
local config = require("neoansible-vault.config")

local M = {}

---Attach a keymap to one buffer if its filetype is eligible.
---@param buf integer
---@param lhs string|nil
---@param rhs fun()
---@param desc string
function M.attach(buf, lhs, rhs, desc)
  if not lhs or lhs == "" then
    return
  end
  if not vim.list_contains(config.get().keymap_filetypes, vim.bo[buf].filetype) then
    return
  end
  vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc })
end

---Attach a keymap to all current and future buffers with eligible filetypes.
---@param group integer augroup used for the FileType autocmd
---@param lhs string|nil
---@param rhs fun()
---@param desc string
function M.setup(group, lhs, rhs, desc)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.attach(buf, lhs, rhs, desc)
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    desc = ("neoansible-vault: %s"):format(desc),
    callback = function(ev)
      M.attach(ev.buf, lhs, rhs, desc)
    end,
  })
end

---Attach a global keymap (no filetype restriction). Use sparingly; the
---handler itself should decide whether the context is an ansible project.
---@param lhs string|nil
---@param rhs fun()
---@param desc string
function M.setup_global(lhs, rhs, desc)
  if not lhs or lhs == "" then
    return
  end
  vim.keymap.set("n", lhs, rhs, { desc = desc })
end

local WK_ICONS = {
  ["<leader>a"] = "󱂚",
  ["<leader>av"] = "󰌆",
}

---which-key spec entries for the configured prefix groups, parents first.
---Intended both for wk.add() and for contributing to which-key's opts.spec
---via lazy.nvim (`opts_extend`): `{ "folke/which-key.nvim", optional = true,
---opts = function() return { spec = require("neoansible-vault").which_key_spec() } end }`.
---@return table[]
function M.which_key_spec()
  local groups = config.get().keymaps.group
  if type(groups) ~= "table" then
    return {}
  end
  local prefixes = vim.tbl_keys(groups)
  table.sort(prefixes, function(a, b)
    return #a < #b
  end)
  local spec = {}
  for _, prefix in ipairs(prefixes) do
    table.insert(spec, { prefix, group = groups[prefix], icon = WK_ICONS[prefix] })
  end
  return spec
end

---Register the prefix groups with which-key so the popup shows names
---instead of "+N keymaps". which-key v3 drains its wk.add queue once at
---load, so: before load -> queue via wk.add; after load -> insert straight
---into which-key.config.mappings (which also clears cached trees).
---Deferred and idempotent: safe to fire on multiple events.
function M.register_group()
  local added_directly = false
  local function add()
    local spec = M.which_key_spec()
    if #spec == 0 then
      return
    end
    local ok, wk = pcall(require, "which-key")
    if not ok or type(wk.add) ~= "function" then
      return
    end
    local wk_config = require("which-key.config")
    if wk_config.loaded then
      if added_directly then
        return
      end
      added_directly = true
      wk_config.add(spec, { create = false })
    else
      wk.add(spec)
    end
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(add)
  end
  local augroup = vim.api.nvim_create_augroup("neoansible_vault_wk", { clear = true })
  vim.api.nvim_create_autocmd("VimEnter", { group = augroup, callback = add })
  vim.api.nvim_create_autocmd("User", { group = augroup, pattern = "VeryLazy", callback = add })
end

return M
