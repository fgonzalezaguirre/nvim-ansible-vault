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

---Window-local highlight mapping for the edit float.
local WINHL = table.concat({
  "Normal:NormalFloat",
  "FloatBorder:NeoAnsibleVaultBorder",
  "FloatTitle:NeoAnsibleVaultTitle",
  "FloatFooter:NeoAnsibleVaultFooter",
}, ",")

---Define the plugin's default highlight groups. `default = true` keeps them
---colorscheme/user-overridable; re-applying on every float also restores
---them after a colorscheme change.
local function apply_highlights()
  vim.api.nvim_set_hl(0, "NeoAnsibleVaultTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "NeoAnsibleVaultFooter", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "NeoAnsibleVaultBorder", { link = "FloatBorder", default = true })
end

---Re-encrypt `plain` back into the source buffer's region.
---@param src_buf integer
---@param region neoansible-vault.InlineRegion
---@param cred neoansible-vault.Credential
---@param vault_id string|nil
---@param plain string
---@param on_success fun()|nil
local function reencrypt(src_buf, region, cred, vault_id, plain, on_success)
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
    if on_success then
      on_success()
    end
    notify(("re-encrypted %s"):format(region.key), vim.log.levels.INFO)
  end)
end

---Open the decrypted secret in a floating window.
---@param src_buf integer
---@param region neoansible-vault.InlineRegion
---@param plaintext string
---@param cred neoansible-vault.Credential
---@param vault_id string|nil
local function open_float(src_buf, region, plaintext, cred, vault_id)
  local cfg = config.get().inline.float
  apply_highlights()

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, to_lines(plaintext))
  vim.bo[fbuf].buftype = "acwrite"
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].swapfile = false
  vim.bo[fbuf].filetype = "yaml" -- a little syntax color for the value
  vim.api.nvim_buf_set_name(fbuf, ("ansible-vault://%s"):format(region.key))

  local content_width = 1
  for _, l in ipairs(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  local title = (" vault: %s%s "):format(region.key, vault_id and (" [" .. vault_id .. "]") or "")
  local footer = " <CR> save & re-encrypt · <Esc> cancel "

  local max_w = math.floor(vim.o.columns * cfg.max_width)
  local max_h = math.floor(vim.o.lines * cfg.max_height)
  -- never narrower than the footer/title, never tinier than 44x3: a 20x1
  -- float for a short secret reads as cramped and clips the footer
  local width =
    math.min(math.max(content_width + 2, vim.fn.strdisplaywidth(footer), vim.fn.strdisplaywidth(title), 44), max_w)
  local height = math.min(math.max(#to_lines(plaintext), 3), max_h)

  local wo = { wrap = false, scrolloff = 0, sidescrolloff = 0, winhighlight = WINHL }

  local win, close
  local ok, snacks = pcall(require, "snacks")
  local sw = nil
  if ok and snacks.win then
    -- LazyVim-native look: consistent border/title/footer. backdrop=false:
    -- snacks' built-in "float" style enables a backdrop window by default,
    -- which renders as an opaque blank pane in some setups.
    ok, sw = pcall(snacks.win, {
      buf = fbuf,
      enter = true,
      width = width,
      height = height,
      border = cfg.border,
      title = title,
      footer = footer,
      backdrop = false,
      wo = wo,
      keys = {
        q = "close",
        ["<esc>"] = "close",
        ["<cr>"] = function()
          vim.cmd.write()
        end,
      },
    })
    if ok and sw then
      win = sw.win
      close = function()
        sw:close()
      end
    end
  end
  if not win then
    win = vim.api.nvim_open_win(fbuf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = cfg.border,
      title = title,
      title_pos = "center",
      footer = footer,
      footer_pos = "center",
    })
    for k, v in pairs(wo) do
      vim.wo[win][k] = v
    end

    local function close_win()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    close = close_win
    vim.keymap.set("n", "<Esc>", close, { buffer = fbuf, desc = "Cancel vault edit" })
    vim.keymap.set("n", "q", close, { buffer = fbuf, desc = "Cancel vault edit" })
  end

  local function save()
    local plain = table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
    reencrypt(src_buf, region, cred, vault_id, plain, function()
      vim.bo[fbuf].modified = false
      close()
    end)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = fbuf,
    desc = "neoansible-vault: re-encrypt inline secret",
    callback = save,
  })
  if not sw then
    vim.keymap.set("n", "<CR>", function()
      vim.cmd.write()
    end, { buffer = fbuf, desc = "Save and re-encrypt" })
  end
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
      -- single-line values edit in vim.ui.input (snacks.input when installed);
      -- multi-line values need the float
      local value = plaintext:gsub("\n$", "")
      local editor = config.get().inline.editor
      if editor ~= "float" and not value:find("\n", 1, true) then
        vim.ui.input({
          prompt = ("vault: %s%s "):format(region.key, vault_id and (" [" .. vault_id .. "]") or ""),
          default = value,
        }, function(input)
          if input == nil then
            return -- cancelled
          end
          reencrypt(buf, region, cred, vault_id, input)
        end)
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

