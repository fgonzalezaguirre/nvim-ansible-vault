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

function tests.mfussenegger_convention_paths()
  vim.cmd.runtime("ftdetect/ansible.lua")
  local dir = h.tmpdir()
  h.assert_eq(ft_of(dir .. "/playbook-setup.yml"), "yaml.ansible", "playbook* filename")
  h.assert_eq(ft_of(dir .. "/molecule/default/converge.yml"), "yaml.ansible")
  h.assert_eq(ft_of(dir .. "/tasks/main.yml"), "yaml.ansible")
end

function tests.ftplugin_sets_keywordprg_and_path()
  if vim.fn.executable("ansible-doc") ~= 1 then
    return -- environment without ansible: nothing to assert
  end
  local dir = h.tmpdir()
  local path = dir .. "/roles/web/tasks/main.yml"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  h.write_file(path, "- name: x\n  ansible.builtin.debug:\n")
  vim.cmd.edit(vim.fn.fnameescape(path))

  h.assert_eq(vim.bo.filetype, "yaml.ansible")
  h.assert_true(vim.bo.keywordprg:find("ansible%-doc") ~= nil, "K falls back to ansible-doc")
  h.assert_true(vim.bo.path:find("roles/web/files") ~= nil, "gf searches files/")
  h.assert_true(vim.bo.path:find("roles/web/templates") ~= nil, "gf searches templates/")

  vim.cmd.bwipeout({ bang = true })
end

function tests.ftplugin_ignores_non_task_files()
  local dir = h.tmpdir()
  h.assert_eq(ft_of(dir .. "/group_vars/all.yml"), "yaml.ansible")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/group_vars/all.yml"))
  h.assert_true(vim.bo.path:find("files") == nil, "path untouched outside tasks/")
  vim.cmd.bwipeout({ bang = true })
end

return tests
