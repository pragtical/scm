local core = require "core"
local style = require "core.style"
local Node = require "core.node"
local EmptyView = require "core.emptyview"
local Widget = require "widget"
local Label = require "widget.label"
local Button = require "widget.button"

---@class plugins.scm.ui.BlameView : widget
---@field display "bottom"|"floating"
local BlameView = Widget:extend()

local function update_layout()
  local root = core.root_view
  Node.copy_position_and_size(root.root_node, root)
  root.root_node:update_layout()
end

---@param display? "bottom"|"floating"
function BlameView:new(display)
  self.display = display or "bottom"
  BlameView.super.new(self, nil, self.display == "floating")
  if self.display == "bottom" then self.border.width = 0 end
  self.header = Label(self, "")
  self.header.scrollable, self.header.clickable = true, true
  self.details = Label(self, "", true)
  self.details.scrollable, self.details.clickable = true, true
  self.copy = Button(self, "Copy Hash")
  self.copy.tooltip = "Copy this commit hash"
  self.copy.on_click = function()
    if self.commit then system.set_clipboard(self.commit) end
  end
  self.diff = Button(self, "View Diff")
  self.diff.tooltip = "Open this commit's changes"
  self.diff.on_click = function()
    local commit, project = self.commit, self.project_dir
    if not commit then return end
    if self.display == "floating" then
      self:on_floating_dismiss()
    else
      core.set_active_view(self.owner)
    end
    require("plugins.scm").open_commit_diff(commit, project)
  end
  for _, control in ipairs({ self.copy, self.diff }) do
    control.border.width = 0
    control.padding.x, control.padding.y = 6 * SCALE, 2 * SCALE
    control:set_label(control.label)
  end
  self.close = Button(self, "")
  self.close.border.width = 0
  self.close:toggle_background(false)
  self.close.padding.x, self.close.padding.y = 4 * SCALE, 0
  self.close:set_icon "X"
  self.close.tooltip = "Dismiss blame details"
  self.close.on_click = function()
    if self.display == "floating" then
      self:on_floating_dismiss()
    else
      self:hide()
      self:on_close()
    end
  end
  self.generation, self.cache, self.pending = 0, {}, {}
  self.cache_count = 0
  self.visible = false
end

function BlameView:on_close() end

function BlameView:hide()
  self.generation = self.generation + 1
  local root = core.root_view.root_node
  local node = root:get_node_for_view(self)
  if node then
    local active = core.active_view
    local owned = self:owns_view(active)
    local empty
    if self.owner and not root:get_node_for_view(self.owner) then
      local parent = node:get_parent_node(root)
      local sibling = parent and (parent.a == node and parent.b or parent.a)
      if sibling and sibling.type == "leaf"
        and sibling.active_view:is(EmptyView)
      then
        empty = sibling.active_view
      end
    end
    node:remove_view(root, self)
    -- The locked companion prevented the closed document's normal collapse.
    local empty_node = empty and root:get_node_for_view(empty)
    if empty_node and empty_node:get_parent_node(root) then
      empty_node:remove_view(root, empty)
    end
    if active and not owned and active ~= empty then
      core.set_active_view(active)
    end
    update_layout()
  end
  BlameView.super.hide(self)
end

function BlameView:attach(owner)
  local root = core.root_view.root_node
  local node = root:get_node_for_view(self)
  local owner_node = root:get_node_for_view(owner)
  if not owner_node or owner_node.locked then return false end
  if node then
    local parent = node:get_parent_node(root)
    if parent and parent.type == "vsplit" and parent.a == owner_node then
      return true
    end
    self:hide()
    owner_node = root:get_node_for_view(owner)
  end
  self:show()
  self.size.y = self.target_height and self.target_height * SCALE
    or style.font:get_height() * 5 + style.padding.y * 2
  owner_node:split("down", self, { y = true }, true)
  update_layout()
  self:fit_height()
  update_layout()
  local line, col = owner.doc:get_selection()
  owner:scroll_to_make_visible(line, col)
  return true
end

function BlameView:fit_height()
  local root = core.root_view.root_node
  local node = root:get_node_for_view(self)
  local parent = node and node:get_parent_node(root)
  if parent then
    local wanted = self.target_height and self.target_height * SCALE
      or style.font:get_height() * 5 + style.padding.y * 2
    self.size.y = math.min(wanted, math.max(0, parent.size.y / 2))
  end
end

function BlameView:set_target_size(axis, value)
  if self.display == "bottom" and axis == "y" then
    local minimum = style.font:get_height() * 2
      + self.copy:get_height() + style.padding.x * 2
    self.target_height = math.max(minimum, value) / SCALE
    self:fit_height()
    return true
  end
  return BlameView.super.set_target_size(self, axis, value)
end

