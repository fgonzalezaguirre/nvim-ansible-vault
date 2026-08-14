local config = require("neoansible-vault.config")
local password = require("neoansible-vault.password")
local h = require("helpers")

local tests = {}

local function reset()
  config.setup({ prompt = false })
  password.clear_cache()
  vim.env.ANSIBLE_VAULT_PASSWORD = nil
  vim.env.ANSIBLE_VAULT_PASSWORD_FILE = nil
end

local function current_state(buf)
  local ok, state = pcall(vim.api.nvim_buf_get_var, buf, "neoansible_vault")
  return ok and state or nil
end

---Open a file and wait for the transparent decrypt to flag the buffer.
local function edit_and_wait(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  h.assert_true(
    h.wait_for(function()
      return current_state(buf) ~= nil
    end),
    "buffer was not flagged as decrypted"
  )
  return buf
end

function tests.transparent_decrypt_on_open()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/secrets.yml"
  h.write_file(path, "db_user: admin\ndb_password: s3cr3t\n")
  h.vault_encrypt(path, passfile)

  local buf = edit_and_wait(path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  h.assert_eq(lines, { "db_user: admin", "db_password: s3cr3t" })
  h.assert_eq(vim.bo[buf].modified, false)
  h.assert_eq(vim.bo[buf].buftype, "acwrite")
  h.assert_eq(vim.bo[buf].swapfile, false)
  h.assert_eq(vim.bo[buf].filetype, "yaml", "filetype still detected from extension")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.write_reencrypts_roundtrip()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/secrets.yml"
  h.write_file(path, "key: old\n")
  h.vault_encrypt(path, passfile)

  local buf = edit_and_wait(path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "key: new", "added: true" })
  vim.cmd.write()
  h.assert_true(
    h.wait_for(function()
      return vim.bo[buf].modified == false
    end),
    "write did not complete"
  )

  -- verify externally: the file on disk must be valid vault ciphertext
  local fd = assert(io.open(path, "r"))
  h.assert_true(fd:read("*l"):match("^%$ANSIBLE_VAULT;") ~= nil, "file on disk is encrypted")
  fd:close()
  h.assert_eq(h.vault_view(path, passfile), "key: new\nadded: true\n")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.vault_id_file_roundtrip()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/prod.yml"
  h.write_file(path, "k: v\n")
  h.vault_encrypt(path, passfile, "prod")

  local buf = edit_and_wait(path)
  h.assert_eq(current_state(buf).vault_id, "prod")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "k: changed" })
  vim.cmd.write()
  h.assert_true(
    h.wait_for(function()
      return vim.bo[buf].modified == false
    end),
    "write did not complete"
  )

  local fd = assert(io.open(path, "r"))
  h.assert_eq(fd:read("*l"), "$ANSIBLE_VAULT;1.2;AES256;prod", "vault-id preserved on write")
  fd:close()
  h.assert_eq(h.vault_view(path, passfile), "k: changed\n")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.rekey_changes_password_and_preserves_vault_id()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local newfile = dir .. "/new-password"
  h.write_file(newfile, "newpass456\n")
  vim.uv.fs_chmod(newfile, 384) -- 0600
  local path = dir .. "/prod.yml"
  h.write_file(path, "k: v\n")
  h.vault_encrypt(path, passfile, "prod")

  local buf = edit_and_wait(path)
  h.assert_eq(current_state(buf).vault_id, "prod")

  -- Stub the two prompts: new password, then new vault-id (kept).
  local orig_input = vim.ui.input
  local prompts = {}
  vim.ui.input = function(opts, cb)
    table.insert(prompts, opts.prompt)
    if opts.prompt:match("^New vault password") then
      cb("newpass456")
    else
      cb("") -- keep current vault-id
    end
  end
  require("neoansible-vault").rekey_buffer()
  h.assert_true(
    h.wait_for(function()
      -- the header keeps the 1.2 label, so poll the password change itself
      local code = h.sys({ "ansible-vault", "view", "--vault-password-file", newfile, path })
      return code == 0
    end),
    "rekey did not complete"
  )
  vim.ui.input = orig_input
  h.assert_eq(#prompts, 2)

  local fd = assert(io.open(path, "r"))
  h.assert_eq(fd:read("*l"), "$ANSIBLE_VAULT;1.2;AES256;prod", "vault-id label preserved")
  fd:close()

  -- old password no longer works, new one does
  local code = h.sys({ "ansible-vault", "view", "--vault-password-file", passfile, path })
  h.assert_true(code ~= 0, "old password must fail after rekey")
  h.assert_eq(h.vault_view(path, newfile), "k: v\n")

  -- simulate the user updating their discovered password file
  h.write_passfile(dir, "newpass456")

  -- buffer is still flagged and writes with the new password
  h.assert_true(current_state(buf) ~= nil)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "k: after-rekey" })
  vim.cmd.write()
  h.assert_true(
    h.wait_for(function()
      return vim.bo[buf].modified == false
    end),
    "write after rekey did not complete"
  )
  h.assert_eq(h.vault_view(path, newfile), "k: after-rekey\n")

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.status_component()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)

  -- plain file: no label
  local plain = dir .. "/plain.yml"
  h.write_file(plain, "k: v\n")
  vim.cmd.edit(vim.fn.fnameescape(plain))
  local plain_buf = vim.api.nvim_get_current_buf()
  h.assert_eq(require("neoansible-vault").status(plain_buf), "")

  -- encrypted file with vault-id, transparently decrypted: [vault:prod]
  local prod = dir .. "/prod.yml"
  h.write_file(prod, "k: v\n")
  h.vault_encrypt(prod, passfile, "prod")
  local prod_buf = edit_and_wait(prod)
  h.assert_eq(require("neoansible-vault").status(prod_buf), "[vault:prod]")

  -- encrypted file without id, auto_decrypt off: ciphertext -> [vault]
  require("neoansible-vault").setup({ prompt = false, auto_decrypt = false })
  local enc = dir .. "/enc.yml"
  h.write_file(enc, "k: v\n")
  h.vault_encrypt(enc, passfile)
  vim.cmd.edit(vim.fn.fnameescape(enc))
  local enc_buf = vim.api.nvim_get_current_buf()
  h.assert_eq(require("neoansible-vault").status(enc_buf), "[vault]")
  -- cached value survives repeat calls
  h.assert_eq(require("neoansible-vault").status(enc_buf), "[vault]")

  vim.cmd.bwipeout({ bang = true })
  vim.cmd.bwipeout({ bang = true })
  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.non_vault_file_untouched()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  h.write_passfile(dir)
  local path = dir .. "/normal.yml"
  h.write_file(path, "just: yaml\n")

  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(300, function()
    return false
  end) -- give the autocmd a chance to (not) fire
  h.assert_eq(current_state(buf), nil)
  h.assert_eq(vim.bo[buf].buftype, "")
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "just: yaml" })

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.wrong_password_leaves_ciphertext()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir, "right-password")
  local path = dir .. "/secrets.yml"
  h.write_file(path, "k: v\n")
  h.vault_encrypt(path, passfile)
  h.write_passfile(dir, "wrong-password") -- discovery now finds the wrong one

  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(2000, function()
    return current_state(buf) ~= nil
  end)
  h.assert_eq(current_state(buf), nil, "buffer must not be flagged on decrypt failure")
  h.assert_true(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT;") ~= nil)

  vim.cmd.bwipeout({ bang = true })
  reset()
end

function tests.explicit_decrypt_and_encrypt_buffer()
  reset()
  require("neoansible-vault").setup({ prompt = false })

  local dir = h.tmpdir()
  local passfile = h.write_passfile(dir)
  local path = dir .. "/manual.yml"
  h.write_file(path, "m: 1\n")
  h.vault_encrypt(path, passfile)

  -- read the ciphertext into a plain scratch buffer (bypasses BufReadPost)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, path)
  local ciphertext = {}
  for line in io.lines(path) do
    table.insert(ciphertext, line)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, ciphertext)

  require("neoansible-vault").decrypt_buffer()
  h.assert_true(
    h.wait_for(function()
      return current_state(buf) ~= nil
    end),
    "explicit decrypt did not flag buffer"
  )
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "m: 1" })

  require("neoansible-vault").encrypt_buffer()
  h.assert_true(
    h.wait_for(function()
      return current_state(buf) == nil and vim.bo[buf].buftype == ""
    end),
    "explicit encrypt did not reset buffer state"
  )
  h.assert_true(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT;") ~= nil)

  vim.cmd.bwipeout({ bang = true })
  reset()
end

return tests
