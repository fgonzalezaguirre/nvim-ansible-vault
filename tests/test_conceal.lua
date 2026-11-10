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

return tests
