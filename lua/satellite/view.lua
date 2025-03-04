local fn, api = vim.fn, vim.api

local util = require("satellite.util")
local async = require("satellite.async")
local Handlers = require("satellite.handlers")

local user_config = require("satellite.config").user_config

local ns = api.nvim_create_namespace("satellite")

local M = {}

local enabled = false
local winids = {}

local function create_view(cfg)
	local bufnr = api.nvim_create_buf(false, true)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].bufhidden = "delete"
	vim.bo[bufnr].buflisted = false

	local winid = api.nvim_open_win(bufnr, false, cfg)

	-- It's not sufficient to just specify Normal highlighting. With just that, a
	-- color scheme's specification of EndOfBuffer would be used to color the
	-- bottom of the scrollbar.
	util.set_window_option(winid, "winhighlight", "Normal:Normal")
	util.set_window_option(winid, "winblend", user_config.winblend)
	util.set_window_option(winid, "foldcolumn", "0")
	util.set_window_option(winid, "wrap", false)

	return bufnr, winid
end

---@param winid integer
---@param bbufnr integer
---@param row integer
---@param height integer
local function render_scrollbar(winid, bbufnr, row, height)
	local winheight = api.nvim_win_get_height(winid)

	local lines = {}
	for i = 1, winheight do
		lines[i] = " "
	end

	vim.bo[bbufnr].modifiable = true
	api.nvim_buf_set_lines(bbufnr, 0, -1, true, lines)
	vim.bo[bbufnr].modifiable = false

	for i = row, row + height do
		pcall(api.nvim_buf_set_extmark, bbufnr, ns, i, 0, {
			virt_text = { { " ", "ScrollView" } },
			virt_text_pos = "overlay",
			priority = 1,
		})
	end
end

---@param bufnr integer
---@param winid integer
---@param bbufnr integer
---@param handler Handler
local function render_handler(bufnr, winid, bbufnr, handler)
	local name = handler.name

	if not handler:enabled() then
		return
	end

	local handler_config = user_config.handlers[name] or {}

	for _, m in ipairs(handler.update(bufnr, winid)) do
		local pos, symbol = m.pos, m.symbol

		local opts = {
			id = not m.unique and pos + 1 or nil,
			priority = handler_config.priority,
		}

		if handler_config.overlap ~= false then
			opts.virt_text = { { symbol, m.highlight } }
			opts.virt_text_pos = "overlay"
			opts.hl_mode = "combine"
		else
			-- Signs are 2 chars so fill the first char with whitespace
			opts.sign_text = " " .. symbol
			opts.sign_hl_group = m.highlight
		end

		local ok, err = pcall(api.nvim_buf_set_extmark, bbufnr, handler.ns, pos, 0, opts)
		if not ok then
			print(string.format("%s ROW: %d", handler.name, pos))
			print(err)
		end
	end
end

---@param winid integer
---@param bar_winid integer
local function reposition_bar(winid, bar_winid, toprow)
	local winwidth = api.nvim_win_get_width(winid)
	local wininfo = vim.fn.getwininfo(bar_winid)[1]
	local signwidth = wininfo.textoff

	local cfg = {
		relative = "win",
		win = winid,
		row = 0,
		col = winwidth - signwidth - 1,
		width = 1 + signwidth,
	}

	api.nvim_win_set_config(bar_winid, cfg)

	vim.w[bar_winid].col = cfg.col
	vim.w[bar_winid].width = cfg.width
	vim.w[bar_winid].row = toprow
end

---@param bbufnr integer
---@param bwinid integer
---@param winid integer
---@param row integer
---@param height integer
local render = async.void(function(bbufnr, bwinid, winid, row, height)
	render_scrollbar(winid, bbufnr, row, height)

	-- Run handlers
	local bufnr = api.nvim_win_get_buf(winid)
	for _, handler in ipairs(Handlers.handlers) do
		render_handler(bufnr, winid, bbufnr, handler)
	end

	reposition_bar(winid, bwinid, row)
end)