---Format a decrypted value as yaml lines at `key_indent`. Single-line values
---stay inline (`key: value`) unless they would break plain-scalar YAML;
---anything else becomes a `key: |-` literal block.
---Also used by reveal.lua.
---@param key string
---@param key_indent integer
---@param value string
---@return string[]
function M.plaintext_lines(key, key_indent, value)
  local indent = string.rep(" ", key_indent)
  value = value:gsub("\n$", "")
  local single = not value:find("\n", 1, true)
    and value == vim.trim(value)
    and not value:find(": ", 1, true)
    and not value:find(" #", 1, true)
  if single then
    if value == "" then
      return { indent .. key .. ": ''" }
    end
    return { indent .. key .. ": " .. value }
  end
  local out = { indent .. key .. ": |-" }
  for line in (value .. "\n"):gmatch("(.-)\n") do
    table.insert(out, indent .. "  " .. line)
  end
  return out
end

---Decrypt the inline vault block under the cursor, replacing it with the
---plaintext value in place (`key: value`, or `key: |-` for multi-line).
---The complement of encrypt_selection: nothing is re-encrypted on write.
function M.decrypt_value()
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
      local new_lines = M.plaintext_lines(region.key, region.key_indent, plaintext)
      vim.api.nvim_buf_set_lines(buf, region.start_row, region.end_row, false, new_lines)
      notify(("decrypted %s; it stays plaintext until re-encrypted"):format(region.key), vim.log.levels.INFO)
    end)
  end)
end

---Encrypt a range of lines into a `key: !vault |` block.
---@param line1 integer 1-indexed first line
---@param line2 integer 1-indexed last line
---@param vault_id string|nil vault-id label (config.vault_id / picker when nil)
---@param opts { force_prompt: boolean|nil }|nil force_prompt: ask for a one-off password
function M.encrypt_selection(line1, line2, vault_id, opts)
  opts = opts or {}
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

  local function with_vault_id(id)
    vim.ui.input({ prompt = "Variable name: ", default = default_key }, function(key)
      if not key or key == "" then
        return
      end
      password.get({ start_dir = buffer_dir(buf), vault_id = id, force_prompt = opts.force_prompt }, function(cred, err)
        if not cred then
          notify_err(err or "no vault password available")
          return
        end
        cli.encrypt_string(plaintext, key, cred, id, function(enc_err, block)
          if enc_err then
            notify_err("encryption failed: " .. enc_err)
            return
          end
          if not vim.api.nvim_buf_is_valid(buf) then
            return
          end
          local new_lines = M.indent_block(block, indent, indent + 2)
          vim.api.nvim_buf_set_lines(buf, line1 - 1, line2, false, new_lines)
          notify(("encrypted %s%s"):format(key, id and (" [vault-id: " .. id .. "]") or ""), vim.log.levels.INFO)
        end)
      end)
    end)
  end

  if vault_id then
    with_vault_id(vault_id)
  else
    require("neoansible-vault.ids").pick(buf, with_vault_id)
  end
end

---Toggle the cursor line: decrypt the `!vault` block under the cursor, or
---encrypt the plaintext value/line under the cursor.
function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if region_at(buf, row) then
    M.decrypt_value()
  else
    M.encrypt_selection(row + 1, row + 1)
  end
end

---Register the inline keymaps (buffer-local to yaml buffers). Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("neoansible_vault_inline", { clear = true })

  local cfg = config.get().inline
  if cfg.enabled then
    local km = config.get().keymaps
    require("neoansible-vault.keymaps").setup(group, km.toggle, function()
      M.toggle()
    end, "Ansible vault: encrypt/decrypt under cursor")
    require("neoansible-vault.keymaps").setup(group, km.reveal_secret, function()
      M.edit()
    end, "Ansible vault: reveal/edit secret under cursor")
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
