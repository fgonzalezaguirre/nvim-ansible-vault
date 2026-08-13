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
  local fd, path = uv.fs_mkstemp(uv.os_tmpdir() .. "/neoansible-vault-XXXXXX")
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
---@param cred neoansible-vault.Credential
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
---@param cred neoansible-vault.Credential
---@param cb fun(err: string|nil, stdout: string|nil)
function M.view(path, cred, cb)
  run_secure(cred, nil, { "view", path }, nil, cb)
end

---Encrypt a plaintext file, writing the ciphertext to `out`.
---@param src string plaintext file
---@param out string destination path
---@param cred neoansible-vault.Credential
---@param vault_id string|nil preserve/add this vault-id label
---@param cb fun(err: string|nil, stdout: string|nil)
function M.encrypt_file(src, out, cred, vault_id, cb)
  run_secure(cred, vault_id, { "encrypt", "--output", out, src }, nil, cb)
end

---Decrypt a vault blob (header + hex body) given as a string.
---@param blob string
---@param cred neoansible-vault.Credential
---@param cb fun(err: string|nil, plaintext: string|nil)
function M.decrypt_blob(blob, cred, cb)
  local uv = vim.uv or vim.loop
  local fd, path = uv.fs_mkstemp(uv.os_tmpdir() .. "/neoansible-vault-blob-XXXXXX")
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

---Encrypt a string, producing a `key: !vault |` block.
---@param plaintext string
---@param key string variable name
---@param cred neoansible-vault.Credential
---@param vault_id string|nil
---@param cb fun(err: string|nil, block: string|nil)
function M.encrypt_string(plaintext, key, cred, vault_id, cb)
  run_secure(cred, vault_id, { "encrypt_string", "--stdin-name", key }, { stdin = plaintext }, cb)
end

return M
