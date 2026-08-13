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
