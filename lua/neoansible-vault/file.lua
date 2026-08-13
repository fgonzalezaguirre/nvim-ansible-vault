---Transparent whole-file vault editing.
---
---A vault-encrypted file opened in a buffer is replaced in-place with its
---decrypted plaintext (BufReadPost). The buffer is flagged via
---`b:neoansible_vault` and switched to `buftype=acwrite`; a buffer-local
---BufWriteCmd re-encrypts on every write.
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

---Split process stdout into buffer lines, dropping the trailing empty entry
---produced by a final newline.
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
---@return table|nil state
local function get_state(buf)
  local ok, state = pcall(vim.api.nvim_buf_get_var, buf, "neoansible_vault")
  if ok then
    return state
  end
  return nil
end

---Mark a decrypted buffer and wire up re-encryption on write.
---@param buf integer
---@param state { path: string, vault_id: string|nil, version: string|nil }
local function flag_buffer(buf, state)
  vim.b[buf].neoansible_vault = state
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  -- NOTE: 'backup'/'writebackup' are global-only options; users who want
  -- plaintext kept out of backups should set them globally.

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    desc = "neoansible-vault: re-encrypt on write",
    callback = function()
      M.write(buf)
    end,
  })
end

---Decrypt the vault file backing `buf` into the buffer.
---@param buf integer
---@param path string
---@param header table parsed vault header
local function decrypt_into(buf, path, header)
  password.get({ start_dir = vim.fs.dirname(path), vault_id = header.vault_id }, function(cred, err)
    if not cred then
      notify_err(err or "no vault password available")
      return
    end
    cli.view(path, cred, function(view_err, out)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if view_err then
        notify_err("failed to decrypt " .. vim.fn.fnamemodify(path, ":t") .. ": " .. view_err)
        return
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, to_lines(out))
      vim.bo[buf].modified = false
      flag_buffer(buf, { path = path, vault_id = header.vault_id, version = header.version })
      notify(
        ("decrypted %s%s"):format(
          vim.fn.fnamemodify(path, ":t"),
          header.vault_id and (" [vault-id: " .. header.vault_id .. "]") or ""
        ),
        vim.log.levels.INFO
      )
    end)
  end)
end

---BufReadPost handler: replace ciphertext with plaintext for vault files.
---@param buf integer
local function on_read(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return
  end
  local header = detect.file_header(path)
  if not header then
    return
  end
  decrypt_into(buf, path, header)
end

---BufWriteCmd handler for flagged buffers: encrypt buffer content to disk.
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
  local text = table.concat(lines, "\n")
  if vim.bo[buf].endofline then
    text = text .. "\n"
  end

  local uv = vim.uv or vim.loop
  local fd, tmp = uv.fs_mkstemp(uv.os_tmpdir() .. "/neoansible-vault-write-XXXXXX")
  if not fd then
    notify_err("failed to create temp file for encryption")
    return
  end
  uv.fs_write(fd, text, 0)
  uv.fs_close(fd)

  password.get({ start_dir = vim.fs.dirname(target), vault_id = state.vault_id }, function(cred, err)
    if not cred then
      pcall(os.remove, tmp)
      notify_err(err or "no vault password available")
      return
    end
    cli.encrypt_file(tmp, target, cred, state.vault_id, function(enc_err)
      pcall(os.remove, tmp)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if enc_err then
        notify_err("failed to encrypt " .. vim.fn.fnamemodify(target, ":t") .. ": " .. enc_err)
        return
      end
      state.path = target
      vim.b[buf].neoansible_vault = state
      vim.bo[buf].modified = false
      notify("encrypted and wrote " .. vim.fn.fnamemodify(target, ":t"), vim.log.levels.INFO)
    end)
  end)
end

---Explicitly decrypt the current buffer (which must contain vault ciphertext).
function M.decrypt_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local header = detect.buffer_header(lines)
  if not header then
    notify_err("current buffer does not look like an ansible vault file")
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local start_dir = path ~= "" and vim.fs.dirname(path) or (vim.uv or vim.loop).cwd()
  password.get({ start_dir = start_dir, vault_id = header.vault_id }, function(cred, err)
    if not cred then
      notify_err(err or "no vault password available")
      return
    end
    cli.decrypt_blob(table.concat(lines, "\n") .. "\n", cred, function(dec_err, out)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if dec_err then
        notify_err("decryption failed: " .. dec_err)
        return
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, to_lines(out))
      vim.bo[buf].modified = false
      flag_buffer(buf, { path = path, vault_id = header.vault_id, version = header.version })
      notify("buffer decrypted; it will be re-encrypted on write", vim.log.levels.INFO)
    end)
  end)
end

---Explicitly encrypt the current buffer, replacing its content with ciphertext.
function M.encrypt_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if detect.buffer_header(lines) then
    notify_err("buffer is already vault encrypted")
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local start_dir = path ~= "" and vim.fs.dirname(path) or (vim.uv or vim.loop).cwd()
  local state = get_state(buf)
  local vault_id = state and state.vault_id or nil

  password.get({ start_dir = start_dir, vault_id = vault_id }, function(cred, err)
    if not cred then
      notify_err(err or "no vault password available")
      return
    end
    local text = table.concat(lines, "\n")
    if vim.bo[buf].endofline then
      text = text .. "\n"
    end
    local uv = vim.uv or vim.loop
    local fd, tmp = uv.fs_mkstemp(uv.os_tmpdir() .. "/neoansible-vault-enc-XXXXXX")
    if not fd then
      notify_err("failed to create temp file for encryption")
      return
    end
    uv.fs_write(fd, text, 0)
    uv.fs_close(fd)
    local out = tmp .. ".out"
    cli.encrypt_file(tmp, out, cred, vault_id, function(enc_err)
      pcall(os.remove, tmp)
      if not vim.api.nvim_buf_is_valid(buf) then
        pcall(os.remove, out)
        return
      end
      if enc_err then
        pcall(os.remove, out)
        notify_err("encryption failed: " .. enc_err)
        return
      end
      local fd_out = io.open(out, "r")
      local ciphertext = fd_out and fd_out:read("*a") or ""
      if fd_out then
        fd_out:close()
      end
      pcall(os.remove, out)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, to_lines(ciphertext))
      vim.bo[buf].modified = true
      -- The buffer now holds ciphertext: drop the transparent-write hook.
      vim.b[buf].neoansible_vault = nil
      vim.bo[buf].buftype = ""
      vim.api.nvim_clear_autocmds({ group = group, buffer = buf, event = "BufWriteCmd" })
      notify("buffer encrypted; write to save the ciphertext", vim.log.levels.INFO)
    end)
  end)
end

---Register autocmds. Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("neoansible_vault", { clear = true })

  if config.get().auto_decrypt then
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = group,
      pattern = "*",
      desc = "neoansible-vault: transparently decrypt vault files",
      callback = function(ev)
        on_read(ev.buf)
      end,
    })
  end
end

return M
