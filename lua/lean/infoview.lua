local components = require'lean.infoview.components'
local lean = require'lean'
local lean3 = require'lean.lean3'
local leanlsp = require'lean.lsp'
local is_lean_buffer = require'lean'.is_lean_buffer
local util = require'lean._util'
local set_augroup = util.set_augroup
local a = require'plenary.async'
local html = require'lean.html'
local rpc = require'lean.rpc'
local protocol = require'vim.lsp.protocol'

local infoview = {
  -- mapping from infoview IDs to infoviews
  ---@type table<number, Infoview>
  _infoviews = {},
  -- all current infoviews
  ---@type Infoview[]
  _by_tabpage = {},
  -- mapping from info IDs to infos
  ---@type table<number, Info>
  _info_by_id = {},
  -- mapping from pin IDs to pins
  ---@type table<number, Pin>
  _pin_by_id = {},
  --- Whether to print additional debug information in the infoview.
  ---@type boolean
  debug = false,
}
local options = {
  _DEFAULTS = {
    width = 50,
    height = 20,

    autoopen = true,
    autopause = false,
    indicators = "auto",
    lean3 = { show_filter = true, mouse_events = false },
    show_processing = true,
    show_no_info_message = false,
    use_widgets = true,

    mappings = {
      ["K"] = [[click]],
      ["<CR>"] = [[click]],
      ["I"] = 'mouse_enter',
      ["i"] = 'mouse_leave',
      ["<Esc>"] = 'clear_all',
      ["C"] = 'clear_all',
      ["<LocalLeader><Tab>"] = [[goto_last_window]]
    }
  }
}

--- An individual pin.
---@class Pin
---@field id number
---@field private __data_div Div
---@field private __div Div
---@field private __ticker table
---@field private __parent_infos table<Info, boolean>
---@field private __ui_position_params UIParams
---@field private __use_widgets boolean
local Pin = {next_id = 1}

--- An individual info.
---@class Info
---@field id number
---@field pin Pin
---@field pins Pin[]
---@field private __auto_diff_pin Pin
---@field private __bufdiv BufDiv
---@field private __diff_bufdiv BufDiv
---@field private __diff_pin Pin
---@field private __pins_div Div
---@field private __parent_infoviews Infoview[]
---@field private __win_event_disable boolean
local Info = {}

--- A "view" on an info (i.e. window).
---@class Infoview
---@field info Info
---@field window integer
---@field private __orientation "vertical"|"horizontal"
---@field private __width number
---@field private __height number
---@field private __diff_win integer
local Infoview = {}

local pin_hl_group = "LeanNvimPin"
vim.highlight.create(pin_hl_group, {
  cterm = 'underline',
  ctermbg = '3',
  gui   = 'underline',
}, true)

local diff_pin_hl_group = "LeanNvimDiffPin"
vim.highlight.create(diff_pin_hl_group, {
  cterm = 'underline',
  ctermbg = '7',
  gui   = 'underline',
}, true)

--- Enables printing of extra debugging information in the infoview.
function infoview.enable_debug()
  infoview.debug = true
end

--- Get the infoview corresponding to the current window.
---@return Infoview
function infoview.get_current_infoview()
  return infoview._by_tabpage[vim.api.nvim_win_get_tabpage(0)]
end

--- Create a new infoview.
---@param open boolean: whether to open the infoview after initializing
---@return Infoview
function Infoview:new(open)
  local new_infoview = { __width = options.width, __height = options.height }
  self.__index = self
  setmetatable(new_infoview, self)

  new_infoview.info = Info:new{ parent = new_infoview }
  table.insert(infoview._infoviews, new_infoview)
  if not open then new_infoview:close() else new_infoview:open() end

  return new_infoview
end

