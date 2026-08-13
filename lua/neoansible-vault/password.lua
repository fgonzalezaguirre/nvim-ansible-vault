---Vault password resolution.
---
---Resolution order (first hit wins):
---  1. `password` from setup()
---  2. `$ANSIBLE_VAULT_PASSWORD` (configurable via `env_password_var`)
---  3. `password_file` from setup()
---  4. `$ANSIBLE_VAULT_PASSWORD_FILE` (configurable via `env_password_file_var`)
---  5. `.env` files discovered walking up from the edited file
---     (`ANSIBLE_VAULT_PASSWORD=...` or `ANSIBLE_VAULT_PASSWORD_FILE=...`)
---  6. `.vault-password` files discovered walking up from the edited file
---  7. Interactive prompt (when `prompt = true`)
---
---The upward search never considers the user's home directory.
local config = require("neoansible-vault.config")

local M = {}

---@class neoansible-vault.Credential
---@field kind "secret"|"file" secret = raw password, file = password file/script path
---@field value string password text (kind=secret) or file path (kind=file)
---@field source string human-readable origin, for messages and :checkhealth

-- In-memory cache of *prompted* passwords, scoped by directory so that
-- different projects do not share a cached password.
-- Entries: { dir = string, vault_id = string, cred = Credential, time = integer }
local cache = {}

