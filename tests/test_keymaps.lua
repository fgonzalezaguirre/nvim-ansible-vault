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

function tests.keymaps_are_buffer_local_to_yaml()
  require("neoansible-vault").setup({ prompt = false })
  local dir = h.tmpdir()

  local yml = dir .. "/vars.yml"
  h.write_file(yml, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(yml))
  local ybuf = vim.api.nvim_get_current_buf()
  h.assert_true(has_map(ybuf, "<leader>ve"), "edit keymap in yaml buffer")
  h.assert_true(has_map(ybuf, "<leader>vl"), "picker keymap in yaml buffer")
  h.assert_true(has_map(ybuf, "<leader>vs"), "encrypt keymap in yaml buffer")
  h.assert_true(has_map(ybuf, "<leader>vr"), "reveal keymap in yaml buffer")

  local py = dir .. "/script.py"
  h.write_file(py, "print(1)\n")
  vim.cmd.edit(vim.fn.fnameescape(py))
  local pbuf = vim.api.nvim_get_current_buf()
  h.assert_true(not has_map(pbuf, "<leader>ve"), "no edit keymap in python buffer")
  h.assert_true(not has_map(pbuf, "<leader>vl"), "no picker keymap in python buffer")
  h.assert_true(not has_map(pbuf, "<leader>vs"), "no encrypt keymap in python buffer")
  h.assert_true(not has_map(pbuf, "<leader>vr"), "no reveal keymap in python buffer")

  vim.cmd.bwipeout({ bang = true })
  vim.cmd.bwipeout({ bang = true })
end

function tests.keymaps_apply_to_ansible_filetype()
  require("neoansible-vault").setup({ prompt = false })
  vim.cmd.runtime("ftdetect/ansible.lua")
  local dir = h.tmpdir()

  local path = dir .. "/playbooks/site.yml"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  h.write_file(path, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  h.assert_eq(vim.bo[buf].filetype, "yaml.ansible")
  h.assert_true(has_map(buf, "<leader>ve"), "edit keymap in yaml.ansible buffer")

  vim.cmd.bwipeout({ bang = true })
end

function tests.encrypt_keymap_encrypts_line_under_cursor()
  require("neoansible-vault").setup({ prompt = false })
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
  vim.api.nvim_feedkeys(vim.keycode("<leader>vs"), "mx", false)
  h.assert_true(h.wait_for(function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("api_token: !vault") ~= nil
  end), "line under cursor was not encrypted")
  vim.ui.input = orig_input

  -- the other line is untouched
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1], "plain: value")

  vim.cmd.bwipeout({ bang = true })
end

return tests
