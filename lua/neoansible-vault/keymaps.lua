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

return M
