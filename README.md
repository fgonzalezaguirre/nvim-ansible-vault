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
    { "<leader>avv", desc = "Ansible vault: encrypt/decrypt under cursor" },
    { "<leader>avV", desc = "Ansible vault: encrypt/decrypt buffer" },
    { "<leader>ave", desc = "Ansible vault: reveal/edit secret under cursor" },
    { "<leader>avE", desc = "Ansible vault: reveal/edit all secrets in buffer" },
    { "<leader>avf", desc = "Ansible vault: find secrets in buffer" },
    { "<leader>avF", desc = "Ansible vault: find secrets in project" },
    { "<leader>avk", desc = "Ansible vault: rekey secret under cursor" },
    { "<leader>avK", desc = "Ansible vault: rekey file" },
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
  password_file_name = { ".vault-password", ".vault_pass", ".vault-pass" }, -- discovered walking up
  dotenv_name = ".env",                   -- discovered walking up from the file
  prompt = true,                -- interactive fallback
  cache_ttl = 900,              -- seconds to cache *prompted* passwords (0 = off)
  vault_id = nil,               -- default vault-id label for new encryptions
  vault_ids = {},               -- per-id sources, e.g.
                                -- { prod = { password_file = "~/.vault-prod" } }
  confirm_default = true,       -- ask which vault-id to use for every new
                                -- encryption (false = silently use the default)
  confirm_decrypt = true,       -- ask before auto-decrypting a vault file on
                                -- open (false = decrypt immediately)
  auto_decrypt = true,          -- transparent whole-file decrypt on read
  keymap_filetypes = { "yaml", "yaml.ansible" }, -- buffers that get keymaps
  inline = {
    enabled = true,
    editor = "auto",            -- "auto": vim.ui.input (snacks.input) for
                                -- single-line values, float for multi-line;
                                -- or force "input" / "float"
    treesitter = true,          -- use YAML tree-sitter parser to avoid false
                                -- positives when available (optional)
    hover = true,               -- K shows a decrypted preview on vault blocks
    float = { max_width = 0.6, max_height = 0.6, border = "rounded" },
  },
  picker = {
    enabled = true,
    backend = "auto",           -- "auto" | "snacks" | "telescope" | "select"
  },
  conceal = {
    enabled = true,             -- hide !vault blob lines behind a [vault] marker
  },
  keymaps = {
    toggle = "<leader>avv",       -- encrypt/decrypt secret under cursor
    toggle_buffer = "<leader>avV",-- encrypt/decrypt whole buffer by state
    edit_secret = "<leader>ave",  -- reveal/edit secret under cursor (editor)
    reveal_buffer = "<leader>avE",-- reveal/edit all secrets in buffer
    find_buffer = "<leader>avf",  -- find secrets in buffer
    find_project = "<leader>avF", -- find secrets + encrypted files in the
                                  -- project (GLOBAL, works from any buffer
                                  -- inside an ansible project)
    rekey_secret = "<leader>avk", -- rekey secret under cursor
    rekey_file = "<leader>avK",   -- rekey file
    group = {                     -- which-key group labels (nil to disable)
      ["<leader>a"] = "ansible",
      ["<leader>av"] = "vault",
    },
  },
  snacks = {
    explorer = true,              -- encrypt/decrypt toggle in the snacks
                                  -- explorer (same <leader>avV key)
    icons = true,                 -- lock icon for encrypted files in pickers
  },
})
```

## Password resolution

For a given vault-id, id-specific sources win; otherwise the default chain
applies (mirroring ansible, which tries every available secret):

1. `vault_ids[id]` from `setup()`
2. `vault_identity_list` — from `ansible.cfg` (`$ANSIBLE_CONFIG` or
   discovered walking up) or `$ANSIBLE_VAULT_IDENTITY_LIST`
3. `password` from `setup()`
4. `$ANSIBLE_VAULT_PASSWORD` (the password itself)
5. `password_file` from `setup()`
6. `$ANSIBLE_VAULT_PASSWORD_FILE` (path to a file or executable script)
7. `vault_password_file` from `ansible.cfg`
8. `.env` files, discovered walking up from the edited file's directory:
   `ANSIBLE_VAULT_PASSWORD=...` or `ANSIBLE_VAULT_PASSWORD_FILE=...`
   (relative paths resolve against the `.env` location; `export` and quotes
   are handled)
9. `.vault-password` / `.vault_pass` / `.vault-pass` files, discovered walking up the same way
10. Interactive prompt via `vim.ui.input({ secret = true })`

The upward search never reads from your home directory. Prompted passwords
are cached in memory only, scoped per directory tree, for `cache_ttl`
seconds. Raw passwords are handed to `ansible-vault` through a `0600` temp
file that is deleted immediately after each call.

### Multiple vault-ids

All common ansible-native ways of providing passwords are understood,
including per-vault-id ones. Given an `ansible.cfg` like:

```ini
[defaults]
vault_identity_list = prod@~/.vault-pass-prod, dev@scripts/get-dev-pass.sh, stag@prompt
```

decrypting a file labeled `$ANSIBLE_VAULT;1.2;AES256;prod` automatically
uses `~/.vault-pass-prod`, while `stag` prompts interactively (cached per
directory). `password_file` values may be executable scripts — ansible-vault
runs them, so password-manager integrations (`pass`, `op`, `bw`, ...) work.

When *creating* new ciphertext you choose the label. By default
(`confirm_default = true`) every encryption flow asks first:

- the first choice is the default — `(default)` (unlabeled), or
  `(default: prod)` when `vault_id = "prod"` is configured
- all other known ids follow, plus `(new id…)` to type a fresh label
- `:AnsibleVaultEncrypt prod` / `:AnsibleVaultEncryptString prod` skip the
  question — passing the id explicitly *is* the answer

Set `confirm_default = false` to encrypt silently: `vault_id` from
`setup()` (or the unlabeled default) is used without asking, and the picker
only appears when identities are known.

Existing ciphertext always keeps its own label when re-encrypted.

### One-off passwords

Normally a resolved password source (config, env, `ansible.cfg`, discovery)
is used automatically. To encrypt with a *different* password just once,
add a bang — it skips all sources and the cache and asks for the password:

- `:AnsibleVaultEncrypt! [vault-id]` — whole buffer
- `:'<,'>AnsibleVaultEncryptString! [vault-id]` — selection / line

The prompted password replaces any cached entry for that vault-id and
directory. To change the password of an already-encrypted file permanently,
use `:AnsibleVaultRekey` instead.

## Usage

### Whole files

Just open an encrypted file — after a confirmation prompt (`confirm_decrypt`,
since the plaintext may be sensitive) it decrypts in place and re-encrypts on
`:w`. Set `confirm_decrypt = false` to skip the prompt and decrypt
immediately. Choosing "keep encrypted" leaves the ciphertext untouched.
The buffer shows a `[vault-id: x]` note when applicable.

| Command | Action |
| --- | --- |
| `:AnsibleVaultDecrypt` | Decrypt the current buffer (re-encrypts on write) |
| `:AnsibleVaultEncrypt[!] [vault-id]` | Encrypt the current buffer, replacing it with ciphertext (`!` asks for a one-off password) |
| `:AnsibleVaultRekey` | Re-encrypt the file with a new password (and optionally a new vault-id) |
| `:AnsibleVaultToggle` | Decrypt the block under the cursor, or encrypt the plaintext under it |
| `:AnsibleVaultDecryptString` | Decrypt the `!vault` block under the cursor back to plaintext |
| `:AnsibleVaultFiles` | Find vault secrets (inline blocks + encrypted files) in the project |
| `:AnsibleVaultClearCache` | Forget cached (prompted) passwords |

### Inline `!vault` blocks

```yaml
db_password: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          6438316338653863633032366232653137...
```

- One key for both directions: cursor on a `key: value` line → `<leader>avv`
  encrypts the value; cursor on a `!vault` block → `<leader>avv` decrypts it
  back to plaintext. (Same as `:AnsibleVaultToggle`.) A `key: value` line keeps
  its key without asking; with `confirm_default = false` and a password source
  it encrypts with no prompt at all.
- Cursor anywhere on the block → `<leader>ave` or `:AnsibleVaultEdit` →
  single-line values open in `vim.ui.input` (the snacks.input dialog when
  installed, same as the variable-name prompt) pre-filled with the current
  value; multi-line values open in the floating editor. `<CR>`/`:w` saves
  and re-encrypts, `<Esc>`/`q` cancels. (`inline.editor` to force one.)
- `<leader>avf` or `:AnsibleVaultSecrets` lists every `!vault` secret in the
  buffer (snacks.nvim or telescope if installed, `vim.ui.select` otherwise)
  and opens the chosen one in the edit float.
- `<leader>avF` or `:AnsibleVaultFiles` searches the whole project: inline
  secrets in yaml files (`file:line key`) and whole-file encrypted files.
  Picking an inline secret jumps to it and opens the edit float.
- `<leader>avE` or `:AnsibleVaultReveal` decrypts **all** blocks in place into
  editable lines (`key: value`, or a `key: |-` literal block for multi-line
  values). `:w` re-encrypts each secret and writes only ciphertext to disk;
  the buffer keeps the plaintext view. Run again to re-encrypt in the
  buffer. Multi-line and vault-id'd secrets are supported.
- Visually select text (or put the cursor on a `key: value` line) →
  `:'<,'>AnsibleVaultEncryptString` → prompts for a variable name and
  replaces the selection with a `!vault` block. For a single `key: value`
  line the key is pre-filled and only the value is encrypted.
- Both `:AnsibleVaultEncryptString` and `:AnsibleVaultEncrypt` accept an
  optional vault-id argument (`:AnsibleVaultEncryptString prod`) and fall
  back to the `vault_id` config option; existing vault-ids are always
  preserved on edit/write.

## Keymaps

All vault operations live under the **`<leader>av` (ansible vault)
prefix** — chosen to coexist with LazyVim defaults and with
[mfussenegger/nvim-ansible](https://github.com/mfussenegger/nvim-ansible)
(which suggests `<leader>t…` for its `run()` and shares our `yaml.ansible`
filetype detection and `K`/`keywordprg` behavior — overlapping, harmless).
Lowercase keys act on the **secret under the cursor**, uppercase on the
**whole buffer**.

The mappings are **buffer-local** — they only exist in buffers whose
filetype is in `keymap_filetypes` (yaml by default), so they cannot clash
with your other mappings. The only exception is `<leader>avF`, which is
**global** and works from any buffer when the current file sits inside an
ansible project (detected via `ansible.cfg`, `group_vars/`, `host_vars/`,
`playbooks/`, or `roles/`); elsewhere it just warns. `K` is global but falls
back to the default `K` off a vault block, and buffer-local mappings (e.g.
LSP hover) take precedence over it.

### which-key group names

So the popup shows `ansible` / `vault` instead of `+N keymaps`, the plugin
exposes `require("neoansible-vault").which_key_spec()`. With lazy.nvim the
installer already adds this to your spec (contributing to which-key's
`opts.spec`, assembled before which-key loads — immune to load-order races):

```lua
{
  "folke/which-key.nvim",
  optional = true,
  opts = function(_, opts)
    opts.spec = opts.spec or {}
    vim.list_extend(opts.spec, require("neoansible-vault").which_key_spec())
  end,
}
```

Without lazy.nvim, `setup()` also calls `wk.add()` directly (queued before
which-key loads, or inserted into the live registry if it already loaded).

| Key | Action |
| --- | --- |
| `<leader>avv` | Encrypt/decrypt toggle: encrypt the value under the cursor, or decrypt the block under it |
| `<leader>avV` | Encrypt/decrypt toggle for the whole buffer, by state |
| `<leader>ave` | Reveal/edit the secret under the cursor (input dialog or float) |
| `<leader>avE` | Reveal/edit all secrets in the buffer in place (`:w` re-encrypts) |
| `<leader>avf` | Find secrets in the buffer (snacks/telescope/select) |
| `<leader>avF` | Find secrets in the project (works from any buffer in ansible projects) |
| `<leader>avk` | Rekey the secret under the cursor (new password, optionally new vault-id) |
| `<leader>avK` | Rekey the file (new password, optionally new vault-id) |
| `K` | Decrypted hover preview of the block under cursor |

## snacks.nvim integration

When snacks.nvim is installed (all optional, no hard dependency):

- **Explorer actions** — the snacks explorer gains an `ansible vault:
  encrypt/decrypt file` toggle action (in-place on disk, dispatched by
  state), bound to `<leader>avV` inside the explorer window. Encryption
  still asks which vault-id to use.
- **Lock icons** — vault-encrypted files show a `󰌆` instead of their
  extension icon in all snacks pickers (detected by content, cached per
  mtime).

Disable either with `snacks = { explorer = false, icons = false }`.

## Picker integration

Finders auto-detect snacks.nvim, then telescope, then `vim.ui.select`
(`picker.backend` to force one). Two deeper integrations are available:

**Snacks sources** — merge into your snacks config, then call
`:lua Snacks.picker.ansible_vault_secrets()` / `ansible_vault_files()`:

```lua
picker = {
  sources = require("neoansible-vault.picker").snacks_sources(),
},
```

**Telescope extension** — `:Telescope neoansible-vault secrets|files`
(`require("telescope").load_extension("neoansible-vault")` if not
auto-loaded).

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

## Highlights

The edit float uses these groups (linked to sensible colorful defaults;
override them in your colorscheme or config to restyle the dialog):

| Group | Default link | Used for |
| --- | --- | --- |
| `NeoAnsibleVaultTitle` | `Title` | float title (`vault: <key>`) |
| `NeoAnsibleVaultFooter` | `Special` | footer key hints |
| `NeoAnsibleVaultBorder` | `FloatBorder` | float border |

```lua
vim.api.nvim_set_hl(0, "NeoAnsibleVaultTitle", { fg = "#f9e2af", bold = true })
```

The float's content gets `filetype=yaml` for basic syntax coloring.

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
