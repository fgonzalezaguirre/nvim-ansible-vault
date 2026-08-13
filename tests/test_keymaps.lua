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

  local py = dir .. "/script.py"
  h.write_file(py, "print(1)\n")
  vim.cmd.edit(vim.fn.fnameescape(py))
  local pbuf = vim.api.nvim_get_current_buf()
  h.assert_true(not has_map(pbuf, "<leader>ve"), "no edit keymap in python buffer")
  h.assert_true(not has_map(pbuf, "<leader>vl"), "no picker keymap in python buffer")

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

return tests
