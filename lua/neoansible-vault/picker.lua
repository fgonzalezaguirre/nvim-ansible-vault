---Secret picker: list the inline `!vault` secrets of the current buffer in
---snacks.nvim, telescope, or a plain vim.ui.select fallback, and jump to or
---edit the chosen one.
local config = require("neoansible-vault.config")
local detect = require("neoansible-vault.detect")

local M = {}

local group = nil

-- defined below with the project-wide picker
---@type fun(e: neoansible-vault.ProjectEntry)
local open_entry

local function notify(msg, level)
  vim.notify(msg, level, { title = "neoansible-vault" })
end

---@class neoansible-vault.PickerEntry
---@field key string YAML key name
---@field lnum integer 1-indexed line of the `key: !vault |` line
---@field vault_id string|nil
---@field text string Display text

---Collect the inline vault secrets of a buffer as picker entries.
---@param buf integer
---@return neoansible-vault.PickerEntry[]
function M.collect(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local regions
  if config.get().inline.treesitter and detect.find_inline_regions_ts then
    regions = detect.find_inline_regions_ts(buf, lines)
  else
    regions = detect.find_inline_regions(lines)
  end
  local entries = {}
  for _, region in ipairs(regions) do
    local header = detect.parse_header((region.blob_lines[1]:gsub("^%s*", "")))
    local vault_id = header and header.vault_id or nil
    table.insert(entries, {
      key = region.key,
      lnum = region.start_row + 1,
      vault_id = vault_id,
      text = ("%s (line %d)%s"):format(region.key, region.start_row + 1, vault_id and (" [" .. vault_id .. "]") or ""),
    })
  end
  return entries
end

---Jump to the chosen entry and open the inline editor on it.
---@param entry neoansible-vault.PickerEntry
local function jump_and_edit(entry)
  vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
  require("neoansible-vault.inline").edit()
end

---Build snacks.nvim picker items. `file` and `pos` let the preview pane show
---the buffer around the secret's line (without them snacks errors with
---"Item has no file").
---@param entries neoansible-vault.PickerEntry[]
---@param bufname string
---@return table[]
function M._snacks_items(entries, bufname)
  return vim.tbl_map(function(e)
    return { text = e.text, entry = e, file = bufname, pos = { e.lnum, 0 } }
  end, entries)
end

---@param entries neoansible-vault.PickerEntry[]
---@param bufname string
---@return boolean handled
local function pick_snacks(entries, bufname)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return false
  end
  snacks.picker.pick({
    title = "Ansible vault secrets",
    items = M._snacks_items(entries, bufname),
    format = "text",
    confirm = function(picker, item)
      picker:close()
      if item then
        jump_and_edit(item.entry)
      end
    end,
  })
  return true
end

---Build a telescope entry: `filename` + `lnum` give the default previewer
---buffer context around the secret.
---@param e neoansible-vault.PickerEntry
---@param bufname string
---@return table
function M._telescope_entry(e, bufname)
  return { value = e, display = e.text, ordinal = e.key, filename = bufname, lnum = e.lnum }
end

---Build the snacks picker opts for project-wide entries (inline secrets and
---encrypted files).
---@param entries neoansible-vault.ProjectEntry[]
---@return table
function M._snacks_files_picker_opts(entries)
  return {
    title = "Ansible vault secrets (project)",
    items = vim.tbl_map(function(e)
      return { text = e.text, entry = e, file = e.path, pos = { e.lnum or 1, 0 } }
    end, entries),
    format = "text",
    confirm = function(p, item)
      p:close()
      if item then
        open_entry(item.entry)
      end
    end,
  }
end

