---Conceal inline `!vault` blobs: the hex body of a vault block is hidden
---(conceal_lines extmarks) and the key line gets a lock marker, so files with
---many secrets stay readable. 'conceallevel' is raised per window while it
---shows a concealed buffer and restored afterwards.
local config = require("neoansible-vault.config")
local detect = require("neoansible-vault.detect")

local M = {}

local group = nil
local ns = vim.api.nvim_create_namespace("neoansible_vault_conceal")
local STATE_VAR = "neoansible_vault_conceal"
local WIN_VAR = "neoansible_vault_conceallevel"

---@param buf integer
---@return boolean
local function is_concealed(buf)
  local ok, flagged = pcall(vim.api.nvim_buf_get_var, buf, STATE_VAR)
  return ok and flagged == true
end

---Raise 'conceallevel' in windows showing a concealed buffer, restore it in
---windows whose buffer is no longer concealed.
---@param buf integer
local function sync_windows(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local wok, saved = pcall(vim.api.nvim_win_get_var, win, WIN_VAR)
    if is_concealed(buf) then
      if not wok then
        pcall(vim.api.nvim_win_set_var, win, WIN_VAR, vim.wo[win].conceallevel)
        if vim.wo[win].conceallevel == 0 then
          vim.wo[win].conceallevel = 2
        end
      end
    elseif wok then
      vim.wo[win].conceallevel = saved
      pcall(vim.api.nvim_win_del_var, win, WIN_VAR)
    end
  end
end

---Recompute conceal extmarks for a buffer.
---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  pcall(vim.api.nvim_buf_set_var, buf, STATE_VAR, false)

  local cfg = config.get().conceal
  if not cfg.enabled or vim.bo[buf].buftype ~= "" then
    sync_windows(buf)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local regions
  if config.get().inline.treesitter then
    regions = detect.find_inline_regions_ts(buf, lines)
  else
    regions = detect.find_inline_regions(lines)
  end

  for _, region in ipairs(regions) do
    local header = detect.parse_header((region.blob_lines[1]:gsub("^%s*", "")))
    local label = " [vault" .. (header and header.vault_id and (":" .. header.vault_id) or "") .. "]"
    vim.api.nvim_buf_set_extmark(buf, ns, region.start_row, 0, {
      virt_text = { { label, "Comment" } },
      virt_text_pos = "eol",
    })
    if region.end_row > region.start_row + 1 then
      -- conceal_lines hides rows start..end_row *inclusive*, while
      -- region.end_row is exclusive: stop at the last blob line.
      vim.api.nvim_buf_set_extmark(buf, ns, region.start_row + 1, 0, {
        end_row = region.end_row - 1,
        conceal_lines = "",
      })
    end
  end

  if #regions > 0 then
    pcall(vim.api.nvim_buf_set_var, buf, STATE_VAR, true)
  end
  sync_windows(buf)
end

---Register autocmds. Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("neoansible_vault_conceal", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "*",
    desc = "neoansible-vault: conceal !vault blobs",
    callback = function(ev)
      M.refresh(ev.buf)
    end,
  })
  -- A concealed buffer entering/leaving a window must sync 'conceallevel'.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave" }, {
    group = group,
    pattern = "*",
    desc = "neoansible-vault: sync conceallevel for vault buffers",
    callback = function(ev)
      sync_windows(ev.buf)
    end,
  })
end

return M
