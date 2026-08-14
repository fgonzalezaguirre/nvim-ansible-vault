local cli = require("neoansible-vault.cli")
local config = require("neoansible-vault.config")
local ids = require("neoansible-vault.ids")
local password = require("neoansible-vault.password")
local h = require("helpers")

local tests = {}

local function reset()
  config.setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  password.clear_cache()
  vim.env.ANSIBLE_VAULT_PASSWORD = nil
  vim.env.ANSIBLE_VAULT_PASSWORD_FILE = nil
  vim.env.ANSIBLE_VAULT_IDENTITY_LIST = nil
  vim.env.ANSIBLE_CONFIG = nil
end

local function resolve(start_dir, vault_id)
  local result = {}
  password.get({ start_dir = start_dir, vault_id = vault_id, allow_prompt = false }, function(cred, err)
    result.cred = cred
    result.err = err
  end)
  return result.cred, result.err
end

local function write_ansible_cfg(dir, lines)
  local path = dir .. "/ansible.cfg"
  h.write_file(path, table.concat(lines, "\n") .. "\n")
  return path
end

function tests.parse_ansible_cfg_identities()
  local dir = h.tmpdir()
  local path = write_ansible_cfg(dir, {
    "[defaults]",
    "vault_identity_list = prod@secrets/prod.pass, dev@/abs/dev.pass, stag@prompt",
    "",
    "[inventory]",
    "vault_password_file = ignored-in-this-section",
  })
  local parsed = password._parse_ansible_cfg(path)
  h.assert_eq(parsed.vault_password_file, nil)
  h.assert_eq(#parsed.identities, 3)
  h.assert_eq(parsed.identities[1].id, "prod")
  h.assert_eq(parsed.identities[1].kind, "file")
  h.assert_eq(parsed.identities[1].value, dir .. "/secrets/prod.pass", "relative to cfg dir")
  h.assert_eq(parsed.identities[2].value, "/abs/dev.pass", "absolute kept")
  h.assert_eq(parsed.identities[3].kind, "prompt")
end

function tests.parse_ansible_cfg_vault_password_file()
  local dir = h.tmpdir()
  local path = write_ansible_cfg(dir, { "[defaults]", "vault_password_file = ./.vault-password" })
  h.assert_eq(password._parse_ansible_cfg(path).vault_password_file, dir .. "/.vault-password")
end

function tests.identity_list_env_parsing()
  local identities = password._parse_identity_list("prod@/x.pass, ops@prompt", "test")
  h.assert_eq(#identities, 2)
  h.assert_eq(identities[1].id, "prod")
  h.assert_eq(identities[1].value, "/x.pass")
  h.assert_eq(identities[2].kind, "prompt")
end

function tests.resolution_per_id_via_config()
  reset()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir, "prod-pass")
  config.setup({
    prompt = false,
    vault_ids = { prod = { password_file = passfile }, dev = { password = "dev-secret" } },
  })
  local cred = resolve(h.tmpdir(), "prod")
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, passfile)
  cred = resolve(h.tmpdir(), "dev")
  h.assert_eq(cred.kind, "secret")
  h.assert_eq(cred.value, "dev-secret")
  reset()
end

function tests.resolution_per_id_via_ansible_cfg_identity_list()
  reset()
  local dir = h.tmpdir()
  vim.fn.mkdir(dir .. "/group_vars", "p")
  local passfile = h.write_passfile(dir, "prod-pass")
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@.vault-password" })

  local cred = resolve(dir .. "/group_vars", "prod")
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, passfile, "identity list path resolved against ansible.cfg dir")
  h.assert_true(cred.source:match("ansible%.cfg") ~= nil)
  reset()
end

function tests.identity_prompt_entry_requests_prompt()
  reset()
  local dir = h.tmpdir()
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = stag@prompt" })

  local cred, err = resolve(dir, "stag")
  h.assert_eq(cred, nil)
  h.assert_true(err:match("prompt") ~= nil, "explains prompting is disabled")

  config.setup({ prompt = true })
  local label = nil
  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    label = opts.prompt
    cb("stag-secret")
  end
  local got = {}
  password.get({ start_dir = dir, vault_id = "stag" }, function(c)
    got.cred = c
  end)
  vim.ui.input = orig_input
  h.assert_eq(label, "Vault password [stag]: ", "prompt is labeled with the vault-id")
  h.assert_eq(got.cred.value, "stag-secret")
  reset()
