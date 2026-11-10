---ansible-vault: ansible vault integration for Neovim.
local M = {}

---@param opts ansible-vault.Config|nil
function M.setup(opts)
  local cfg = require("ansible-vault.config").setup(opts)
  require("ansible-vault.file").setup()
  require("ansible-vault.inline").setup()
  require("ansible-vault.picker").setup()
  require("ansible-vault.conceal").setup()
  require("ansible-vault.reveal").setup()
  require("ansible-vault.keymaps").register_group()
  require("ansible-vault.snacks").setup()
  return cfg
end

---Edit the inline `!vault` block under the cursor.
function M.edit_inline()
  require("ansible-vault.inline").edit()
end

---Pick an inline `!vault` secret in the current buffer and edit it.
function M.pick_secret()
  require("ansible-vault.picker").pick()
end

---Toggle reveal mode: decrypt all inline secrets in place, re-encrypt on write.
function M.toggle_reveal()
  require("ansible-vault.reveal").toggle()
end

---Pick a vault-encrypted file in the project and open it.
function M.pick_vault_file()
  require("ansible-vault.picker").pick_file()
end

---Encrypt a range of lines into a `key: !vault |` block.
---@param line1 integer 1-indexed first line
---@param line2 integer 1-indexed last line
---@param vault_id string|nil vault-id label (defaults to config.vault_id / picker)
---@param opts { force_prompt: boolean|nil }|nil force_prompt: ask for a one-off password
function M.encrypt_selection(line1, line2, vault_id, opts)
  require("ansible-vault.inline").encrypt_selection(line1, line2, vault_id, opts)
end

---Decrypt the `!vault` block under the cursor into plaintext lines.
function M.decrypt_inline()
  require("ansible-vault.inline").decrypt_value()
end

---Toggle the cursor line: decrypt a `!vault` block, or encrypt a plaintext value.
function M.toggle_inline()
  require("ansible-vault.inline").toggle()
end

---Decrypt the current buffer; it will be re-encrypted on write.
function M.decrypt_buffer()
  require("ansible-vault.file").decrypt_buffer()
end

---Encrypt the current buffer, replacing its content with ciphertext.
---@param vault_id string|nil vault-id label (defaults to config.vault_id / picker)
---@param opts { force_prompt: boolean|nil }|nil force_prompt: ask for a one-off password
function M.encrypt_buffer(vault_id, opts)
  require("ansible-vault.file").encrypt_buffer(vault_id, opts)
end

---Rekey the vault file backing the current buffer with a new password.
function M.rekey_buffer()
  require("ansible-vault.file").rekey_buffer()
end

---Forget all cached vault passwords.
function M.clear_password_cache()
  require("ansible-vault.password").clear_cache()
end

---which-key spec entries (for lazy.nvim `opts_extend` on which-key's spec).
---@return table[]
function M.which_key_spec()
  return require("ansible-vault.keymaps").which_key_spec()
end

---Statusline component: vault state of a buffer as a short label.
---Returns "[vault]" or "[vault:<id>]" for vault-related buffers, "" otherwise.
---Results are cached per buffer and invalidated on change.
---@param buf integer|nil defaults to the current buffer
---@return string
function M.status(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  local ok, state = pcall(vim.api.nvim_buf_get_var, buf, "ansible_vault")
  if ok and state then
    return state.vault_id and ("[vault:" .. state.vault_id .. "]") or "[vault]"
  end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached_ok, cached = pcall(vim.api.nvim_buf_get_var, buf, "ansible_vault_status")
  if cached_ok and cached.tick == tick then
    return cached.value
  end

  local value = ""
  local path = vim.api.nvim_buf_get_name(buf)
  if path ~= "" then
    local header = require("ansible-vault.detect").file_header(path)
    if header then
      value = header.vault_id and ("[vault:" .. header.vault_id .. "]") or "[vault]"
    end
  end
  pcall(vim.api.nvim_buf_set_var, buf, "ansible_vault_status", { tick = tick, value = value })
  return value
end

return M