--- Open this infoview if it isn't already open
function Infoview:open()
  if self.window then return end

  local window_before_split = vim.api.nvim_get_current_win()

  local win_width = vim.api.nvim_win_get_width(window_before_split)
  local win_height = vim.api.nvim_win_get_height(window_before_split)

  local ch_aspect_ratio = 2.5 -- characters are 2.5x taller than they are wide
  if win_width > ch_aspect_ratio * win_height then -- vertical split
    self.__orientation = "vertical"
    vim.cmd("botright " .. self.__width .. "vsplit")
  else -- horizontal split
    self.__orientation = "horizontal"
    vim.cmd("botright " .. self.__height .. "split")
  end
  vim.cmd(string.format("buffer %d", self.info.__bufdiv.buf))
  -- Set the filetype now. Any earlier, and only buffer-local options will be
  -- properly set in the infoview, since the buffer isn't actually shown in a
  -- window until we run :buffer above.
  vim.api.nvim_buf_set_option(self.info.__bufdiv.buf, 'filetype', 'leaninfo')
  self.window = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(window_before_split)

  self.info:focus_on_current_buffer()

  self:__refresh_diff()
end

--- API for opening an auxilliary window relative to the current infoview window.
--- @param buf number @buffer to put in the new window
--- @param orientation string @"leftabove" or "rightbelow"
--- @return number @new window handle or nil if the infoview is closed
function Infoview:__open_win(buf, orientation)
  if not self.window then return end

  self.info.__win_event_disable = true
  local window_before_split = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(self.window)

  if self.__orientation == "vertical" then
    vim.cmd(orientation .. self.__width .. "vsplit")
    vim.cmd("vertical resize " .. self.__width)
  else
    vim.cmd(orientation .. self.__height .. "split")
    vim.cmd("resize " .. self.__height)
  end
  local new_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(new_win, buf)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'leaninfo')

  vim.api.nvim_set_current_win(window_before_split)
  self.info.__win_event_disable = false

  return new_win
end

function Infoview:__refresh()
  local valid_windows = {}

  self.info.__win_event_disable = true
  for _, win in pairs({self.window, self.__diff_win}) do
    if win and vim.api.nvim_win_is_valid(win) then
      table.insert(valid_windows, win)
    end
  end

  for _, win in pairs(valid_windows) do
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_command("set winfixwidth")
    end)
  end

  for _, win in pairs(valid_windows) do
    vim.api.nvim_win_call(win, function()
      if self.__orientation == "vertical" then
        vim.cmd("vertical resize " .. self.__width)
      else
        vim.cmd("resize " .. self.__height)
      end
    end)
  end
  self.info.__win_event_disable = false
end

--- Either open or close a diff window for this infoview depending on whether its info has a diff pin.
function Infoview:__refresh_diff()
  if not self.window then return end

  if not self.info.__diff_pin then self:__close_diff() return end

  local diff_bufdiv = self.info.__diff_bufdiv

  if not self.__diff_win then
    self.__diff_win = self:__open_win(diff_bufdiv.buf, "leftabove")
  end

  for _, win in pairs({self.__diff_win, self.window}) do
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_command"diffthis"
      vim.api.nvim_command("set foldmethod=manual")
      vim.api.nvim_command("setlocal wrap")
    end)
  end

  self:__refresh()
end

--- Close this infoview's diff window.
function Infoview:__close_diff()
  if not self.window or not self.__diff_win then return end

  self.info.__win_event_disable = true
  vim.api.nvim_win_call(self.window, function() vim.api.nvim_command"diffoff" end)

  if vim.api.nvim_win_is_valid(self.__diff_win) then
    vim.api.nvim_win_call(self.__diff_win, function() vim.api.nvim_command"diffoff" end)
    vim.api.nvim_win_close(self.__diff_win, true)
  end
  self.info.__win_event_disable = false

  self.__diff_win = nil

  self:__refresh()
end

--- Close this infoview.
function Infoview:close()
  if not self.window then return end

  self:__close_diff()

  self.info.__win_event_disable = true
  if vim.api.nvim_win_is_valid(self.window) then
    vim.api.nvim_win_close(self.window, true)
  end
  self.info.__win_event_disable = false

  self.window = nil

  self.info:focus_on_current_buffer()
end

--- Retrieve the contents of the infoview as a table.
function Infoview:get_lines(start_line, end_line)
  if not self.window then error("infoview is not open") end
  start_line = start_line or 0
  end_line = end_line or -1
  return vim.api.nvim_buf_get_lines(self.info.__bufdiv.buf, start_line, end_line, true)
end

--- Toggle this infoview being open.
function Infoview:toggle()
  if self.window then self:close() else self:open() end
end

