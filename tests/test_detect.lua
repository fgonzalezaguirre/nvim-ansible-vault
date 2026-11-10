local detect = require("ansible-vault.detect")
local h = require("helpers")

local SAMPLE_YAML = {
  "plain: value",
  "db_password: !vault |",
  "          $ANSIBLE_VAULT;1.1;AES256",
  "          6438316338653863633032366232653137633135613237653666353732323335383730",
  "          313933633437616633333834366462303937343839356332393165393035393233643061",
  "other: thing",
  "nested:",
  "  key: !vault |",
  "    $ANSIBLE_VAULT;1.2;AES256;prod",
  "    3937336566663138653134393864613138356532636338383337353265316338643737336536",
  "    3664",
  "after: done",
}

local tests = {}

function tests.parse_header_basic()
  local header = detect.parse_header("$ANSIBLE_VAULT;1.1;AES256")
  h.assert_eq(header, { version = "1.1", cipher = "AES256", vault_id = nil })
end

function tests.parse_header_with_vault_id()
  local header = detect.parse_header("$ANSIBLE_VAULT;1.2;AES256;prod")
  h.assert_eq(header, { version = "1.2", cipher = "AES256", vault_id = "prod" })
end

function tests.parse_header_rejects_non_vault()
  h.assert_eq(detect.parse_header("plain: value"), nil)
  h.assert_eq(detect.parse_header(""), nil)
  h.assert_eq(detect.parse_header(nil), nil)
  h.assert_eq(detect.parse_header("  $ANSIBLE_VAULT;1.1;AES256"), nil, "indented header must not match")
end

function tests.buffer_header()
  h.assert_true(detect.buffer_header({ "$ANSIBLE_VAULT;1.1;AES256", "6162" }) ~= nil)
  h.assert_eq(detect.buffer_header({ "key: value" }), nil)
end

function tests.find_inline_regions()
  local regions = detect.find_inline_regions(SAMPLE_YAML)
  h.assert_eq(#regions, 2, "should find two regions")

  local first = regions[1]
  h.assert_eq(first.key, "db_password")
  h.assert_eq(first.start_row, 1)
  h.assert_eq(first.end_row, 5, "end_row is exclusive")
  h.assert_eq(first.key_indent, 0)
  h.assert_eq(first.blob_indent, 10)
  h.assert_eq(#first.blob_lines, 3)

  local second = regions[2]
  h.assert_eq(second.key, "key")
  h.assert_eq(second.start_row, 7)
  h.assert_eq(second.end_row, 11)
  h.assert_eq(second.key_indent, 2)
  h.assert_eq(second.blob_indent, 4)
end

function tests.inline_region_at()
  h.assert_eq(detect.inline_region_at(SAMPLE_YAML, 0), nil, "plain line has no region")
  h.assert_eq(detect.inline_region_at(SAMPLE_YAML, 2).key, "db_password", "cursor on blob line")
  h.assert_eq(detect.inline_region_at(SAMPLE_YAML, 1).key, "db_password", "cursor on tag line")
  h.assert_eq(detect.inline_region_at(SAMPLE_YAML, 9).key, "key")
  h.assert_eq(detect.inline_region_at(SAMPLE_YAML, 11), nil, "line after block has no region")
end

function tests.region_blob_text()
  local region = detect.find_inline_regions(SAMPLE_YAML)[1]
  local blob = detect.region_blob_text(region)
  local blob_lines = vim.split(blob, "\n", { plain = true })
  h.assert_eq(blob_lines[1], "$ANSIBLE_VAULT;1.1;AES256", "indentation stripped")
  h.assert_true(blob_lines[2]:match("^[0-9a-f]+$") ~= nil)
  h.assert_true(blob:sub(-1) == "\n", "blob ends with newline")
end

function tests.find_inline_regions_ignores_lookalikes()
  local lines = {
    "not_a_block: !vault |",
    "  $ANSIBLE_VAULT;1.1;AES256",
    "next: value", -- only one blob line -> not a valid region
    "bad: !vault |",
    "  no header here",
    "  61626364",
  }
  h.assert_eq(#detect.find_inline_regions(lines), 0)
end

---@return integer|nil buf buffer with SAMPLE_YAML, or nil if no YAML parser
local function ts_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- get_parser returns nil + error (no throw) when the parser is missing
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "yaml")
  if not ok or not parser then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil
  end
  return buf
end

function tests.ts_detection_matches_line_based()
  local buf = ts_buf(SAMPLE_YAML)
  if not buf then
    print("  (skipped: no yaml tree-sitter parser)")
    return
  end
  local regions = detect.find_inline_regions_ts(buf, SAMPLE_YAML)
  h.assert_eq(#regions, 2, "tree-sitter finds the same two regions")
  h.assert_eq(regions[1].key, "db_password")
  h.assert_eq(regions[2].key, "key")
  h.assert_eq(detect.inline_region_at_ts(buf, SAMPLE_YAML, 2).key, "db_password")
  vim.api.nvim_buf_delete(buf, { force = true })
end

function tests.ts_detection_rejects_false_positives()
  local lines = {
    "# db_password: !vault |",
    "#   $ANSIBLE_VAULT;1.1;AES256",
    "#   6438316338653863633032366232653137",
    "script: |",
    "  db_password: !vault |",
    "    $ANSIBLE_VAULT;1.1;AES256",
    "    6438316338653863633032366232653137",
    "real: !vault |",
    "  $ANSIBLE_VAULT;1.1;AES256",
    "  6438316338653863633032366232653137",
  }
  -- Line-based detection alone matches the vault-looking text embedded in
  -- the `script` block scalar; tree-sitter knows it is just scalar content.
  h.assert_eq(#detect.find_inline_regions(lines), 2)
  local buf = ts_buf(lines)
  if not buf then
    print("  (skipped: no yaml tree-sitter parser)")
    return
  end
  local regions = detect.find_inline_regions_ts(buf, lines)
  h.assert_eq(#regions, 1, "only the real tag survives tree-sitter filtering")
  h.assert_eq(regions[1].key, "real")
  vim.api.nvim_buf_delete(buf, { force = true })
end

return tests
