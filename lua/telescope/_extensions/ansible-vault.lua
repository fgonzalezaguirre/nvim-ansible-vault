---Telescope extension: `:Telescope ansible-vault secrets|files`.
return require("telescope").register_extension({
  exports = {
    secrets = function()
      require("ansible-vault.picker").pick({ backend = "telescope" })
    end,
    files = function()
      require("ansible-vault.picker").pick_file({ backend = "telescope" })
    end,
  },
})
