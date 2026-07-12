-- Trivial LÖVE game used to prove the hermetic-couch pipeline end-to-end (offline).
function love.load()
  love.window.setTitle("hermetic-couch")
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.printf("hermetic-couch: hello from LÖVE 2D", 0, h / 2 - 10, w, "center")
  love.graphics.printf("press Esc to quit", 0, h / 2 + 14, w, "center")
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  end
end
