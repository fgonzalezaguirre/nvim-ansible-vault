---Vault password resolution.
---
---For a given vault-id, id-specific sources win; otherwise the default
---chain applies (mirroring ansible, which tries every available secret):
---  1. `vault_ids[id]` from setup()
---  2. `vault_identity_list` (ansible.cfg / $ANSIBLE_VAULT_IDENTITY_LIST)
---  3. `password` from setup()
---  4. `$ANSIBLE_VAULT_PASSWORD` (configurable via `env_password_var`)
---  5. `password_file` from setup()
---  6. `$ANSIBLE_VAULT_PASSWORD_FILE` (configurable via `env_password_file_var`)
---  7. `vault_password_file` from ansible.cfg ($ANSIBLE_CONFIG or discovered)
---  8. `.env` files discovered walking up from the edited file
---     (`ANSIBLE_VAULT_PASSWORD=...` or `ANSIBLE_VAULT_PASSWORD_FILE=...`)
---  9. `.vault-password` / `.vault_pass` files discovered walking up
--- 10. Interactive prompt (when `prompt = true`)
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

---Expand `~` and resolve `path` against `base_dir` when relative.
---@param path string
---@param base_dir string
---@return string
local function resolve_path(path, base_dir)
  if vim.startswith(path, "~") then
    path = vim.fn.expand(path)
  elseif not vim.startswith(path, "/") then
    path = vim.fn.simplify(base_dir .. "/" .. path)
  end
  return path
end

---@class neoansible-vault.Identity
---@field id string vault-id label
---@field kind "secret"|"file"|"prompt" secret = raw password, file = password file/script, prompt = ask interactively
---@field value string|nil password (kind=secret) or file path (kind=file)
---@field origin string human-readable origin, for messages

---Parse the vault-relevant keys of an ansible.cfg file ([defaults] section).
---@param path string
---@return { vault_password_file: string|nil, identities: neoansible-vault.Identity[] }
local function parse_ansible_cfg(path)
  local result = { vault_password_file = nil, identities = {} }
  local fd = io.open(path, "r")
  if not fd then
    return result
  end
  local base_dir = vim.fs.dirname(path)
  local in_defaults = false
  for line in fd:lines() do
    line = vim.trim(line)
    if line:match("^#") or line:match("^;") or line == "" then
      goto continue
    end
    local section = line:match("^%[([^%]]+)%]")
    if section then
      in_defaults = vim.trim(section):lower() == "defaults"
      goto continue
    end
    if in_defaults then
      local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
      if key then
        key = key:lower()
        if key == "vault_password_file" and value ~= "" then
          result.vault_password_file = resolve_path(value, base_dir)
        elseif key == "vault_identity_list" then
          for entry in value:gmatch("[^,]+") do
            local id, source = entry:match("^%s*([^@%s]+)%s*@%s*(.-)%s*$")
            if id and source and source ~= "" then
              if source:lower() == "prompt" then
                table.insert(result.identities, { id = id, kind = "prompt", origin = "ansible.cfg: " .. path })
              else
                table.insert(result.identities, {
                  id = id,
                  kind = "file",
                  value = resolve_path(source, base_dir),
                  origin = "ansible.cfg: " .. path,
                })
              end
            end
          end
        end
      end
    end
    ::continue::
  end
  fd:close()
  return result
end

---Parse an identity list string ("prod@/path, dev@prompt") as found in
---$ANSIBLE_VAULT_IDENTITY_LIST.
---@param value string
---@param origin string
---@return neoansible-vault.Identity[]
local function parse_identity_list(value, origin)
  local identities = {}
  for entry in value:gmatch("[^,]+") do
    local id, source = entry:match("^%s*([^@%s]+)%s*@%s*(.-)%s*$")
    if id and source and source ~= "" then
      if source:lower() == "prompt" then
        table.insert(identities, { id = id, kind = "prompt", origin = origin })
      else
        table.insert(identities, { id = id, kind = "file", value = resolve_path(source, "."), origin = origin })
      end
    end
  end
  return identities
end