end

function tests.unknown_id_falls_back_to_default_chain()
  reset()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir, "default-pass")
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@/nonexistent" })
  -- unknown id: default chain (discovered .vault-password) still applies,
  -- mirroring ansible trying every available secret
  local cred = resolve(dir, "unknown")
  h.assert_eq(cred.value, passfile)
  reset()
end

function tests.ansible_cfg_vault_password_file_in_default_chain()
  reset()
  local dir = h.tmpdir()
  vim.fn.mkdir(dir .. "/group_vars", "p")
  local passfile = h.write_passfile(dir)
  write_ansible_cfg(dir, { "[defaults]", "vault_password_file = .vault-password" })
  local cred = resolve(dir .. "/group_vars")
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, passfile)
  reset()
end

function tests.ansible_config_env_var_points_at_cfg()
  reset()
  local dir = h.tmpdir()
  local elsewhere = h.tmpdir()
  local passfile = h.write_passfile(elsewhere)
  write_ansible_cfg(elsewhere, { "[defaults]", "vault_password_file = .vault-password" })
  vim.env.ANSIBLE_CONFIG = elsewhere .. "/ansible.cfg"
  h.assert_eq(password._find_ansible_cfg(dir), elsewhere .. "/ansible.cfg")
  local cred = resolve(dir)
  h.assert_eq(cred.value, passfile)
  reset()
end

function tests.env_identity_list_resolution()
  reset()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir, "env-id-pass")
  vim.env.ANSIBLE_VAULT_IDENTITY_LIST = "prod@" .. passfile
  local cred = resolve(dir, "prod")
  h.assert_eq(cred.value, passfile)
  h.assert_true(cred.source:match("ANSIBLE_VAULT_IDENTITY_LIST") ~= nil)
  reset()
end

function tests.known_ids_aggregates_and_dedupes()
  reset()
  local dir = h.tmpdir()
  config.setup({
    prompt = false,
    confirm_default = false,
    confirm_decrypt = false,
    vault_ids = { dev = { password = "x" } },
  })
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@/a, dev@/b, stag@prompt" })
  vim.env.ANSIBLE_VAULT_IDENTITY_LIST = "ops@/c, prod@/d"
  local known = password.known_ids(dir)
  h.assert_true(vim.tbl_contains(known, "dev"))
  h.assert_true(vim.tbl_contains(known, "prod"))
  h.assert_true(vim.tbl_contains(known, "stag"))
  h.assert_true(vim.tbl_contains(known, "ops"))
  h.assert_eq(#known, 4, "deduped")
  reset()
end

function tests.vault_pass_alternate_discovery()
  reset()
  local dir = h.tmpdir()
  vim.fn.mkdir(dir .. "/sub", "p")
  h.write_file(dir .. "/.vault_pass", h.PASSWORD .. "\n")
  vim.uv.fs_chmod(dir .. "/.vault_pass", 384)
  local cred = resolve(dir .. "/sub")
  h.assert_eq(cred.kind, "file")
  h.assert_eq(cred.value, dir .. "/.vault_pass", "common .vault_pass convention discovered")
  reset()
end

function tests.vault_password_takes_precedence_over_vault_pass()
  reset()
  local dir = h.tmpdir()
  h.write_passfile(dir)
  h.write_file(dir .. "/.vault_pass", "other\n")
  local cred = resolve(dir)
  h.assert_eq(cred.value, dir .. "/.vault-password", "first name in list wins per directory")
  reset()
end

function tests.roundtrip_encrypt_with_identity_list_id()
  reset()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir, "prod-pass")
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@.vault-password" })

  local cred = resolve(dir, "prod")
  local done, result = false, {}
  cli.encrypt_string("multi-vault-secret", "api_key", cred, "prod", function(err, out)
    result.err = err
    result.out = out
    done = true
  end)
  h.assert_true(h.wait_for(function()
    return done
  end))
  h.assert_eq(result.err, nil)
  h.assert_true(result.out:match("%$ANSIBLE_VAULT;1%.2;AES256;prod") ~= nil, "labeled with the prod vault-id")

  local blob_lines = {}
  for line in result.out:gmatch("[^\n]+") do
    table.insert(blob_lines, (line:gsub("^%s*", "")))
  end
  table.remove(blob_lines, 1)
  local ddone, dres = false, {}
  cli.decrypt_blob(table.concat(blob_lines, "\n") .. "\n", cred, function(err, out)
    dres.err = err
    dres.out = out
    ddone = true
  end)
  h.assert_true(h.wait_for(function()
    return ddone
  end))
  h.assert_eq(dres.err, nil)
  h.assert_eq(dres.out, "multi-vault-secret")
  reset()
