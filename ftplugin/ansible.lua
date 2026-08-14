-- Buffer-local conveniences for yaml.ansible buffers.
-- Adapted from mfussenegger/nvim-ansible (MIT).

-- K opens ansible-doc for the module name under the cursor.
if vim.fn.executable("ansible-doc") == 1 then
  vim.bo.keywordprg = ":sp term://ansible-doc"
end

-- From a tasks/ file, gf can jump into the sibling files/ and templates/
-- directories of the same role.
local fname = vim.api.nvim_buf_get_name(0)
if fname:find("tasks/") then
  local paths = {
    vim.bo.path,
    vim.fs.dirname(fname:gsub("tasks/", "files/")),
    vim.fs.dirname(fname:gsub("tasks/", "templates/")),
    vim.fs.dirname(fname),
  }
  vim.bo.path = table.concat(paths, ",")
end
