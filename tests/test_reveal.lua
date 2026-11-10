local detect = require("ansible-vault.detect")
local h = require("helpers")

local tests = {}

---Edit a yaml file with two inline vault blocks; returns buf, dir, passfile.
local function edit_secrets_file()
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block1 = h.vault_encrypt_string("s3cr3t", "db_password", passfile)
  local block2 = h.vault_encrypt_string("t0k3n", "api_token", passfile)
  local lines = { "app: demo" }
  vim.list_extend(lines, vim.split(block1, "\n", { plain = true }))
  table.insert(lines, "other: value")
  vim.list_extend(lines, vim.split(block2, "\n", { plain = true }))
  table.insert(lines, "after: done")
  local path = dir .. "/vars.yml"
  h.write_file(path, table.concat(lines, "\n") .. "\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), dir, passfile
end

---@param buf integer
---@return string[]
local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param lines string[]
---@return boolean
local function has_ciphertext(lines)
  for _, l in ipairs(lines) do
    if l:match("%$ANSIBLE_VAULT;") then
      return true
    end
  end
  return false
end

---Decrypt the inline block for `key` found in `lines` with the CLI.
---@return string plaintext
local function decrypt_block(lines, key, passfile, dir, name)
  local regions = detect.find_inline_regions(lines)
  local region = vim.tbl_filter(function(r)
    return r.key == key
  end, regions)[1]
  h.assert_true(region ~= nil, "block for " .. key .. " exists in " .. name)
  local blob_path = dir .. "/" .. key .. ".blob"
  h.write_file(blob_path, detect.region_blob_text(region))
  local code, out, err =
    h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
  h.assert_eq(code, 0, err)
  return out
end

function tests.reveal_shows_plaintext_and_write_reencrypts()
  require("ansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local buf, dir, passfile = edit_secrets_file()

  require("ansible-vault").toggle_reveal()
  h.assert_true(
    h.wait_for(function()
      return vim.b[buf].ansible_vault_reveal ~= nil
    end),
    "reveal did not engage"
  )

  local lines = buf_lines(buf)
  h.assert_true(not has_ciphertext(lines), "no ciphertext left in buffer")
  h.assert_true(vim.tbl_contains(lines, "db_password: s3cr3t"), "first secret revealed")
  h.assert_true(vim.tbl_contains(lines, "api_token: t0k3n"), "second secret revealed")
  h.assert_eq(lines[1], "app: demo", "surrounding lines untouched")
  h.assert_eq(lines[#lines], "after: done")
  h.assert_eq(vim.bo[buf].buftype, "acwrite")

  -- edit one secret and write: disk gets ciphertext, buffer keeps plaintext
  local row = vim.tbl_contains(lines, "db_password: s3cr3t") and vim.fn.index(lines, "db_password: s3cr3t") + 1 or nil
  h.assert_true(row ~= nil)
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { "db_password: n3w-s3cr3t" })
  vim.cmd.write()
  h.assert_true(
    h.wait_for(function()
      return vim.bo[buf].modified == false
    end),
    "write did not complete"
  )

  local fd = assert(io.open(vim.api.nvim_buf_get_name(buf), "r"))
  local disk = vim.split(fd:read("*a"), "\n", { plain = true })
  fd:close()
  h.assert_true(has_ciphertext(disk), "disk holds ciphertext")
  h.assert_eq(decrypt_block(disk, "db_password", passfile, dir, "disk"), "n3w-s3cr3t")
  h.assert_eq(decrypt_block(disk, "api_token", passfile, dir, "disk"), "t0k3n")
  h.assert_true(vim.tbl_contains(disk, "app: demo"), "yaml structure preserved on disk")

  -- buffer still shows plaintext after the write
  h.assert_true(vim.tbl_contains(buf_lines(buf), "db_password: n3w-s3cr3t"))
  h.assert_true(not has_ciphertext(buf_lines(buf)))

  -- toggle off: blocks re-encrypted in the buffer
  require("ansible-vault").toggle_reveal()
  h.assert_true(
    h.wait_for(function()
      return has_ciphertext(buf_lines(buf))
    end),
    "unreveal did not re-encrypt the buffer"
  )
  h.assert_eq(vim.b[buf].ansible_vault_reveal, nil)
  h.assert_eq(vim.bo[buf].buftype, "")
  h.assert_eq(decrypt_block(buf_lines(buf), "db_password", passfile, dir, "buffer"), "n3w-s3cr3t")

  vim.cmd.bwipeout({ bang = true })
end

function tests.reveal_multiline_roundtrip()
  require("ansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block = h.vault_encrypt_string("line one\nline two", "cert", passfile)
  local path = dir .. "/vars.yml"
  h.write_file(path, block)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  require("ansible-vault").toggle_reveal()
  h.assert_true(
    h.wait_for(function()
      return vim.b[buf].ansible_vault_reveal ~= nil
    end),
    "reveal did not engage"
  )

  h.assert_eq(buf_lines(buf), { "cert: |-", "  line one", "  line two" }, "multi-line value as literal block")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "cert: |-", "  line one", "  line 2 changed", "  line three" })
  vim.cmd.write()
  h.assert_true(
    h.wait_for(function()
      return vim.bo[buf].modified == false
    end),
    "write did not complete"
  )

  local fd = assert(io.open(path, "r"))
  local disk = vim.split(fd:read("*a"), "\n", { plain = true })
  fd:close()
  h.assert_eq(decrypt_block(disk, "cert", passfile, dir, "disk"), "line one\nline 2 changed\nline three")

  vim.cmd.bwipeout({ bang = true })
end

function tests.reveal_without_secrets_notifies()
  require("ansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  local dir = h.tmpdir()
  local path = dir .. "/plain.yml"
  h.write_file(path, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  require("ansible-vault").toggle_reveal()
  vim.wait(300, function()
    return false
  end)
  h.assert_eq(vim.b[buf].ansible_vault_reveal, nil, "no state for a plain buffer")
  h.assert_eq(vim.bo[buf].buftype, "")

  vim.cmd.bwipeout({ bang = true })
end

return tests
