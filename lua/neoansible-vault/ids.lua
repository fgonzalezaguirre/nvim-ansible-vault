---Vault-id selection for new encryptions.
---
---Existing encrypted content always keeps its own vault-id label; this
---module only decides which id (if any) *new* ciphertext gets.
local config = require("neoansible-vault.config")
local password = require("neoansible-vault.password")

local M = {}

local DEFAULT_CHOICE = "(default)"
local NEW_ID_CHOICE = "(new id…)"

---@param buf integer
---@return string
local function buffer_dir(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path ~= "" then
    return vim.fs.dirname(path)
  end
  return (vim.uv or vim.loop).cwd()
end

---The vault-id labels known for a buffer's project.
---@param buf integer
---@return string[]
function M.known(buf)
  return password.known_ids(buffer_dir(buf))
end

---Choose the vault-id for a new encryption.
---With `confirm_default = true` (the default) the user is always asked:
---the default (config.vault_id, else unlabeled) plus all known ids and a
---"(new id…)" entry. With `confirm_default = false` the default is used
---silently and the picker only appears when identities are known.
---@param buf integer
---@param cb fun(vault_id: string|nil)
function M.pick(buf, cb)
  local cfg = config.get()
  local known = M.known(buf)
  local default_id = (cfg.vault_id and cfg.vault_id ~= "") and cfg.vault_id or nil

  if not cfg.confirm_default then
    if default_id then
      cb(default_id)
      return
    end
    if #known == 0 then
      cb(nil)
      return
    end
  end

  local entries = {
    { choice = default_id and ("(default: " .. default_id .. ")") or DEFAULT_CHOICE, id = default_id },
  }
  for _, id in ipairs(known) do
    if id ~= default_id then
      table.insert(entries, { choice = id, id = id })
    end
  end
  table.insert(entries, { choice = NEW_ID_CHOICE, is_new = true })

  local choices = {}
  for i, entry in ipairs(entries) do
    choices[i] = entry.choice
  end
  vim.ui.select(choices, { prompt = "Encrypt with vault-id:" }, function(choice)
    if choice == nil then
      return -- aborted: cancel the whole operation
    end
    for _, entry in ipairs(entries) do
      if entry.choice == choice then
        if entry.is_new then
          vim.ui.input({ prompt = "New vault-id: " }, function(input)
            if input and input ~= "" then
              cb(input)
            end
          end)
        else
          cb(entry.id)
        end
        return
      end
    end
  end)
end

---Command completion for vault-id arguments.
---@param buf integer
---@return fun(arglead: string): string[]
function M.complete(buf)
  return function(arglead)
    return vim.tbl_filter(function(id)
      return vim.startswith(id, arglead)
    end, M.known(buf))
  end
end

return M
