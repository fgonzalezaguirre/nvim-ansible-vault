---Dependency-free test runner: nvim --headless -l tests/run.lua
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = package.path .. ";" .. root .. "/tests/?.lua"

vim.cmd("filetype on")

-- Install the plugin like a user would (commands + auto setup).
vim.cmd.runtime("plugin/neoansible-vault.lua")

local files = vim.fn.glob(root .. "/tests/test_*.lua", false, true)
table.sort(files)

local passed, failed = 0, 0
local failures = {}

for _, file in ipairs(files) do
  local suite_name = vim.fn.fnamemodify(file, ":t:r")
  local ok, suite = pcall(dofile, file)
  if not ok then
    failed = failed + 1
    table.insert(failures, ("%-24s LOAD ERROR: %s"):format(suite_name, suite))
    goto continue
  end

  local names = vim.tbl_keys(suite)
  table.sort(names)
  for _, name in ipairs(names) do
    local test_ok, err = pcall(suite[name])
    if test_ok then
      passed = passed + 1
      print(("PASS %s.%s"):format(suite_name, name))
    else
      failed = failed + 1
      table.insert(failures, ("FAIL %s.%s\n     %s"):format(suite_name, name, tostring(err):gsub("\n", "\n     ")))
      print(("FAIL %s.%s"):format(suite_name, name))
    end
  end

  ::continue::
end

print("")
for _, failure in ipairs(failures) do
  print(failure)
end
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
