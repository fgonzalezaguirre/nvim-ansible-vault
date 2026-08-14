---Recognize common Ansible project layouts as the `yaml.ansible` filetype,
---so users can hook their own config (and lazy.nvim `ft` triggers) to it.
---Pattern set extended with mfussenegger/nvim-ansible (MIT) conventions.
vim.filetype.add({
  pattern = {
    [".*/playbooks/.*%.ya?ml"] = "yaml.ansible",
    [".*/playbook.*%.ya?ml"] = "yaml.ansible",
    [".*/group_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/host_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/defaults/.*%.ya?ml"] = "yaml.ansible",
    [".*/tasks/.*%.ya?ml"] = "yaml.ansible",
    [".*/molecule/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/tasks/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/handlers/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/defaults/.*%.ya?ml"] = "yaml.ansible",
  },
})