local function is_file(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

local function is_readable(path)
  return is_file(path) and vim.fn.filereadable(path) == 1
end

---Walk up from `start_dir`, calling `fn(dir)` for each directory.
---Stops at the filesystem root and never calls `fn` for the home directory.
---@param start_dir string
---@param fn fun(dir: string): any
---@param home string|nil override for testing
---@return any
local function walk_up(start_dir, fn, home)
  home = home or (vim.uv or vim.loop).os_homedir()
  local dir = vim.fs.normalize(start_dir)
  while dir and dir ~= "" do
    if dir ~= home then
      local result = fn(dir)
      if result then
        return result
      end
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---Parse a dotenv file for vault-related variables.
---@param path string
---@return string|nil password, string|nil password_file
local function parse_dotenv(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, nil
  end
  local password, password_file = nil, nil
  for line in fd:lines() do
    local name, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if not name then
      name, value = line:match("^%s*export%s+([%w_]+)%s*=%s*(.-)%s*$")
    end
    if name and value then
      value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
      if name == "ANSIBLE_VAULT_PASSWORD" and value ~= "" then
        password = password or value
      elseif name == "ANSIBLE_VAULT_PASSWORD_FILE" and value ~= "" then
        password_file = password_file or value
      end
    end
  end
  fd:close()
  return password, password_file
end

---@param value string
---@param source string
---@return neoansible-vault.Credential
local function secret(value, source)
  return { kind = "secret", value = value, source = source }
end

---@param path string
---@param source string
---@return neoansible-vault.Credential|nil, string|nil error
local function file(path, source)
  if not is_file(path) then
    return nil, ("vault password file not found: %s (%s)"):format(path, source)
  end
  if not is_readable(path) then
    return nil, ("vault password file not readable: %s (%s)"):format(path, source)
  end
  return { kind = "file", value = path, source = source }, nil
end

---Synchronous resolution steps (everything except the interactive prompt).
---@param start_dir string directory of the file being edited
---@return neoansible-vault.Credential|nil, string|nil error
local function resolve_static(start_dir)
  local cfg = config.get()

  if cfg.password and cfg.password ~= "" then
    return secret(cfg.password, "config: password")
  end

  local env_password = vim.env[cfg.env_password_var]
  if env_password and env_password ~= "" then
    return secret(env_password, "env: " .. cfg.env_password_var)
  end

  if cfg.password_file and cfg.password_file ~= "" then
    return file(cfg.password_file, "config: password_file")
  end

  local env_file = vim.env[cfg.env_password_file_var]
  if env_file and env_file ~= "" then
    return file(env_file, "env: " .. cfg.env_password_file_var)
  end

  -- .env discovery
  local dotenv_cred, dotenv_err = walk_up(start_dir, function(dir)
    local path = dir .. "/" .. cfg.dotenv_name
    if not is_readable(path) then
      return nil
    end
    local password, password_file = parse_dotenv(path)
    if password then
      return secret(password, "dotenv: " .. path)
    end
    if password_file then
      if not vim.startswith(password_file, "/") then
        password_file = vim.fn.simplify(dir .. "/" .. password_file)
      end
      local cred, err = file(password_file, "dotenv: " .. path)
      if cred then
        return cred
      end
      dotenv_err = err
    end
    return nil
  end)
  if dotenv_cred then
    return dotenv_cred
  end

  -- .vault-password discovery
  local discovered = walk_up(start_dir, function(dir)
    local path = dir .. "/" .. cfg.password_file_name
    if is_readable(path) then
      return file(path, "discovered: " .. path)
    end
    return nil
  end)
  if discovered then
    return discovered
  end

  return nil, dotenv_err
end

---Find a fresh cached prompt entry covering `start_dir` (longest prefix wins).
---@param start_dir string
---@param vault_id string|nil
---@return neoansible-vault.Credential|nil
local function cache_lookup(start_dir, vault_id)
  local cfg = config.get()
  if cfg.cache_ttl <= 0 then
    return nil
  end
  local now = (vim.uv or vim.loop).now()
  local best = nil
  for _, entry in ipairs(cache) do
    if
      entry.vault_id == (vault_id or "default")
      and now - entry.time < cfg.cache_ttl * 1000
      and (start_dir == entry.dir or vim.startswith(start_dir, entry.dir .. "/"))
      and (not best or #entry.dir > #best.dir)
    then
      best = entry
    end
  end
  return best and best.cred or nil
end

---@param start_dir string
---@param vault_id string|nil
---@param cred neoansible-vault.Credential
local function cache_store(start_dir, vault_id, cred)
  table.insert(cache, {
    dir = start_dir,
    vault_id = vault_id or "default",
    cred = cred,
    time = (vim.uv or vim.loop).now(),
  })
end

---Resolve a vault credential, asynchronously (may prompt).
---@param opts { start_dir: string, vault_id: string|nil, allow_prompt: boolean|nil }
---@param cb fun(cred: neoansible-vault.Credential|nil, err: string|nil)
function M.get(opts, cb)
  local cfg = config.get()

  -- Static sources are cheap to check and always take precedence.
  local cred, err = resolve_static(opts.start_dir)
  if cred then
    cb(cred, nil)
    return
  end

  local cached = cache_lookup(opts.start_dir, opts.vault_id)
  if cached then
    cb(cached, nil)
    return
  end

  local allow_prompt = opts.allow_prompt
  if allow_prompt == nil then
    allow_prompt = cfg.prompt
  end
  if not allow_prompt then
    cb(nil, err or "no vault password source found (tried config, env, .env, " .. cfg.password_file_name .. ")")
    return
  end

  local label = opts.vault_id and ("Vault password [%s]: "):format(opts.vault_id) or "Vault password: "
  vim.ui.input({ prompt = label, secret = true }, function(input)
    if not input or input == "" then
      cb(nil, "no password given")
      return
    end
    local prompted = secret(input, "prompt")
    cache_store(opts.start_dir, opts.vault_id, prompted)
    cb(prompted, nil)
  end)
end

---Forget all cached passwords.
function M.clear_cache()
  cache = {}
end

---Describe which source would resolve for a directory (for :checkhealth).
---@param start_dir string
---@return string|nil source, string|nil error
function M.describe_source(start_dir)
  local cred, err = resolve_static(start_dir)
  if cred then
    return cred.source, nil
  end
  return nil, err
end

-- exposed for tests
M._walk_up = walk_up
M._parse_dotenv = parse_dotenv

return M
