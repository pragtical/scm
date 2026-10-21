---Coordinate complete multi-project scans and coalesce newer requests.
local Scanner = {}
Scanner.__index = Scanner

function Scanner.new()
  return setmetatable({ running = false }, Scanner)
end

function Scanner:request(jobs, run, finished)
  if self.running then
    self.queued = { jobs, run, finished }
    return
  end
  self.running, self.pending = true, #jobs
  local function finish()
    if finished then
      finished()
    end
    self.running = false
    local queued = self.queued
    self.queued = nil
    if queued then
      self:request(table.unpack(queued))
    end
  end
  if #jobs == 0 then
    finish()
    return
  end
  for _, job in ipairs(jobs) do
    local complete = false
    run(job, function()
      if complete then
        return
      end
      complete = true
      self.pending = self.pending - 1
      if self.pending == 0 then
        finish()
      end
    end)
  end
end

return Scanner
