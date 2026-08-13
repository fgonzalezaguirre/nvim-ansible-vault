---Shared test helpers. Runs inside `nvim --headless -l tests/run.lua`.
local M = {}

M.PASSWORD = "testpass123"

---Repository root (parent of the tests directory).
M.root = (function()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(source))
end)()

---Create a unique temp directory.
---@return string
function M.tmpdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param path string
---@param content string
function M.write_file(path, content)
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

---Write a vault password file (0600) into `dir`.
---@param dir string
---@param password string|nil defaults to M.PASSWORD
---@return string path
function M.write_passfile(dir, password)
  local path = dir .. "/.vault-password"
  M.write_file(path, (password or M.PASSWORD) .. "\n")
  vim.uv.fs_chmod(path, 384) -- 0600
  return path
end

---@return neoansible-vault.Credential
function M.cred(dir)
  return { kind = "file", value = M.write_passfile(dir), source = "test" }
end

---Run a command synchronously.
---@param args string[]
---@param stdin string|nil
---@return integer code, string stdout, string stderr
function M.sys(args, stdin)
  local res = vim.system(args, { text = true, stdin = stdin }):wait(15000)
  return res.code, res.stdout or "", res.stderr or ""
end

---Encrypt a file in place with ansible-vault.
---@param path string
---@param passfile string
---@param vault_id string|nil
function M.vault_encrypt(path, passfile, vault_id)
  local args = { "ansible-vault", "encrypt" }
  if vault_id then
    vim.list_extend(args, { "--vault-id", vault_id .. "@" .. passfile })
  else
    vim.list_extend(args, { "--vault-password-file", passfile })
  end
  table.insert(args, path)
  local code, _, err = M.sys(args)
  assert(code == 0, "vault encrypt failed: " .. err)
end

---View a vault file.
---@param path string
---@param passfile string
---@return string plaintext
function M.vault_view(path, passfile)
  local code, out, err = M.sys({ "ansible-vault", "view", "--vault-password-file", passfile, path })
  assert(code == 0, "vault view failed: " .. err)
  return out
end

---Produce a `key: !vault |` block.
---@param plaintext string
---@param key string
---@param passfile string
---@return string block
function M.vault_encrypt_string(plaintext, key, passfile)
  local code, out, err =
    M.sys({ "ansible-vault", "encrypt_string", "--vault-password-file", passfile, "--stdin-name", key }, plaintext)
  assert(code == 0, "vault encrypt_string failed: " .. err)
  return out
end

---Poll `cond` until it returns true or the timeout expires.
---@param cond fun(): boolean
---@param timeout integer|nil ms
---@return boolean
function M.wait_for(cond, timeout)
  return vim.wait(timeout or 10000, cond, 50)
end

---Find a window displaying a buffer whose name matches `pat`.
---@param pat string lua pattern
---@return integer|nil win, integer|nil buf
function M.find_win(pat)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf):match(pat) then
      return win, buf
    end
  end
  return nil, nil
end

function M.assert_eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      ("%s\n  expected: %s\n  actual:   %s"):format(msg or "values differ", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function M.assert_true(value, msg)
  if not value then
    error(msg or "expected truthy value", 2)
  end
end

return M
