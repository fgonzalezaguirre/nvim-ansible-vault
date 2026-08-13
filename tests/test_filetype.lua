local h = require("helpers")

local tests = {}

---@param path string
---@return string filetype
local function ft_of(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  h.write_file(path, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local ft = vim.bo.filetype
  vim.cmd.bwipeout({ bang = true })
  return ft
end

function tests.ansible_paths_get_yaml_ansible_filetype()
  vim.cmd.runtime("ftdetect/ansible.lua")
  local dir = h.tmpdir()

  h.assert_eq(ft_of(dir .. "/playbooks/site.yml"), "yaml.ansible")
  h.assert_eq(ft_of(dir .. "/roles/web/vars/main.yml"), "yaml.ansible")
  h.assert_eq(ft_of(dir .. "/roles/web/tasks/install.yaml"), "yaml.ansible")
  h.assert_eq(ft_of(dir .. "/roles/web/handlers/main.yml"), "yaml.ansible")
  h.assert_eq(ft_of(dir .. "/roles/web/defaults/main.yml"), "yaml.ansible")
  h.assert_eq(ft_of(dir .. "/group_vars/all.yml"), "yaml.ansible")
  h.assert_eq(ft_of(dir .. "/host_vars/web01.yml"), "yaml.ansible")
end

function tests.plain_yaml_untouched()
  vim.cmd.runtime("ftdetect/ansible.lua")
  local dir = h.tmpdir()
  h.assert_eq(ft_of(dir .. "/config.yml"), "yaml")
  h.assert_eq(ft_of(dir .. "/roles.yml"), "yaml", "filename alone is not enough")
end

return tests
