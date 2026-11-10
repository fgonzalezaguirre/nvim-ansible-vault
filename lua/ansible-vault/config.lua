---Configuration handling for ansible-vault.
local M = {}

---@class ansible-vault.FloatConfig
---@field max_width number Maximum float width as a fraction of the editor (0-1)
---@field max_height number Maximum float height as a fraction of the editor (0-1)
---@field border string Border style passed to nvim_open_win()

---@class ansible-vault.InlineConfig
---@field enabled boolean Enable inline `!vault` editing
---@field editor "auto"|"input"|"float" Value editor: "auto" uses vim.ui.input for single-line values, the float otherwise
---@field treesitter boolean Use tree-sitter (YAML parser) to reject false-positive matches when available
---@field hover boolean Map K to a decrypted hover preview on vault blocks (falls back to default K)
---@field float ansible-vault.FloatConfig

---@class ansible-vault.KeymapsConfig
---@field toggle string|nil Encrypt the plaintext under the cursor / decrypt the block under the cursor
---@field toggle_buffer string|nil Encrypt the buffer / decrypt the buffer, depending on its state
---@field edit_secret string|nil Reveal/edit the secret under the cursor (floating editor)
---@field reveal_buffer string|nil Reveal/edit all secrets in the buffer in place
---@field find_buffer string|nil Find vault secrets in the current buffer
---@field find_project string|nil Find vault secrets and encrypted files in the project (global, guarded by ansible project detection)
---@field rekey_secret string|nil Rekey the secret under the cursor (new password/vault-id)
---@field rekey_file string|nil Rekey the vault file with a new password
---@field group table<string, string>|nil which-key group labels keyed by prefix (nil disables)

---@class ansible-vault.SnacksConfig
---@field explorer boolean Add encrypt/decrypt file actions to the snacks explorer
---@field icons boolean Show a lock icon for vault-encrypted files in snacks pickers

---@class ansible-vault.PickerConfig
---@field enabled boolean Enable the secret picker
---@field backend "auto"|"snacks"|"telescope"|"select" Picker backend (auto tries snacks, then telescope, then vim.ui.select)

---@class ansible-vault.ConcealConfig
---@field enabled boolean Conceal the hex body of inline `!vault` blocks

---@class ansible-vault.VaultIdConfig
---@field password string|nil Password for this vault-id, set directly (use with care)
---@field password_file string|nil Password file or executable script for this vault-id

---@class ansible-vault.Config
---@field password string|nil Vault password set directly in config (use with care)
---@field password_file string|nil Explicit path to a vault password file or executable script
---@field env_password_var string Environment variable holding the password directly
---@field env_password_file_var string Environment variable holding a password file path
---@field password_file_name string|string[] File name(s) to discover walking up from the edited file
---@field dotenv_name string Dotenv file name to discover walking up from the edited file
---@field prompt boolean Prompt for the password when no other source resolves
---@field cache_ttl integer Seconds to cache resolved passwords in memory (0 disables)
---@field vault_id string|nil Default vault-id label for new encryptions
---@field vault_ids table<string, ansible-vault.VaultIdConfig> Per-vault-id password sources
---@field confirm_default boolean Ask which vault-id to use for every new encryption (off = silently use the default)
---@field confirm_decrypt boolean Ask for authorization before auto-decrypting a vault file on open (off = decrypt immediately)
---@field auto_decrypt boolean Transparently decrypt whole-file vault files on read
---@field keymap_filetypes string[] Filetypes that get the buffer-local keymaps
---@field inline ansible-vault.InlineConfig
---@field picker ansible-vault.PickerConfig
---@field conceal ansible-vault.ConcealConfig
---@field keymaps ansible-vault.KeymapsConfig
---@field snacks ansible-vault.SnacksConfig

---@type ansible-vault.Config
M.defaults = {
  password = nil,
  password_file = nil,
  env_password_var = "ANSIBLE_VAULT_PASSWORD",
  env_password_file_var = "ANSIBLE_VAULT_PASSWORD_FILE",
  password_file_name = { ".vault-password", ".vault_pass", ".vault-pass" },
  dotenv_name = ".env",
  prompt = true,
  cache_ttl = 900,
  vault_id = nil,
  vault_ids = {},
  confirm_default = true,
  confirm_decrypt = true,
  auto_decrypt = true,
  keymap_filetypes = { "yaml", "yaml.ansible" },
  inline = {
    enabled = true,
    editor = "auto",
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
    backend = "auto",
  },
  conceal = {
    enabled = true,
  },
  keymaps = {
    toggle = "<leader>avv",
    toggle_buffer = "<leader>avV",
    edit_secret = "<leader>ave",
    reveal_buffer = "<leader>avE",
    find_buffer = "<leader>avf",
    find_project = "<leader>avF",
    rekey_secret = "<leader>avk",
    rekey_file = "<leader>avK",
    group = {
      ["<leader>a"] = "ansible",
      ["<leader>av"] = "vault",
    },
  },
  snacks = {
    explorer = true,
    icons = true,
  },
}

---@type ansible-vault.Config
M.options = vim.deepcopy(M.defaults)

M._did_setup = false

---@param opts ansible-vault.Config|nil
---@return ansible-vault.Config
function M.setup(opts)
  opts = opts or {}
  vim.validate({ opts = { opts, "table" } })
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  M._did_setup = true
  return M.options
end

---@return ansible-vault.Config
function M.get()
  return M.options
end

return M
