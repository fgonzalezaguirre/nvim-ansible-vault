# neoansible-vault

Ansible vault integration for Neovim: transparent editing of vault-encrypted
files and inline `!vault` secrets, powered by the real `ansible-vault` CLI.

## Features

- **Transparent whole-file editing** — open a vault-encrypted file and see
  plaintext; `:w` re-encrypts automatically. Vault-ids (`1.2` format) are
  detected and preserved.
- **Inline secret editing** — cursor on a `!vault` block, one keypress, edit
  the decrypted value in a floating window, save to re-encrypt in place.
- **Encrypt new secrets** — turn any line or selection into a `!vault` block.
- **Secret picker** — list all `!vault` secrets in the buffer via snacks.nvim,
  telescope, or a plain `vim.ui.select` fallback; pick one to jump straight
  into the edit float.
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
{ "you/neoansible-vault", opts = {} }              -- from a git remote
{ dir = "~/dev/fga/neoansible-vault", opts = {} }  -- or a local checkout
```

The plugin also works with zero configuration — autocmds and commands are
registered with defaults if `setup()` is never called.

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
  inline = {
    enabled = true,
    keymap = "<leader>ve",      -- edit !vault block under cursor
    treesitter = true,          -- use YAML tree-sitter parser to avoid false
                                -- positives when available (optional)
    float = { max_width = 0.6, max_height = 0.6, border = "rounded" },
  },
  picker = {
    enabled = true,
    keymap = "<leader>vl",      -- pick a !vault secret in the buffer
    backend = "auto",           -- "auto" | "snacks" | "telescope" | "select"
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
- Visually select text (or put the cursor on a `key: value` line) →
  `:'<,'>AnsibleVaultEncryptString` → prompts for a variable name and
  replaces the selection with a `!vault` block. For a single `key: value`
  line the key is pre-filled and only the value is encrypted.
- Both `:AnsibleVaultEncryptString` and `:AnsibleVaultEncrypt` accept an
  optional vault-id argument (`:AnsibleVaultEncryptString prod`) and fall
  back to the `vault_id` config option; existing vault-ids are always
  preserved on edit/write.

## Security notes

- Decrypted whole-file buffers use `noswapfile`; the float scratch buffers
  are wiped on close. Plaintext still exists in memory (and undo history)
  while a buffer is open — that is inherent to transparent editing.
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