end

function tests.pick_prefers_config_vault_id_silently()
  reset()
  config.setup({ prompt = false, confirm_default = false, confirm_decrypt = false, vault_id = "prod" })
  local selected, called = "unset", false
  local orig_select = vim.ui.select
  vim.ui.select = function()
    called = true
  end
  ids.pick(0, function(id)
    selected = id
  end)
  vim.ui.select = orig_select
  h.assert_eq(selected, "prod")
  h.assert_eq(called, false, "no picker when config.vault_id is set")
  reset()
end

function tests.pick_returns_nil_without_known_ids()
  reset()
  local selected = "unset"
  ids.pick(0, function(id)
    selected = id
  end)
  h.assert_eq(selected, nil, "no ids configured anywhere -> unlabeled default, no picker")
  reset()
end

function tests.pick_offers_select_with_known_ids()
  reset()
  local dir = h.tmpdir()
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@/a, dev@/b" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/vars.yml")
  vim.api.nvim_set_current_buf(buf)

  local items = nil
  local orig_select = vim.ui.select
  vim.ui.select = function(choices, _, cb)
    items = choices
    cb("prod")
  end
  local selected = nil
  ids.pick(buf, function(id)
    selected = id
  end)
  vim.ui.select = orig_select
  h.assert_eq(selected, "prod")
  h.assert_eq(items[1], "(default)")
  h.assert_true(vim.tbl_contains(items, "prod"))
  h.assert_true(vim.tbl_contains(items, "dev"))

  vim.api.nvim_buf_delete(buf, { force = true })
  reset()
end

