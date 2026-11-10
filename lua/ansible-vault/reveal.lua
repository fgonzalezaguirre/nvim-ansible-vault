---Reveal all inline `!vault` secrets in the buffer as editable plaintext.
---
---Toggling on decrypts every `!vault` block in place (a `key: value` line,
---or a `key: |-` literal block for multi-line values) and switches the
---buffer to acwrite: every `:w` re-encrypts each secret and writes only
---ciphertext to disk, while the buffer keeps the plaintext view. Toggling
---off re-encrypts the blocks inside the buffer as well.
local cli = require("ansible-vault.cli")
local config = require("ansible-vault.config")
local detect = require("ansible-vault.detect")
local inline = require("ansible-vault.inline")
local password = require("ansible-vault.password")

local M = {}

local group = nil
local STATE_VAR = "ansible_vault_reveal"

local function notify(msg, level)
  vim.notify(msg, level, { title = "ansible-vault" })
end

local function notify_err(msg)
  notify(msg, vim.log.levels.ERROR)
end

---@param buf integer
---@return table|nil state
local function get_state(buf)
  local ok, state = pcall(vim.api.nvim_buf_get_var, buf, STATE_VAR)
  return ok and state or nil
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

---Run fn(item, step) sequentially over items.
---@param items any[]
---@param fn fun(item: any, step: fun())
---@param done fun()
local function each(items, fn, done)
  local i = 0
  local function step()
    i = i + 1
    if i > #items then
      done()
      return
    end
    fn(items[i], step)
  end
  step()
end

