local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Widget = require "widget"
local review = require "plugins.scm.review"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"

---Scrollable numbered unified/side-by-side diff with selectable hunks.
---@class plugins.scm.ui.DiffPreview : widget
local DiffPreview = Widget:extend()

function DiffPreview:new(parent)
  DiffPreview.super.new(self, parent)
  self.border.width = 0
  self.scrollable = true
  self.font = "code_font"
  self.rows, self.paired = {}, {}
  self.selected_hunk = nil
  self.side_by_side = false
  self.message = "No changes"
  self.generation = 0
  self.parse_key = {}
end

function DiffPreview:set_message(message)
  core.threads[self.parse_key] = nil
  self.generation = self.generation + 1
  self.rows, self.paired, self.selected_hunk = {}, {}, nil
  self.line_selection = nil
  self.message = message
  self.scroll.x, self.scroll.y = 0, 0
  self.scroll.to.x, self.scroll.to.y = 0, 0
  self:schedule_update()
end

local function tokenize_line(syn, text, state, first_line)
  local tokens, next_state, resume
  repeat
    tokens, next_state, resume = tokenizer.tokenize(
      syn, text, state, resume or { first_line = first_line }
    )
    if resume then
      coroutine.yield()
    end
  until not resume
  -- Line endings terminate comments, but must not be drawn inside a diff row.
  local last = #tokens
  if last > 0 and tokens[last]:sub(-1) == "\n" then
    tokens[last] = tokens[last]:sub(1, -2)
    if tokens[last] == "" then
      tokens[last], tokens[last - 1] = nil, nil
    end
  end
  return tokens, next_state
end

