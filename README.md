# neoansible-vault

Ansible vault integration for Neovim: transparent editing of vault-encrypted
files and inline `!vault` secrets, powered by the real `ansible-vault` CLI.

## Features

- **Transparent whole-file editing** — open a vault-encrypted file and see
  plaintext; `:w` re-encrypts automatically. Vault-ids (`1.2` format) are
  detected and preserved.
- **Inline secret editing** — cursor on a `!vault` block, one keypress, edit
  the decrypted value in a floating window, save to re-encrypt in place.
- **Encrypt new secrets** — turn any line or selection into a `!vault` block;
  decrypt a single block back to plaintext with `:AnsibleVaultDecryptString`.
- **Vault file picker** — `:AnsibleVaultFiles` lists vault-encrypted files in
  the project (snacks/telescope/`vim.ui.select`) and opens the chosen one.
- **Secret picker** — list all `!vault` secrets in the buffer via snacks.nvim,
  telescope, or a plain `vim.ui.select` fallback; pick one to jump straight
  into the edit float.
- **Concealed blobs** — the hex body of `!vault` blocks is hidden behind a
  `[vault]` marker, so secret-heavy files stay readable (`'conceallevel'` is
  managed per window and restored automatically).
- **Hover preview** — `K` on a `!vault` block shows the decrypted value in a
  read-only float without entering edit mode (falls back to default `K`
  elsewhere; LSP buffer-local `K` mappings take precedence).
- **Reveal mode** — `:AnsibleVaultReveal` decrypts every `!vault` block in
  the buffer into editable plaintext lines; `:w` re-encrypts each secret and
  writes only ciphertext to disk. Toggle again to re-encrypt in the buffer.
- **`yaml.ansible` filetype** — common Ansible layouts (`playbooks/`,
  `roles/*/{tasks,handlers,vars,defaults}`, `group_vars`, `host_vars`) are
  detected as `yaml.ansible` for your own autocmds and lazy.nvim `ft` triggers.
- **Flexible password management** — environment variable, `.env` files,
  `.vault-password` discovery, executable password scripts, or interactive
  prompt (cached in memory only).

## Requirements

- Neovim >= 0.12
- `ansible-vault` on `$PATH` (from `ansible-core`)
- Optional: YAML tree-sitter parser (e.g. via nvim-treesitter) for more
  precise `!vault` detection — the plugin falls back to line-based
  detection without it

## Installation

**Installer script (easiest)** — detects your setup and does the right thing:

```sh
./install.sh              # lazy.nvim spec if lazy is detected, else pack dir
./install.sh --lazy       # force lazy.nvim spec
./install.sh --pack       # force Vim package install (:help packages)
./install.sh --pack --link  # symlink instead of copy (live changes, for dev)
./install.sh uninstall    # remove spec/pack install again
```

With lazy.nvim (including LazyVim) the installer writes
`lua/plugins/neoansible-vault.lua` into your config's plugin import
directory, pointing at this repo via `dir =` — restart nvim or run
`:Lazy sync` afterwards. Without lazy.nvim it copies into the standard
package directory (`~/.local/share/nvim/site/pack/neoansible-vault/start/...`),
which Neovim auto-loads at startup. The installer checks for Neovim >= 0.12
and `ansible-vault`, generates helptags, and refuses to touch files it did
not create.

