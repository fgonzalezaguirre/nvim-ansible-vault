---Secret picker: list the inline `!vault` secrets of the current buffer in
---snacks.nvim, telescope, or a plain vim.ui.select fallback, and jump to or
---edit the chosen one.
local config = require("neoansible-vault.config")
local detect = require("neoansible-vault.detect")

local M = {}

local group = nil

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

---@param entries neoansible-vault.PickerEntry[]
---@return boolean handled
local function pick_snacks(entries)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return false
  end
  snacks.picker.pick({
    title = "Ansible vault secrets",
    items = vim.tbl_map(function(e)
      return { text = e.text, entry = e }
    end, entries),
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

---@param entries neoansible-vault.PickerEntry[]
---@return boolean handled
local function pick_telescope(entries)
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
          return { value = e, display = e.text, ordinal = e.key, lnum = e.lnum }
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
function M.pick()
  local buf = vim.api.nvim_get_current_buf()
  local entries = M.collect(buf)
  if #entries == 0 then
    notify("no !vault secrets in this buffer", vim.log.levels.WARN)
    return
  end

  local backend = config.get().picker.backend
  if backend == "snacks" or backend == "auto" then
    if pick_snacks(entries) then
      return
    elseif backend == "snacks" then
      notify("snacks.nvim picker not available", vim.log.levels.ERROR)
      return
    end
  end
  if backend == "telescope" or backend == "auto" then
    if pick_telescope(entries) then
      return
    elseif backend == "telescope" then
      notify("telescope.nvim not available", vim.log.levels.ERROR)
      return
    end
  end
  pick_select(entries)
end

---Register the picker keymap. Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("neoansible_vault_picker", { clear = true })

  local cfg = config.get().picker
  if cfg.enabled and cfg.keymap and cfg.keymap ~= "" then
    vim.keymap.set("n", cfg.keymap, function()
      M.pick()
    end, { desc = "Pick an ansible vault secret in this buffer" })
  end
end

return M
