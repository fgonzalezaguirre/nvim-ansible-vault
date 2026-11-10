---snacks.nvim integration (all optional, config-gated, no hard dependency):
---
---  * explorer = true: adds "ansible vault: encrypt/decrypt file" actions to
---    the snacks explorer, bound to the same <leader>a keys as the
---    buffer-level file commands.
---  * icons = true: shows a lock icon for vault-encrypted files in all
---    snacks pickers (the explorer included), detected by file content,
---    cached per mtime.
local cli = require("ansible-vault.cli")
local config = require("ansible-vault.config")
local detect = require("ansible-vault.detect")
local ids = require("ansible-vault.ids")
local password = require("ansible-vault.password")

local M = {}

local ICON = "󰌆 "
local ICON_HL = "Special"

local function notify(msg, level)
  vim.notify(msg, level, { title = "ansible-vault" })
end

-- path -> { mtime = integer|nil, encrypted = boolean }
local probe_cache = {}

---Is the file at `path` vault-encrypted? (first-line probe, cached by mtime)
---@param path string
---@return boolean
function M.is_encrypted(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  local mtime = stat and stat.type == "file" and stat.mtime.sec or nil
  local cached = probe_cache[path]
  if cached and cached.mtime == mtime then
    return cached.encrypted
  end
  local encrypted = mtime ~= nil and detect.file_header(path) ~= nil
  probe_cache[path] = { mtime = mtime, encrypted = encrypted }
  return encrypted
end

---Invalidate the icon cache entry for a path.
---@param path string
local function invalidate(path)
  probe_cache[path] = nil
end

---Refresh the explorer tree after changing a file.
---@param picker any
---@param dir string
local function refresh_explorer(picker, dir)
  local ok_tree, Tree = pcall(require, "snacks.explorer.tree")
  if ok_tree then
    pcall(Tree.refresh, Tree, dir)
  end
  local ok_actions, Actions = pcall(require, "snacks.explorer.actions")
  if ok_actions then
    pcall(Actions.update, picker, { refresh = true })
  end
end

---snacks explorer action: encrypt the file under the cursor.
---@param picker any
---@param item any
function M.explorer_encrypt(picker, item)
  if not item or not item.file or item.dir then
    return
  end
  if M.is_encrypted(item.file) then
    notify(item.file .. " is already vault encrypted", vim.log.levels.WARN)
    return
  end
  local start_dir = vim.fs.dirname(item.file)
  ids.pick_dir(start_dir, function(vault_id)
    -- vault_id is nil when the user chose "(default)"; on picker abort the
    -- callback is never invoked and nothing happens.
    password.get({ start_dir = start_dir, vault_id = vault_id }, function(cred, err)
      if not cred then
        notify(err or "no vault password available", vim.log.levels.ERROR)
        return
      end
      cli.encrypt_inplace(item.file, cred, vault_id, function(enc_err)
        if enc_err then
          notify("encryption failed: " .. enc_err, vim.log.levels.ERROR)
          return
        end
        invalidate(item.file)
        notify(
          ("encrypted %s%s"):format(
            vim.fn.fnamemodify(item.file, ":t"),
            vault_id and (" [vault-id: " .. vault_id .. "]") or ""
          ),
          vim.log.levels.INFO
        )
        refresh_explorer(picker, start_dir)
      end)
    end)
  end)
end

---snacks explorer action: decrypt the file under the cursor.
---@param picker any
---@param item any
function M.explorer_decrypt(picker, item)
  if not item or not item.file or item.dir then
    return
  end
  local header = detect.file_header(item.file)
  if not header then
    notify(item.file .. " is not vault encrypted", vim.log.levels.WARN)
    return
  end
  local start_dir = vim.fs.dirname(item.file)
  password.get({ start_dir = start_dir, vault_id = header.vault_id }, function(cred, err)
    if not cred then
      notify(err or "no vault password available", vim.log.levels.ERROR)
      return
    end
    cli.decrypt_inplace(item.file, cred, function(dec_err)
      if dec_err then
        notify("decryption failed: " .. dec_err, vim.log.levels.ERROR)
        return
      end
      invalidate(item.file)
      notify(("decrypted %s"):format(vim.fn.fnamemodify(item.file, ":t")), vim.log.levels.INFO)
      refresh_explorer(picker, start_dir)
    end)
  end)
end

---snacks explorer action: toggle the file under the cursor — decrypt when
---encrypted, encrypt when plaintext.
---@param picker any
---@param item any
function M.explorer_toggle(picker, item)
  if not item or not item.file or item.dir then
    return
  end
  if M.is_encrypted(item.file) then
    M.explorer_decrypt(picker, item)
  else
    M.explorer_encrypt(picker, item)
  end
end

---Register explorer actions and keymaps, and wrap the icon resolver.
---Uses the live snacks config table, so it also works when snacks was set
---up before us. No-op when snacks is not installed.
function M.setup()
  local cfg = config.get().snacks
  if not cfg or (not cfg.explorer and not cfg.icons) then
    return
  end
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    return
  end

  if cfg.explorer then
    local picker_cfg = Snacks.config.picker
    picker_cfg.sources = picker_cfg.sources or {}
    local explorer = picker_cfg.sources.explorer or {}

    explorer.actions = explorer.actions or {}
    explorer.actions.ansible_vault_toggle = { action = M.explorer_toggle, desc = "Ansible vault: encrypt/decrypt file" }
    explorer.actions.ansible_vault_encrypt = { action = M.explorer_encrypt, desc = "Ansible vault: encrypt file" }
    explorer.actions.ansible_vault_decrypt = { action = M.explorer_decrypt, desc = "Ansible vault: decrypt file" }

    local km = config.get().keymaps
    explorer.win = explorer.win or {}
    explorer.win.list = explorer.win.list or {}
    explorer.win.list.keys = explorer.win.list.keys or {}
    if km.toggle_buffer and km.toggle_buffer ~= "" then
      explorer.win.list.keys[km.toggle_buffer] = "ansible_vault_toggle"
    end

    picker_cfg.sources.explorer = explorer
  end

  if cfg.icons and not M._icons_wrapped then
    M._icons_wrapped = true
    local util = Snacks.util
    local orig_icon = util.icon
    ---@diagnostic disable-next-line: duplicate-set-field
    util.icon = function(name, cat, opts)
      if cat == "file" and type(name) == "string" and M.is_encrypted(name) then
        return ICON, ICON_HL
      end
      return orig_icon(name, cat, opts)
    end
  end
end

return M
