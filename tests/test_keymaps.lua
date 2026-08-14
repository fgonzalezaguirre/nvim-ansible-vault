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

local EXPECTED = { "<leader>ve", "<leader>vf", "<leader>vF", "<leader>vr", "<leader>vR" }

function tests.keymaps_are_buffer_local_to_yaml()
  require("neoansible-vault").setup({ prompt = false })
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
  require("neoansible-vault").setup({ prompt = false })
  vim.cmd.runtime("ftdetect/ansible.lua")
  local dir = h.tmpdir()

  local path = dir .. "/playbooks/site.yml"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  h.write_file(path, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  h.assert_eq(vim.bo[buf].filetype, "yaml.ansible")
  h.assert_true(has_map(buf, "<leader>ve"), "toggle keymap in yaml.ansible buffer")

  vim.cmd.bwipeout({ bang = true })
end

function tests.toggle_encrypts_line_under_cursor()
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
  vim.api.nvim_feedkeys(vim.keycode("<leader>ve"), "mx", false)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("api_token: !vault") ~= nil
    end),
    "toggle did not encrypt the plaintext line"
  )
  vim.ui.input = orig_input

  -- toggle again on the new block: decrypts it back to plaintext
  vim.api.nvim_feedkeys(vim.keycode("<leader>ve"), "mx", false)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "api_token: abc123"
    end),
    "toggle did not decrypt the vault block"
  )
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1], "plain: value", "other lines untouched")

  vim.cmd.bwipeout({ bang = true })
end

return tests