**Manual** — with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "fgonzalezaguirre/neoansible-vault", -- or: dir = "~/dev/fga/neoansible-vault",
  -- load before any file read so vault files decrypt transparently on open
  event = "BufReadPre",
  keys = {
    { "<leader>ve", desc = "Edit ansible vault secret" },
    { "<leader>vl", desc = "Pick ansible vault secret" },
  },
  opts = {},
}
```

The plugin also works with zero configuration — autocmds and commands are
registered with defaults if `setup()` is never called, even when the plugin
is loaded lazily after startup.

## Configuration

Defaults:

```lua
require("neoansible-vault").setup({
  password = nil,               -- vault password directly (careful!)
  password_file = nil,          -- explicit password file or executable script
  env_password_var = "ANSIBLE_VAULT_PASSWORD",
  env_password_file_var = "ANSIBLE_VAULT_PASSWORD_FILE",
  password_file_name = ".vault-password", -- discovered walking up from the file
  dotenv_name = ".env",                   -- discovered walking up from the file
  prompt = true,                -- interactive fallback
  cache_ttl = 900,              -- seconds to cache *prompted* passwords (0 = off)
  vault_id = nil,               -- default vault-id label for new encryptions
  auto_decrypt = true,          -- transparent whole-file decrypt on read
  keymap_filetypes = { "yaml", "yaml.ansible" }, -- buffers that get keymaps
  inline = {
    enabled = true,
    keymap = "<leader>ve",      -- edit !vault block under cursor
    encrypt_keymap = "<leader>vs", -- encrypt the value/line under cursor
    decrypt_keymap = "<leader>vd", -- decrypt !vault block under cursor to plaintext
    reveal_keymap = "<leader>vr",  -- toggle in-place editing of all secrets
    treesitter = true,          -- use YAML tree-sitter parser to avoid false
                                -- positives when available (optional)
    hover = true,               -- K shows a decrypted preview on vault blocks
    float = { max_width = 0.6, max_height = 0.6, border = "rounded" },
  },
  picker = {
    enabled = true,
    keymap = "<leader>vl",      -- pick a !vault secret in the buffer
    files_keymap = "<leader>vf", -- pick a vault-encrypted file in the project
    backend = "auto",           -- "auto" | "snacks" | "telescope" | "select"
  },
  conceal = {
    enabled = true,             -- hide !vault blob lines behind a [vault] marker
  },
})
```

## Password resolution

First hit wins:

1. `password` from `setup()`
2. `$ANSIBLE_VAULT_PASSWORD` (the password itself)
3. `password_file` from `setup()`
4. `$ANSIBLE_VAULT_PASSWORD_FILE` (path to a file or executable script)
5. `.env` files, discovered walking up from the edited file's directory:
   `ANSIBLE_VAULT_PASSWORD=...` or `ANSIBLE_VAULT_PASSWORD_FILE=...`
   (relative paths resolve against the `.env` location; `export` and quotes
   are handled)
6. `.vault-password` files, discovered walking up the same way
7. Interactive prompt via `vim.ui.input({ secret = true })`

The upward search never reads from your home directory. Prompted passwords
are cached in memory only, scoped per directory tree, for `cache_ttl`
seconds. Raw passwords are handed to `ansible-vault` through a `0600` temp
file that is deleted immediately after each call.

## Usage

### Whole files

Just open an encrypted file — it decrypts in place and re-encrypts on `:w`.
The buffer shows a `[vault-id: x]` note when applicable.

| Command | Action |
| --- | --- |
| `:AnsibleVaultDecrypt` | Decrypt the current buffer (re-encrypts on write) |
| `:AnsibleVaultEncrypt [vault-id]` | Encrypt the current buffer, replacing it with ciphertext |
| `:AnsibleVaultRekey` | Re-encrypt the file with a new password (and optionally a new vault-id) |
| `:AnsibleVaultDecryptString` | Decrypt the `!vault` block under the cursor back to plaintext |
| `:AnsibleVaultFiles` | Pick a vault-encrypted file in the project and open it |
| `:AnsibleVaultClearCache` | Forget cached (prompted) passwords |

### Inline `!vault` blocks

```yaml
db_password: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          6438316338653863633032366232653137...
```

- Cursor anywhere on the block → `<leader>ve` or `:AnsibleVaultEdit` →
  floating window with the plaintext. `<CR>`/`:w` saves and re-encrypts,
  `<Esc>`/`q` cancels.
- `<leader>vl` or `:AnsibleVaultSecrets` lists every `!vault` secret in the
  buffer (snacks.nvim or telescope if installed, `vim.ui.select` otherwise)
  and opens the chosen one in the edit float.
- `<leader>vr` or `:AnsibleVaultReveal` decrypts **all** blocks in place into
  editable lines (`key: value`, or a `key: |-` literal block for multi-line
  values). `:w` re-encrypts each secret and writes only ciphertext to disk;
  the buffer keeps the plaintext view. Run again to re-encrypt in the
  buffer. Multi-line and vault-id'd secrets are supported.
- Cursor on a `key: value` line → `<leader>vs` encrypts just the value
  (equivalent to `:AnsibleVaultEncryptString` on the current line).
- The inverse: cursor on a `!vault` block → `<leader>vd` or
  `:AnsibleVaultDecryptString` replaces the block with plaintext
  (`key: value`, or `key: |-` for multi-line). Nothing is re-encrypted — the
  value stays plaintext until you encrypt it again.
- Visually select text (or put the cursor on a `key: value` line) →
  `:'<,'>AnsibleVaultEncryptString` → prompts for a variable name and
  replaces the selection with a `!vault` block. For a single `key: value`
  line the key is pre-filled and only the value is encrypted.
- Both `:AnsibleVaultEncryptString` and `:AnsibleVaultEncrypt` accept an
  optional vault-id argument (`:AnsibleVaultEncryptString prod`) and fall
  back to the `vault_id` config option; existing vault-ids are always
  preserved on edit/write.

## Keymaps

The `<leader>v*` mappings are **buffer-local** — they only
exist in buffers whose filetype is in `keymap_filetypes` (yaml by default),
so they cannot clash with your other mappings. `<leader>v` is unused by
LazyVim (core and extras). `K` is global but falls back to the default `K`
off a vault block, and buffer-local mappings (e.g. LSP hover) take
precedence over it.

| Key | Action |
| --- | --- |
| `<leader>ve` | Edit the `!vault` block under the cursor (float) |
| `<leader>vl` | Pick a secret in the buffer (snacks/telescope/select) |
| `<leader>vf` | Pick a vault-encrypted file in the project |
| `<leader>vs` | Encrypt the value/line under the cursor |
| `<leader>vd` | Decrypt the block under the cursor back to plaintext |
| `<leader>vr` | Reveal/edit all secrets in place (`:w` re-encrypts) |
| `K` | Decrypted hover preview of the block under cursor |

## Snacks explorer integration

`:AnsibleVaultFiles` already uses snacks when installed. To also mark
vault-encrypted files in the snacks explorer, add a custom `format` to your
snacks config:

```lua
picker = {
  sources = {
    explorer = {
      format = function(item, p)
        local ret = require("snacks.picker.format").file(item, p)
        if item.file and not item.dir then
          local fd = io.open(item.file, "r")
          local first = fd and fd:read("*l")
          if fd then fd:close() end
          if first and first:match("^%$ANSIBLE_VAULT;") then
            table.insert(ret, { " [vault]", "DiagnosticWarn" })
          end
        end
        return ret
      end,
    },
  },
},
```

## Statusline

`require("neoansible-vault").status()` returns `[vault]` or `[vault:<id>]`
for vault-related buffers (`""` otherwise) — cached per buffer and safe to
call on every redraw. With lualine:

```lua
sections = { lualine_x = { { require("neoansible-vault").status } } }
```

## Security notes

- Decrypted whole-file buffers and revealed inline secrets use `noswapfile`;
  float scratch buffers are wiped on close. Plaintext still exists in memory
  (and undo history) while a buffer is open or revealed — that is inherent to
  transparent editing.
- `'backup'`/`'writebackup'` are global-only options; set them yourself if
  you want to keep plaintext out of backups.
- The plugin never logs or persists passwords; prompted passwords live only
  in the in-memory cache (`:AnsibleVaultClearCache` to purge).

## Development

```sh
make test    # run the test suite (needs nvim and ansible-vault on PATH)
make format  # stylua
```

Tests are dependency-free: `nvim --headless -l tests/run.lua` drives real
`ansible-vault` round-trips against fixtures in temp directories.

Run `:checkhealth neoansible-vault` to diagnose your setup.