-- Show a scrollbar for the specified 'winid' window ID, using the specified
-- 'bar_winid' floating window ID (a new floating window will be created if
-- this is -1). Returns -1 if the bar is not shown, and the floating window ID
-- otherwise.
local function show_scrollbar(winid)
	local bufnr = api.nvim_win_get_buf(winid)
	local buf_filetype = vim.bo[bufnr].filetype

	util.invalidate_virtual_line_count_cache(winid)

	-- Skip if the filetype is on the list of exclusions.
	if vim.tbl_contains(user_config.excluded_filetypes, buf_filetype) then
		return
	end

	local wininfo = fn.getwininfo(winid)[1]

	-- Don't show in terminal mode, since the bar won't be properly updated for
	-- insertions.
	if wininfo.terminal ~= 0 then
		return
	end

	if util.in_cmdline_win(winid) then
		return
	end

	local winheight = api.nvim_win_get_height(winid)
	local winwidth = api.nvim_win_get_width(winid)
	if winheight == 0 or winwidth == 0 then
		return
	end
	if vim.fn.has("nvim-0.8") > 0 then
		if vim.o.winbar ~= "" then
			winheight = winheight - 1
		end
	end

	local line_count = api.nvim_buf_line_count(bufnr)

	if line_count == 0 then
		return
	end

	-- Don't show the position bar when all lines are on screen.
	local topline, botline = util.visible_line_range(winid)
	if botline - topline + 1 == line_count then
		return
	end

	local cfg = {
		win = winid,
		relative = "win",
		style = "minimal",
		focusable = false,
		zindex = user_config.zindex,
		height = winheight,
		width = 1,
		row = 0,
		col = winwidth - 1,
	}

	local bar_winid = winids[winid]
	local bar_bufnr

	if bar_winid then
		local bar_wininfo = vim.fn.getwininfo(bar_winid)[1]
		-- wininfo can be nil when pressing <C-w>o in help buffers
		if bar_wininfo then
			local signwidth = bar_wininfo.textoff
			cfg.col = cfg.col - signwidth
			cfg.width = cfg.width + signwidth
		end
	end

	if bar_winid and api.nvim_win_is_valid(bar_winid) then
		api.nvim_win_set_config(bar_winid, cfg)
		bar_bufnr = api.nvim_win_get_buf(bar_winid)
	else
		cfg.noautocmd = true
		bar_bufnr, bar_winid = create_view(cfg)
		winids[winid] = bar_winid
	end

	local toprow = util.row_to_barpos(winid, topline - 1)
	local height = util.height_to_virtual(winid, topline - 1, botline - 1)
	render(bar_bufnr, bar_winid, winid, toprow, height)

	vim.w[bar_winid].height = height
	vim.w[bar_winid].row = toprow
	vim.w[bar_winid].col = cfg.col
	vim.w[bar_winid].width = cfg.width

	return true
end

-- Returns view properties for the specified window. An empty dictionary
-- is returned if there is no corresponding scrollbar.
function M.get_props(winid)
	local bar_winid = winids[winid]
	if not bar_winid then
		return
	end

	return {
		height = vim.w[bar_winid].height,
		row = vim.w[bar_winid].row,
		col = vim.w[bar_winid].col,
		width = vim.w[bar_winid].width,
	}
end

local function get_target_windows()
	if user_config.current_only then
		return { api.nvim_get_current_win() }
	end

	local target_wins = {}
	local current_tab = api.nvim_get_current_tabpage()
	for _, winid in ipairs(api.nvim_list_wins()) do
		if util.is_ordinary_window(winid) and api.nvim_win_get_tabpage(winid) == current_tab then
			target_wins[#target_wins + 1] = winid
		end
	end
	return target_wins
end

local function close(winid)
	local bar_winid = winids[winid]
	if not api.nvim_win_is_valid(bar_winid) then
		return
	end
	if util.in_cmdline_win(winid) then
		return
	end
	util.noautocmd(function()
		api.nvim_win_close(bar_winid, true)
	end)
	winids[winid] = nil
end

-- Given a target window row, the corresponding scrollbar is moved to that row.
-- The row is adjusted (up in value, down in visual position) such that the full
-- height of the scrollbar remains on screen.
function M.move_scrollbar(winid, row)
	local bar_winid = winids[winid]
	if not bar_winid then
		-- Can happen if mouse is dragged over other floating windows
		return
	end
	local height = api.nvim_win_get_var(bar_winid, "height")

	local bar_bufnr0 = api.nvim_win_get_buf(bar_winid)
	render(bar_bufnr0, bar_winid, winid, row, height)
end

function M.refresh_bars()
	local current_wins = {}

	if enabled then
		for _, winid in ipairs(get_target_windows()) do
			if show_scrollbar(winid) then
				current_wins[#current_wins + 1] = winids[winid]
			end
		end
	end

	-- Close any remaining bars
	for winid, swinid in pairs(winids) do
		if not vim.tbl_contains(current_wins, swinid) then
			close(winid)
		end
	end
end

function M.remove_bars()
	for winid, _ in pairs(winids) do
		close(winid)
	end
end

function M.disable()
	enabled = false
	M.remove_bars()
end

function M.enable()
	enabled = true
	M.refresh_bars()
end

function M.enabled()
	return enabled
end

return M
