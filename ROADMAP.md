# ROADMAP

- [x] neovim plugin for ansible vault integration
- [x] file, environment variable, and prompt based password management
      (`password`/`password_file` config, `$ANSIBLE_VAULT_PASSWORD`,
      `$ANSIBLE_VAULT_PASSWORD_FILE`, `.env` files, `.vault-password`
      discovery, interactive prompt with in-memory cache)
- [x] auto detection of ansible vault encrypted files
      (whole-file `$ANSIBLE_VAULT;` header incl. vault-ids, inline `!vault` blocks)
- [x] inline secret editing with automatic re-encryption
      (floating-window editor, `:AnsibleVaultEdit`, `:AnsibleVaultEncryptString`)

- [x] inline secret encryption
      (`:AnsibleVaultEncryptString` turns a line/selection into a `!vault` block)
- [x] file encryption/decryption commands
      (`:AnsibleVaultDecrypt`, `:AnsibleVaultEncrypt`)
- [x] Tree-sitter based inline region detection
      (optional YAML parser filters false positives; line-based fallback)
- [x] telescope/snacks.nvim integration
      (`:AnsibleVaultSecrets` picker with `vim.ui.select` fallback)
- [x] rekey support
      (`:AnsibleVaultRekey` with vault-id label preservation)
- [x] vault-id on encryption
      (`vault_id` config + optional `[vault-id]` argument on encrypt commands)
- [x] multi-vault password sources
      (per-id `vault_ids` config; `ansible.cfg` `vault_identity_list` and
      `vault_password_file`; `$ANSIBLE_VAULT_IDENTITY_LIST`; `$ANSIBLE_CONFIG`;
      `@prompt` identities; `.vault_pass` discovery alias; vault-id picker and
      command completion for new encryptions)
- [x] new vault-ids and one-off passwords on encryption
      (`[vault-id]` args accept any label, picker offers "(new id…)";
      `:AnsibleVaultEncrypt[!]` / `:AnsibleVaultEncryptString[!]` bang skips
      all password sources and prompts for a one-off password that replaces
      the cached one)
- [x] confirm-before-encrypt (`confirm_default`, default on)
      (every encryption flow asks whether to use the default vault/password,
      a known vault-id, or a new id; explicit `[vault-id]` args skip the
      question; set to false for silent default behavior)
- [x] statusline component
      (`require("neoansible-vault").status()` → `[vault]` / `[vault:<id>]`)
- [x] lazy.nvim integration
      (lazy-loading spec in README/install.sh, zero-config bootstrap works
      when loaded after startup)
- [x] concealed inline blobs
      (hex bodies hidden via conceal_lines extmarks with a `[vault]` marker)
- [x] hover preview
      (`K` on a `!vault` block shows the decrypted value read-only)
- [x] `yaml.ansible` filetype detection
      (playbooks, roles, group_vars/host_vars layouts)
- [x] buffer-local keymaps
      (`<leader>ve`/`<leader>vl` only exist in yaml buffers; `K` falls back
      to default K; `<leader>v` is unused by LazyVim)
- [x] encrypt value/line under cursor (`<leader>vs`)
- [x] decrypt a block back to plaintext
      (`:AnsibleVaultDecryptString`, `<leader>vd`)
- [x] vault file picker (`:AnsibleVaultFiles`, `<leader>vf`)
- [x] reveal mode: in-place decrypt-all with re-encrypt on write
      (`:AnsibleVaultReveal`, `<leader>vr`)
- [x] interface cleanup
      (single `keymaps` config table; `<leader>ve` encrypt/decrypt toggle;
      `<leader>vf`/`<leader>vF` find in buffer/project; `<leader>vr`/`<leader>vR`
      reveal secret/buffer; snacks.win edit float; snacks picker sources;
      telescope extension)