---Locate the ansible.cfg applying to `start_dir`: $ANSIBLE_CONFIG first,
---then discovered walking up (home directory excluded, like ansible's cwd
---lookup but rooted at the edited file).
---@param start_dir string
---@return string|nil
local function find_ansible_cfg(start_dir)
  local env_cfg = vim.env.ANSIBLE_CONFIG
  if env_cfg and env_cfg ~= "" and is_readable(env_cfg) then
    return env_cfg
  end
  return walk_up(start_dir, function(dir)
    local path = dir .. "/ansible.cfg"
    if is_readable(path) then
      return path
    end
    return nil
  end)
end

---All known vault identities for a directory: setup() vault_ids first, then
---ansible.cfg vault_identity_list, then $ANSIBLE_VAULT_IDENTITY_LIST.
---@param start_dir string
---@return neoansible-vault.Identity[]
local function identities_for(start_dir)
  local cfg = config.get()
  local identities = {}
  for id, spec in pairs(cfg.vault_ids or {}) do
    if spec.password and spec.password ~= "" then
      table.insert(identities, { id = id, kind = "secret", value = spec.password, origin = "config: vault_ids" })
    elseif spec.password_file and spec.password_file ~= "" then
      table.insert(identities, {
        id = id,
        kind = "file",
        value = resolve_path(spec.password_file, "."),
        origin = "config: vault_ids",
      })
    end
  end
  local cfg_path = find_ansible_cfg(start_dir)
  if cfg_path then
    for _, identity in ipairs(parse_ansible_cfg(cfg_path).identities) do
      table.insert(identities, identity)
    end
  end
  local env_list = vim.env.ANSIBLE_VAULT_IDENTITY_LIST
  if env_list and env_list ~= "" then
    for _, identity in ipairs(parse_identity_list(env_list, "env: ANSIBLE_VAULT_IDENTITY_LIST")) do
      table.insert(identities, identity)
    end
  end
  return identities
end

---The vault-id labels known for a directory, in declaration order, deduped.
---@param start_dir string
---@return string[]
function M.known_ids(start_dir)
  local seen, ids = {}, {}
  for _, identity in ipairs(identities_for(start_dir)) do
    if not seen[identity.id] then
      seen[identity.id] = true
      table.insert(ids, identity.id)
    end
  end
  return ids
end

---@param start_dir string
---@param vault_id string
---@return neoansible-vault.Identity|nil
local function identity_for(start_dir, vault_id)
  for _, identity in ipairs(identities_for(start_dir)) do
    if identity.id == vault_id then
      return identity
    end
  end
  return nil
end

---@param names string|string[]
---@return string[]
local function as_list(names)
  if type(names) == "table" then
    return names
  end
  return { names }
end

