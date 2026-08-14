---neoansible-vault: ansible vault integration for Neovim.
local M = {}

---@param opts neoansible-vault.Config|nil
function M.setup(opts)
  local cfg = require("neoansible-vault.config").setup(opts)
  require("neoansible-vault.file").setup()
  require("neoansible-vault.inline").setup()
  require("neoansible-vault.picker").setup()
  require("neoansible-vault.conceal").setup()
  require("neoansible-vault.reveal").setup()
  return cfg
end

---Edit the inline `!vault` block under the cursor.
function M.edit_inline()
  require("neoansible-vault.inline").edit()
end

---Pick an inline `!vault` secret in the current buffer and edit it.
function M.pick_secret()
  require("neoansible-vault.picker").pick()
end

---Toggle reveal mode: decrypt all inline secrets in place, re-encrypt on write.
function M.toggle_reveal()
  require("neoansible-vault.reveal").toggle()
end

---Pick a vault-encrypted file in the project and open it.
function M.pick_vault_file()
  require("neoansible-vault.picker").pick_file()
end

---Encrypt a range of lines into a `key: !vault |` block.
---@param line1 integer 1-indexed first line
---@param line2 integer 1-indexed last line
---@param vault_id string|nil vault-id label (defaults to config.vault_id)
function M.encrypt_selection(line1, line2, vault_id)
  require("neoansible-vault.inline").encrypt_selection(line1, line2, vault_id)
end

---Decrypt the `!vault` block under the cursor into plaintext lines.
function M.decrypt_inline()
  require("neoansible-vault.inline").decrypt_value()
end

---Toggle the cursor line: decrypt a `!vault` block, or encrypt a plaintext value.
function M.toggle_inline()
  require("neoansible-vault.inline").toggle()
end

---Decrypt the current buffer; it will be re-encrypted on write.
function M.decrypt_buffer()
  require("neoansible-vault.file").decrypt_buffer()
end

---Encrypt the current buffer, replacing its content with ciphertext.
---@param vault_id string|nil vault-id label (defaults to config.vault_id)
function M.encrypt_buffer(vault_id)
  require("neoansible-vault.file").encrypt_buffer(vault_id)
end

---Rekey the vault file backing the current buffer with a new password.
function M.rekey_buffer()
  require("neoansible-vault.file").rekey_buffer()
end

---Forget all cached vault passwords.
function M.clear_password_cache()
  require("neoansible-vault.password").clear_cache()
end

---Statusline component: vault state of a buffer as a short label.
---Returns "[vault]" or "[vault:<id>]" for vault-related buffers, "" otherwise.
---Results are cached per buffer and invalidated on change.
---@param buf integer|nil defaults to the current buffer
---@return string
function M.status(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  local ok, state = pcall(vim.api.nvim_buf_get_var, buf, "neoansible_vault")
  if ok and state then
    return state.vault_id and ("[vault:" .. state.vault_id .. "]") or "[vault]"
  end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached_ok, cached = pcall(vim.api.nvim_buf_get_var, buf, "neoansible_vault_status")
  if cached_ok and cached.tick == tick then
    return cached.value
  end

  local value = ""
  local path = vim.api.nvim_buf_get_name(buf)
  if path ~= "" then
    local header = require("neoansible-vault.detect").file_header(path)
    if header then
      value = header.vault_id and ("[vault:" .. header.vault_id .. "]") or "[vault]"
    end
  end
  pcall(vim.api.nvim_buf_set_var, buf, "neoansible_vault_status", { tick = tick, value = value })
  return value
end

return M
