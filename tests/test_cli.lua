local cli = require("neoansible-vault.cli")
local h = require("helpers")

local tests = {}

---Call an async cli function and wait for the result.
local function await(fn, ...)
  local n = select("#", ...)
  local call = { ... }
  local result = {}
  local done = false
  call[n + 1] = function(err, out)
    result.err = err
    result.out = out
    done = true
  end
  fn(unpack(call, 1, n + 1))
  h.assert_true(h.wait_for(function()
    return done
  end), "async cli call timed out")
  return result.err, result.out
end

function tests.executable()
  h.assert_true(cli.executable(), "ansible-vault must be on PATH for these tests")
end

function tests.encrypt_string_decrypt_blob_roundtrip()
  local dir = h.tmpdir()
  local cred = h.cred(dir)

  local err, block = await(cli.encrypt_string, "topsecret", "my_key", cred, nil)
  h.assert_eq(err, nil)
  h.assert_true(block:match("^my_key: !vault |") ~= nil, "block has key tag")

  -- strip the 10-space indent encrypt_string emits
  local blob_lines = {}
  for line in block:gmatch("[^\n]+") do
    table.insert(blob_lines, (line:gsub("^%s*", "")))
  end
  table.remove(blob_lines, 1) -- drop the key line
  local blob = table.concat(blob_lines, "\n") .. "\n"

  local derr, plaintext = await(cli.decrypt_blob, blob, cred)
  h.assert_eq(derr, nil)
  h.assert_eq(plaintext, "topsecret")
end

function tests.view_and_encrypt_file_roundtrip()
  local dir = h.tmpdir()
  local cred = h.cred(dir)
  local src = dir .. "/plain.yml"
  local enc = dir .. "/enc.yml"
  h.write_file(src, "alpha: 1\nbeta: two\n")

  local err = await(cli.encrypt_file, src, enc, cred, nil)
  h.assert_eq(err, nil)

  local fd = assert(io.open(enc, "r"))
  h.assert_true(fd:read("*l"):match("^%$ANSIBLE_VAULT;") ~= nil, "output is vault encrypted")
  fd:close()

  local verr, out = await(cli.view, enc, cred)
  h.assert_eq(verr, nil)
  h.assert_eq(out, "alpha: 1\nbeta: two\n")
end

function tests.vault_id_is_preserved()
  local dir = h.tmpdir()
  local cred = h.cred(dir)
  local src = dir .. "/plain.yml"
  local enc = dir .. "/enc.yml"
  h.write_file(src, "k: v\n")

  local err = await(cli.encrypt_file, src, enc, cred, "prod")
  h.assert_eq(err, nil)
  local fd = assert(io.open(enc, "r"))
  h.assert_eq(fd:read("*l"), "$ANSIBLE_VAULT;1.2;AES256;prod")
  fd:close()

  -- decryption works with a plain password file regardless of the id label
  local verr, out = await(cli.view, enc, cred)
  h.assert_eq(verr, nil)
  h.assert_eq(out, "k: v\n")
end

function tests.wrong_password_reports_error()
  local dir = h.tmpdir()
  local cred = h.cred(dir)
  local src = dir .. "/plain.yml"
  local enc = dir .. "/enc.yml"
  h.write_file(src, "k: v\n")
  h.assert_eq(await(cli.encrypt_file, src, enc, cred, nil), nil)

  local bad = { kind = "secret", value = "definitely-wrong", source = "test" }
  local err, out = await(cli.view, enc, bad)
  h.assert_true(err ~= nil, "wrong password must produce an error")
  h.assert_eq(out, nil)
end

function tests.secret_credential_uses_tempfile()
  local dir = h.tmpdir()
  local src = dir .. "/plain.yml"
  local enc = dir .. "/enc.yml"
  h.write_file(src, "k: v\n")

  local secret_cred = { kind = "secret", value = h.PASSWORD, source = "test" }
  local err = await(cli.encrypt_file, src, enc, secret_cred, nil)
  h.assert_eq(err, nil)
  local verr, out = await(cli.view, enc, secret_cred)
  h.assert_eq(verr, nil)
  h.assert_eq(out, "k: v\n")
end

return tests
