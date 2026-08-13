if vim.g.loaded_neoansible_vault == 1 then
  return
end
vim.g.loaded_neoansible_vault = 1

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify("neoansible-vault requires Neovim >= 0.12", vim.log.levels.ERROR, { title = "neoansible-vault" })
  return
end

vim.api.nvim_create_user_command("AnsibleVaultEdit", function()
  require("neoansible-vault").edit_inline()
end, { desc = "Edit the !vault block under the cursor" })

vim.api.nvim_create_user_command("AnsibleVaultSecrets", function()
  require("neoansible-vault").pick_secret()
end, { desc = "Pick a !vault secret in the current buffer" })

vim.api.nvim_create_user_command("AnsibleVaultEncryptString", function(cmd)
  require("neoansible-vault").encrypt_selection(cmd.line1, cmd.line2)
end, { range = true, desc = "Encrypt lines/selection into a !vault block" })

vim.api.nvim_create_user_command("AnsibleVaultDecrypt", function()
  require("neoansible-vault").decrypt_buffer()
end, { desc = "Decrypt the current buffer (re-encrypts on write)" })

vim.api.nvim_create_user_command("AnsibleVaultEncrypt", function()
  require("neoansible-vault").encrypt_buffer()
end, { desc = "Encrypt the current buffer, replacing it with ciphertext" })

vim.api.nvim_create_user_command("AnsibleVaultRekey", function()
  require("neoansible-vault").rekey_buffer()
end, { desc = "Rekey the vault file with a new password (and vault-id)" })

vim.api.nvim_create_user_command("AnsibleVaultClearCache", function()
  require("neoansible-vault").clear_password_cache()
  vim.notify("vault password cache cleared", vim.log.levels.INFO, { title = "neoansible-vault" })
end, { desc = "Forget cached vault passwords" })

-- Work out of the box with defaults when the user never calls setup().
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("neoansible_vault_bootstrap", { clear = true }),
  once = true,
  callback = function()
    if not require("neoansible-vault.config")._did_setup then
      require("neoansible-vault").setup({})
    end
  end,
})
