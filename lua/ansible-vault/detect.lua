---Detection of ansible-vault content: whole-file headers and inline `!vault` blocks.
local M = {}

---Parse a vault envelope header line.
---`$ANSIBLE_VAULT;1.1;AES256` or `$ANSIBLE_VAULT;1.2;AES256;myid`
---@param line string|nil
---@return { version: string, cipher: string, vault_id: string|nil }|nil
function M.parse_header(line)
  if type(line) ~= "string" then
    return nil
  end
  local version, cipher, id = line:match("^%$ANSIBLE_VAULT;([%d%.]+);([%w_]+);?(.*)$")
  if not version then
    return nil
  end
  if id == "" then
    id = nil
  end
  return { version = version, cipher = cipher, vault_id = id }
end

---Check whether a list of buffer lines is a whole-file vault document.
---@param lines string[]
---@return table|nil header Parsed header, or nil
function M.buffer_header(lines)
  return M.parse_header(lines[1])
end

---Read and parse the vault header of a file on disk.
---@param path string
---@return table|nil header
function M.file_header(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local line = fd:read("*l")
  fd:close()
  return M.parse_header(line)
end

-- key: !vault |
--           $ANSIBLE_VAULT;1.1;AES256
--           6438...
local TAG_PAT = "^(%s*)(.-):%s*!vault%s*|%s*$"
local HEX_PAT = "^%s*[0-9a-fA-F]+%s*$"
local HEADER_PAT = "^%s*%$ANSIBLE_VAULT;"

---@class ansible-vault.InlineRegion
---@field start_row integer 0-indexed row of the `key: !vault |` line
---@field end_row integer 0-indexed row one past the last blob line (exclusive)
---@field key string YAML key name
---@field key_indent integer Indentation (columns) of the key line
---@field blob_indent integer Indentation (columns) of the blob lines
---@field blob_lines string[] Raw blob lines as they appear in the buffer

---Find all inline `!vault` regions in a list of lines.
---@param lines string[]
---@return ansible-vault.InlineRegion[]
function M.find_inline_regions(lines)
  local regions = {}
  local i = 1
  while i <= #lines do
    local indent, key = lines[i]:match(TAG_PAT)
    if indent then
      local key_indent = #indent
      local blob = {}
      local blob_indent = nil
      local j = i + 1
      while j <= #lines do
        local l = lines[j]
        if l:match("^%s*$") then
          break
        end
        local li = #(l:match("^%s*"))
        if li <= key_indent then
          break
        end
        if not (l:match(HEX_PAT) or l:match(HEADER_PAT)) then
          break
        end
        blob_indent = blob_indent or li
        table.insert(blob, l)
        j = j + 1
      end
      -- A valid region needs at least the header line plus one hex line.
      if #blob >= 2 and blob[1]:match(HEADER_PAT) then
        table.insert(regions, {
          start_row = i - 1,
          end_row = j - 1,
          key = vim.trim(key),
          key_indent = key_indent,
          blob_indent = blob_indent,
          blob_lines = blob,
        })
        i = j
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return regions
end

---Find the inline vault region containing the given row, if any.
---@param lines string[]
---@param row integer 0-indexed row
---@return ansible-vault.InlineRegion|nil
function M.inline_region_at(lines, row)
  for _, region in ipairs(M.find_inline_regions(lines)) do
    if row >= region.start_row and row < region.end_row then
      return region
    end
  end
  return nil
end

---Locate `!vault` tag rows via tree-sitter (YAML parser).
---@param buf integer
---@return table<integer, boolean>|nil rows set of 0-indexed tag rows, or nil if TS is unavailable
function M.ts_vault_rows(buf)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "yaml")
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end
  local qok, query = pcall(vim.treesitter.query.parse, "yaml", "(tag) @tag")
  if not qok or not query then
    return nil
  end
  local rows = {}
  for _, node in query:iter_captures(tree:root(), buf, 0, -1) do
    if vim.treesitter.get_node_text(node, buf) == "!vault" then
      rows[node:start()] = true
    end
  end
  return rows
end

---Find all inline `!vault` regions, using tree-sitter to reject false
---positives (comments, quoted strings) when the YAML parser is available.
---Falls back to pure line-based detection otherwise.
---@param buf integer
---@param lines string[]
---@return ansible-vault.InlineRegion[]
function M.find_inline_regions_ts(buf, lines)
  local regions = M.find_inline_regions(lines)
  local tag_rows = M.ts_vault_rows(buf)
  if not tag_rows then
    return regions
  end
  local filtered = {}
  for _, region in ipairs(regions) do
    if tag_rows[region.start_row] then
      table.insert(filtered, region)
    end
  end
  return filtered
end

---Find the inline vault region containing the given row (tree-sitter aware).
---@param buf integer
---@param lines string[]
---@param row integer 0-indexed row
---@return ansible-vault.InlineRegion|nil
function M.inline_region_at_ts(buf, lines, row)
  for _, region in ipairs(M.find_inline_regions_ts(buf, lines)) do
    if row >= region.start_row and row < region.end_row then
      return region
    end
  end
  return nil
end

---Extract the bare vault blob (header + hex, indentation stripped) from a region.
---@param region ansible-vault.InlineRegion
---@return string
function M.region_blob_text(region)
  local stripped = {}
  for _, l in ipairs(region.blob_lines) do
    table.insert(stripped, (l:gsub("^%s*", "")))
  end
  return table.concat(stripped, "\n") .. "\n"
end

return M
