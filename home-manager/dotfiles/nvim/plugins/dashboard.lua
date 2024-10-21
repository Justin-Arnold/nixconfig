return {
  -- Add dashboard.nvim
  {
    'nvimdev/dashboard-nvim',
    event = 'VimEnter',
    config = function()
      require('dashboard').setup {
        shuffle_letter = false,
        config = {
	  week_header = {
	    enable = true
	  },
	  shortcut = {
            { desc = '󰊳 Update', group = '@property', action = 'Lazy update', key = 'u' },
            {
              icon = ' ',
              icon_hl = '@variable',
              desc = 'Files',
              group = 'Label',
              action = 'Telescope find_files',
              key = 'f',
            },
          },
	  footer = {
	    '',
	    '',
	    '',
	    'Coding Like Poetry'
	  },
	}
      }
    end,
    dependencies = { {'nvim-tree/nvim-web-devicons'}}
  }
}
