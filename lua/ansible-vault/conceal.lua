---Conceal inline `!vault` blobs: the hex body of a vault block is hidden
---(conceal_lines extmarks) and the key line gets a lock marker, so files with
---many secrets stay readable. 'conceallevel' is raised per window while it
---shows a concealed buffer and restored afterwards.
---
---With `conceal.atomic` (default) the `!vault |` token on the key line stands
---for the whole hidden blob:
---  * the blob is shown only while the cursor is on the token;
---  * the cursor never rests on blob lines (j/k, searches and jumps skip
---    them), and the token behaves like a single character: landing inside it
---    snaps to its start, moving forward off it (w, l, e, $) jumps past the
---    block;
---  * breaking the token (x, dw, D, C, cw, ...) deletes the blob too, and so
---    does deleting the key line; one `u` restores everything;
---  * `dd` on the key line deletes (and yanks) the whole block, `o` opens the
---    new line below the block, and lines that end up between a key and its
---    blob (linewise put, :put, ...) are moved below the blob.
local config = require("ansible-vault.config")
local detect = require("ansible-vault.detect")

local M = {}

local group = nil
local ns = vim.api.nvim_create_namespace("ansible_vault_conceal")
local track_ns = vim.api.nvim_create_namespace("ansible_vault_conceal_track")
local STATE_VAR = "ansible_vault_conceal"
local WIN_VAR = "ansible_vault_conceallevel"
local TOKEN = "!vault |"

---@class ansible-vault.ConcealRegion
---@field s integer 0-indexed key row
---@field e integer 0-indexed row past the blob (exclusive)
---@field tc integer 0-indexed byte column of the `!vault` token on the key row

---Per-buffer result of the last refresh.
---@type table<integer, { regions: ansible-vault.ConcealRegion[], expanded: integer|nil }>
local cache = {}

---Blocks tracked across edits (refreshed outside insert mode only, so the
---state from before an insert is still there on InsertLeave).
---@type table<integer, { mark: integer, blob: string[], prefix: string }[]>
local tracked = {}

---Last cursor position per window, to tell the direction of a motion.
---@type table<integer, { buf: integer, row: integer, col: integer }>
local lastpos = {}

---Set by `o` on a key line: the cursor is parked on the last blob line on
---purpose, don't move it before `o` runs.
local hold_cursor = false

---@return boolean
local function atomic()
  local cfg = config.get().conceal
  return cfg.enabled and cfg.atomic ~= false
end

---@param buf integer
---@return boolean
local function is_concealed(buf)
  local ok, flagged = pcall(vim.api.nvim_buf_get_var, buf, STATE_VAR)
  return ok and flagged == true
end

---@return boolean
local function in_insert()
  return vim.api.nvim_get_mode().mode:match("^[iR]") ~= nil
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

---0-indexed cursor (row, col) if `buf` is shown in the current window.
---@param buf integer
---@return integer|nil row, integer|nil col
local function cursor_pos(buf)
  if vim.api.nvim_get_current_buf() ~= buf then
    return nil, nil
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] - 1, pos[2]
end

---Key row of the region whose `!vault |` token the cursor is on, if any.
---@param regions ansible-vault.ConcealRegion[]
---@param row integer|nil
---@param col integer|nil
---@return integer|nil
local function token_owner(regions, row, col)
  if not row then
    return nil
  end
  for _, r in ipairs(regions) do
    if row == r.s and col >= r.tc then
      return r.s
    end
  end
  return nil
end

---@param buf integer
---@param row integer 0-indexed
---@return ansible-vault.ConcealRegion|nil
local function region_at(buf, row)
  local entry = cache[buf]
  for _, r in ipairs(entry and entry.regions or {}) do
    if row >= r.s and row < r.e then
      return r
    end
  end
  return nil
end

---Recompute conceal extmarks for a buffer.
---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  pcall(vim.api.nvim_buf_set_var, buf, STATE_VAR, false)
  cache[buf] = nil

  local cfg = config.get().conceal
  if not cfg.enabled or vim.bo[buf].buftype ~= "" then
    vim.api.nvim_buf_clear_namespace(buf, track_ns, 0, -1)
    tracked[buf] = nil
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

  local entry = { regions = {}, expanded = nil }
  for _, region in ipairs(regions) do
    local tc = lines[region.start_row + 1]:find("!vault", 1, true)
    table.insert(entry.regions, { s = region.start_row, e = region.end_row, tc = (tc or 1) - 1 })
  end
  if atomic() then
    entry.expanded = token_owner(entry.regions, cursor_pos(buf))
  end

  if not in_insert() then
    vim.api.nvim_buf_clear_namespace(buf, track_ns, 0, -1)
    tracked[buf] = {}
    for i, region in ipairs(regions) do
      local r = entry.regions[i]
      table.insert(tracked[buf], {
        mark = vim.api.nvim_buf_set_extmark(buf, track_ns, r.s, 0, { invalidate = true, undo_restore = false }),
        blob = region.blob_lines,
        prefix = lines[r.s + 1]:sub(1, r.tc),
      })
    end
  end

  for _, region in ipairs(regions) do
    local header = detect.parse_header((region.blob_lines[1]:gsub("^%s*", "")))
    local label = " [vault" .. (header and header.vault_id and (":" .. header.vault_id) or "") .. "]"
    vim.api.nvim_buf_set_extmark(buf, ns, region.start_row, 0, {
      virt_text = { { label, "Comment" } },
      virt_text_pos = "eol",
    })
    if region.end_row > region.start_row + 1 and entry.expanded ~= region.start_row then
      -- conceal_lines hides rows start..end_row *inclusive*, while
      -- region.end_row is exclusive: stop at the last blob line.
      vim.api.nvim_buf_set_extmark(buf, ns, region.start_row + 1, 0, {
        end_row = region.end_row - 1,
        conceal_lines = "",
      })
    end
  end

  cache[buf] = entry
  if #regions > 0 then
    pcall(vim.api.nvim_buf_set_var, buf, STATE_VAR, true)
  end
  sync_windows(buf)
