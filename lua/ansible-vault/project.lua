---Ansible project detection: find the project root above a directory by
---looking for common ansible layout markers. The upward search never
---considers the user's home directory.
local M = {}

local MARKER_FILES = { "ansible.cfg" }
local MARKER_DIRS = { "group_vars", "host_vars", "playbooks", "roles" }

---@param path string
---@return boolean
local function exists(path)
  return (vim.uv or vim.loop).fs_stat(path) ~= nil
end

---Find the ansible project root at or above `dir`.
---@param dir string
---@return string|nil
function M.root(dir)
  local home = (vim.uv or vim.loop).os_homedir()
  dir = vim.fs.normalize(dir)
  while dir and dir ~= "" do
    if dir ~= home then
      for _, name in ipairs(MARKER_FILES) do
        if exists(dir .. "/" .. name) then
          return dir
        end
      end
      for _, name in ipairs(MARKER_DIRS) do
        local path = dir .. "/" .. name
        local stat = (vim.uv or vim.loop).fs_stat(path)
        if stat and stat.type == "directory" then
          return dir
        end
      end
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---@param dir string
---@return boolean
function M.is_ansible_project(dir)
  return M.root(dir) ~= nil
end

---The directory to start detection from: the current buffer's directory,
---falling back to the cwd.
---@return string
function M.current_dir()
  local path = vim.api.nvim_buf_get_name(0)
  if path ~= "" then
    return vim.fs.dirname(path)
  end
  return (vim.uv or vim.loop).cwd()
end

return M
