---:checkhealth neoansible-vault
local M = {}

function M.check()
  local health = vim.health
  health.start("neoansible-vault")

  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim >= 0.12")
  else
    health.error("Neovim >= 0.12 is required")
  end

  local cli = require("neoansible-vault.cli")
  if cli.executable() then
    local res = vim.system({ "ansible-vault", "--version" }, { text = true }):wait(5000)
    local first = res.stdout and res.stdout:match("[^\n]+") or "unknown version"
    health.ok("ansible-vault found: " .. vim.trim(first))
  else
    health.error("ansible-vault not found in PATH", { "Install ansible-core (provides ansible-vault)." })
  end

  local password = require("neoansible-vault.password")
  local cwd = (vim.uv or vim.loop).cwd()
  local source, err = password.describe_source(cwd)
  if source then
    health.ok("vault password resolves from: " .. source)
  else
    health.warn("no vault password source found for cwd", {
      err or "set $ANSIBLE_VAULT_PASSWORD, $ANSIBLE_VAULT_PASSWORD_FILE, a .env file, or a .vault-password file",
      "interactive prompting is " .. (require("neoansible-vault.config").get().prompt and "enabled" or "disabled"),
    })
  end
end

return M
