local core = require "core"
local style = require "core.style"
local Widget = require "widget"
local Label = require "widget.label"
local ListBox = require "widget.listbox"
local TextBox = require "widget.textbox"
local SelectBox = require "widget.selectbox"
local CheckBox = require "widget.checkbox"
local Button = require "widget.button"
local DiffPreview = require "plugins.scm.ui.diffpreview"
local CommitDetails = require "plugins.scm.ui.commitdetails"
local review = require "plugins.scm.review"

---Read-only comparison with file navigation and session-local review progress.
---@class plugins.scm.ui.DiffView : widget
local DiffView = Widget:extend()

local status_labels = {
  added = "Added", deleted = "Deleted", renamed = "Renamed",
  copied = "Copied", mode_changed = "Mode changed",
  type_changed = "Type changed",
}

local function change_summary(file)
  local parts = {}
  if status_labels[file.status] then
    parts[#parts + 1] = status_labels[file.status]
  end
  if file.binary then
    parts[#parts + 1] = "Binary"
  end
  if file.inserts + file.deletes > 0 or #parts == 0 then
    parts[#parts + 1] = "+" .. file.inserts .. " -" .. file.deletes
  end
  return table.concat(parts, ", ")
end

---@param title string
---@param text string
---@param project_dir? string
---@param commit? plugins.scm.backend.commit
function DiffView:new(title, text, project_dir, commit)
  DiffView.super.new(self, nil, false)
  self.defer_draw, self.border.width = false, 0
  self.name, self.text, self.project_dir =
    title or "Changes", text or "", project_dir
  self.files, self.parse_key, self.filter_key, self.generation = {}, {}, {}, 0
  self.commit_details = CommitDetails(self)
  self.commit_details:set_commit(commit)
  self.search = TextBox(self, "", "Filter changed files...")
  self.search.on_change = function()
    self:filter(true)
  end
  self.file_filter = SelectBox(self, "Files")
  self.file_filter:add_option("All Files", "all")
  self.file_filter:add_option("Unreviewed", "unreviewed")
  self.file_filter:add_option("Viewed", "viewed")
  self.file_filter:add_option("Binary", "binary")
  self.file_filter:set_selected(1)
  self.file_filter.on_selected = function()
    self:filter()
  end
  self.file_selector = SelectBox(self, "Changed files")
  self.file_selector.on_selected = function(_, _, file) self:select(file) end
  self.container = Widget(self)
  self.container.border.width = 0
  self.list = ListBox(self.container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list.on_row_click = function(_, _, file)
    self:select(file)
  end
  self.preview = DiffPreview(self)
  self.filename = Label(self, "Loading changes...")
  self.filename.scrollable = true
  self.progress = Label(self, "")
  self.mode = SelectBox(self, "Diff layout")
  self.mode:add_option("Unified", false)
  self.mode:add_option("Side by Side", true)
  self.mode:set_selected(1)
  self.mode.on_selected = function(_, _, split)
    self.preview.side_by_side = split
    core.redraw = true
  end
  self.viewed = CheckBox(self, "Viewed")
  self.viewed.on_checked = function(_, checked)
    if self.selected then
      self.selected.viewed = checked
    end
    self:update_progress()
    if self.file_filter:get_selected_data() ~= "all" then
      self:filter()
    end
  end
  self.next = Button(self, "Next Unreviewed")
  self.next.on_click = function()
    self:next_unreviewed()
  end
  self.raw = Button(self, "View Text")
  self.raw.on_click = function()
    local ReadDocView = require "plugins.scm.ui.readdocview"
    core.root_view
      :get_active_node_default()
      :add_view(ReadDocView(self.name, self:get_text_diff()))
  end
  self:show()
  if #self.text > 16 * 1024 * 1024 then
    self.preview:set_message "Diff exceeds the 16 MiB preview limit"
    self.filename:set_label "Large comparison"
    return
  end
  core.add_thread(function()
    local generation = self.generation
    local parsed = review.diff(self.text, function()
      coroutine.yield()
    end)
    if self.generation ~= generation then
      return
    end
    for i, file in ipairs(parsed.files) do
      self.files[#self.files + 1] = {
        path = file.path or file.old_path or ("File " .. i),
        start = file.start,
        finish = file.finish,
        inserts = file.inserts,
        deletes = file.deletes,
        binary = file.binary,
        status = file.status,
      }
      if i % 100 == 0 then
        coroutine.yield()
      end
      if self.generation ~= generation then
        return
      end
    end
    if #self.files == 0 and self.text ~= "" then
      self.files[1] = {
        path = "Changes",
        start = 1,
        finish = #self.text,
        inserts = parsed.inserts,
        deletes = parsed.deletes,
      }
    end
    self:filter()
  end, self.parse_key)
end

function DiffView:get_text_diff()
  local header = CommitDetails.text(self.commit_details.commit)
  return header ~= "" and header .. "\n\n" .. self.text or self.text
end

function DiffView:filter(debounce)
  self.filter_generation = (self.filter_generation or 0) + 1
  local generation = self.filter_generation
  core.add_thread(function()
    if debounce then
      coroutine.yield(0.1)
    end
    if self.filter_generation ~= generation then
      return
    end
    local selected = self.selected
    self.list:filter(nil)
    self.list:clear()
    self.list.columns = {}
    self.list:add_column "File"
    self.list:add_column "Changes"
    self.file_selector.list:clear()
    self.file_selector:set_label "Changed files"
    local selection
    local query = self.search:get_text():lower()
    local mode = self.file_filter:get_selected_data()
    for i, file in ipairs(self.files) do
      local include = mode == "all"
        or mode == "viewed" and file.viewed
        or mode == "unreviewed" and not file.viewed
        or mode == "binary" and file.binary
      if include and file.path:lower():find(query, 1, true) then
        self.list:add_row({
          file.path,
          ListBox.COLEND,
          change_summary(file),
        }, file)
        self.file_selector:add_option(
          file.path .. "  (" .. change_summary(file) .. ")", file
        )
        core.redraw = true
        if file == selected then
          selection = #self.list.rows
        end
      end
      if i % 100 == 0 then
        coroutine.yield()
      end
      if self.filter_generation ~= generation then
        return
      end
    end
    self.list:set_selected(selection or (#self.list.rows > 0 and 1 or nil))
    self:select(self.list:get_row_data(self.list:get_selected() or 0))
    self:update_progress()
  end, self.filter_key)
end

function DiffView:select(file)
  self.selected = file
  local selected
  for i = 1, #self.list.rows do
    if self.list:get_row_data(i) == file then selected = i break end
  end
  self.list:set_selected(selected)
  self.file_selector:set_selected(selected or 0)
  self.viewed:set_checked(file and file.viewed == true or false)
  self.filename:set_label(file and file.path or "No matching files")
  if file then
    self.preview:set_diff(self.text:sub(file.start, file.finish), file.path)
  else
    self.preview:set_message "No matching files"
  end
  core.redraw = true
end

function DiffView:update_progress()
  local viewed = 0
  for _, file in ipairs(self.files) do
    if file.viewed then
      viewed = viewed + 1
    end
  end
  self.progress:set_label(viewed .. " / " .. #self.files .. " files viewed")
  core.redraw = true
end

function DiffView:next_unreviewed()
  local count, selected = #self.list.rows, self.list:get_selected() or 0
  for offset = 1, count do
    local index = (selected + offset - 1) % count + 1
    local file = self.list:get_row_data(index)
    if not file.viewed then
      self.list:set_selected(index)
      self:select(file)
      return
    end
  end
end

function DiffView:update()
  if not DiffView.super.update(self) then
    return false
  end
  local width, height = self.size.x, self.size.y
  local pad, row = style.padding.x, style.font:get_height() + 14 * SCALE
  local narrow = width < 700 * SCALE
  local sidebar = narrow and width or math.min(340 * SCALE, width * 0.3)
  local header = self.commit_details:layout(
    pad / 2, pad / 2, width - pad, math.min(220 * SCALE, height * 0.3)
  )
  local offset = header > 0 and header + pad or 0
  local list_bottom = height - row
  self.search:set_position(pad / 2, offset + pad / 2)
  self.search:set_size(narrow and (width - pad * 1.5) * 0.6
    or sidebar - pad, row)
  local filter_x = narrow
    and self.search.position.rx + self.search:get_width() + pad / 2
    or pad / 2
  self.file_filter:set_position(filter_x,
    narrow and offset + pad / 2 or offset + row + pad)
  self.file_filter:set_size(
    narrow and width - filter_x - pad / 2 or sidebar - pad, row
  )
  self.container.visible = not narrow
  self.file_selector.visible = narrow
  self.file_selector:set_position(pad / 2, offset + row + pad)
  self.file_selector:set_size(width - pad, row)
  self.container:set_position(pad / 2, offset + row * 2 + pad * 1.5)
  self.container:set_size(
    sidebar - pad,
    math.max(1, list_bottom - offset - row * 2 - pad * 2)
  )
  if not narrow then self.list:resize_to_parent() end
  self.progress:set_position(pad / 2, height - row)
  self.progress:set_size(width - pad, row)
  local left, top =
    narrow and pad / 2 or sidebar,
    narrow and offset + row * 2 + pad * 1.5 or offset + pad / 2
  local available = width - left - pad / 2
  self.filename.visible = not narrow
  self.filename:set_position(left, top)
  self.filename:set_size(available, row)
  local x, y = left, narrow and top or top + row
  self.mode:set_size(math.min(160 * SCALE, available), row)
  for _, control in ipairs({ self.mode, self.viewed, self.next, self.raw }) do
    control.visible = control == self.mode
      or control == self.raw
      or self.selected ~= nil
    if control.visible then
      if x > left and x + control:get_width() > left + available then
        x, y = left, y + row + pad / 2
      end
      control:set_position(x, y)
      x = x + control:get_width() + pad / 2
    end
  end
  self.preview:set_position(left, y + row + pad / 2)
  self.preview:set_size(
    available,
    math.max(1, height - self.preview.position.ry - row - pad / 2)
  )
  return true
end

function DiffView:try_close(close)
  self.generation = self.generation + 1
  self.filter_generation = (self.filter_generation or 0) + 1
  core.threads[self.filter_key] = nil
  core.threads[self.parse_key], core.threads[self.preview.parse_key] = nil, nil
  close()
end

return DiffView
