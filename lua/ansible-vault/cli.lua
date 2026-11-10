---Async wrappers around the `ansible-vault` CLI.
---
---All functions are non-blocking (vim.system) and take a callback of the
---form `cb(err, stdout)`. `err` is nil on success and a string on failure.
local M = {}

---@return boolean
function M.executable()
  return vim.fn.executable("ansible-vault") == 1
end

---Write a secret to a private temp file so it can be passed to ansible-vault
---via --vault-password-file. Returns the path and a cleanup function.
---@param value string
---@return string|nil path, fun()|nil cleanup, string|nil err
local function secret_tempfile(value)
  local uv = vim.uv or vim.loop
  local fd, path = uv.fs_mkstemp(uv.os_tmpdir() .. "/ansible-vault-XXXXXX")
  if not fd then
    return nil, nil, "failed to create temp file for vault password"
  end
  uv.fs_write(fd, value, 0)
  uv.fs_close(fd)
  local cleaned = false
  return path, function()
    if not cleaned then
      cleaned = true
      pcall(os.remove, path)
    end
  end, nil
end

---Run ansible-vault with a password file wired in.
---@param passfile string path to a vault password file or script
---@param vault_id string|nil encrypt with this vault-id label (nil = default)
---@param sub string[] subcommand and its arguments (before auth args)
---@param opts { stdin: string|nil }|nil
---@param cb fun(err: string|nil, stdout: string|nil)
local function run(passfile, vault_id, sub, opts, cb)
  opts = opts or {}
  local args = { "ansible-vault" }
  vim.list_extend(args, sub)
  if vault_id then
    table.insert(args, "--vault-id")
    table.insert(args, vault_id .. "@" .. passfile)
  else
    table.insert(args, "--vault-password-file")
    table.insert(args, passfile)
  end
  vim.system(args, { text = true, stdin = opts.stdin }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        cb(nil, res.stdout)
      else
        local err = vim.trim(res.stderr or "")
        if err == "" then
          err = ("ansible-vault exited with code %d"):format(res.code)
        end
        cb(err, nil)
      end
    end)
  end)
end

---Run with a credential, managing a temp password file when the credential
---is a raw secret. The temp file is always removed afterwards.
---@param cred ansible-vault.Credential
---@param vault_id string|nil
---@param sub string[]
---@param opts { stdin: string|nil }|nil
---@param cb fun(err: string|nil, stdout: string|nil)
local function run_secure(cred, vault_id, sub, opts, cb)
  if cred.kind == "file" then
    run(cred.value, vault_id, sub, opts, cb)
    return
  end
  local path, cleanup, err = secret_tempfile(cred.value)
  if not path then
    vim.schedule(function()
      cb(err, nil)
    end)
    return
  end
  run(path, vault_id, sub, opts, function(e, out)
    cleanup()
    cb(e, out)
  end)
end

---Print a vault file to stdout without modifying it.
---@param path string
---@param cred ansible-vault.Credential
---@param cb fun(err: string|nil, stdout: string|nil)
function M.view(path, cred, cb)
  run_secure(cred, nil, { "view", path }, nil, cb)
end

---Encrypt a plaintext file, writing the ciphertext to `out`.
---@param src string plaintext file
---@param out string destination path
---@param cred ansible-vault.Credential
---@param vault_id string|nil preserve/add this vault-id label
---@param cb fun(err: string|nil, stdout: string|nil)
function M.encrypt_file(src, out, cred, vault_id, cb)
  run_secure(cred, vault_id, { "encrypt", "--output", out, src }, nil, cb)
end

---Decrypt a vault blob (header + hex body) given as a string.
---@param blob string
---@param cred ansible-vault.Credential
---@param cb fun(err: string|nil, plaintext: string|nil)
function M.decrypt_blob(blob, cred, cb)
  local uv = vim.uv or vim.loop
  local fd, path = uv.fs_mkstemp(uv.os_tmpdir() .. "/ansible-vault-blob-XXXXXX")
  if not fd then
    vim.schedule(function()
      cb("failed to create temp file for vault blob", nil)
    end)
    return
  end
  uv.fs_write(fd, blob, 0)
  uv.fs_close(fd)
  run_secure(cred, nil, { "decrypt", "--output", "-", path }, nil, function(err, out)
    pcall(os.remove, path)
    cb(err, out)
  end)
end

---Materialize a credential as a passfile path: file credentials are used
---directly, raw secrets go to a 0600 temp file.
---@param cred ansible-vault.Credential
---@return string|nil path, fun() cleanup, string|nil err
local function cred_passfile(cred)
  if cred.kind == "file" then
    return cred.value, function() end, nil
  end
  local path, cleanup, err = secret_tempfile(cred.value)
  return path, cleanup or function() end, err
end

---Rekey a vault file: re-encrypt it with a new password and optionally a new
---vault-id label. An existing vault-id label is preserved unless
---`opts.new_vault_id` says otherwise (passing no new id would drop the label).
---@param path string
---@param old_cred ansible-vault.Credential
---@param new_cred ansible-vault.Credential
---@param opts { vault_id: string|nil, new_vault_id: string|nil }|nil
---@param cb fun(err: string|nil)
function M.rekey(path, old_cred, new_cred, opts, cb)
  opts = opts or {}
  local old_file, old_cleanup, oerr = cred_passfile(old_cred)
  if not old_file then
    vim.schedule(function()
      cb(oerr)
    end)
    return
  end
  local new_file, new_cleanup, nerr = cred_passfile(new_cred)
  if not new_file then
    old_cleanup()
    vim.schedule(function()
      cb(nerr)
    end)
    return
  end

  local args = { "ansible-vault", "rekey" }
  if opts.vault_id then
    vim.list_extend(args, { "--vault-id", opts.vault_id .. "@" .. old_file })
  else
    vim.list_extend(args, { "--vault-password-file", old_file })
  end
  local new_id = opts.new_vault_id or opts.vault_id -- preserve the label
  if new_id then
    vim.list_extend(args, { "--new-vault-id", new_id .. "@" .. new_file })
  else
    vim.list_extend(args, { "--new-vault-password-file", new_file })
  end
  table.insert(args, path)

  vim.system(args, { text = true }, function(res)
    old_cleanup()
    new_cleanup()
    vim.schedule(function()
      if res.code == 0 then
        cb(nil)
      else
        local err = vim.trim(res.stderr or "")
        if err == "" then
          err = ("ansible-vault rekey exited with code %d"):format(res.code)
        end
        cb(err)
      end
    end)
  end)
end

---Encrypt a string, producing a `key: !vault |` block.
---@param plaintext string
---@param key string variable name
---@param cred ansible-vault.Credential
---@param vault_id string|nil
---@param cb fun(err: string|nil, block: string|nil)
function M.encrypt_string(plaintext, key, cred, vault_id, cb)
  run_secure(cred, vault_id, { "encrypt_string", "--stdin-name", key }, { stdin = plaintext }, cb)
end

---Encrypt a file in place (plaintext on disk -> vault ciphertext on disk).
---@param path string
---@param cred ansible-vault.Credential
---@param vault_id string|nil
---@param cb fun(err: string|nil, stdout: string|nil)
function M.encrypt_inplace(path, cred, vault_id, cb)
  run_secure(cred, vault_id, { "encrypt", path }, nil, cb)
end

---Decrypt a file in place (vault ciphertext on disk -> plaintext on disk).
---@param path string
---@param cred ansible-vault.Credential
---@param cb fun(err: string|nil, stdout: string|nil)
function M.decrypt_inplace(path, cred, cb)
  run_secure(cred, nil, { "decrypt", path }, nil, cb)
end

return M