---Locate a revealed entry's key line in `lines` (1-indexed), searching from
---`from_row`. Keys are matched by indent + name only.
---@return integer|nil row 1-indexed row of the key line
local function find_key(lines, entry, from_row)
  local prefix = string.rep(" ", entry.key_indent) .. entry.key .. ":"
  for row = from_row, #lines do
    local l = lines[row]
    if vim.startswith(l, prefix) and (l:sub(#prefix + 1, #prefix + 1):match("[%s]") or #l == #prefix) then
      return row
    end
  end
  return nil
end

---Extract the plaintext value of a revealed entry starting at its key line.
---@return string|nil value, integer|nil end_row 1-indexed row past the value, string|nil err
local function extract_value(lines, entry, row)
  local prefix = string.rep(" ", entry.key_indent) .. entry.key .. ":"
  local rest = vim.trim(lines[row]:sub(#prefix + 1))
  if rest:match("^!vault%s*|") then
    return nil, nil, "block is encrypted again (undone reveal?)"
  end
  if rest:match("^|%-?$") then
    -- literal block: following lines indented deeper than the key
    local value_lines = {}
    local j = row + 1
    while j <= #lines do
      local bl = lines[j]
      if bl:match("^%s*$") then
        break
      end
      if #(bl:match("^%s*")) <= entry.key_indent then
        break
      end
      table.insert(value_lines, bl:sub(entry.key_indent + 3))
      j = j + 1
    end
    if #value_lines == 0 then
      return nil, nil, "empty literal block"
    end
    return table.concat(value_lines, "\n"), j
  end
  if rest == "''" then
    rest = ""
  end
  return rest, row + 1
end

---Resolve and cache one credential per vault-id.
---@param buf integer
---@param vault_id string|nil
---@param cache table<string, ansible-vault.Credential>
---@param cb fun(cred: ansible-vault.Credential|nil)
local function cred_for(buf, vault_id, cache, cb)
  local ck = vault_id or ""
  if cache[ck] then
    cb(cache[ck])
    return
  end
  password.get({ start_dir = buffer_dir(buf), vault_id = vault_id }, function(cred, err)
    if not cred then
      notify_err(err or "no vault password available")
      cb(nil)
      return
    end
    cache[ck] = cred
    cb(cred)
  end)
end

---Encrypt every revealed entry found in `lines` back into `!vault` blocks.
---@param buf integer
---@param lines string[]
---@param state table
---@param cb fun(err: string|nil, out_lines: string[]|nil)
local function transform(buf, lines, state, cb)
  -- locate and extract all entries in document order
  local extracted = {}
  local from = 1
  for _, entry in ipairs(state.entries) do
    local row = find_key(lines, entry, from)
    if not row then
      cb(("cannot find revealed key %q; was it renamed or removed?"):format(entry.key))
      return
    end
    local value, end_row, err = extract_value(lines, entry, row)
    if not value then
      cb(("cannot read %q: %s"):format(entry.key, err))
      return
    end
    table.insert(extracted, { entry = entry, value = value, row = row, end_row = end_row })
    from = end_row
  end

  local creds = {}
  each(extracted, function(x, step)
    cred_for(buf, x.entry.vault_id, creds, function(cred)
      if not cred then
        step()
        return
      end
      cli.encrypt_string(x.value, x.entry.key, cred, x.entry.vault_id, function(err, block)
        if err then
          x.err = err
        else
          x.lines = inline.indent_block(block, x.entry.key_indent, x.entry.key_indent + 2)
        end
        step()
      end)
    end)
  end, function()
    for _, x in ipairs(extracted) do
      if x.err then
        cb(("failed to encrypt %q: %s"):format(x.entry.key, x.err))
        return
      end
      if not x.lines then
        cb(("no vault password available for %q"):format(x.entry.key))
        return
      end
    end
    -- splice the encrypted blocks in, bottom-up
    local out = vim.deepcopy(lines)
    for i = #extracted, 1, -1 do
      local x = extracted[i]
      for _ = x.row, x.end_row - 1 do
        table.remove(out, x.row)
      end
      for j = #x.lines, 1, -1 do
        table.insert(out, x.row, x.lines[j])
      end
    end
    cb(nil, out)
  end)
end

---BufWriteCmd handler: write ciphertext to disk, keep the plaintext view.
---@param buf integer
function M.write(buf)
  local state = get_state(buf)
  if not state then
    return
  end
  local target = vim.api.nvim_buf_get_name(buf)
  if target == "" then
    notify_err("cannot write vault buffer without a file name")
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  transform(buf, lines, state, function(err, out)
    if err then
      notify_err("write aborted: " .. err)
      return
    end
    local text = table.concat(out, "\n")
    if vim.bo[buf].endofline then
      text = text .. "\n"
    end
    local fd = io.open(target, "w")
    if not fd then
      notify_err("cannot open " .. vim.fn.fnamemodify(target, ":t") .. " for writing")
      return
    end
    fd:write(text)
    fd:close()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
    end
    notify(
      ("wrote %s (%d secret(s) re-encrypted)"):format(vim.fn.fnamemodify(target, ":t"), #state.entries),
      vim.log.levels.INFO
    )
  end)
end

---Decrypt every `!vault` block in the buffer into editable plaintext.
---@param buf integer
local function reveal(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local regions
  if config.get().inline.treesitter then
    regions = detect.find_inline_regions_ts(buf, lines)
  else
    regions = detect.find_inline_regions(lines)
  end
  if #regions == 0 then
    notify("no !vault secrets in this buffer", vim.log.levels.WARN)
    return
  end

  local creds = {}
  local entries = {}
  each(regions, function(region, step)
    local header = detect.parse_header((region.blob_lines[1]:gsub("^%s*", "")))
    local vault_id = header and header.vault_id or nil
    cred_for(buf, vault_id, creds, function(cred)
      if not cred then
        step()
        return
      end
      cli.decrypt_blob(detect.region_blob_text(region), cred, function(err, plaintext)
        if err then
          notify_err(("failed to decrypt %s: %s (left encrypted)"):format(region.key, err))
        else
          table.insert(entries, {
            key = region.key,
            key_indent = region.key_indent,
            vault_id = vault_id,
            value = plaintext,
            region = region,
          })
        end
        step()
      end)
    end)
  end, function()
    if #entries == 0 then
      notify_err("no secrets could be decrypted")
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    -- replace blocks with plaintext, bottom-up so rows stay valid
    table.sort(entries, function(a, b)
      return a.region.start_row > b.region.start_row
    end)
    for _, e in ipairs(entries) do
      vim.api.nvim_buf_set_lines(
        buf,
        e.region.start_row,
        e.region.end_row,
        false,
        inline.plaintext_lines(e.key, e.key_indent, e.value)
      )
    end

    -- document-order, slim state for the write path
    table.sort(entries, function(a, b)
      return a.region.start_row < b.region.start_row
    end)
    local slim = {}
    for _, e in ipairs(entries) do
      table.insert(slim, { key = e.key, key_indent = e.key_indent, vault_id = e.vault_id })
    end
    vim.b[buf][STATE_VAR] = { entries = slim }
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      buffer = buf,
      desc = "ansible-vault: re-encrypt revealed secrets on write",
      callback = function()
        M.write(buf)
      end,
    })
    notify(
      ("revealed %d secret(s); :w writes ciphertext to disk, :AnsibleVaultReveal toggles back"):format(#slim),
      vim.log.levels.INFO
    )
  end)
end

---Re-encrypt every revealed secret inside the buffer and drop reveal state.
---@param buf integer
local function unreveal(buf)
  local state = get_state(buf)
  if not state then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  transform(buf, lines, state, function(err, out)
    if err then
      notify_err("unreveal failed: " .. err)
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
    vim.b[buf][STATE_VAR] = nil
    vim.bo[buf].buftype = ""
    vim.bo[buf].modified = true
    vim.api.nvim_clear_autocmds({ group = group, buffer = buf, event = "BufWriteCmd" })
    notify("secrets re-encrypted in the buffer; write to save the ciphertext", vim.log.levels.INFO)
  end)
end

---Toggle reveal mode for the current buffer.
function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  if get_state(buf) then
    unreveal(buf)
  else
    reveal(buf)
  end
end

---Register the toggle keymap (buffer-local to yaml buffers). Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("ansible_vault_reveal", { clear = true })

  local cfg = config.get().inline
  if cfg.enabled then
    require("ansible-vault.keymaps").setup(group, config.get().keymaps.reveal_buffer, function()
      M.toggle()
    end, "Ansible vault: reveal/edit all secrets in buffer")
  end
end

return M