--- Set the currently active Lean buffer to update the info.
function Info:focus_on_current_buffer()
  if not is_lean_buffer() then return end
  local any_open = false
  for _, parent in ipairs(self.__parent_infoviews) do
    if parent.window then
      any_open = true
      break
    end
  end

  if any_open then
    set_augroup("LeanInfoviewUpdate", string.format([[
      autocmd CursorMoved <buffer> lua require'lean.infoview'.__update(%d)
      autocmd CursorMovedI <buffer> lua require'lean.infoview'.__update(%d)
    ]], self.id, self.id), 0)
  else
    set_augroup("LeanInfoviewUpdate", "", 0)
  end
end

---@return Info
function Info:new(opts)
  local new_info = {
    id = #infoview._info_by_id + 1,
    pin = Pin:new(options.autopause, options.use_widgets),
    pins = {},
    __parent_infoviews = { opts.parent },
    __pins_div = html.Div:new("", "info", nil),
    __win_event_disable = false,
  }
  table.insert(infoview._info_by_id, new_info)

  self.__index = self
  setmetatable(new_info, self)
  self = new_info

  self.__pins_div.events = {
    goto_last_window = function()
      if self.last_window then
        vim.api.nvim_set_current_win(self.last_window)
      end
    end
  }

  local function mk_buf(name, listed)
    local bufnr = vim.api.nvim_create_buf(listed or false, true)
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
    vim.api.nvim_buf_set_name(bufnr, name)
    return bufnr
  end

  self.__bufdiv = html.BufDiv:new(mk_buf("lean://info/" .. self.id .. "/curr", true), self.__pins_div, options.mappings)
  self.__diff_bufdiv = html.BufDiv:new(mk_buf("lean://info/" .. self.id .. "/diff"), self.pin.__div, options.mappings)

  -- Show/hide current pin extmark when entering/leaving infoview.
  set_augroup("LeanInfoviewShowPin", string.format([[
    autocmd WinEnter <buffer=%d> lua require'lean.infoview'.__show_curr_pin(%d)
    autocmd WinLeave <buffer=%d> lua require'lean.infoview'.__hide_curr_pin(%d)
  ]], self.__bufdiv.buf, self.id, self.__bufdiv.buf, self.id), self.__bufdiv.buf)

  -- Make sure we notice even if someone manually :q's the infoview window.
  set_augroup("LeanInfoviewClose", string.format([[
    autocmd WinClosed <buffer=%d> lua require'lean.infoview'.__was_closed(%d)
  ]], self.__bufdiv.buf, self.id), self.__bufdiv.buf)

  -- Make sure we notice even if someone manually :q's the diff window.
  set_augroup("LeanInfoviewClose", string.format([[
    autocmd WinClosed <buffer=%d> lua require'lean.infoview'.__diff_was_closed(%d)
  ]], self.__diff_bufdiv.buf, self.id), self.__diff_bufdiv.buf)

  self.pin:__add_parent_info(self)

  self:render()

  return self
end

function Info:__new_current_pin()
  self.pin = Pin:new(options.autopause, options.use_widgets)
  self.pin:__add_parent_info(self)
end

function Info:add_pin()
  local new_params = vim.deepcopy(self.pin.__ui_position_params)
  table.insert(self.pins, self.pin)
  self:maybe_show_pin_extmark(tostring(self.pin.id))
  self:__new_current_pin()
  self.pin:move(new_params)
  self:render()
end

---@param params UIParams
function Info:__set_diff_pin(params)
  if not self.__diff_pin then
    self.__diff_pin = Pin:new(options.autopause, options.use_widgets)
    self.__diff_pin:__add_parent_info(self)
    self.__diff_bufdiv.__div = self.__diff_pin.__div
    self.__diff_pin:show_extmark(nil, diff_pin_hl_group)
  end

  self.__diff_pin:move(params)

  self:render()
end

--- Close all parent infoviews.
function Info:close_parent_infoviews()
  for _, parent in ipairs(self.__parent_infoviews) do
    parent:close()
  end
end

function Info:clear_pins()
  for _, pin in pairs(self.pins) do
    pin:__remove_parent_info(self)
  end

  self.pins = {}
  self:render()
end

function Info:__clear_diff_pin()
  if not self.__diff_pin then return end
  self.__diff_pin:__remove_parent_info(self)
  self.__diff_pin = nil
  self.__diff_bufdiv.__div = self.pin.__div
  self:render()