---Snacks picker sources. Merge into your snacks config to call them as
---`:lua Snacks.picker.ansible_vault_secrets()`:
---`opts.picker.sources = require("neoansible-vault.picker").snacks_sources()`
---@return table<string, table>
function M.snacks_sources()
  return {
    ansible_vault_secrets = {
      title = "Ansible vault secrets",
      format = "text",
      finder = function()
        local buf = vim.api.nvim_get_current_buf()
        return M._snacks_items(M.collect(buf), vim.api.nvim_buf_get_name(buf))
      end,
      confirm = function(p, item)
        p:close()
        if item then
          jump_and_edit(item.entry)
        end
      end,
    },
    ansible_vault_files = {
      title = "Ansible vault secrets (project)",
      format = "text",
      finder = function()
        local entries = M.collect_project((vim.uv or vim.loop).cwd())
        return vim.tbl_map(function(e)
          return { text = e.text, entry = e, file = e.path, pos = { e.lnum or 1, 0 } }
        end, entries)
      end,
      confirm = function(p, item)
        p:close()
        if item then
          open_entry(item.entry)
        end
      end,
    },
  }
end

---@param entries neoansible-vault.PickerEntry[]
---@param bufname string
---@return boolean handled
local function pick_telescope(entries, bufname)
  local ok = pcall(require, "telescope.pickers")
  if not ok then
    return false
  end
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values
  pickers
    .new({}, {
      prompt_title = "Ansible vault secrets",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          return M._telescope_entry(e, bufname)
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            jump_and_edit(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
  return true
end

---@param entries neoansible-vault.PickerEntry[]
local function pick_select(entries)
  vim.ui.select(entries, {
    prompt = "Ansible vault secrets",
    format_item = function(e)
      return e.text
    end,
  }, function(choice)
    if choice then
      jump_and_edit(choice)
    end
  end)
end

---Open the secret picker for the current buffer.
---@param opts { backend: string|nil }|nil
function M.pick(opts)
  local buf = vim.api.nvim_get_current_buf()
  local entries = M.collect(buf)
  if #entries == 0 then
    notify("no !vault secrets in this buffer", vim.log.levels.WARN)
    return
  end
  local bufname = vim.api.nvim_buf_get_name(buf)

  local backend = (opts and opts.backend) or config.get().picker.backend
  if backend == "snacks" or backend == "auto" then
    if pick_snacks(entries, bufname) then
      return
    elseif backend == "snacks" then
      notify("snacks.nvim picker not available", vim.log.levels.ERROR)
      return
    end
  end
  if backend == "telescope" or backend == "auto" then
    if pick_telescope(entries, bufname) then
      return
    elseif backend == "telescope" then
      notify("telescope.nvim not available", vim.log.levels.ERROR)
      return
    end
  end
  pick_select(entries)
end

---Directories that never contain user vault files worth listing.
local SKIP_DIRS = { node_modules = true, vendor = true, __pycache__ = true, [".terraform"] = true, [".venv"] = true }

---Yield every regular file under `root` (hidden directories skipped).
---@param root string
---@param cb fun(path: string)
local function walk_files(root, cb)
  local function scan(dir)
    for name, kind in vim.fs.dir(dir) do
      local path = dir .. "/" .. name
      if kind == "directory" then
        if not SKIP_DIRS[name] and not vim.startswith(name, ".") then
          scan(path)
        end
      elseif kind == "file" then
        cb(path)
      end
    end
  end
  scan(root)
end

---Recursively collect vault-encrypted files under `root` (whole-file
---`$ANSIBLE_VAULT;` header). Hidden directories are skipped.
---@param root string
---@return { path: string, rel: string, vault_id: string|nil, text: string }[]
function M.collect_files(root)
  root = vim.fs.normalize(root)
  local out = {}
  walk_files(root, function(path)
    local header = detect.file_header(path)
    if header then
      local rel = path:sub(#root + 2)
      table.insert(out, {
        path = path,
        rel = rel,
        vault_id = header.vault_id,
        text = rel .. (header.vault_id and (" [" .. header.vault_id .. "]") or ""),
      })
    end
  end)
  table.sort(out, function(a, b)
    return a.rel < b.rel
  end)
  return out
end

---@class neoansible-vault.ProjectEntry
---@field kind "file"|"inline"
---@field path string
---@field rel string path relative to the scanned root
---@field key string|nil inline: the secret's key
---@field lnum integer|nil inline: 1-indexed line of the `key: !vault |` line
---@field vault_id string|nil
---@field text string display text

---Recursively collect vault secrets under `root`: whole-file encrypted files
---and inline `!vault` blocks in yaml files.
---@param root string
---@return neoansible-vault.ProjectEntry[]
function M.collect_project(root)
  root = vim.fs.normalize(root)
  local out = {}
  walk_files(root, function(path)
    local rel = path:sub(#root + 2)
    local badge = function(vault_id)
      return vault_id and (" [" .. vault_id .. "]") or ""
    end
    local header = detect.file_header(path)
    if header then
      table.insert(out, {
        kind = "file",
        path = path,
        rel = rel,
        vault_id = header.vault_id,
        text = ("%s (encrypted file)%s"):format(rel, badge(header.vault_id)),
      })
    elseif path:match("%.ya?ml$") then
      local fd = io.open(path, "r")
      if not fd then
        return
      end
      local lines = vim.split(fd:read("*a") or "", "\n", { plain = true })
      fd:close()
      for _, region in ipairs(detect.find_inline_regions(lines)) do
        local blob_header = detect.parse_header((region.blob_lines[1]:gsub("^%s*", "")))
        local vault_id = blob_header and blob_header.vault_id or nil
        table.insert(out, {
          kind = "inline",
          path = path,
          rel = rel,
          key = region.key,
          lnum = region.start_row + 1,
          vault_id = vault_id,
          text = ("%s:%d  %s%s"):format(rel, region.start_row + 1, region.key, badge(vault_id)),
        })
      end
    end
  end)
  table.sort(out, function(a, b)
    return (a.rel .. (a.key or "")) < (b.rel .. (b.key or ""))
  end)
  return out
end

---@param e neoansible-vault.ProjectEntry
function open_entry(e)
  vim.cmd.edit(vim.fn.fnameescape(e.path))
  if e.kind == "inline" and e.lnum then
    vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
    require("neoansible-vault.inline").edit()
  end
  -- whole vault files decrypt transparently on read
end

---Open the project-wide vault secrets picker: inline `!vault` blocks in yaml
---files plus whole-file encrypted files. Confirming jumps to the secret and
---opens the edit float (inline) or edits the file (transparent decrypt).
---@param opts { backend: string|nil }|nil
function M.pick_file(opts)
  local root = (vim.uv or vim.loop).cwd()
  local entries = M.collect_project(root)
  if #entries == 0 then
    notify("no vault secrets found under " .. root, vim.log.levels.WARN)
    return
  end

  local backend = (opts and opts.backend) or config.get().picker.backend
  if backend == "snacks" or backend == "auto" then
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.picker then
      snacks.picker.pick(M._snacks_files_picker_opts(entries))
      return
    elseif backend == "snacks" then
      notify("snacks.nvim picker not available", vim.log.levels.ERROR)
      return
    end
  end
  if backend == "telescope" or backend == "auto" then
    local ok = pcall(require, "telescope.pickers")
    if ok then
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local conf = require("telescope.config").values
      pickers
        .new({}, {
          prompt_title = "Ansible vault secrets (project)",
          finder = finders.new_table({
            results = entries,
            entry_maker = function(e)
              return { value = e, display = e.text, ordinal = e.text, filename = e.path, lnum = e.lnum or 1 }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if selection then
                open_entry(selection.value)
              end
            end)
            return true
          end,
        })
        :find()
      return
    elseif backend == "telescope" then
      notify("telescope.nvim not available", vim.log.levels.ERROR)
      return
    end
  end
  vim.ui.select(entries, {
    prompt = "Ansible vault secrets (project)",
    format_item = function(e)
      return e.text
    end,
  }, function(choice)
    if choice then
      open_entry(choice)
    end
  end)
end

---Register the picker keymaps (buffer-local to yaml buffers). Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("neoansible_vault_picker", { clear = true })

  local cfg = config.get().picker
  if cfg.enabled then
    local km = config.get().keymaps
    require("neoansible-vault.keymaps").setup(group, km.find_buffer, function()
      M.pick()
    end, "Ansible vault: find secrets in buffer")
    require("neoansible-vault.keymaps").setup(group, km.find_project, function()
      M.pick_file()
    end, "Ansible vault: find secrets in project")
  end
end

return M