function tests.complete_filters_known_ids()
  reset()
  local dir = h.tmpdir()
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@/a, pre@/b, dev@/c" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/vars.yml")
  vim.api.nvim_set_current_buf(buf)
  h.assert_eq(ids.complete(buf)("pr"), { "prod", "pre" })
  h.assert_eq(#ids.complete(buf)(""), 3)
  vim.api.nvim_buf_delete(buf, { force = true })
  reset()
end

function tests.force_prompt_skips_static_sources()
  reset()
  local dir = h.tmpdir()
  h.write_passfile(dir, "file-pass")
  config.setup({ prompt = true })

  local orig_input = vim.ui.input
  vim.ui.input = function(_, cb)
    cb("forced-pass")
  end
  local got = {}
  password.get({ start_dir = dir, vault_id = nil, force_prompt = true }, function(cred)
    got.cred = cred
  end)
  vim.ui.input = orig_input
  h.assert_eq(got.cred.value, "forced-pass", "one-off password used despite discovered file")
  reset()
end

function tests.force_prompt_replaces_cached_password()
  reset()
  local dir = h.tmpdir()
  config.setup({ prompt = true })
  local orig_input = vim.ui.input

  vim.ui.input = function(_, cb)
    cb("old-pass")
  end
  password.get({ start_dir = dir, vault_id = nil }, function() end)

  vim.ui.input = function(_, cb)
    cb("new-pass")
  end
  password.get({ start_dir = dir, vault_id = nil, force_prompt = true }, function() end)

  -- a normal lookup must now hit the replacement, not prompt again
  local prompts = 0
  vim.ui.input = function(_, cb)
    prompts = prompts + 1
    cb("unexpected")
  end
  local got = {}
  password.get({ start_dir = dir, vault_id = nil }, function(cred)
    got.cred = cred
  end)
  vim.ui.input = orig_input
  h.assert_eq(prompts, 0)
  h.assert_eq(got.cred.value, "new-pass", "forced password replaced the cached one")
  reset()
end

function tests.pick_new_id_choice_prompts_for_label()
  reset()
  local dir = h.tmpdir()
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@/a" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/vars.yml")
  vim.api.nvim_set_current_buf(buf)

  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(choices, _, cb)
    h.assert_eq(choices[#choices], "(new id…)", "new-id choice is offered last")
    cb(choices[#choices])
  end
  vim.ui.input = function(opts, cb)
    h.assert_eq(opts.prompt, "New vault-id: ")
    cb("custom")
  end
  local selected = nil
  ids.pick(buf, function(id)
    selected = id
  end)
  vim.ui.select, vim.ui.input = orig_select, orig_input
  h.assert_eq(selected, "custom")

  vim.api.nvim_buf_delete(buf, { force = true })
  reset()
end

function tests.encrypt_bang_uses_one_off_password()
  reset()
  require("neoansible-vault").setup({})
  local dir = h.tmpdir()
  h.write_passfile(dir, "file-pass")
  local path = dir .. "/plain.yml"
  h.write_file(path, "token: abc123\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    cb(opts.secret and "forced-pass" or opts.default)
  end
  vim.cmd("AnsibleVaultEncrypt! prod")
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT;") ~= nil
    end),
    "buffer was not encrypted"
  )
  vim.ui.input = orig_input

  local header = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  h.assert_eq(header, "$ANSIBLE_VAULT;1.2;AES256;prod", "labeled with the new vault-id")

  local blob = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  local ok_done, ok_out = false, nil
  cli.decrypt_blob(blob, { kind = "secret", value = "forced-pass", source = "test" }, function(_, out)
    ok_out = out
    ok_done = true
  end)
  h.assert_true(h.wait_for(function()
    return ok_done
  end))
  h.assert_eq(ok_out, "token: abc123\n", "decrypts with the one-off password")

  local bad_done, bad_err = false, nil
  cli.decrypt_blob(blob, { kind = "secret", value = "file-pass", source = "test" }, function(err)
    bad_err = err
    bad_done = true
  end)
  h.assert_true(h.wait_for(function()
    return bad_done
  end))
  h.assert_true(bad_err ~= nil, "does NOT decrypt with the configured password")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.confirm_default_asks_without_known_ids()
  reset()
  config.setup({ prompt = false, confirm_default = true })
  local items = nil
  local orig_select = vim.ui.select
  vim.ui.select = function(choices, _, cb)
    items = choices
    cb("(default)")
  end
  local selected = "unset"
  ids.pick(0, function(id)
    selected = id
  end)
  vim.ui.select = orig_select
  h.assert_eq(items, { "(default)", "(new id…)" }, "asks even when nothing is configured")
  h.assert_eq(selected, nil, "(default) means the unlabeled default vault/password")
  reset()
end

function tests.confirm_default_labels_config_vault_id()
  reset()
  local dir = h.tmpdir()
  write_ansible_cfg(dir, { "[defaults]", "vault_identity_list = prod@/a, dev@/b" })
  config.setup({ prompt = false, confirm_default = true, vault_id = "prod" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/vars.yml")
  vim.api.nvim_set_current_buf(buf)

  local items = nil
  local orig_select = vim.ui.select
  vim.ui.select = function(choices, _, cb)
    items = choices
    cb(choices[1])
  end
  local selected = nil
  ids.pick(buf, function(id)
    selected = id
  end)
  vim.ui.select = orig_select
  h.assert_eq(items[1], "(default: prod)")
  h.assert_eq(selected, "prod", "choosing the default yields config.vault_id")
  local count = 0
  for _, choice in ipairs(items) do
    if choice == "prod" then
      count = count + 1
    end
  end
  h.assert_eq(count, 0, "default id is not duplicated in the list")
  h.assert_true(vim.tbl_contains(items, "dev"))

  vim.api.nvim_buf_delete(buf, { force = true })
  reset()
end

function tests.encrypt_selection_asks_and_uses_new_id()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = true })
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/vars.yml"
  h.write_file(path, "api_token: abc123\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(choices, _, cb)
    cb(choices[#choices]) -- "(new id…)"
  end
  vim.ui.input = function(opts, cb)
    if opts.prompt == "New vault-id: " then
      cb("custom")
    else
      cb(opts.default) -- variable name
    end
  end
  require("neoansible-vault").encrypt_selection(1, 1)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("!vault") ~= nil
    end),
    "selection was not encrypted"
  )
  vim.ui.select, vim.ui.input = orig_select, orig_input

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  h.assert_true(lines[2]:match("%$ANSIBLE_VAULT;1%.2;AES256;custom") ~= nil, "labeled with the new id")

  local region = require("neoansible-vault.detect").inline_region_at(lines, 0)
  local blob_path = dir .. "/blob.txt"
  h.write_file(blob_path, require("neoansible-vault.detect").region_blob_text(region))
  local code, out = h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
  h.assert_eq(code, 0)
  h.assert_eq(out, "abc123", "encrypted with the default password")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

return tests
