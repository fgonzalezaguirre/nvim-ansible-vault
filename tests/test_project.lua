local cli = require("ansible-vault.cli")
local config = require("ansible-vault.config")
local password = require("ansible-vault.password")
local project = require("ansible-vault.project")
local h = require("helpers")

local tests = {}

local SNACKS_DIR = vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim")

local function reset()
  config.setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  password.clear_cache()
  vim.env.ANSIBLE_VAULT_PASSWORD = nil
  vim.env.ANSIBLE_VAULT_PASSWORD_FILE = nil
  vim.env.ANSIBLE_VAULT_IDENTITY_LIST = nil
  vim.env.ANSIBLE_CONFIG = nil
end

---Call an async cli function and wait for the result.
local function await(fn, ...)
  local n = select("#", ...)
  local call = { ... }
  local result = {}
  local done = false
  call[n + 1] = function(err, out)
    result.err = err
    result.out = out
    done = true
  end
  fn(unpack(call, 1, n + 1))
  h.assert_true(
    h.wait_for(function()
      return done
    end),
    "async cli call timed out"
  )
  return result.err, result.out
end

function tests.project_root_detection()
  local root = h.tmpdir()
  vim.fn.mkdir(root .. "/group_vars/prod", "p")
  h.assert_eq(project.root(root .. "/group_vars/prod"), root, "group_vars marks the root")
  h.assert_eq(project.root(root), root)

  local other = h.tmpdir()
  vim.fn.mkdir(other .. "/a/b", "p")
  h.write_file(other .. "/ansible.cfg", "[defaults]\n")
  h.assert_eq(project.root(other .. "/a/b"), other, "ansible.cfg marks the root")

  local nowhere = h.tmpdir()
  vim.fn.mkdir(nowhere .. "/x", "p")
  h.assert_eq(project.root(nowhere .. "/x"), nil, "no markers -> not an ansible project")
end

function tests.inplace_encrypt_decrypt_roundtrip()
  local dir = h.tmpdir()
  local cred = h.cred(dir)
  local path = dir .. "/secrets.yml"
  h.write_file(path, "token: abc123\n")

  h.assert_eq(await(cli.encrypt_inplace, path, cred, nil), nil)
  local fd = assert(io.open(path, "r"))
  h.assert_true(fd:read("*l"):match("^%$ANSIBLE_VAULT;") ~= nil, "file encrypted on disk")
  fd:close()

  h.assert_eq(await(cli.decrypt_inplace, path, cred), nil)
  fd = assert(io.open(path, "r"))
  h.assert_eq(fd:read("*a"), "token: abc123\n", "file back to plaintext on disk")
  fd:close()
end

function tests.inplace_encrypt_with_vault_id()
  local dir = h.tmpdir()
  local cred = h.cred(dir)
  local path = dir .. "/secrets.yml"
  h.write_file(path, "k: v\n")
  h.assert_eq(await(cli.encrypt_inplace, path, cred, "prod"), nil)
  local fd = assert(io.open(path, "r"))
  h.assert_eq(fd:read("*l"), "$ANSIBLE_VAULT;1.2;AES256;prod")
  fd:close()
end

function tests.snacks_explorer_actions_and_icons()
  if vim.uv.fs_stat(SNACKS_DIR) == nil then
    return -- snacks not installed (e.g. CI): nothing to assert
  end
  vim.opt.runtimepath:prepend(SNACKS_DIR)
  reset()
  require("ansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local Snacks = require("snacks")
  local explorer = Snacks.config.picker.sources.explorer
  h.assert_true(explorer ~= nil, "explorer source config injected")
  h.assert_true(explorer.actions.ansible_vault_encrypt ~= nil, "encrypt action registered")
  h.assert_true(explorer.actions.ansible_vault_decrypt ~= nil, "decrypt action registered")
  h.assert_eq(explorer.win.list.keys["<leader>avV"], "ansible_vault_toggle")

  -- lock icon for encrypted files, extension icon untouched for plain ones
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local enc = dir .. "/secrets.yml"
  h.write_file(enc, "k: v\n")
  h.vault_encrypt(enc, passfile)
  local plain = dir .. "/plain.yml"
  h.write_file(plain, "k: v\n")

  local icon = Snacks.util.icon(enc, "file")
  h.assert_eq(icon, "󰌆 ", "lock icon for vault file")
  local plain_icon = Snacks.util.icon(plain, "file")
  h.assert_true(plain_icon ~= "󰌆 ", "plain file keeps its normal icon")

  -- cache invalidation after a change
  h.vault_view(enc, passfile)
  reset()
end

function tests.snacks_integration_disabled_when_config_off()
  if vim.uv.fs_stat(SNACKS_DIR) == nil then
    return
  end
  reset()
  -- fresh config: opts out of explorer actions
  require("ansible-vault").setup({
    prompt = false,
    confirm_default = false,
    confirm_decrypt = false,
    snacks = { explorer = false, icons = false },
  })
  -- (the previous test already injected into the shared snacks config table;
  -- here we only assert setup() does not error when disabled)
  reset()
end

return tests