end

--- Show a pin extmark if it is appropriate based on configuration.
function Info:maybe_show_pin_extmark(...)
  if not options.indicators or options.indicators == "never" then return end
  -- self.pins is apparently all *other* pins, so we check it's empty
  if options.indicators == "auto" and #self.pins == 0 then return end
  self.pin:show_extmark(...)
end

--- Set the current window as the last window used to update this Info.
function Info:set_last_window()
  self.last_window = vim.api.nvim_get_current_win()
end

--- Update this info's pins div.
function Info:__render_pins()
  self.__pins_div.divs = {}
  local function render_pin(pin, current)
    local header_div = html.Div:new("", "pin-header")
    if infoview.debug then
      header_div:insert_div("-- PIN " .. tostring(pin.id), "pin-id-header")

      local function add_attribute(text, name)
        header_div:insert_div(" [" .. text .. "]", name .. "-attribute")
      end
      if current then add_attribute("CURRENT", "current") end
      if pin.paused then add_attribute("PAUSED", "paused") end
      if pin.loading then add_attribute("LOADING", "loading") end
    end

    local params = pin.__ui_position_params
    if not current and params then
      local bufnr = vim.fn.bufnr(params.filename)
      local filename
      if bufnr ~= -1 then
        filename = vim.fn.bufname(bufnr)
      else
        filename = params.filename
      end
      if not infoview.debug then
        header_div:insert_div("-- ", "pin-id-header")
      else
        header_div:insert_div(": ", "pin-header-separator")
      end
      local location_text = ("%s at %d:%d"):format(filename,
        params.row + 1, params.col + 1)
      header_div:insert_div(location_text, "pin-location")

      header_div.highlightable = true
      header_div.events = {
        click = function()
          if self.last_window then
            vim.api.nvim_set_current_win(self.last_window)
            local uri_bufnr = vim.fn.bufnr(params.filename)
            vim.api.nvim_set_current_buf(uri_bufnr)
            vim.api.nvim_win_set_cursor(0, { params.row + 1, params.col })
          end
        end
      }
    end
    if not header_div:is_empty() then
      header_div:insert_div("\n", "pin-header-end")
    end

    local pin_div = html.Div:new("", "pin_wrapper")
    pin_div:add_div(header_div)
    if pin.__div then pin_div:add_div(pin.__div) end

    return pin_div
  end

  self.__pins_div:add_div(render_pin(self.pin, true))

  for _, pin in ipairs(self.pins) do
    self.__pins_div:add_div(html.Div:new("\n\n", "pin_spacing"))
    self.__pins_div:add_div(render_pin(pin, false))
  end
end

--- Update this info's physical contents.
function Info:render()
  self:__render_pins()

  self.__bufdiv:buf_render()
  if self.__diff_pin then self.__diff_bufdiv:buf_render() end

  for _, parent in ipairs(self.__parent_infoviews) do
    parent:__refresh_diff()
  end

  collectgarbage()
end

--- Update the diff pin to use the current pin's positon params if they are valid,
--- and the provided params if they are not.
---@param params UIParams
function Info:__update_auto_diff_pin(params)
  if self.pin.__ui_position_params and util.position_params_valid(self.pin.__ui_position_params) then
    -- update diff pin to previous position
    self:__set_diff_pin(self.pin.__ui_position_params)
  elseif params then
    -- if previous position invalid, use current position
    self:__set_diff_pin(params)
  end
end

--- Move the current pin to the specified location.
---@param params UIParams
function Info:move_pin(params)
  if self.__auto_diff_pin then self:__update_auto_diff_pin(params) end
  self.pin:move(params)
end

--- Toggle auto diff pin mode.
--- @param clear boolean @clear the pin when disabling auto diff pin mode?
function Info:__toggle_auto_diff_pin(clear)
  if self.__auto_diff_pin then
    self.__auto_diff_pin = false
    if clear then self:__clear_diff_pin() end
  else
    self.__auto_diff_pin = true
    -- only update the diff pin if there isn't already one
    if not self.__diff_pin then self:__update_auto_diff_pin() end
  end
end

