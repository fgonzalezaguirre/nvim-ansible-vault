local config = require("neoansible-vault.config")
local detect = require("neoansible-vault.detect")
local password = require("neoansible-vault.password")
local h = require("helpers")

local tests = {}

local function reset()
  config.setup({ prompt = false, confirm_default = false, confirm_decrypt = false })
  password.clear_cache()
  vim.env.ANSIBLE_VAULT_PASSWORD = nil
  vim.env.ANSIBLE_VAULT_PASSWORD_FILE = nil
end

---Build a yaml buffer containing one inline vault block; returns buf, dir.
local function make_yaml_buffer(plaintext)
  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local block = h.vault_encrypt_string(plaintext, "db_password", passfile)
  local lines = { "plain: value" }
  for line in block:gmatch("[^\n]+") do
    table.insert(lines, line)
  end
  table.insert(lines, "after: done")

  local path = dir .. "/vars.yml"
  h.write_file(path, table.concat(lines, "\n") .. "\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), dir, passfile
end

function tests.edit_decrypts_into_float_and_reencrypts_on_save()
  reset()
  require("neoansible-vault").setup({
    prompt = false,
    confirm_default = false,
    confirm_decrypt = false,
    inline = { editor = "float" },
  })

  local buf, dir, passfile = make_yaml_buffer("original-secret")
  vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- inside the blob

  require("neoansible-vault").edit_inline()
  local win, fbuf = nil, nil
  h.assert_true(
    h.wait_for(function()
      win, fbuf = h.find_win("ansible%-vault://db_password")
      return win ~= nil
    end),
    "float did not open"
  )
  h.assert_eq(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), { "original-secret" })

  -- the float is never cramped: wide enough for the footer, a few lines tall
  h.assert_true(vim.api.nvim_win_get_width(win) >= 44, "float has a sensible minimum width")
  h.assert_true(vim.api.nvim_win_get_height(win) >= 3, "float has a sensible minimum height")

  -- edit the secret and save via :w (BufWriteCmd on the float)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "updated-secret" })
  vim.api.nvim_set_current_win(win)
  vim.cmd.write()
  h.assert_true(
    h.wait_for(function()
      return not vim.api.nvim_win_is_valid(win)
    end),
    "float did not close after save"
  )

  -- source buffer must now contain a fresh !vault block that decrypts to the new value
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local region = detect.inline_region_at(lines, 1)
  h.assert_true(region ~= nil, "vault block still present")
  h.assert_eq(lines[1], "plain: value", "line before block untouched")
  h.assert_eq(lines[2], "db_password: !vault |", "key line keeps its indent")
  h.assert_eq(lines[#lines], "after: done", "surrounding content untouched")

  local blob_path = dir .. "/blob.txt"
  h.write_file(blob_path, detect.region_blob_text(region))
  local code, out = h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
  h.assert_eq(code, 0)
  h.assert_eq(out, "updated-secret")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.edit_single_line_uses_input_dialog()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf, dir, passfile = make_yaml_buffer("original-secret")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local seen_default = nil
  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    seen_default = opts.default
    cb("updated-secret")
  end
  require("neoansible-vault").edit_inline()
  h.assert_true(
    h.wait_for(function()
      return seen_default ~= nil
    end),
    "input dialog was not shown"
  )
  vim.ui.input = orig_input

  h.assert_eq(seen_default, "original-secret", "input dialog pre-filled with the current value")
  h.assert_eq(h.find_win("ansible%-vault://"), nil, "no float opened for a single-line value")

  -- wait for the async re-encryption to land in the buffer
  local blob_path = dir .. "/blob.txt"
  local out = nil
  h.assert_true(
    h.wait_for(function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local region = detect.inline_region_at(lines, 1)
      if not region then
        return false
      end
      h.write_file(blob_path, detect.region_blob_text(region))
      local code
      code, out = h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
      return code == 0 and out == "updated-secret"
    end),
    "block was not re-encrypted with the new value"
  )

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.edit_multiline_falls_back_to_float()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf = make_yaml_buffer("line one\nline two")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local input_called = false
  local orig_input = vim.ui.input
  vim.ui.input = function(_, cb)
    input_called = true
    cb(nil)
  end
  require("neoansible-vault").edit_inline()
  local win = nil
  h.assert_true(
    h.wait_for(function()
      win = h.find_win("ansible%-vault://db_password")
      return win ~= nil
    end),
    "float did not open for a multi-line value"
  )
  vim.ui.input = orig_input
  h.assert_true(not input_called, "input dialog not used for multi-line values")

  pcall(vim.api.nvim_win_close, win, true)
  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.edit_outside_block_notifies_and_does_nothing()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf = make_yaml_buffer("x")
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "plain: value"
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  require("neoansible-vault").edit_inline()
  vim.wait(300, function()
    return false
  end)
  h.assert_eq(h.find_win("ansible%-vault://"), nil, "no float opened")
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "buffer unchanged")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.decrypt_value_replaces_block_with_plaintext()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf = make_yaml_buffer("s3cr3t")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  require("neoansible-vault").decrypt_inline()
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "db_password: s3cr3t"
    end),
    "block was not decrypted in place"
  )

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  h.assert_eq(lines, { "plain: value", "db_password: s3cr3t", "after: done" }, "block replaced by plaintext")

  -- nothing flagged for re-encryption: :w writes plaintext as-is
  vim.cmd.write()
  local fd = assert(io.open(vim.api.nvim_buf_get_name(buf), "r"))
  local disk = fd:read("*a")
  fd:close()
  h.assert_true(disk:match("db_password: s3cr3t") ~= nil, "plaintext written to disk")
  h.assert_true(not disk:match("%$ANSIBLE_VAULT;"), "no ciphertext on disk")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.decrypt_value_outside_block_notifies()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf = make_yaml_buffer("x")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  require("neoansible-vault").decrypt_inline()
  vim.wait(300, function()
    return false
  end)
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "buffer unchanged")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.hover_shows_decrypted_preview()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf = make_yaml_buffer("hover-secret")
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- on the `db_password: !vault |` line

  local inline = require("neoansible-vault.inline")
  h.assert_true(inline.hover(), "hover on a vault block is handled")

  -- open_floating_preview opens an unnamed float containing the plaintext
  local fwin = nil
  h.assert_true(
    h.wait_for(function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= "" then
          local wbuf = vim.api.nvim_win_get_buf(win)
          if (vim.api.nvim_buf_get_lines(wbuf, 0, 1, false)[1] or ""):match("hover%-secret") then
            fwin = win
            return true
          end
        end
      end
      return false
    end),
    "hover float did not show the decrypted value"
  )
  pcall(vim.api.nvim_win_close, fwin, true)

  -- outside a block: not handled, no float
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  h.assert_true(not inline.hover(), "hover outside a block falls through")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.encrypt_selection_single_key_line()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/vars.yml"
  h.write_file(path, "api_token: abc123\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    cb(opts.default) -- accept the parsed key name
  end
  require("neoansible-vault").encrypt_selection(1, 1)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("!vault") ~= nil
    end),
    "selection was not encrypted"
  )
  vim.ui.input = orig_input

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  h.assert_eq(lines[1], "api_token: !vault |", "parsed key name used")
  local region = detect.inline_region_at(lines, 0)
  h.assert_true(region ~= nil)

  local blob_path = dir .. "/blob.txt"
  h.write_file(blob_path, detect.region_blob_text(region))
  local code, out = h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
  h.assert_eq(code, 0)
  h.assert_eq(out, "abc123", "only the value was encrypted")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.parse_scalar_reads_what_yaml_reads()
  local inline = require("neoansible-vault.inline")
  local cases = {
    { "abc123", "abc123", nil },
    { "abc123   # the token", "abc123", "the token" },
    { '"123456:quoted"', "123456:quoted", nil },
    { '"123456:quoted"   # from BotFather', "123456:quoted", "from BotFather" },
    { [["say \"hi\" # not a comment"]], 'say "hi" # not a comment', nil },
    { "'it''s # fine'", "it's # fine", nil },
    { "pass#word", "pass#word", nil },
    { '"unterminated', '"unterminated', nil },
    { '"a" b', '"a" b', nil },
  }
  for _, case in ipairs(cases) do
    local value, comment = inline.parse_scalar(case[1])
    h.assert_eq(value, case[2], "value of " .. case[1])
    h.assert_eq(comment, case[3], "comment of " .. case[1])
  end