---Synchronous resolution steps (everything except the interactive prompt).
---@param start_dir string directory of the file being edited
---@param vault_id string|nil vault-id the credential is needed for
---@return neoansible-vault.Credential|nil, string|nil error, boolean wants_prompt
local function resolve_static(start_dir, vault_id)
  local cfg = config.get()

  -- 1/2. id-specific sources: setup() vault_ids and identity lists
  if vault_id then
    local identity = identity_for(start_dir, vault_id)
    if identity then
      if identity.kind == "prompt" then
        return nil, nil, true
      end
      if identity.kind == "secret" then
        return secret(identity.value, identity.origin), nil, false
      end
      local cred, err = file(identity.value, identity.origin)
      if cred then
        return cred, nil, false
      end
      return nil, err, false
    end
  end

  if cfg.password and cfg.password ~= "" then
    return secret(cfg.password, "config: password"), nil, false
  end

  local env_password = vim.env[cfg.env_password_var]
  if env_password and env_password ~= "" then
    return secret(env_password, "env: " .. cfg.env_password_var), nil, false
  end

  if cfg.password_file and cfg.password_file ~= "" then
    local cred, err = file(cfg.password_file, "config: password_file")
    return cred, err, false
  end

  local env_file = vim.env[cfg.env_password_file_var]
  if env_file and env_file ~= "" then
    local cred, err = file(env_file, "env: " .. cfg.env_password_file_var)
    return cred, err, false
  end

  -- ansible.cfg vault_password_file
  local cfg_path = find_ansible_cfg(start_dir)
  if cfg_path then
    local cfg_password_file = parse_ansible_cfg(cfg_path).vault_password_file
    if cfg_password_file then
      local cred, err = file(cfg_password_file, "ansible.cfg: " .. cfg_path)
      if cred then
        return cred, nil, false
      end
      return nil, err, false
    end
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
      local cred, err = file(resolve_path(password_file, dir), "dotenv: " .. path)
      if cred then
        return cred
      end
      dotenv_err = err
    end
    return nil
  end)
  if dotenv_cred then
    return dotenv_cred, nil, false
  end

  -- password file discovery (.vault-password, .vault_pass, ...)
  local discovered = walk_up(start_dir, function(dir)
    for _, name in ipairs(as_list(cfg.password_file_name)) do
      local path = dir .. "/" .. name
      if is_readable(path) then
        return file(path, "discovered: " .. path)
      end
    end
    return nil
  end)
  if discovered then
    return discovered, nil, false
  end

  return nil, dotenv_err, false
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
---@param replace boolean|nil drop existing entries for this dir+id first
local function cache_store(start_dir, vault_id, cred, replace)
  if replace then
    local key = vault_id or "default"
    cache = vim.tbl_filter(function(entry)
      return not (entry.dir == start_dir and entry.vault_id == key)
    end, cache)
  end
  table.insert(cache, {
    dir = start_dir,
    vault_id = vault_id or "default",
    cred = cred,
    time = (vim.uv or vim.loop).now(),
  })
end

---Resolve a vault credential, asynchronously (may prompt).
---`opts.force_prompt` skips all static sources and the cache and asks for a
---one-off password, which then replaces any cached entry for this dir+id.
---@param opts { start_dir: string, vault_id: string|nil, allow_prompt: boolean|nil, force_prompt: boolean|nil }
---@param cb fun(cred: neoansible-vault.Credential|nil, err: string|nil)
function M.get(opts, cb)
  local cfg = config.get()
  local err, wants_prompt = nil, false

  -- Static sources are cheap to check and always take precedence.
  if not opts.force_prompt then
    local cred
    cred, err, wants_prompt = resolve_static(opts.start_dir, opts.vault_id)
    if cred then
      cb(cred, nil)
      return
    end

    local cached = cache_lookup(opts.start_dir, opts.vault_id)
    if cached then
      cb(cached, nil)
      return
    end
  end

  local allow_prompt = opts.allow_prompt
  if allow_prompt == nil then
    allow_prompt = cfg.prompt
  end
  if not allow_prompt then
    if wants_prompt then
      cb(nil, ("vault-id '%s' is configured to prompt, but prompting is disabled"):format(opts.vault_id))
    else
      cb(nil, err or "no vault password source found (tried config, env, ansible.cfg, .env, discovered password files)")
    end
    return
  end

  local label = opts.vault_id and ("Vault password [%s]: "):format(opts.vault_id) or "Vault password: "
  vim.ui.input({ prompt = label, secret = true }, function(input)
    if not input or input == "" then
      cb(nil, "no password given")
      return
    end
    local prompted = secret(input, "prompt")
    cache_store(opts.start_dir, opts.vault_id, prompted, opts.force_prompt)
    cb(prompted, nil)
  end)
end

---Forget all cached passwords.
function M.clear_cache()
  cache = {}
end

---Describe which source would resolve for a directory (for :checkhealth).
---@param start_dir string
---@param vault_id string|nil
---@return string|nil source, string|nil error
function M.describe_source(start_dir, vault_id)
  local cred, err, wants_prompt = resolve_static(start_dir, vault_id)
  if cred then
    return cred.source, nil
  end
  if wants_prompt then
    return ("identity list: prompt for vault-id '%s'"):format(vault_id), nil
  end
  return nil, err
end

-- exposed for tests
M._walk_up = walk_up
M._parse_dotenv = parse_dotenv
M._parse_ansible_cfg = parse_ansible_cfg
M._parse_identity_list = parse_identity_list
M._find_ansible_cfg = find_ansible_cfg

return M