---@return Pin
function Pin:new(paused, use_widgets)
  local new_pin = {
    id = self.next_id,
    paused = paused,
    __data_div = html.Div:new("", "pin-data", nil),
    __div = html.Div:new("", "pin", nil),
    __parent_infos = {},
    __ticker = util.Ticker:new(),
    __use_widgets = use_widgets,
  }
  self.next_id = self.next_id + 1
  infoview._pin_by_id[new_pin.id] = new_pin

  self.__index = self
  setmetatable(new_pin, self)

  return new_pin
end

--- Set whether this pin uses a widget or a plain goal/term goal.
function Pin:enable_widgets(use_widgets)
  self.__use_widgets = use_widgets
  self:update()
end

---@param new_parent Info
function Pin:__add_parent_info(new_parent)
  self.__parent_infos[new_parent] = true
end

local extmark_ns = vim.api.nvim_create_namespace("LeanNvimPinExtmarks")

function Pin:_teardown()
  if self.extmark then vim.api.nvim_buf_del_extmark(self.extmark_buf, extmark_ns, self.extmark) end
  infoview._pin_by_id[self.id] = nil
end

function Pin:__remove_parent_info(info)
  self.__parent_infos[info] = nil
  if vim.tbl_isempty(self.__parent_infos) then self:_teardown() end
end

--- Update this pin's current position.
---@param params UIParams
function Pin:set_position_params(params)
  self:update_extmark(params)
end

--- Update pin extmark based on position, used when resetting pin position.
---@param params UIParams
function Pin:update_extmark(params)
  if not params then return end

  local buf = vim.fn.bufnr(params.filename)

  if buf ~= -1 then
    local line = params.row
    local col = params.col

    self:__update_extmark_style(buf, line, col)

    self:update_position()
  end
end