end

---Keep the cursor off blob lines and treat the `!vault |` token as a single
---character; then expand/collapse the blob for the token under the cursor.
---@param buf integer
function M.on_cursor_moved(buf)
  local entry = cache[buf]
  if not entry or #entry.regions == 0 or vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  if not atomic() then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local row, col = cursor_pos(buf)

  if hold_cursor then
    hold_cursor = false
  elseif not in_insert() then
    local prev = lastpos[win]
    if prev and prev.buf ~= buf then
      prev = nil
    end
    local nlines = vim.api.nvim_buf_line_count(buf)
    local new_row, new_col = row, col
    for _, r in ipairs(entry.regions) do
      local past = r.e < nlines and r.e or nil
      if row > r.s and row < r.e then
        -- on a blob line: continue in the direction the cursor was going
        if past and (not prev or prev.row <= r.s) then
          new_row = past
          local len = #vim.api.nvim_buf_get_lines(buf, past, past + 1, false)[1]
          new_col = math.max(0, math.min(col, len - 1))
        else
          new_row, new_col = r.s, r.tc
        end
        break
      elseif row == r.s and col > r.tc then
        if past and prev and prev.row == r.s and prev.col == r.tc then
          -- moving forward off the token: jump past the block
          local l = vim.api.nvim_buf_get_lines(buf, past, past + 1, false)[1]
          new_row, new_col = past, #(l:match("^%s*"))
          if new_col >= #l then
            new_col = math.max(0, #l - 1)
          end
        else
          new_col = r.tc
        end
        break
      end
    end
    if new_row ~= row or new_col ~= col then
      row, col = new_row, new_col
      vim.api.nvim_win_set_cursor(win, { row + 1, col })
    end
    lastpos[win] = { buf = buf, row = row, col = col }
  end

  if token_owner(entry.regions, row, col) ~= entry.expanded then
    M.refresh(buf)
  end
end

---true if `s` can be obtained by deleting characters from `of`.
---@param s string
---@param of string
---@return boolean
local function is_fragment(s, of)
  local j = 1
  for i = 1, #s do
    local found = of:find(s:sub(i, i), j, true)
    if not found then
      return false
    end
    j = found + 1
  end
  return true
end

---Find `blob` as a run of consecutive lines; prefer the first run at or after
---row `from` (0-indexed), else any.
---@param lines string[]
---@param blob string[]
---@param from integer
---@return integer|nil row 0-indexed start of the run
local function find_run(lines, blob, from)
  local function at(i)
    for k = 1, #blob do
      if lines[i + k - 1] ~= blob[k] then
        return false
      end
    end
    return true
  end
  for i = from + 1, #lines - #blob + 1 do
    if at(i) then
      return i - 1
    end
  end
  for i = 1, math.min(from, #lines - #blob + 1) do
    if at(i) then
      return i - 1
    end
  end
  return nil
end

---@param buf integer
---@param first integer
---@param last integer exclusive
---@param replacement string[]
local function set_lines_joined(buf, first, last, replacement)
  -- join with the user's change so a single `u` reverts both
  pcall(vim.cmd.undojoin)
  vim.api.nvim_buf_set_lines(buf, first, last, false, replacement)
end

---Repair tracked blocks after an edit: drop blobs whose key line was deleted
---or whose `!vault |` token was broken, and move lines that landed between
---a key line and its blob below the blob.
---@param buf integer
function M.repair(buf)
  if not atomic() or not vim.api.nvim_buf_is_valid(buf) or not tracked[buf] then
    return
  end
  local ut = vim.fn.undotree(buf)
  if ut.seq_cur ~= ut.seq_last then
    return -- undoing/redoing: leave the restored text alone
  end

  vim.api.nvim_buf_call(buf, function()
    for _, t in ipairs(tracked[buf]) do
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local mark = vim.api.nvim_buf_get_extmark_by_id(buf, track_ns, t.mark, { details = true })
      local key_row = mark[1]
      local key_gone = key_row == nil or (mark[3] and mark[3].invalid)
      local start = find_run(lines, t.blob, key_gone and 0 or key_row + 1)
      if start then
        local stop = start + #t.blob
        local above = lines[start] -- line right above the run (1-indexed start == row start-1)
        local attached = above ~= nil and above:match(detect.TAG_PAT) ~= nil
        if key_gone then
          if not attached then
            set_lines_joined(buf, start, stop, {})
          end
        else
          local key_line = lines[key_row + 1]
          if key_line:match(detect.TAG_PAT) then
            if start > key_row + 1 then
              -- lines were inserted between key and blob: move them below
              local between = vim.list_slice(lines, key_row + 2, start)
              local cur = vim.api.nvim_win_get_cursor(0)
              set_lines_joined(buf, key_row + 1, stop, vim.list_extend(vim.deepcopy(t.blob), between))
              if cur[1] - 1 > key_row and cur[1] - 1 < start then
                pcall(vim.api.nvim_win_set_cursor, 0, { cur[1] + #t.blob, cur[2] })
              end
            end
          elseif start == key_row + 1 then
            -- token broken: the value is gone, and so is the blob
            set_lines_joined(buf, start, stop, {})
            local keep = vim.trim(t.prefix) == "" and t.prefix or t.prefix:gsub("%s+$", "")
            if vim.startswith(key_line, keep) then
              -- drop what is left of the token; text typed around an intact
              -- token (A x, i x) becomes the new value
              local rest = vim.trim((key_line:sub(#keep + 1):gsub("%s*!vault%s*|%s*", " ", 1)))
              if rest == "" or is_fragment(rest, TOKEN) then
                set_lines_joined(buf, key_row, key_row + 1, { keep })
              elseif rest ~= vim.trim(key_line:sub(#keep + 1)) then
                set_lines_joined(buf, key_row, key_row + 1, { keep .. " " .. rest })
              end
            end
          end
        end
      end
    end
  end)
end

---Line range to delete for `dd` with `count`, widened so that any vault
---block it touches is removed whole (key line + blob).
---@param buf integer
---@param row integer 0-indexed cursor row
---@param count integer
---@return integer first, integer last 0-indexed, inclusive
function M.delete_range(buf, row, count)
  local first = row
  local last = math.min(row + count - 1, vim.api.nvim_buf_line_count(buf) - 1)
  local entry = cache[buf]
  for _, r in ipairs(entry and entry.regions or {}) do
    if r.s <= last and r.e - 1 >= first then
      first = math.min(first, r.s)
      last = math.max(last, r.e - 1)
    end
  end
  return first, last
end

---`dd` replacement: delete whole vault blocks, behave natively elsewhere.
function M.delete_lines()
  local buf = vim.api.nvim_get_current_buf()
  local count = vim.v.count1
  local reg = vim.v.register
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local first, last = M.delete_range(buf, row, count)
  if first == row and last == row + count - 1 then
    vim.cmd(('normal! "%s%ddd'):format(reg, count))
    return
  end
  vim.cmd(("%d,%ddelete %s"):format(first + 1, last + 1, reg))
end

---`o` replacement: on a vault key line, open the new line below the blob.
function M.open_below()
  local count = vim.v.count1
  local buf = vim.api.nvim_get_current_buf()
  local r = region_at(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
  local keys = (count > 1 and tostring(count) or "") .. "o"
  if r then
    hold_cursor = true
    vim.api.nvim_win_set_cursor(0, { r.e, 0 }) -- 1-indexed r.e == last blob line
    -- autoindent would copy the blob's indent: use the key line's instead
    local key_indent = vim.api.nvim_buf_get_lines(buf, r.s, r.s + 1, false)[1]:match("^%s*")
    keys = keys .. vim.keycode("0<C-d>") .. key_indent
  end
  -- "i": run before anything already typed after `o`
  vim.api.nvim_feedkeys(keys, "ni", false)
end

---Register autocmds. Idempotent.
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("ansible_vault_conceal", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "TextChangedI" }, {
    group = group,
    pattern = "*",
    desc = "ansible-vault: conceal !vault blobs",
    callback = function(ev)
      M.refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    pattern = "*",
    desc = "ansible-vault: keep !vault blocks whole and concealed",
    callback = function(ev)
      M.repair(ev.buf)
      M.refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    pattern = "*",
    desc = "ansible-vault: treat the !vault token as the hidden blob",
    callback = function(ev)
      M.on_cursor_moved(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      hold_cursor = false
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = "*",
    callback = function(ev)
      cache[ev.buf] = nil
      tracked[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      lastpos[tonumber(ev.match)] = nil
    end,
  })
  -- A concealed buffer entering/leaving a window must sync 'conceallevel'.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave" }, {
    group = group,
    pattern = "*",
    desc = "ansible-vault: sync conceallevel for vault buffers",
    callback = function(ev)
      sync_windows(ev.buf)
    end,
  })

  if atomic() then
    local keymaps = require("ansible-vault.keymaps")
    keymaps.setup(group, "dd", function()
      M.delete_lines()
    end, "Delete line (whole block on a !vault secret)")
    keymaps.setup(group, "o", function()
      M.open_below()
    end, "Open line below (below the block on a !vault secret)")
  end
end

return M
