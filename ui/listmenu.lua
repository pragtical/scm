---Bind a list's menu so a second right-click can select a different row,
---including when the floating menu overlaps that row.
return function(menu)
  local pressed = menu.on_mouse_pressed
  menu.on_mouse_pressed = function(self, button, x, y, clicks)
    local source = self.source_view
    if
      button == "right"
      and self.show_context_menu
      and source
      and source.list
      and source.list:mouse_on_top(x, y)
    then
      local row = source.list:get_row_at_position(x, y)
      if row then
        self:hide()
        source.list:set_selected(row)
        return self:show(x, y)
      end
    end
    return pressed(self, button, x, y, clicks)
  end
end