function DiffPreview:set_diff(text, filename)
  if #text > 16 * 1024 * 1024 then
    self:set_message "Text diff exceeds the 16 MiB preview limit"
    return
  end
  if
    self.last_diff == text
    and self.last_filename == filename
    and not self.message
  then
    return
  end
  self:set_message(text == "" and "No textual changes" or "Loading diff...")
  self.last_diff, self.last_filename = text, filename
  local generation = self.generation
  core.add_thread(function()
    local parsed = review.diff(text, function()
      coroutine.yield()
    end)
    if generation ~= self.generation then
      return
    end
    local visible = {}
    for i, row in ipairs(parsed.rows) do
      if
        row.kind ~= "meta"
        or row.hunk
        or row.detail
        or row.text:match "^diff %-%-git"
        or row.text:match "^Index:"
        or #parsed.files == 0
        or row.file and (#row.file.hunks == 0 or row.file.binary)
      then
        visible[#visible + 1] = row
      end
      if i % 100 == 0 then
        coroutine.yield()
        if generation ~= self.generation then
          return
        end
      end
    end
    local paired = review.side_by_side(visible, function()
      coroutine.yield()
    end)
    if generation ~= self.generation then
      return
    end
    self.rows, self.paired = visible, paired
    local max_line = 1
    for _, row in ipairs(visible) do
      max_line = math.max(max_line, row.old or 0, row.new or 0)
    end
    self.line_digits = math.max(2, #tostring(max_line))
    self.content_width = 0
    local file
    local old_path, new_path = filename or "", filename or ""
    local old_syn = syntax.get(old_path, "")
    local new_syn = old_syn
    local old_state, new_state
    for i, row in ipairs(parsed.rows) do
      if row.file ~= file then
        file = row.file
        old_path = file and (file.old_path or file.path) or filename or ""
        new_path = file and (file.path or file.old_path) or filename or ""
        old_syn = syntax.get(old_path, "")
        new_syn = old_path == new_path and old_syn or syntax.get(new_path, "")
        old_state, new_state = nil, nil
      end
      local line = row.text:gsub("\r$", "")
      self.content_width = math.max(
        self.content_width,
        style.code_font:get_width((line:gsub("\t", "    ")))
      )
      line = line .. "\n"
      if row.old == 1 then
        old_syn = syntax.get(old_path, line)
      end
      if row.new == 1 then
        new_syn = syntax.get(new_path, line)
      end
      if row.kind == "hunk" then
        old_state, new_state = nil, nil
      elseif row.kind == "delete" then
        row.tokens, old_state = tokenize_line(old_syn, line, old_state,
          row.old == 1)
      elseif row.kind == "insert" then
        row.tokens, new_state = tokenize_line(new_syn, line, new_state,
          row.new == 1)
      elseif row.kind == "context" then
        local incoming_new = new_state
        row.tokens, new_state = tokenize_line(new_syn, line, new_state,
          row.new == 1)
        if
          old_syn == new_syn and old_state == incoming_new
          and (row.old == 1) == (row.new == 1)
        then
          row.old_tokens, old_state = row.tokens, new_state
        else
          row.old_tokens, old_state = tokenize_line(old_syn, line, old_state,
            row.old == 1)
        end
      end
      if i % 100 == 0 then
        coroutine.yield()
      end
      if generation ~= self.generation then
        return
      end
    end
    self.selected_hunk = parsed.files[1] and parsed.files[1].hunks[1]
    self.inserts, self.deletes = parsed.inserts, parsed.deletes
    self.message = #self.rows == 0 and "No textual changes" or nil
    self:schedule_update()
  end, self.parse_key)
end

function DiffPreview:get_line_height()
  return style.code_font:get_height() + 4 * SCALE
end

function DiffPreview:get_scrollable_size()
  local rows = self.side_by_side and self.paired or self.rows
  return math.max(
    self.size.y,
    #rows * self:get_line_height() + style.padding.y * 2
  )
end

function DiffPreview:get_h_scrollable_size()
  local width = (self.content_width or 0)
    + style.code_font:get_width "000000 000000 "
  return math.max(self.size.x, self.side_by_side and width * 2 or width)
end

function DiffPreview:on_click(button, x, y)
  if button ~= "left" then
    return
  end
  local index = math.floor(
    (y - self.position.y + self.scroll.y - style.padding.y)
      / self:get_line_height()
  ) + 1
  local rows = self.side_by_side and self.paired or self.rows
  self.selected_hunk = rows[index] and rows[index].hunk
  self:schedule_update()
end

function DiffPreview:row_at(y, x)
  local rows = self.side_by_side and self.paired or self.rows
  local index = math.floor(
    (y - self.position.y + self.scroll.y - style.padding.y)
      / self:get_line_height()
  ) + 1
  local row = rows[index]
  if self.side_by_side and row then
    row = x
        and x < self.position.x + self.size.x / 2
        and (row.left or row.right)
      or (row.right or row.left)
  end
  return row
end

function DiffPreview:on_mouse_pressed(button, x, y, clicks)
  local handled = DiffPreview.super.on_mouse_pressed(self, button, x, y, clicks)
  if button == "left" then
    local row = self:row_at(y, x)
    self.selected_hunk = row and row.hunk
    self.line_selection = row
        and row.hunk_line
        and { row.hunk_line, row.hunk_line }
      or nil
    self.selecting = self.line_selection ~= nil
  end
  return handled
end

function DiffPreview:on_mouse_moved(x, y, dx, dy)
  DiffPreview.super.on_mouse_moved(self, x, y, dx, dy)
  if self.selecting then
    local row = self:row_at(y, x)
    if row and row.hunk == self.selected_hunk and row.hunk_line then
      self.line_selection[2] = row.hunk_line
      self:schedule_update()
    end
  end
end

function DiffPreview:on_mouse_released(...)
  self.selecting = false
  return DiffPreview.super.on_mouse_released(self, ...)
end

function DiffPreview:move_hunk(direction)
  local hunks = {}
  for i, row in ipairs(self.rows) do
    if row.kind == "hunk" then
      hunks[#hunks + 1] = { index = i, hunk = row.hunk }
    end
  end
  if #hunks == 0 then
    return
  end
  local index = 1
  for i, item in ipairs(hunks) do
    if item.hunk == self.selected_hunk then
      index = i
      break
    end
  end
  index = common.clamp(index + direction, 1, #hunks)
  self.selected_hunk = hunks[index].hunk
  local rows = self.side_by_side and self.paired or self.rows
  for i, row in ipairs(rows) do
    if row.hunk == self.selected_hunk then
      self.scroll.to.y = (i - 1) * self:get_line_height()
      break
    end
  end
  self:schedule_update()
end

local function tint(color)
  return { color[1], color[2], color[3], 25 }
end

function DiffPreview:draw_cell(row, x, y, w, side)
  if not row then
    return
  end
  local font, lh = style.code_font, self:get_line_height()
  local kind = row.kind
  local color = kind == "insert" and style.diff_insert
    or kind == "delete" and style.diff_delete
    or kind == "hunk" and style.accent
    or style.text
  if kind == "insert" or kind == "delete" then
    renderer.draw_rect(
      x, y, w, lh,
      kind == "insert" and style.diff_insert_background
        or style.diff_delete_background
    )
  elseif kind == "hunk" then
    renderer.draw_rect(
      x,
      y,
      w,
      lh,
      row.hunk == self.selected_hunk and style.selection or style.background2
    )
  end
  local selection = self.line_selection
  if
    selection
    and row.hunk == self.selected_hunk
    and row.hunk_line
    and row.hunk_line >= math.min(selection[1], selection[2])
    and row.hunk_line <= math.max(selection[1], selection[2])
  then
    renderer.draw_rect(x, y, w, lh, style.selection)
  end
  local digits = self.line_digits or 2
  local gutter = font:get_width(string.rep("0", digits) .. " ")
  local number = side == "left" and row.old or side == "right" and row.new
  local numbers = side and tostring(number or "")
    or string.format(
      "%" .. digits .. "s %" .. digits .. "s",
      row.old or "",
      row.new or ""
    )
  if not side then
    gutter = font:get_width(string.rep("0", digits * 2 + 2))
  end
  if row.kind == "meta" or row.kind == "hunk" then
    gutter, numbers = 8 * SCALE, ""
  end
  core.push_clip_rect(x, y, w, lh)
  common.draw_text(
    font,
    style.dim,
    numbers,
    "right",
    x,
    y,
    gutter - 8 * SCALE,
    lh
  )
  core.push_clip_rect(x + gutter, y, math.max(0, w - gutter), lh)
  local tx = x + gutter - self.scroll.x
  if self.whitespace_errors and row.kind == "insert" then
    local start = row.text:find "[ \t]+$"
    if start then
      local before = row.text:sub(1, start - 1):gsub("\t", "    ")
      local space = row.text:sub(start):gsub("\t", "    ")
      renderer.draw_rect(
        tx + font:get_width(before),
        y,
        font:get_width(space),
        lh,
        tint(style.error)
      )
    end
  end
  if row.change_start and row.change_end >= row.change_start then
    local prefix = row.text:sub(1, row.change_start - 1):gsub("\t", "    ")
    local change =
      row.text:sub(row.change_start, row.change_end):gsub("\t", "    ")
    renderer.draw_rect(
      tx + font:get_width(prefix),
      y,
      font:get_width(change),
      lh,
      kind == "insert" and style.diff_insert_inline or style.diff_delete_inline
    )
  end
  local tokens = side == "left" and row.old_tokens or row.tokens
  if tokens then
    for _, kind_name, text in tokenizer.each_token(tokens) do
      tx = renderer.draw_text(
        font,
        text:gsub("\t", "    "),
        tx,
        y + 2 * SCALE,
        style.syntax[kind_name] or color
      )
    end
  else
    renderer.draw_text(
      font,
      row.text:gsub("\t", "    "):gsub("\r$", ""),
      tx,
      y + 2 * SCALE,
      color
    )
  end
  core.pop_clip_rect()
  core.pop_clip_rect()
end

function DiffPreview:draw()
  if not DiffPreview.super.draw(self) then
    return false
  end
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  core.push_clip_rect(x, y, w, h)
  if self.message then
    common.draw_text(
      style.font,
      style.dim,
      self.message,
      "center",
      x + 12,
      y + 12,
      w - 24,
      h - 24
    )
  else
    local rows = self.side_by_side and self.paired or self.rows
    local lh = self:get_line_height()
    local first = math.max(1, math.floor(self.scroll.y / lh))
    local last = math.min(#rows, first + math.ceil(h / lh) + 1)
    for i = first, last do
      local py = y + style.padding.y + (i - 1) * lh - self.scroll.y
      if self.side_by_side then
        local half = math.floor(w / 2)
        self:draw_cell(rows[i].left, x, py, half, "left")
        self:draw_cell(rows[i].right, x + half, py, w - half, "right")
      else
        self:draw_cell(rows[i], x, py, w)
      end
    end
    if self.side_by_side then
      renderer.draw_rect(x + math.floor(w / 2), y, 1, h, style.divider)
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
  return true
end

return DiffPreview
