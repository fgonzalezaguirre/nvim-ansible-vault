local config = require("neoansible-vault.config")
local password = require("neoansible-vault.password")
local h = require("helpers")

local tests = {}

---Resolve synchronously (prompt disabled), returning cred, err.
local function resolve(start_dir)
  local result = {}
  password.get({ start_dir = start_dir, vault_id = nil, allow_prompt = false }, function(cred, err)
    result.cred = cred
    result.err = err
  end)
  return result.cred, result.err
end

local function reset()
  config.setup({})
  password.clear_cache()
  vim.env.ANSIBLE_VAULT_PASSWORD = nil
  vim.env.ANSIBLE_VAULT_PASSWORD_FILE = nil
end

function tests.env_password_direct()
  reset()
  vim.env.ANSIBLE_VAULT_PASSWORD = "from-env"
  local cred = resolve(h.tmpdir())
  h.assert_eq(cred.kind, "secret")
  h.assert_eq(cred.value, "from-env")
  h.assert_eq(cred.source, "env: ANSIBLE_VAULT_PASSWORD")
  reset()
end

function tests.env_password_file()
  reset()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  vim.env.ANSIBLE_VAULT_PASSWORD_FILE = passfile
  local cred = resolve(h.tmpdir())
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, passfile)
  reset()
end

function tests.config_password_and_file()
  reset()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  config.setup({ password = "from-config" })
  local cred = resolve(h.tmpdir())
  h.assert_eq(cred.value, "from-config", "config password wins")

  config.setup({ password_file = passfile })
  cred = resolve(h.tmpdir())
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, passfile)
  reset()
end

function tests.dotenv_discovery_direct_password()
  reset()
  local root = h.tmpdir()
  vim.fn.mkdir(root .. "/group_vars/prod", "p")
  h.write_file(root .. "/.env", "ANSIBLE_VAULT_PASSWORD=from-dotenv\nOTHER=ignored\n")
  local cred = resolve(root .. "/group_vars/prod")
  h.assert_eq(cred.kind, "secret")
  h.assert_eq(cred.value, "from-dotenv")
  h.assert_true(cred.source:match("dotenv") ~= nil)
  reset()
end

function tests.dotenv_discovery_password_file_relative()
  reset()
  local root = h.tmpdir()
  vim.fn.mkdir(root .. "/sub", "p")
  local passfile = h.write_passfile(root)
  h.write_file(root .. "/.env", "ANSIBLE_VAULT_PASSWORD_FILE=./.vault-password\n")
  local cred = resolve(root .. "/sub")
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, passfile, "relative path resolved against .env location")
  reset()
end

function tests.dotenv_quoted_and_export()
  reset()
  local root = h.tmpdir()
  h.write_file(root .. "/.env", 'export ANSIBLE_VAULT_PASSWORD="quoted value"\n')
  local cred = resolve(root)
  h.assert_eq(cred.value, "quoted value")
  reset()
end

function tests.vault_password_file_discovery()
  reset()
  local root = h.tmpdir()
  vim.fn.mkdir(root .. "/a/b/c", "p")
  local passfile = h.write_passfile(root)
  local cred = resolve(root .. "/a/b/c")
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, passfile)
  reset()
end

function tests.nearest_ancestor_wins()
  reset()
  local root = h.tmpdir()
  vim.fn.mkdir(root .. "/near", "p")
  h.write_passfile(root, "far")
  local near = h.write_passfile(root .. "/near", "near")
  local cred = resolve(root .. "/near")
  h.assert_eq(cred.value, near)
  reset()
end

function tests.home_directory_is_never_checked()
  reset()
  local fake_home = h.tmpdir()
  h.write_passfile(fake_home)
  local seen = {}
  password._walk_up(fake_home .. "/project", function(dir)
    table.insert(seen, dir)
    return nil
  end, fake_home)
  for _, dir in ipairs(seen) do
    h.assert_true(dir ~= fake_home, "walk_up must skip the home directory")
  end
  h.assert_eq(seen[1], fake_home .. "/project")
  reset()
end

function tests.precedence_env_over_dotenv()
  reset()
  local root = h.tmpdir()
  h.write_file(root .. "/.env", "ANSIBLE_VAULT_PASSWORD=from-dotenv\n")
  vim.env.ANSIBLE_VAULT_PASSWORD = "from-env"
  local cred = resolve(root)
  h.assert_eq(cred.value, "from-env", "env var beats .env discovery")
  reset()
end

function tests.no_source_reports_error()
  reset()
  local dir = h.tmpdir()
  local cred, err = resolve(dir)
  h.assert_eq(cred, nil)
  h.assert_true(err ~= nil, "error message expected")
  reset()
end

function tests.prompt_is_cached_per_directory()
  reset()
  local root = h.tmpdir()
  vim.fn.mkdir(root .. "/proj/sub", "p")
  local prompts = 0
  local orig_input = vim.ui.input
  vim.ui.input = function(_, cb)
    prompts = prompts + 1
    cb("prompted")
  end

  local first = {}
  password.get({ start_dir = root .. "/proj", vault_id = nil }, function(cred)
    first.cred = cred
  end)
  local second = {}
  password.get({ start_dir = root .. "/proj/sub", vault_id = nil }, function(cred)
    second.cred = cred
  end)

  vim.ui.input = orig_input
  h.assert_eq(prompts, 1, "second lookup in child dir must reuse the cached prompt")
  h.assert_eq(first.cred.value, "prompted")
  h.assert_eq(second.cred.value, "prompted")
  reset()
end

return tests
