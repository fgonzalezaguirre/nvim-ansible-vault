local config = require("neoansible-vault.config")
local detect = require("neoansible-vault.detect")
local password = require("neoansible-vault.password")
local h = require("helpers")

local tests = {}

local function reset()
  config.setup({ prompt = false })
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
  require("neoansible-vault").setup({ prompt = false })

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

function tests.edit_outside_block_notifies_and_does_nothing()
  reset()
  require("neoansible-vault").setup({ prompt = false })

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

function tests.hover_shows_decrypted_preview()
  reset()
  require("neoansible-vault").setup({ prompt = false })

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
  require("neoansible-vault").setup({ prompt = false })

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

function tests.encrypt_selection_multiline()
  reset()
  require("neoansible-vault").setup({ prompt = false })

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
  require("neoansible-vault").setup({ prompt = false })

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
  require("neoansible-vault").setup({ prompt = false, vault_id = "stage" })

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

return tests
