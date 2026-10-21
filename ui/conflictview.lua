local core = require "core"
local style = require "core.style"
local DocView = require "core.docview"
local Widget = require "widget"
local Button = require "widget.button"
local SelectBox = require "widget.selectbox"
local MessageBox = require "widget.messagebox"
local DiffPreview = require "plugins.scm.ui.diffpreview"
local conflicts = require "plugins.scm.conflicts"

---@class plugins.scm.ui.ConflictView : core.docview
local ConflictView = DocView:extend()

function ConflictView:new(path, directory, backend, versions)
  ConflictView.super.new(self, core.open_doc(path))
  self.project_dir, self.backend = directory, backend
  self.toolbar = Widget(nil, false)
  self.toolbar.border.width = 0
  self.toolbar.defer_draw = false
  self.toolbar:show()
  self.controls, self.sources, self.current = {}, {}, 1
  local function add(label, fn)
    local control = Button(self.toolbar, label)
    control.on_click = fn
    self.controls[#self.controls + 1] = control
  end
  add("<", function()
    self:next_conflict(-1)
  end)
  add(">", function()
    self:next_conflict(1)
  end)
  for _, choice in ipairs({ "ours", "theirs", "both", "base" }) do
    add("Use " .. choice, function()
      self:resolve(choice)
    end)
  end
  add("Save / Resolve", function()
    self:mark_resolved()
  end)
  self.source_selector = SelectBox(self.toolbar, "Source")
  for _, name in ipairs({ "BASE", "OURS", "THEIRS" }) do
    self.source_selector:add_option(name, name)
  end
  self.source_selector:set_selected(2)
  for _, name in ipairs({ "base", "ours", "theirs" }) do
    local preview = DiffPreview(self.toolbar)
    local text = versions and versions[name] or ""
    local lines = {}
    for line in (text .. "\n"):gmatch "([^\n]*)\n" do
      lines[#lines + 1] = " " .. line
    end
    preview:set_diff(
      "Index: "
        .. name:upper()
        .. "\n@@ -1 +1 @@\n"
        .. table.concat(lines, "\n")
        .. "\n",
      path
    )
    self.sources[#self.sources + 1] = preview
  end
  self:next_conflict(0)
end

function ConflictView:get_name()
  return "Resolve: " .. ConflictView.super.get_name(self)
end

function ConflictView:get_content_offset()
  local x, y = ConflictView.super.get_content_offset(self)
  return x, y + (self.header_height or 0)
end

function ConflictView:get_scrollable_size()
  return ConflictView.super.get_scrollable_size(self)
    + (self.header_height or 0)
end

function ConflictView:next_conflict(direction)
  local blocks = conflicts.parse(self.doc.lines)
  self.current = math.max(1, math.min(#blocks, self.current + direction))
  if blocks[self.current] then
    self.doc:set_selection(blocks[self.current].first, 1)
    self:scroll_to_line(blocks[self.current].first, false, true)
  end
end

function ConflictView:resolve(choice)
  local blocks = conflicts.parse(self.doc.lines)
  local block = blocks[self.current]
  if not block then
    return
  end
  if choice == "base" and not block.has_base then
    MessageBox.error(
      "SCM Resolve",
      "This block has no base section. "
        .. "Inspect the base pane and edit the result manually."
    )
    return
  end
  local last, col = block.last + 1, 1
  if last > #self.doc.lines then
    last, col = block.last, #self.doc.lines[block.last]
  end
  self.doc:replace_cursor(1, block.first, 1, last, col, function()
    return conflicts.text(block, choice)
  end)
  self.doc:set_selection(block.first, 1)
  self.current = math.min(self.current, math.max(1, #blocks - 1))
  self:next_conflict(0)
end

function ConflictView:mark_resolved()
  if conflicts.has_markers(self.doc.lines) then
    MessageBox.error("SCM Resolve", "Resolve every conflict block first.")
    return
  end
  self.doc:save()
  if self.backend:has_staging() then
    self.backend:stage_file(
      self.doc.abs_filename,
      self.project_dir,
      function(ok, errmsg)
        if not ok then
          MessageBox.error("SCM Resolve", errmsg)
        end
        require("plugins.scm").update()
      end
    )
  else
    require("plugins.scm").update()
  end
end

function ConflictView:update()
  ConflictView.super.update(self)
  local row, gap = style.font:get_height() + 20 * SCALE, 6 * SCALE
  local x, y = 0, 0
  self.toolbar.position.x, self.toolbar.position.y =
    self.position.x, self.position.y
  self.toolbar.size.x = self.size.x
  for _, control in ipairs(self.controls) do
    if x + control:get_width() > self.size.x then
      x, y = 0, y + row
    end
    control:set_position(x, y)
    x = x + control:get_width() + gap
  end
  local sources_y = y + row
  local narrow = self.size.x < 650 * SCALE
  self.source_selector.visible = narrow
  if narrow then
    self.source_selector:set_position(0, sources_y)
    self.source_selector:set_size(math.min(220 * SCALE, self.size.x), row)
    sources_y = sources_y + row
  end
  local height = math.max(60 * SCALE, math.min(140 * SCALE, self.size.y * 0.25))
  for i, source in ipairs(self.sources) do
    source.visible = not narrow or i == self.source_selector:get_selected()
    source:set_position(narrow and 0 or (i - 1) * self.size.x / 3, sources_y)
    source:set_size(narrow and self.size.x or self.size.x / 3 - gap, height)
  end
  self.header_height = sources_y + height + gap
  self.toolbar.size.y = self.header_height
  self.toolbar:update()
end

function ConflictView:draw()
  core.push_clip_rect(
    self.position.x,
    self.position.y + (self.header_height or 0),
    self.size.x,
    math.max(0, self.size.y - (self.header_height or 0))
  )
  ConflictView.super.draw(self)
  core.pop_clip_rect()
  self.toolbar:draw()
end

function ConflictView:on_mouse_pressed(button, x, y, clicks)
  if y < self.position.y + (self.header_height or 0) then
    return self.toolbar:on_mouse_pressed(button, x, y, clicks)
  end
  return ConflictView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function ConflictView:on_mouse_released(...)
  if self.toolbar:on_mouse_released(...) then
    return true
  end
  return ConflictView.super.on_mouse_released(self, ...)
end

function ConflictView:on_mouse_moved(x, y, dx, dy)
  self.header_hovered = y < self.position.y + (self.header_height or 0)
  self.toolbar:on_mouse_moved(x, y, dx, dy)
  if not self.header_hovered then
    return ConflictView.super.on_mouse_moved(self, x, y, dx, dy)
  end
end

function ConflictView:on_mouse_wheel(y, x)
  if self.header_hovered then
    return self.toolbar:on_mouse_wheel(y, x)
  end
  return ConflictView.super.on_mouse_wheel(self, y, x)
end

function ConflictView:try_close(close)
  ConflictView.super.try_close(self, function()
    for _, source in ipairs(self.sources) do
      core.threads[source.parse_key] = nil
    end
    close()
  end)
end

return ConflictView
