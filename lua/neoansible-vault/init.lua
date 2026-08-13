---neoansible-vault: ansible vault integration for Neovim.
local M = {}

---@param opts neoansible-vault.Config|nil
function M.setup(opts)
  local cfg = require("neoansible-vault.config").setup(opts)
  require("neoansible-vault.file").setup()
  require("neoansible-vault.inline").setup()
  require("neoansible-vault.picker").setup()
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

---Encrypt a range of lines into a `key: !vault |` block.
---@param line1 integer 1-indexed first line
---@param line2 integer 1-indexed last line
function M.encrypt_selection(line1, line2)
  require("neoansible-vault.inline").encrypt_selection(line1, line2)
end

---Decrypt the current buffer; it will be re-encrypted on write.
function M.decrypt_buffer()
  require("neoansible-vault.file").decrypt_buffer()
end

---Encrypt the current buffer, replacing its content with ciphertext.
function M.encrypt_buffer()
  require("neoansible-vault.file").encrypt_buffer()
end

---Rekey the vault file backing the current buffer with a new password.
function M.rekey_buffer()
  require("neoansible-vault.file").rekey_buffer()
end

---Forget all cached vault passwords.
function M.clear_password_cache()
  require("neoansible-vault.password").clear_cache()
end

return M