function BlameView:present(owner, backend, project, info, line, col)
  local commit = info and info.commit
  if commit and commit:match "^0+$" then commit = nil end
  if not commit and self.display == "floating" then
    self:hide()
    return
  end
  local key = project .. "\0" .. (commit or "uncommitted")
  self.anchor_line, self.anchor_col = line, col
  if owner == self.dismissed_owner and key == self.dismissed_key then
    return
  end
  if
    owner == self.owner
    and key == self.current_key
    and self.visible
  then
    if self.display == "bottom" then self:attach(owner) end
    return
  end
  if self.display == "bottom" and not self:attach(owner) then return end
  self.owner, self.commit, self.project_dir = owner, commit, project
  self.current_key = key
  self.generation = self.generation + 1
  local generation = self.generation
  self.header:set_label({
    style.accent,
    commit and commit:sub(1, 12) or "Uncommitted changes",
    "  ",
    style.dim,
    info and info.date or "",
    self.display == "floating" and Widget.NEWLINE or "  ",
    style.dim,
    info and info.author or "",
  })
  self.header.tooltip = commit
  self.copy.visible, self.diff.visible = commit ~= nil, commit ~= nil
  local function show_message(text)
    if generation ~= self.generation then
      return
    end
    self.message = text:sub(1, 16384):gsub("\n+$", "")
    self.details:set_label(self.message)
    self:update_size_position()
    core.redraw = true
  end
  self.show_message = show_message
  show_message(commit and (info.summary or "Loading commit details...")
    or "This line has no committed history.")
  if self.display == "floating" then self:set_floating(true, {
    owner = owner,
    focus = "click",
    interactive = true,
    dismiss_on_escape = true,
    dismiss_on_outside_click = true,
    dismiss_on_owner_click = true,
    consume_outside_click = false,
    anchor = {
      side = "bottom",
      align = "start",
      gap = 4 * SCALE,
      target = function()
        if not owner.doc or self.anchor_line > #owner.doc.lines then
          return nil
        end
        local x, y =
          owner:get_line_screen_position(self.anchor_line, self.anchor_col)
        return { x = x, y = y, w = 1, h = owner:get_line_height() }
      end,
    },
  }) end
  self:show()
  self:update_size_position()
  if not commit then return end
  local cache_key = key
  if self.cache[cache_key] then
    show_message(self.cache[cache_key])
    return
  end
  if self.pending[cache_key] then return end
  self.pending[cache_key] = true
  backend:get_commit_info(commit, project, function(details)
    self.pending[cache_key] = nil
    local message = "Commit details are unavailable."
    if details then
      message = details.summary or ""
      if details.message and details.message ~= "" then
        message = message ~= "" and message .. "\n\n" .. details.message
          or details.message
      end
    end
    if self.cache_count >= 64 then
      self.cache, self.cache_count = {}, 0
    end
    self.cache[cache_key], self.cache_count = message, self.cache_count + 1
    if self.visible and self.current_key == cache_key then
      self.show_message(message)
    end
  end)
end

function BlameView:on_floating_dismiss()
  self.dismissed_key = self.current_key
  self.dismissed_owner = self.owner
  self.generation = self.generation + 1
  self:hide()
end

function BlameView:update()
  if not BlameView.super.update(self) then
    return false
  end
  self:update_size_position()
  return true
end

function BlameView:update_size_position()
  local pad, row = style.padding.x, style.font:get_height()
  if self.display == "floating" then
    local width = math.min(460 * SCALE, core.root_view.size.x - pad * 2)
    local border = self.border.width * 2
    self.details:set_size(math.max(0, width - border - pad), 1)
    self.details:wrap_text()
    local _, text_height = self.details:get_content_size()
    local limit = math.max(row, math.floor(96 * SCALE / row) * row)
    local height = row * 2 + pad * 2 + border
      + math.min(limit, text_height) + self.copy:get_height()
    self:set_size(width, math.min(height, core.root_view.size.y - 40 * SCALE))
  else
    self:fit_height()
  end
  self.close:set_position(
    self.size.x - self.close:get_width() - pad / 2,
    pad / 2
  )
  self.header:set_position(pad / 2, pad / 2)
  self.header:set_size(
    math.max(0, self.size.x - pad * 2 - self.close:get_width()),
    row * (self.display == "floating" and 2 or 1)
  )
  self.copy:set_position(
    pad / 2,
    self.size.y - self.copy:get_height() - pad / 2
  )
  self.diff:set_position(self.copy:get_right() + pad / 2, self.copy.position.ry)
  self.details:set_position(pad / 2, self.header:get_height() + pad)
  self.details:set_size(
    self.size.x - pad,
    math.max(0, self.copy.position.ry - self.details.position.ry - pad / 2)
  )
  self.details:wrap_text()
end

return BlameView
