---Inline `!vault` secret editing via a floating window.
---
---The vault block under the cursor is decrypted into a floating scratch
---buffer. Writing the float (`:w` or `<CR>`) re-encrypts the content with
---`ansible-vault encrypt_string` and replaces the original block in place.
local cli = require("neoansible-vault.cli")
local config = require("neoansible-vault.config")
local detect = require("neoansible-vault.detect")
local password = require("neoansible-vault.password")

local M = {}

local group = nil

local function notify(msg, level)
  vim.notify(msg, level, { title = "neoansible-vault" })
end

local function notify_err(msg)
  notify(msg, vim.log.levels.ERROR)
end

---@param text string
---@return string[]
local function to_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---@param buf integer
---@return string start_dir
local function buffer_dir(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path ~= "" then
    return vim.fs.dirname(path)
  end
  return (vim.uv or vim.loop).cwd()
end

---Re-indent `encrypt_string` output to match the original region.
---Also used by reveal.lua.
---@param block string raw encrypt_string stdout
---@param key_indent integer
---@param blob_indent integer
---@return string[]
function M.indent_block(block, key_indent, blob_indent)
  local out = {}
  for i, line in ipairs(to_lines(block)) do
    if i == 1 then
      table.insert(out, string.rep(" ", key_indent) .. line)
    else
      table.insert(out, string.rep(" ", blob_indent) .. (line:gsub("^%s*", "")))
    end
  end
  return out
end

---Open the decrypted secret in a floating window.
---@param src_buf integer
---@param region neoansible-vault.InlineRegion
---@param plaintext string
---@param cred neoansible-vault.Credential
---@param vault_id string|nil
local function open_float(src_buf, region, plaintext, cred, vault_id)
  local cfg = config.get().inline.float

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, to_lines(plaintext))
  vim.bo[fbuf].buftype = "acwrite"
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].swapfile = false
  vim.api.nvim_buf_set_name(fbuf, ("ansible-vault://%s"):format(region.key))

  local content_width = 1
  for _, l in ipairs(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  local max_w = math.floor(vim.o.columns * cfg.max_width)
  local max_h = math.floor(vim.o.lines * cfg.max_height)
  local width = math.min(math.max(content_width + 1, 20), max_w)
  local height = math.min(math.max(#to_lines(plaintext), 1), max_h)

  local title = (" vault: %s%s "):format(region.key, vault_id and (" [" .. vault_id .. "]") or "")
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = cfg.border,
    title = title,
    title_pos = "center",
    footer = " <CR> save & re-encrypt · <Esc> cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function save()
    local plain = table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
    cli.encrypt_string(plain, region.key, cred, vault_id, function(err, block)
      if err then
        notify_err("re-encryption failed: " .. err)
        return
      end
      if not vim.api.nvim_buf_is_valid(src_buf) then
        notify_err("source buffer is gone; discarding changes")
        return
      end
      local new_lines = M.indent_block(block, region.key_indent, region.blob_indent)
      vim.api.nvim_buf_set_lines(src_buf, region.start_row, region.end_row, false, new_lines)
      vim.bo[fbuf].modified = false
      close()
      notify(("re-encrypted %s"):format(region.key), vim.log.levels.INFO)
    end)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = fbuf,
    desc = "neoansible-vault: re-encrypt inline secret",
    callback = save,
  })
  vim.keymap.set("n", "<CR>", function()
    vim.cmd.write()
  end, { buffer = fbuf, desc = "Save and re-encrypt" })
  vim.keymap.set("n", "<Esc>", close, { buffer = fbuf, desc = "Cancel vault edit" })
  vim.keymap.set("n", "q", close, { buffer = fbuf, desc = "Cancel vault edit" })
end

---Find the vault region under the cursor, honoring the treesitter option.
---@param buf integer
---@param row integer 0-indexed row
---@return neoansible-vault.InlineRegion|nil
local function region_at(buf, row)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if config.get().inline.treesitter then
    return detect.inline_region_at_ts(buf, lines, row)
  end
  return detect.inline_region_at(lines, row)
end

---Edit the inline vault block under the cursor.
function M.edit()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local region = region_at(buf, row)
  if not region then
    notify_err("no !vault block under the cursor")
    return
  end

  local header = detect.parse_header((region.blob_lines[1]:gsub("^%s*", "")))
  local vault_id = header and header.vault_id or nil

  password.get({ start_dir = buffer_dir(buf), vault_id = vault_id }, function(cred, err)
    if not cred then
      notify_err(err or "no vault password available")
      return
    end
    cli.decrypt_blob(detect.region_blob_text(region), cred, function(dec_err, plaintext)
      if dec_err then
        notify_err("failed to decrypt " .. region.key .. ": " .. dec_err)
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      open_float(buf, region, plaintext, cred, vault_id)
    end)
  end)
end

---Show the decrypted secret under the cursor in a read-only hover float.
---@return boolean handled true when the cursor is on a vault block
function M.hover()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local region = region_at(buf, row)
  if not region then
    return false
  end

  local header = detect.parse_header((region.blob_lines[1]:gsub("^%s*", "")))
  local vault_id = header and header.vault_id or nil

  password.get({ start_dir = buffer_dir(buf), vault_id = vault_id }, function(cred, err)
    if not cred then
      notify_err(err or "no vault password available")
      return
    end
    cli.decrypt_blob(detect.region_blob_text(region), cred, function(dec_err, plaintext)
      if dec_err then
        notify_err("failed to decrypt " .. region.key .. ": " .. dec_err)
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.lsp.util.open_floating_preview(to_lines(plaintext), "yaml", {
        border = config.get().inline.float.border,
        focus = false,
      })
    end)
  end)
  return true
end

---Encrypt a range of lines into a `key: !vault |` block.
---@param line1 integer 1-indexed first line
---@param line2 integer 1-indexed last line
---@param vault_id string|nil vault-id label (defaults to config.vault_id)
function M.encrypt_selection(line1, line2, vault_id)
  vault_id = vault_id or config.get().vault_id
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if #lines == 0 then
    return
  end

  -- If the selection is a single `key: value` line, default to that key and
  -- encrypt only the value.
  local default_key = "secret"
  local indent = #(lines[1]:match("^%s*"))
  local plaintext = table.concat(lines, "\n")
  if #lines == 1 then
    local key, value = lines[1]:match("^%s*([%w_.%-]+):%s*(.-)%s*$")
    if key and value ~= "" then
      default_key = key
      plaintext = value
    end
  end

  vim.ui.input({ prompt = "Variable name: ", default = default_key }, function(key)
    if not key or key == "" then
      return
    end
    password.get({ start_dir = buffer_dir(buf), vault_id = vault_id }, function(cred, err)
      if not cred then
        notify_err(err or "no vault password available")
        return
      end
      cli.encrypt_string(plaintext, key, cred, vault_id, function(enc_err, block)
        if enc_err then
          notify_err("encryption failed: " .. enc_err)
          return
        end
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local new_lines = M.indent_block(block, indent, indent + 2)
        vim.api.nvim_buf_set_lines(buf, line1 - 1, line2, false, new_lines)
        notify(("encrypted %s"):format(key), vim.log.levels.INFO)
      end)
    end)
  end)
end

---Register the inline-edit keymap (buffer-local to yaml buffers). Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("neoansible_vault_inline", { clear = true })

  local cfg = config.get().inline
  if cfg.enabled then
    require("neoansible-vault.keymaps").setup(group, cfg.keymap, function()
      M.edit()
    end, "Edit ansible vault secret under cursor")
    require("neoansible-vault.keymaps").setup(group, cfg.encrypt_keymap, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      M.encrypt_selection(row, row)
    end, "Encrypt the value/line under cursor into a !vault block")
  end
  if cfg.enabled and cfg.hover then
    -- Global on purpose: buffer-local (e.g. LSP hover) K mappings still take
    -- precedence; everywhere else the fallback below runs the default K.
    vim.keymap.set("n", "K", function()
      if not M.hover() then
        vim.api.nvim_feedkeys("K", "n", false)
      end
    end, { desc = "Preview ansible vault secret / default K" })
  end
end

return M
