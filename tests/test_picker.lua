local picker = require("neoansible-vault.picker")
local h = require("helpers")

local tests = {}

---@param lines string[]
---@return integer buf
local function yaml_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

function tests.collect_finds_secrets_with_line_numbers()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block = h.vault_encrypt_string("s3cr3t", "db_password", passfile)
  local lines = vim.list_extend({ "plain: value" }, vim.split(block, "\n", { plain = true }))
  local buf = yaml_buf(lines)

  local entries = picker.collect(buf)
  h.assert_eq(#entries, 1)
  h.assert_eq(entries[1].key, "db_password")
  h.assert_eq(entries[1].lnum, 2, "1-indexed line of the key line")
  h.assert_eq(entries[1].vault_id, nil)
  h.assert_true(entries[1].text:match("db_password") ~= nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end

function tests.collect_reports_vault_id()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local code, out, err = h.sys({
    "ansible-vault",
    "encrypt_string",
    "--vault-id",
    "prod@" .. passfile,
    "--stdin-name",
    "api_token",
  }, "s3cr3t")
  assert(code == 0, "encrypt_string failed: " .. err)
  local buf = yaml_buf(vim.split(out, "\n", { plain = true }))
  local entries = picker.collect(buf)
  h.assert_eq(#entries, 1)
  h.assert_eq(entries[1].vault_id, "prod")
  h.assert_true(entries[1].text:match("%[prod%]") ~= nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end

function tests.collect_empty_buffer()
  local buf = yaml_buf({ "plain: value", "nothing: here" })
  h.assert_eq(#picker.collect(buf), 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

function tests.snacks_items_have_file_and_pos_for_preview()
  local entries = { { key = "db_password", lnum = 5, vault_id = "prod", text = "db_password (line 5) [prod]" } }
  local items = picker._snacks_items(entries, "/tmp/vars.yml")
  h.assert_eq(#items, 1)
  h.assert_eq(items[1].text, entries[1].text)
  h.assert_eq(items[1].entry, entries[1])
  h.assert_eq(items[1].file, "/tmp/vars.yml", "file set: snacks preview needs it")
  h.assert_eq(items[1].pos, { 5, 0 }, "pos points at the secret line")
end

function tests.telescope_entry_has_filename_for_preview()
  local e = { key = "db_password", lnum = 5, vault_id = nil, text = "db_password (line 5)" }
  local entry = picker._telescope_entry(e, "/tmp/vars.yml")
  h.assert_eq(entry.value, e)
  h.assert_eq(entry.display, e.text)
  h.assert_eq(entry.ordinal, "db_password")
  h.assert_eq(entry.filename, "/tmp/vars.yml", "filename set: telescope preview needs it")
  h.assert_eq(entry.lnum, 5)
end

function tests.pick_falls_back_to_vim_ui_select()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block = h.vault_encrypt_string("s3cr3t", "db_password", passfile)
  local path = dir .. "/secrets.yml"
  h.write_file(path, table.concat(vim.split(block, "\n", { plain = true }), "\n"))
  vim.cmd.edit(vim.fn.fnameescape(path))

  -- Force the vim.ui.select backend and capture the offered items.
  require("neoansible-vault.config").get().picker.backend = "select"
  local offered = nil
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    offered = items
    cb(nil) -- cancel: do not open the edit float
  end
  picker.pick()
  vim.ui.select = orig_select
  require("neoansible-vault.config").get().picker.backend = "auto"

  h.assert_eq(#offered, 1)
  h.assert_eq(offered[1].key, "db_password")
  vim.cmd.bwipeout({ bang = true })
end

return tests
