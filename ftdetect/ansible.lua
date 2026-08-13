---Recognize common Ansible project layouts as the `yaml.ansible` filetype,
---so users can hook their own config (and lazy.nvim `ft` triggers) to it.
vim.filetype.add({
  pattern = {
    [".*/playbooks/.*%.ya?ml"] = "yaml.ansible",
    [".*/group_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/host_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/tasks/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/handlers/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/[^/]+/defaults/.*%.ya?ml"] = "yaml.ansible",
  },
})