end

function tests.encrypt_selection_strips_quotes_and_keeps_the_comment()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/vars.yml"
  h.write_file(path, 'channel:\n  token: "123456:quoted-token"   # from BotFather\n')
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    cb(opts.default)
  end
  require("neoansible-vault").encrypt_selection(2, 2)
  h.assert_true(
    h.wait_for(function()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("!vault") ~= nil
    end),
    "selection was not encrypted"
  )
  vim.ui.input = orig_input

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  h.assert_eq(lines[2], "  # from BotFather", "comment kept on its own line")
  h.assert_eq(lines[3], "  token: !vault |")
  local region = detect.inline_region_at(lines, 2)
  h.assert_true(region ~= nil)

  local blob_path = dir .. "/blob.txt"
  h.write_file(blob_path, detect.region_blob_text(region))
  local code, out = h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
  h.assert_eq(code, 0)
  h.assert_eq(out, "123456:quoted-token", "quotes and comment are not part of the secret")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.encrypt_selection_multiline()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/vars.yml"
  h.write_file(path, "line one\nline two\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  local orig_input = vim.ui.input
  vim.ui.input = function(_, cb)
    cb("cert")
  end
  require("neoansible-vault").encrypt_selection(1, 2)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("cert: !vault") ~= nil
    end),
    "selection was not encrypted"
  )
  vim.ui.input = orig_input

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local region = detect.inline_region_at(lines, 0)
  h.assert_true(region ~= nil)
  local blob_path = dir .. "/blob.txt"
  h.write_file(blob_path, detect.region_blob_text(region))
  local code, out = h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
  h.assert_eq(code, 0)
  h.assert_eq(out, "line one\nline two")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.encrypt_selection_with_vault_id()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/vars.yml"
  h.write_file(path, "api_token: abc123\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    cb(opts.default)
  end
  require("neoansible-vault").encrypt_selection(1, 1, "prod")
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("!vault") ~= nil
    end),
    "selection was not encrypted"
  )
  vim.ui.input = orig_input

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local region = detect.inline_region_at(lines, 0)
  h.assert_true(region ~= nil)
  h.assert_true(region.blob_lines[1]:match("%$ANSIBLE_VAULT;1%.2;AES256;prod") ~= nil, "vault-id label applied")

  local blob_path = dir .. "/blob.txt"
  h.write_file(blob_path, detect.region_blob_text(region))
  local code, out = h.sys({ "ansible-vault", "decrypt", "--vault-id", "prod@" .. passfile, "--output", "-", blob_path })
  h.assert_eq(code, 0)
  h.assert_eq(out, "abc123")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.encrypt_selection_uses_config_vault_id()
  reset()
  require("neoansible-vault").setup({
    prompt = false,
    confirm_default = false,
    confirm_decrypt = false,
    vault_id = "stage",
  })

  local dir = h.tmpdir()
  h.write_passfile(dir)
  local path = dir .. "/vars.yml"
  h.write_file(path, "api_token: abc123\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    cb(opts.default)
  end
  require("neoansible-vault").encrypt_selection(1, 1)
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("!vault") ~= nil
    end),
    "selection was not encrypted"
  )
  vim.ui.input = orig_input

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local region = detect.inline_region_at(lines, 0)
  h.assert_true(region ~= nil)
  h.assert_true(region.blob_lines[1]:match("%$ANSIBLE_VAULT;1%.2;AES256;stage") ~= nil, "config vault_id applied")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.rekey_secret_under_cursor()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf, dir = make_yaml_buffer("old-secret")

  local inputs = {}
  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    table.insert(inputs, opts.prompt)
    if opts.secret then
      cb("brand-new-pass")
    else
      cb("") -- keep the vault-id (none)
    end
  end

  vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- inside the blob
  require("neoansible-vault.inline").rekey()
  h.assert_true(
    h.wait_for(function()
      return #inputs >= 2
    end),
    "rekey prompts did not run"
  )
  h.assert_true(
    h.wait_for(function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return require("neoansible-vault.detect").inline_region_at(lines, 1) ~= nil and vim.bo[buf].modified
    end),
    "block was not replaced"
  )
  vim.ui.input = orig_input

  h.assert_eq(inputs[1], "New vault password: ")
  h.assert_eq(inputs[2], "New vault-id (empty = keep none): ")

  -- decrypts with the NEW password, not the old one
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local region = require("neoansible-vault.detect").inline_region_at(lines, 1)
  local blob_path = dir .. "/blob.txt"
  h.write_file(blob_path, require("neoansible-vault.detect").region_blob_text(region))

  h.write_file(dir .. "/new.pass", "brand-new-pass\n")
  vim.uv.fs_chmod(dir .. "/new.pass", 384)
  local code, out =
    h.sys({ "ansible-vault", "decrypt", "--vault-password-file", dir .. "/new.pass", "--output", "-", blob_path })
  h.assert_eq(code, 0)
  h.assert_eq(out, "old-secret")

  local passfile = dir .. "/.vault-password"
  local bad_code = h.sys({ "ansible-vault", "decrypt", "--vault-password-file", passfile, "--output", "-", blob_path })
  h.assert_true(bad_code ~= 0, "old password no longer works")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.rekey_secret_with_new_vault_id()
  reset()
  require("neoansible-vault").setup({ prompt = false, confirm_default = false, confirm_decrypt = false })

  local buf, _ = make_yaml_buffer("x")
  local orig_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    cb(opts.secret and "new-pass" or "prod")
  end
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  require("neoansible-vault.inline").rekey()
  h.assert_true(
    h.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:match("AES256;prod") ~= nil
    end),
    "new vault-id label not applied"
  )
  vim.ui.input = orig_input

  vim.cmd.bwipeout({ bang = true })
  reset()
end

return tests
