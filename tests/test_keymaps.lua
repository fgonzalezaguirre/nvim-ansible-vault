local h = require("helpers")

local tests = {}

---@param buf integer
---@param lhs string
---@return boolean
local function has_map(buf, lhs)
  local expanded = vim.keycode(lhs) -- <leader> is expanded in stored mappings
  return vim.tbl_filter(function(m)
    return m.lhs == expanded
  end, vim.api.nvim_buf_get_keymap(buf, "n"))[1] ~= nil
end

-- buffer-local (yaml/yaml.ansible only); <leader>avF is intentionally global
local EXPECTED = {
  "<leader>avv",
  "<leader>avV",
  "<leader>ave",
  "<leader>avE",
  "<leader>avf",
  "<leader>avk",
  "<leader>avK",
}

function tests.keymaps_are_buffer_local_to_yaml()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local dir = h.tmpdir()

  local yml = dir .. "/vars.yml"
  h.write_file(yml, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(yml))
  local ybuf = vim.api.nvim_get_current_buf()
  for _, lhs in ipairs(EXPECTED) do
    h.assert_true(has_map(ybuf, lhs), lhs .. " present in yaml buffer")
  end

  local py = dir .. "/script.py"
  h.write_file(py, "print(1)\n")
  vim.cmd.edit(vim.fn.fnameescape(py))
  local pbuf = vim.api.nvim_get_current_buf()
  for _, lhs in ipairs(EXPECTED) do
    h.assert_true(not has_map(pbuf, lhs), lhs .. " absent in python buffer")
  end

  vim.cmd.bwipeout({ bang = true })
  vim.cmd.bwipeout({ bang = true })
end

function tests.keymaps_apply_to_ansible_filetype()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  vim.cmd.runtime("ftdetect/ansible.lua")
  local dir = h.tmpdir()

  local path = dir .. "/playbooks/site.yml"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  h.write_file(path, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  h.assert_eq(vim.bo[buf].filetype, "yaml.ansible")
  h.assert_true(has_map(buf, "<leader>avv"), "toggle keymap in yaml.ansible buffer")

  vim.cmd.bwipeout({ bang = true })
end

function tests.toggle_encrypts_line_under_cursor()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local dir = h.tmpdir()
  h.write_passfile(dir)
  local path = dir .. "/vars.yml"
  h.write_file(path, "api_token: abc123\nplain: value\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    cb(opts.default) -- accept the parsed key name
  end
  vim.api.nvim_feedkeys(vim.keycode("<leader>avv"), "mx", false)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("api_token: !vault") ~= nil
    end),
    "toggle did not encrypt the plaintext line"
  )
  vim.ui.input = orig_input

  -- toggle again on the new block: decrypts it back to plaintext
  vim.api.nvim_feedkeys(vim.keycode("<leader>avv"), "mx", false)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "api_token: abc123"
    end),
    "toggle did not decrypt the vault block"
  )
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1], "plain: value", "other lines untouched")

  vim.cmd.bwipeout({ bang = true })
end

---Remove a global map again (setup_global has no teardown).
local function del_global(lhs)
  pcall(vim.keymap.del, "n", vim.keycode(lhs))
end

function tests.project_keymap_is_global_but_guarded()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local dir = h.tmpdir()

  -- outside an ansible project: warns, opens nothing
  h.write_file(dir .. "/notes.txt", "hello\n")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/notes.txt"))
  local notified = nil
  local orig_notify = vim.notify
  vim.notify = function(msg)
    notified = msg
  end
  vim.api.nvim_feedkeys(vim.keycode("<leader>avF"), "mx", false)
  vim.wait(500, function()
    return notified ~= nil
  end, 50)
  vim.notify = orig_notify
  h.assert_true(notified ~= nil and notified:match("not an ansible project") ~= nil, "guard warned")

  -- inside an ansible project: picker opens (vim.ui.select fallback)
  local proj = h.tmpdir()
  vim.fn.mkdir(proj .. "/group_vars", "p")
  local passfile = h.write_passfile(proj)
  local block = h.vault_encrypt_string("s3cr3t", "db_password", passfile)
  local vars = { "plain: value" }
  for line in block:gmatch("[^\n]+") do
    table.insert(vars, line)
  end
  h.write_file(proj .. "/group_vars/all.yml", table.concat(vars, "\n") .. "\n")
  h.write_file(proj .. "/notes.txt", "hello\n")
  vim.cmd.edit(vim.fn.fnameescape(proj .. "/notes.txt"))
  local selected = "unset"
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    selected = items
    cb(nil)
  end
  vim.api.nvim_feedkeys(vim.keycode("<leader>avF"), "mx", false)
  local ok = h.wait_for(function()
    return selected ~= "unset"
  end)
  vim.ui.select = orig_select
  h.assert_true(ok, "project picker opened from a non-yaml buffer")
  h.assert_true(#selected == 1, "found the project secret")
  del_global("<leader>avF")
  vim.cmd.bwipeout({ bang = true })
  vim.cmd.bwipeout({ bang = true })
end

---Stub which-key (loaded=false/true) and capture registration.
---@param loaded boolean simulate a which-key whose load() already ran
---@return table[], table[] queued, direct
local function with_stubbed_wk(loaded)
  local queued, direct = {}, {}
  package.preload["which-key"] = function()
    return {
      add = function(spec)
        vim.list_extend(queued, spec)
      end,
    }
  end
  package.preload["which-key.config"] = function()
    return {
      loaded = loaded,
      add = function(spec)
        vim.list_extend(direct, spec)
      end,
    }
  end
  package.loaded["which-key"] = nil
  package.loaded["which-key.config"] = nil
  require("neoansible-vault.keymaps").register_group()
  vim.api.nvim_exec_autocmds("VimEnter", {})
  vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
  vim.wait(300, function()
    return #queued > 0 or #direct > 0
  end, 50)
  package.preload["which-key"] = nil
  package.preload["which-key.config"] = nil
  package.loaded["which-key"] = nil
  package.loaded["which-key.config"] = nil
  return queued, direct
end

local function groups_of(entries)
  local groups = {}
  for _, entry in ipairs(entries) do
    groups[entry[1]] = entry.group
  end
  return groups
end

function tests.which_key_groups_queued_before_load()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local queued = with_stubbed_wk(false)
  local groups = groups_of(queued)
  h.assert_eq(groups["<leader>a"], "ansible")
  h.assert_eq(groups["<leader>av"], "vault")
end

function tests.which_key_groups_inserted_directly_after_load()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local queued, direct = with_stubbed_wk(true)
  h.assert_eq(#queued, 0, "late registration must not use the drained queue")
  local groups = groups_of(direct)
  h.assert_eq(groups["<leader>a"], "ansible")
  h.assert_eq(groups["<leader>av"], "vault")
end

return tests
