local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Widget = require "widget"

---@class plugins.scm.ui.BinaryDiffView : widget
local BinaryDiffView = Widget:extend()
local SIDES = { "before", "after" }

local function decode(text, path)
  if text == "" or #text > 16 * 1024 * 1024 then
    return nil
  end
  local temp = core.temp_filename(
    "." .. (path:match "%.(%w+)$" or "bin"),
    os.getenv "TMPDIR" or os.getenv "TEMP" or "/tmp"
  )
  local file = io.open(temp, "wb")
  if not file then
    return nil
  end
  file:write(text)
  file:close()
  local image = canvas.load_image(temp)
  os.remove(temp)
  return image
end

function BinaryDiffView:new(path, versions)
  BinaryDiffView.super.new(self, nil, false)
  self.defer_draw, self.scrollable = false, true
  self.name = common.basename(path) .. " - Binary Diff"
  self.versions, self.images, self.rows = versions, {}, {}
  for i, key in ipairs(SIDES) do
    self.images[i] = decode(versions[key], path)
  end
  self.parse_key = {}
  core.add_thread(function()
    local length = math.min(65536, math.max(#versions.before, #versions.after))
    for offset = 1, length, 16 do
      local row = {}
      for i, key in ipairs(SIDES) do
        local text, hex, ascii = versions[key]:sub(offset, offset + 15), {}, {}
        for index = 1, #text do
          local byte = text:byte(index)
          hex[#hex + 1] = string.format("%02x", byte)
          ascii[#ascii + 1] = byte >= 32 and byte < 127 and string.char(byte)
            or "."
        end
        row[i] = text == "" and "" or string.format(
          "%08x  %-47s  %s",
          offset - 1,
          table.concat(hex, " "),
          table.concat(ascii)
        )
      end
      self.rows[#self.rows + 1] = row
      if #self.rows % 100 == 0 then
        core.redraw = true
        coroutine.yield()
      end
    end
    core.redraw = true
  end, self.parse_key)
  self:show()
end

function BinaryDiffView:get_header_height()
  return style.font:get_height() + style.padding.y * 2
end

function BinaryDiffView:get_line_height()
  return style.code_font:get_height() + 4 * SCALE
end

function BinaryDiffView:get_hex_row_count()
  local bytes = 0
  if self.images then
    for i, key in ipairs(SIDES) do
      if not self.images[i] then bytes = math.max(bytes, #self.versions[key]) end
    end
  end
  return math.min(#(self.rows or {}), math.ceil(bytes / 16))
end

function BinaryDiffView:get_scrollable_size()
  local rows = self:get_hex_row_count()
  if rows == 0 then
    return self.size.y
  end
  local scrollbar = self:get_h_scrollable_size() > self.size.x
    and style.expanded_scrollbar_size or 0
  return math.max(self.size.y, self:get_header_height()
    + rows * self:get_line_height() + style.padding.y * 2 + scrollbar)
end

function BinaryDiffView:get_h_scrollable_size()
  if self:get_hex_row_count() == 0 then
    return self.size.x
  end
  return math.max(self.size.x,
    (style.code_font:get_width(string.rep("0", 75)) + style.padding.x * 2) * 2)
end

function BinaryDiffView:draw()
  if not BinaryDiffView.super.draw(self) then
    return false
  end
  local x, y, width, height =
    self.position.x, self.position.y, self.size.x, self.size.y
  local half, row = width / 2, self:get_line_height()
  local px, py = style.padding.x, style.padding.y
  local header = math.min(height, self:get_header_height())
  local scrollbar = self:get_h_scrollable_size() > width
    and style.expanded_scrollbar_size or 0
  local body_y = y + header
  local body_height = math.max(0, height - header - scrollbar)
  local rows = self:get_hex_row_count()
  core.push_clip_rect(x, y, width, height)
  for i, key in ipairs(SIDES) do
    local left, image = x + (i - 1) * half, self.images[i]
    core.push_clip_rect(left, y, half, header)
    renderer.draw_text(
      style.font,
      key:upper() .. "  " .. #self.versions[key] .. " bytes",
      left + px,
      y + py,
      style.text
    )
    core.pop_clip_rect()
    core.push_clip_rect(left, body_y, half, body_height)
    if image then
      local w, h = image:get_size()
      local factor = math.min(1,
        math.max(1, half - px * 2) / w,
        math.max(1, body_height - py * 2) / h)
      local sw, sh =
        math.max(1, math.floor(w * factor)), math.max(1, math.floor(h * factor))
      self.scaled = self.scaled or {}
      if not self.scaled[i]
        or self.scaled[i].width ~= sw or self.scaled[i].height ~= sh
      then
        self.scaled[i] = {
          width = sw, height = sh, image = image:scaled(sw, sh, "linear"),
        }
      end
      renderer.draw_canvas(
        self.scaled[i].image, left + (half - sw) / 2, body_y + py
      )
    else
      local offset = self.scroll.y - py
      local first = math.max(1, math.floor(offset / row) + 1)
      local last = math.min(rows, math.ceil((offset + body_height) / row))
      for index = first, last do
        local changed = self.rows[index][1] ~= self.rows[index][2]
        renderer.draw_text(
          style.code_font,
          self.rows[index][i],
          left + px - self.scroll.x / 2,
          body_y + (index - 1) * row - offset,
          changed and (i == 1 and style.diff_delete or style.diff_insert)
            or style.dim
        )
      end
    end
    core.pop_clip_rect()
  end
  renderer.draw_rect(x, body_y - 1, width, 1, style.divider)
  renderer.draw_rect(x + half, y, 1, height, style.divider)
  core.pop_clip_rect()
  self:draw_scrollbar()
  return true
end

function BinaryDiffView:try_close(close)
  if self.parse_key then
    core.threads[self.parse_key] = nil
  end
  close()
end

return BinaryDiffView
