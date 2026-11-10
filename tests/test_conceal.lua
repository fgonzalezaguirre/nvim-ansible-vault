local conceal = require("ansible-vault.conceal")
local h = require("helpers")

local tests = {}

local ns = vim.api.nvim_create_namespace("ansible_vault_conceal")

---Edit a yaml file with one real vault block; returns buf and block lines.
---@return integer buf, string passfile, string dir
local function edit_vault_file()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block = h.vault_encrypt_string("s3cr3t", "db_password", passfile)
  local path = dir .. "/vars.yml"
  local lines = vim.list_extend({ "plain: value" }, vim.split(block, "\n", { plain = true }))
  h.write_file(path, table.concat(lines, "\n") .. "\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), passfile, dir
end

function tests.conceal_marks_blob_lines()
  require("ansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local buf = edit_vault_file()

  conceal.refresh(buf)

  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local has_label, has_conceal = false, false
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.virt_text then
      has_label = true
      h.assert_eq(d.virt_text[1][1], " [vault]")
      h.assert_eq(m[2], 1, "label on the key line")
    end
    if d.conceal_lines ~= nil then
      has_conceal = true
      h.assert_eq(m[2], 2, "conceal starts on the first blob line")
    end
  end
  h.assert_true(has_label, "key line has a lock label")
  h.assert_true(has_conceal, "blob lines are concealed")
  h.assert_eq(vim.b[buf].ansible_vault_conceal, true)
  h.assert_eq(vim.wo.conceallevel, 2, "conceallevel raised in the showing window")

  -- remove the block: extmarks cleared and conceallevel restored
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain: value" })
  conceal.refresh(buf)
  h.assert_eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
  h.assert_eq(vim.wo.conceallevel, 0, "conceallevel restored")

  vim.cmd.bwipeout({ bang = true })
end

function tests.conceal_disabled_is_noop()
  require("ansible-vault").setup({
    prompt = false,
    confirm_default = false,
    confirm_decrypt = false,
    conceal = { enabled = false },
  })
  local buf = edit_vault_file()

  conceal.refresh(buf)
  h.assert_eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
  h.assert_eq(vim.wo.conceallevel, 0)

  vim.cmd.bwipeout({ bang = true })
  require("ansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
end

-- atomic !vault token -------------------------------------------------------

local BLOCK = {
  "plain: value",
  "secret: !vault |",
  "  $ANSIBLE_VAULT;1.1;AES256",
  "  61626364",
  "  65666768",
  "next: visible",
  "last: x",
}

---Scratch yaml buffer with a fake (structurally valid) vault block.
---@return integer buf
local function block_buf(lines)
  require("ansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  vim.cmd.enew()
  vim.bo.filetype = "yaml"
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or BLOCK)
  -- start a fresh undo block so tests can undo exactly their own change
  vim.bo[buf].undolevels = vim.bo[buf].undolevels
  conceal.refresh(buf)
  return buf
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---Move the cursor (1-indexed row, 0-indexed col) like a user motion would.
local function move(buf, row, col)
  vim.api.nvim_win_set_cursor(0, { row, col })
  conceal.on_cursor_moved(buf)
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1], pos[2]
end

---Run a normal-mode edit and the TextChanged handling that follows it.
local function edit(buf, keys)
  vim.cmd("normal " .. keys)
  conceal.repair(buf)
  conceal.refresh(buf)
end

local function concealed(buf)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].conceal_lines ~= nil then
      return true
    end
  end
  return false
end

function tests.blob_shown_only_on_token()
  local buf = block_buf()
  move(buf, 1, 0)
  move(buf, 2, 0)
  h.assert_true(concealed(buf), "cursor on the key name keeps the blob hidden")
  move(buf, 2, 8)
  h.assert_true(not concealed(buf), "cursor on the token shows the blob")
  move(buf, 1, 0)
  h.assert_true(concealed(buf), "leaving the token hides it again")
  vim.cmd.bwipeout({ bang = true })
end

function tests.cursor_skips_blob_lines()
  local buf = block_buf()
  move(buf, 2, 0)
  h.assert_eq({ move(buf, 3, 0) }, { 6, 0 }, "j from the key line lands past the blob")
  h.assert_eq({ move(buf, 5, 0) }, { 2, 8 }, "k from below lands on the token")
  vim.cmd.bwipeout({ bang = true })
end

function tests.token_acts_as_one_character()
  local buf = block_buf()
  move(buf, 2, 0)
  h.assert_eq({ move(buf, 2, 15) }, { 2, 8 }, "$ from the key snaps to the token start")
  h.assert_eq({ move(buf, 2, 9) }, { 6, 0 }, "w/l off the token jumps past the block")
  vim.cmd.bwipeout({ bang = true })
end

function tests.breaking_token_drops_blob_and_undo_restores()
  local buf = block_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 8 })
  edit(buf, "x")
  h.assert_eq(lines_of(buf), { "plain: value", "secret:", "next: visible", "last: x" })
  vim.cmd("normal! u")
  h.assert_eq(lines_of(buf), BLOCK, "one undo restores token and blob")
  vim.cmd.bwipeout({ bang = true })
end

function tests.replacing_token_keeps_new_value()
  local buf = block_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 8 })
  edit(buf, "Cnew_value")
  h.assert_eq(lines_of(buf), { "plain: value", "secret: new_value", "next: visible", "last: x" })
  vim.cmd.bwipeout({ bang = true })
end

function tests.typing_after_token_becomes_value()
  local buf = block_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  edit(buf, "A x")
  h.assert_eq(lines_of(buf), { "plain: value", "secret: x", "next: visible", "last: x" })
  vim.cmd.bwipeout({ bang = true })
end

function tests.deleting_key_line_drops_blob()
  local buf = block_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  edit(buf, "Vd") -- not the dd mapping
  h.assert_eq(lines_of(buf), { "plain: value", "next: visible", "last: x" })
  vim.cmd.bwipeout({ bang = true })
end

function tests.dd_deletes_and_yanks_block()
  local buf = block_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  conceal.delete_lines()
  h.assert_eq(lines_of(buf), { "plain: value", "next: visible", "last: x" })
  h.assert_eq(vim.fn.getreg('"'), table.concat(vim.list_slice(BLOCK, 2, 5), "\n") .. "\n")
  vim.cmd.bwipeout({ bang = true })
end

function tests.linewise_put_moves_below_blob()
  local buf = block_buf()
  vim.fn.setreg("a", { "added: 1" }, "V")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  edit(buf, '"ap')
  local expect = vim.deepcopy(BLOCK)
  table.insert(expect, 6, "added: 1")
  h.assert_eq(lines_of(buf), expect)
  h.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 6, "cursor follows the moved line")
  vim.cmd.bwipeout({ bang = true })
end

function tests.edits_elsewhere_leave_blocks_alone()
  local buf = block_buf()
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  edit(buf, "dd")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  edit(buf, "cwpassword")
  local expect = vim.deepcopy(BLOCK)
  table.remove(expect, 6)
  expect[2] = "password: !vault |"
  h.assert_eq(lines_of(buf), expect)
  vim.cmd.bwipeout({ bang = true })
end

return tests
