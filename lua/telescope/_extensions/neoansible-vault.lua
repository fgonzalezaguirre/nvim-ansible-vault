---Telescope extension: `:Telescope neoansible-vault secrets|files`.
return require("telescope").register_extension({
  exports = {
    secrets = function()
      require("neoansible-vault.picker").pick({ backend = "telescope" })
    end,
    files = function()
      require("neoansible-vault.picker").pick_file({ backend = "telescope" })
    end,
  },
})
