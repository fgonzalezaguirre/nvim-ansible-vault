---Configuration handling for neoansible-vault.
local M = {}

---@class neoansible-vault.FloatConfig
---@field max_width number Maximum float width as a fraction of the editor (0-1)
---@field max_height number Maximum float height as a fraction of the editor (0-1)
---@field border string Border style passed to nvim_open_win()

---@class neoansible-vault.InlineConfig
---@field enabled boolean Enable inline `!vault` editing
---@field keymap string|nil Keymap (normal mode) to edit the vault block under the cursor
---@field encrypt_keymap string|nil Keymap (normal mode) to encrypt the value/line under the cursor
---@field treesitter boolean Use tree-sitter (YAML parser) to reject false-positive matches when available
---@field hover boolean Map K to a decrypted hover preview on vault blocks (falls back to default K)
---@field float neoansible-vault.FloatConfig

---@class neoansible-vault.PickerConfig
---@field enabled boolean Enable the secret picker
---@field keymap string|nil Keymap (normal mode) to pick a secret in the current buffer
---@field backend "auto"|"snacks"|"telescope"|"select" Picker backend (auto tries snacks, then telescope, then vim.ui.select)

---@class neoansible-vault.ConcealConfig
---@field enabled boolean Conceal the hex body of inline `!vault` blocks

---@class neoansible-vault.Config
---@field password string|nil Vault password set directly in config (use with care)
---@field password_file string|nil Explicit path to a vault password file or executable script
---@field env_password_var string Environment variable holding the password directly
---@field env_password_file_var string Environment variable holding a password file path
---@field password_file_name string File name to discover walking up from the edited file
---@field dotenv_name string Dotenv file name to discover walking up from the edited file
---@field prompt boolean Prompt for the password when no other source resolves
---@field cache_ttl integer Seconds to cache resolved passwords in memory (0 disables)
---@field vault_id string|nil Default vault-id label for new encryptions
---@field auto_decrypt boolean Transparently decrypt whole-file vault files on read
---@field keymap_filetypes string[] Filetypes that get the buffer-local keymaps
---@field inline neoansible-vault.InlineConfig
---@field picker neoansible-vault.PickerConfig
---@field conceal neoansible-vault.ConcealConfig

---@type neoansible-vault.Config
M.defaults = {
  password = nil,
  password_file = nil,
  env_password_var = "ANSIBLE_VAULT_PASSWORD",
  env_password_file_var = "ANSIBLE_VAULT_PASSWORD_FILE",
  password_file_name = ".vault-password",
  dotenv_name = ".env",
  prompt = true,
  cache_ttl = 900,
  vault_id = nil,
  auto_decrypt = true,
  keymap_filetypes = { "yaml", "yaml.ansible" },
  inline = {
    enabled = true,
    keymap = "<leader>ve",
    encrypt_keymap = "<leader>vs",
    treesitter = true,
    hover = true,
    float = {
      max_width = 0.6,
      max_height = 0.6,
      border = "rounded",
    },
  },
  picker = {
    enabled = true,
    keymap = "<leader>vl",
    backend = "auto",
  },
  conceal = {
    enabled = true,
  },
}

---@type neoansible-vault.Config
M.options = vim.deepcopy(M.defaults)

M._did_setup = false

---@param opts neoansible-vault.Config|nil
---@return neoansible-vault.Config
function M.setup(opts)
  opts = opts or {}
  vim.validate({ opts = { opts, "table" } })
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  M._did_setup = true
  return M.options
end

---@return neoansible-vault.Config
function M.get()
  return M.options
end

return M