function Pin:__update_extmark_style(buf, line, col)
  if not buf and not self.extmark then return end

  -- not a brand new extmark
  if not buf then
    buf = self.extmark_buf
    local extmark_pos = vim.api.nvim_buf_get_extmark_by_id(buf, extmark_ns, self.extmark, {})
    line = extmark_pos[1]
    col = extmark_pos[2]
  end

  local buf_line = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
  local end_col = 0
  if buf_line then
    if col < #buf_line then
      -- vim.str_utfindex rounds up to the next UTF16 index if in the middle of a UTF8 sequence;
      -- so convert next byte to UTF16 and back to get UTF8 index of next codepoint
      local _, next_utf16 = vim.str_utfindex(buf_line, col + 1)
      end_col = (col < #buf_line) and vim.str_byteindex(buf_line, next_utf16, true)
    else
      end_col = col
    end
  end

  self.extmark = vim.api.nvim_buf_set_extmark(buf, extmark_ns,
    line, col,
    {
      id = self.extmark;
      end_col = end_col;
      hl_group = self.extmark_hl_group;
      virt_text = self.extmark_virt_text;
      virt_text_pos = "right_align";
    })
  self.extmark_buf = buf
end

--- Update pin position based on extmark, used directly when changing text, indirectly when setting position.
function Pin:update_position()
  local extmark = self.extmark
  if not extmark then return end

  local buf = self.extmark_buf
  if buf == -1 then return end

  local extmark_pos = vim.api.nvim_buf_get_extmark_by_id(buf, extmark_ns, extmark, {})

  local encoding = util._get_offset_encoding(buf) or "utf-32"
  local use_utf16 = encoding == "utf-16"
  local new_pos = {}

  new_pos.line = extmark_pos[1]
  local buf_line = vim.api.nvim_buf_get_lines(buf, new_pos.line, new_pos.line + 1, false)[1]
  if buf_line then
    local utf32, utf16 = vim.str_utfindex(buf_line, extmark_pos[2])
    new_pos.character = use_utf16 and utf16 or utf32
  else
    new_pos.character = 0
  end

  local new_params = { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = new_pos }
  local new_ui_params = { filename = vim.uri_to_fname(vim.uri_from_bufnr(buf)),
    row = extmark_pos[1], col = extmark_pos[2] }
  self.__position_params = new_params
  self.__ui_position_params = new_ui_params
end

function Pin:show_extmark(name, hlgroup)
  self.extmark_hl_group = hlgroup or pin_hl_group
  if name then
    self.extmark_virt_text = {{"← " .. (name or tostring(self.id)), "Comment"}}
  else
    self.extmark_virt_text = nil
  end
  self:__update_extmark_style()
end

function Pin:hide_extmark()
  self.extmark_hl_group = nil
  self.extmark_virt_text = nil
  self:__update_extmark_style()
end

---Stop updating this pin.
function Pin:pause()
  if self.paused then return end
  self.paused = true

  self.__data_div = self.__data_div:dummy_copy()
  if not self:set_loading(false) then
    self.__div.divs = { self.__data_div }
    self:__render_parents()
  end

  -- abort any pending requests
  self.__ticker:lock()
end

---Restart updating this pin.
function Pin:unpause()
  if not self.paused then return end
  self.paused = false
  self:update()
end

---Toggle whether this pin receives updates.
function Pin:toggle_pause()
  if not self.paused then self:pause() else self:unpause() end
end

--- Triggered when manually moving a pin.
---@param params UIParams
function Pin:move(params)
  self:set_position_params(params)
  self:update()
end

function Pin:__render_parents()
  for parent, _ in pairs(self.__parent_infos) do
    parent:render()
  end
end

-- Indicate that the pin is either loading or done loading, if it isn't already set as such.
function Pin:set_loading(loading)
  if loading and not self.loading then
    self.__div.divs = {}
    local data_div_copy = self.__data_div:dummy_copy()

    self.__div:add_div(data_div_copy)

    self.loading = true

    self:__render_parents()
    return true
  elseif not loading and self.loading then
    self.__div.divs = {}
    self.__div:add_div(self.__data_div)

    self.loading = false

    self:__render_parents()
    return true
  end

  return false
end

function Pin:async_update(force, _, lean3_opts)
  if not force and self.paused then return end

  local tick = self.__ticker:lock()

  if self.__position_params and (force or not self.paused) then
    self:__update(tick, lean3_opts)
  end
  if not tick:check() then return end

  if not self:set_loading(false) then
    self:__render_parents()
  end
end

Pin.update = a.void(Pin.async_update)

--- async function to update this pin's contents given the current position.
function Pin:__update(tick, lean3_opts)
  self:set_loading(true)
  local blocks = {} ---@type Div[]
  local new_data_div = html.Div:new("", "pin-data", nil)

  local params = self.__position_params

  local buf = vim.fn.bufnr(vim.uri_to_fname(params.textDocument.uri))
  if buf == -1 then
    error("No corresponding buffer found for update.")
    return false
  end

  --- TODO if changes are currently being debounced for this buffer, add debounce timer delay
  do
    local line = params.position.line

    if lean.is_lean3_buffer() then
      lean3_opts = lean3_opts or {}
      lean3.update_infoview(
        self,
        new_data_div,
        buf,
        params,
        self.__use_widgets,
        lean3_opts,
        options.lean3,
        options.show_processing,
        options.show_no_info_message
      )
      goto finish
    end

    if require"lean.progress".is_processing_at(params) then
      if options.show_processing then
        new_data_div:insert_div("Processing file...", "processing-msg")
      end
      goto finish
    end

    self.sess = rpc.open(buf, params)
    if not tick:check() then return true end

    local goal_div
    if self.__use_widgets then
      local goal, err = self.sess:getInteractiveGoals(params)
      if not tick:check() then return true end
      if err and err.code == protocol.ErrorCodes.ContentModified then
        return self:__update(tick, lean3_opts)
      end
      if not err then
        goal_div = components.interactive_goals(goal, self.sess)
      end
    end

    if not goal_div then
      local err, goal = leanlsp.plain_goal(params, buf)
      if not tick:check() then return true end
      if err and err.code == protocol.ErrorCodes.ContentModified then
        return self:__update(tick, lean3_opts)
      end
      goal_div = components.goal(goal)
    end

    local term_goal_div
    if self.__use_widgets then
      local term_goal, err = self.sess:getInteractiveTermGoal(params)
      if not tick:check() then return true end
      if err and err.code == protocol.ErrorCodes.ContentModified then
        return self:__update(tick, lean3_opts)
      end
      if not err then
        term_goal_div = components.interactive_term_goal(term_goal, self.sess)
      end
    end

    if not term_goal_div then
      local err, term_goal = leanlsp.plain_term_goal(params, buf)
      if not tick:check() then return true end
      if err and err.code == protocol.ErrorCodes.ContentModified then
        return self:__update(tick, lean3_opts)
      end
      term_goal_div = components.term_goal(term_goal)
    end

    vim.list_extend(blocks, goal_div)
    vim.list_extend(blocks, term_goal_div)
    if options.show_no_info_message and #goal_div + #term_goal_div == 0 then
      table.insert(blocks, html.Div:new("No info.", "no-tactic-term"))
    end

    local diagnostics_div
    if self.__use_widgets then
      local diags, err = self.sess:getInteractiveDiagnostics({ start = line, ['end'] = line + 1 })
      if not tick:check() then return true end
      if err and err.code == protocol.ErrorCodes.ContentModified then
        return self:__update(tick, lean3_opts)
      end
      if not err then
        diagnostics_div = components.interactive_diagnostics(diags, line, self.sess)
      end
    end

    vim.list_extend(blocks, diagnostics_div or components.diagnostics(buf, line))

    new_data_div:add_div(html.concat(blocks, '\n\n'))

    if not tick:check() then return true end
  end

  new_data_div.events.clear_all = function(ctx) ---@param ctx DivEventContext
    vim.api.nvim_set_current_win(ctx.self.last_win)
    new_data_div:find(function (div) ---@param div Div
      if div.events.clear then div.events.clear(ctx) end
    end)
  end

  ::finish::
  self.__data_div = new_data_div
  return true
end

--- Close all open infoviews (across all tabs).
function infoview.close_all()
  for _, each in ipairs(infoview._infoviews) do
    each:close()
  end
end

--- An infoview was closed, either directly via `Infoview.close` or manually.
--- Will be triggered via a `WinClosed` autocmd.
---@param id number @info id
function infoview.__was_closed(id)
  local info = infoview._info_by_id[id]
  if info.__win_event_disable then return end
  info:close_parent_infoviews()
end

--- An infoview diff window was closed.
--- Will be triggered via a `WinClosed` autocmd.
---@param id number @info id
function infoview.__diff_was_closed(id)
  local info = infoview._info_by_id[id]
  if info.__win_event_disable then return end
  info:__clear_diff_pin()
end

--- An infoview was entered, show the extmark for the current pin.
--- Will be triggered via a `WinEnter` autocmd.
---@param id number @info id
function infoview.__show_curr_pin(id)
  local info = infoview._info_by_id[id]
  if info.__win_event_disable then return end
  info:maybe_show_pin_extmark("current")
end

--- An infoview was left, hide the extmark for the current pin.
--- Will be triggered via a `WinLeave` autocmd.
---@param id number @info id
function infoview.__hide_curr_pin(id)
  local info = infoview._info_by_id[id]
  if info.__win_event_disable then return end
  info.pin:hide_extmark()
end

--- Update the info contents appropriately for Lean 4 or 3.
--- @param id number @Info id
function infoview.__update(id)
  local info = id and infoview._info_by_id[id] or infoview.get_current_infoview().info
  if info.__win_event_disable then return end

  if not is_lean_buffer() then return end
  info:set_last_window()
  pcall(info.move_pin, info, util.make_position_params())
end

--- Update pins corresponding to the given URI.
function infoview.__update_pin_by_uri(uri)
  if infoview.enabled then
    for _, pin in pairs(infoview._pin_by_id) do
      if pin.__position_params and pin.__position_params.textDocument.uri == uri then
        pin:update()
      end
    end
  end
end

--- on_lines callback to update pins position according to the given textDocument/didChange parameters.
function infoview.__update_pin_positions(_, bufnr, _, _, _, _, _, _, _)
  for _, pin in pairs(infoview._pin_by_id) do
    if pin.__position_params and pin.__position_params.textDocument.uri == vim.uri_from_bufnr(bufnr) then
      vim.schedule_wrap(function()
        pin:update_position()
        pin:update(false, 500)
      end)()
    end
  end
end

--- Enable and open the infoview across all Lean buffers.
function infoview.enable(opts)
  options = vim.tbl_extend("force", options._DEFAULTS, opts)
  infoview.mappings = options.mappings
  infoview.enabled = true
  set_augroup("LeanInfoviewInit", [[
    autocmd FileType lean3 lua require'lean.infoview'.make_buffer_focusable(vim.fn.expand('<afile>'))
    autocmd FileType lean lua require'lean.infoview'.make_buffer_focusable(vim.fn.expand('<afile>'))
  ]])
end

--- Configure the infoview to update when this buffer is active.
function infoview.make_buffer_focusable(name)
  local bufnr = vim.fn.bufnr(name)
  if bufnr == -1 then return end
  if bufnr == vim.api.nvim_get_current_buf() then
    -- because FileType can happen after BufEnter
    infoview.__bufenter()
    infoview.get_current_infoview().info:focus_on_current_buffer()
  end

  -- WinEnter is necessary for the edge case where you have
  -- a file open in a tab with an infoview and move to a
  -- new window in a new tab with that same file but no infoview
  set_augroup("LeanInfoviewSetFocus", string.format([[
    autocmd BufEnter <buffer=%d> lua require'lean.infoview'.__bufenter()
    autocmd BufEnter,WinEnter <buffer=%d> lua if require'lean.infoview'.get_current_infoview()]] ..
    [[ then require'lean.infoview'.get_current_infoview().info:focus_on_current_buffer() end
  ]], bufnr, bufnr), 0)
end

--- Set whether a new infoview is automatically opened when entering Lean buffers.
function infoview.set_autoopen(autoopen)
  options.autoopen = autoopen
end

--- Set whether a new pin is automatically paused.
function infoview.set_autopause(autopause)
  options.autopause = autopause
end

local attached_buffers = {}

--- Callback when entering a Lean buffer.
function infoview.__bufenter()
  infoview.__maybe_autoopen()
  local bufnr = vim.api.nvim_get_current_buf()
  if not attached_buffers[bufnr] then
    vim.api.nvim_buf_attach(bufnr, false, {on_lines = infoview.__update_pin_positions;})
    attached_buffers[bufnr] = true
  end
  infoview.__update()
end

--- Open an infoview for the current buffer if it isn't already open.
function infoview.__maybe_autoopen()
  local tabpage = vim.api.nvim_win_get_tabpage(0)
  if not infoview._by_tabpage[tabpage] then
    infoview._by_tabpage[tabpage] = Infoview:new(options.autoopen)
  end
end

function infoview.open()
  infoview.__maybe_autoopen()
  infoview.get_current_infoview():open()
end

function infoview.toggle()
  local iv = infoview.get_current_infoview()
  if iv ~= nil then
    iv:toggle()
  else
    infoview.open()
  end
end

function infoview.pin_toggle_pause()
  local iv = infoview.get_current_infoview()
  if iv then iv.info.pin:toggle_pause() end
end

function infoview.add_pin()
  if not is_lean_buffer() then return end
  infoview.open()
  infoview.get_current_infoview().info:set_last_window()
  infoview.get_current_infoview().info:add_pin()
end

function infoview.set_diff_pin()
  if not is_lean_buffer() then return end
  infoview.open()
  infoview.get_current_infoview().info:set_last_window()
  infoview.get_current_infoview().info:__set_diff_pin(util.make_position_params())
end

function infoview.clear_pins()
  local iv = infoview.get_current_infoview()
  if iv ~= nil then
    iv.info:clear_pins()
  end
end

function infoview.clear_diff_pin()
  local iv = infoview.get_current_infoview()
  if iv ~= nil then
    iv.info:__clear_diff_pin()
  end
end

function infoview.toggle_auto_diff_pin(clear)
  if not is_lean_buffer() then return end
  infoview.open()
  infoview.get_current_infoview().info:__toggle_auto_diff_pin(clear)
end

function infoview.enable_widgets()
  local iv = infoview.get_current_infoview()
  if iv ~= nil then iv.info.pin:set_widget(true) end
end

function infoview.disable_widgets()
  local iv = infoview.get_current_infoview()
  if iv ~= nil then iv.info.pin:set_widget(false) end
end

function infoview.go_to()
  infoview.open()
  local curr_info = infoview.get_current_infoview().info
  -- if there is no last win, just go straight to the window itself
  if not curr_info.__bufdiv:buf_last_win_valid() then
    vim.api.nvim_set_current_win(infoview.get_current_infoview().window)
  else
    curr_info.__bufdiv:buf_enter_win()
  end
end

return infoview
