package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")

-- namespace UseGateOrder
UseGateOrder = {}
UseGateOrder.mapPaths = {}
UseGateOrder.updating = false

if onClient() then
  include("data/scripts/player/map/mapcommands")
  include("data/scripts/entity/orderchain")
  local Azimuth = include("azimuthlib-basic")
  local str = tostring

  local map, player
  local mapQueue = {}
  local mapMsLimit = 30 -- timelimit for integrating updated mapdata, includes the clientUpdate delta

  local wndUseGate, lastCoords, lastPos
  local gateTable = {}
  local colors = {
    known = ColorARGB(0.7, 0.4, 0.8, 0.4),
    unknown = ColorARGB(0.7, 0.9, 0.7, 0.5),
    wormhole = ColorARGB(0.7, 0.4, 0.4, 0.8),
  }

  local wndPathFinding, cntArrows, pfFrom, pfTo, pfShips, pfJumpRange, pfResult, pfSelected, pfBtnTable
  local jumpRange = 35

  MapCommands.registerModdedMapCommand(OrderType.FlyThroughGate, {
    tooltip = "Use Gate"%_t,
    icon = "data/textures/icons/plasma-cell.png",
    callback = "onFlyThroughGatePressed",
    shouldHideCallback = "hideUseGate",
  }) -- these are registered in MapCommands' scope so they will need that namespace

  -- MapCommands.registerModdedMapCommand(OrderType.PathFinding, {
  --   tooltip = "Path Finding"%_t,
  --   icon = "data/textures/icons/semi-conductor.png",
  --   callback = "onPathFindingPressed",
  --   -- shouldHideCallback = "hidePathFinding",
  -- })


  --== init and general stuff ==--
  function UseGateOrder.initialize()
    local res = getResolution()
    local size = vec2(640, 140)
    player = Player()
    map = GalaxyMap()

    -- player:registerCallback("onShowGalaxyMap", "onShowGalaxyMap")
    player:registerCallback("onHideGalaxyMap", "onHideGalaxyMap")
    player:registerCallback("onKnownSectorAdded", "onKnownSectorAdded")
    player:registerCallback("onGalaxyMapMouseUp", "onGalaxyMapMouseUp")
    -- player:registerCallback("onSelectMapCoordinates", "onSelectMapCoordinates")
    player:registerCallback("onMapRenderAfterLayers", "onMapRenderAfterLayers")

    wndUseGate = map:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    -- wndUseGate.position = vec2(wndUseGate.position.x, wndUseGate.position.y + res.y / 4)
    -- wndUseGate.caption = "Fly through Gate /* Order Window Caption Use Gate */"%_t
    wndUseGate.showCloseButton = 1
    wndUseGate.closeableWithEscape = 1
    -- wndUseGate.moveable = 1

    size.x = 400
    size.y = 240
    wndPathFinding = map:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    wndPathFinding.position = vec2(res.x - wndPathFinding.size.x, res.y - wndPathFinding.size.y)
    wndPathFinding.showCloseButton = 1
    wndPathFinding.closeableWithEscape = 1
    -- wndPathFinding.moveable = 1
    cntArrows = map:createContainer()

    MapCommands.addWindow(wndUseGate)
    MapCommands.addWindow(wndPathFinding)
    MapCommands.hideWindows()

    -- updatePaths()
    UseGateOrder.asyncMapUpdate()
  end

  function UseGateOrder.onHideGalaxyMap()
    MapCommands.unlockWindow(wndPathFinding)
    MapCommands.hideWindows()
    cntArrows:clear()
    pfResult = {}
  end

  -- TODO remove? --
  function UseGateOrder.onSelectMapCoordinates()
  end

  function UseGateOrder.onGalaxyMapMouseUp(btn, srcX, srcY, secX, secY, moved)
    if btn == 2 and player:knowsSector(secX, secY) then -- middle mouse button
      MapCommands.onPathFindingPressed()
      if not wndPathFinding.visible then return end

      pfTo = ivec2(secX, secY)
      wndPathFinding.caption = "${x1} : ${y1}  >  ${x2} : ${y2}" % {
        x1 = pfFrom.x, y1 = pfFrom.y, x2 = pfTo.x, y2 = pfTo.y }
      UseGateOrder.findPathTo(pfFrom, pfTo, pfJumpRange)
    end
  end

  function UseGateOrder.onMapRenderAfterLayers()
    if wndUseGate.visible then
      if #MapCommands.getSelectedPortraits() < 1 then
        wndUseGate:hide()

      -- check if the chain mode (overwrite or enchain) changed or if the map was moved
      -- to minimize the update calls to this
      elseif enqueueNextOrder ~= MapCommands.isEnqueueing() or
      lastPos ~= ivec2(map:getCoordinatesScreenPosition(ivec2(lastCoords.x, lastCoords.y))) then
        if MapCommands.hideUseGate() then
          wndUseGate:hide()
        else
          MapCommands.onFlyThroughGatePressed()
        end

      end
    end

    if pfResult and pfResult[1] and not wndPathFinding.visible then
      cntArrows:clear()
      pfResult = {}
    end

    -- if pfResult and pfResult[1] and wndPathFinding.visible then
    --   local hover = ivec2(map:getHoveredCoordinates())
    --   if hover ~= lastCoords then
    --     lastCoords = hover
    --     local sHov = str(hover)
    --     if pfResult[1][sHov] then
    --       local hov = pfResult[1][sHov]
    --       wndPathFinding.caption = sHov.." / G: ${g} / J: ${j}" % { g = hov.gate or "#", j = hov.jump or "#" }
    --       -- cntArrows:clear()
    --       -- for sxy, path in pairs(pfResult[sHov]) do
    --         -- if type(path) ~= "number" then
    --           -- local arr = cntArrows:createMapArrowLine()
    --           -- arr.from = hover
    --           -- arr.to = path.vec
    --         -- end
    --       -- end
    --     end
    --   end
    -- end
  end


  --== Map Update ==--
  function UseGateOrder.asyncMapUpdate(range) -- async --
    if UseGateOrder.updating then return end

    local code = [[
    include("data/scripts/player/map/mapcommands")
    include("data/scripts/player/use_gate_order")

    local str = tostring
    local paths = {}

    function distance(vFrom, vTo)
      local dx = vTo.x - vFrom.x
      local dy = vTo.y - vFrom.y
      return math.sqrt(dx * dx + dy * dy)
    end

    function findNearbySectors(sector, range)
      if not (sector and sector.x and sector.y) then eprint("[fNS]: no sector given") return end
      if not range then eprint("[fNS]: no range given") return end
      sector = ivec2(sector.x, sector.y)

      local result = {}
      for y = -range, range do
        for x = -range, range do
          local sec = sector - ivec2(x, y)
          local dist = distance(sector, sec)
          if dist > 0 and dist <= range and paths[str(sec)] then
            table.insert(result, { vec = sec, dist = dist })
          end
        end
      end

      table.sort(result, function(a,b) return a.dist < b.dist end)
      return next(result) and result or nil
    end

    function run(player, range)
      range = range and range > 0 and range or 25
      local start = appTimeMs()
      local count = 0
      local next = next

      local sectors = { player:getKnownSectors() }
      for _, sec in ipairs(sectors) do -- sec.note
        if sec.visited then
          local xy = ivec2(sec:getCoordinates())
          local sxy = str(xy)
          if not paths[sxy] then
            local gates = {}
            for i, dest in ipairs({ sec:getGateDestinations() }) do
              if player:knowsSector(dest.x, dest.y) then
                gates[str(dest)] = { vec = dest, dist = distance(xy, dest) }
              end
            end
            for i, dest in ipairs({ sec:getWormHoleDestinations() }) do
              -- only add wormholes if the destination is known
              if player:knowsSector(dest.x, dest.y) then
                gates[str(dest)] = { vec = dest, dist = distance(xy, dest), isWormhole = true }
              end
            end

            paths[sxy] = { vec = xy, gates = gates }
            count = count + 1
          end
        end
      end

      for sxy, sector in pairs(paths) do
        -- if not next(sector.gates) then
        -- paths[sxy] = nil
        -- else
        paths[sxy].nearby = findNearbySectors(sector.vec, range)
        -- end
      end

      return paths, count, appTimeMs() - start
    end
    ]]

    UseGateOrder.updating = true
    async("onPathUpdateDone", code, Player(), range and range > 0 and range or jumpRange)
  end

  function UseGateOrder.updateSector(sx, sy, range)
    if not sy then
      sy = sx.y
      sx = sx.x
    end
    range = range and range > 0 and range or jumpRange

    local vec = ivec2(sx,sy)
    local sec = player:getKnownSector(sx,sy)
    if sec.visited then
      local sxy = str(vec)
      local result = { vec = vec, gates = {} }

      for i, dest in ipairs({ sec:getGateDestinations() }) do
        result.gates[str(dest)] = { vec = dest, dist = distance(vec, dest) }
      end
      for i, dest in ipairs({ sec:getWormHoleDestinations() }) do
        -- only add wormholes if the destination is known
        if player:knowsSector(dest.x, dest.y) then
          result.gates[str(dest)] = { vec = dest, dist = distance(vec, dest), isWormhole = true }
        end
      end

      -- only find nearby sectors and finally add this sector if it even has gates and/or wormholes
      if next(result.gates) then
        local nearby = {}
        for y = -range, range do
          for x = -range, range do
            local sec = vec - ivec2(x, y)
            local dist = distance(vec, sec)
            if dist > 0 and dist <= range and player:knowsSector(sec.x, sec.y) then
              table.insert(nearby, { vec = sec, dist = dist })
            end
          end
        end

        table.sort(nearby, function(a,b) return a.dist < b.dist end)
        result.nearby = nearby

        UseGateOrder.mapPaths[sxy] = result
      end
    end
  end

  -- add the found map data iteratively instead of just overwriting it
  -- I'm pretty sure there was a reason for doing it this way...
  function UseGateOrder.onPathUpdateDone(paths, count, duration)
    mapQueue = paths
    print("path update took ${t} ms for ${c} sectors" % { t = duration, c = count })
  end

  function UseGateOrder.updateClient(delta)
    if not UseGateOrder.updating or not next(mapQueue) then return end
    delta = delta * 1000

    local start = appTimeMs()
    local duration
    local count = 0
    local minCount = 100

    for sxy, sector in pairs(mapQueue) do
      UseGateOrder.mapPaths[sxy] = sector
      mapQueue[sxy] = nil
      count = count + 1
      duration = delta + (appTimeMs() - start)
      if duration >= mapMsLimit and count >= minCount then
        print("delta exceeded:", delta, duration, count)
        return
      end
    end

    print("delta", delta, duration, count)
    UseGateOrder.updating = false
    async("", [[
      function run(map_paths)
        include("data/scripts/lib/azimuthlib-basic").saveConfig("Map_Paths", map_paths, _, true)
      end
      ]], UseGateOrder.mapPaths)
  end

  function UseGateOrder.onKnownSectorAdded(x, y)
    local vec = ivec2(x, y)
    local known = player:getKnownSector(x, y)
    if known.visited and not UseGateOrder.mapPaths[str(vec)] and #{known:getGateDestinations()} > 0 then
      print("updating sector "..str(vec))
      UseGateOrder.updateSector(x, y)
      -- UseGateOrder.mapPaths[str(vec)] = { vec = vec }
      -- UseGateOrder.asyncMapUpdate()
    end
  end


  --== Path Finder ==--
  function MapCommands.onPathFindingPressed() -- these are registered in MapCommands' scope so they need that namespace
    enqueueNextOrder = MapCommands.isEnqueueing()
    wndPathFinding:clear()
    cntArrows:clear()

    pfShips = MapCommands.getSelectedPortraits() -- .info.chain / .coordinates
    if #pfShips < 1 then
      MapCommands.unlockWindow(wndPathFinding)
      wndPathFinding:hide()
      return
    end

    pfFrom = pfShips[1] and pfShips[1].coordinates
    for _, ship in ipairs(pfShips) do
      if ship.owner == player.index then
        pfJumpRange = player:getShipHyperspaceReach(ship.name)
        -- canPassRifts = canPassRifts and player:getShipCanPassRifts(ship.name)
      elseif player.alliance then
        pfJumpRange = player.alliance:getShipHyperspaceReach(ship.name)
        -- canPassRifts = canPassRifts and alliance:getShipCanPassRifts(ship.name)
      end
    end

    if enqueueNextOrder then
      -- printTable(pfShips)
      local chain = pfShips[1].info.chain
      pfFrom = ivec2(chain[#chain].x, chain[#chain].y)
    end

    MapCommands.hideWindows()
    MapCommands.lockWindow(wndPathFinding)
    wndPathFinding:show()
    wndPathFinding.caption = "Path from ${x} : ${y}  >  ?" % { x = pfFrom.x, y = pfFrom.y }
  end

  function UseGateOrder.findPathTo(vFrom, vTo, range) -- async --
    pfResult = nil
    if not (vFrom and vFrom.x and vFrom.y and vTo and vTo.x and vTo.y) then return false end
    vFrom = ivec2(vFrom.x, vFrom.y)
    vTo   = ivec2(vTo.x, vTo.y)

    local code = [[include("data/scripts/lib/utility")
    local Azimuth = include("azimuthlib-basic")

    local open = {}
    local closed = {}
    local routes = {}
    local dests = {}
    local dead = {}
    local str = tostring

    function distance(vFrom, vTo, round)
      local dx = vTo.x - vFrom.x
      local dy = vTo.y - vFrom.y
      dist = math.sqrt(dx * dx + dy * dy)
      local factor = 10
      for i = 2, (round or 0) do factor = factor * 10 end
      return round and (math.floor(dist * factor + 0.5) / factor) or dist
    end

    function nextPath(sectors, ignore, maxdist, needgate)
      local left = maxdist or 999999
      local vec, gate

      for _, sector in pairs(sectors or open) do
        if sector.left < left and (ignore or {})[str(sector.vec)] == nil
        and (needgate and next((closed[str(sector.vec)] or {}).gates or {}) or not needgate) then
          vec = sector.vec
          gate = sector.gate
          left = sector.left
        end
      end

      return vec, gate
    end

    function optimizeSector(sector, prefJumps) -- 'prefJump' just means that it should find the shortest path, regardless of transit type
      if not (sector.gate and sector.dist) then return false end
      local sxy = str(sector.vec)
      local update = false
      if not dests[sxy] then dests[sxy] = { gates = {}, jumps = {} } end

      for i, set in ipairs({ sector.gates, sector.nearby }) do
        local sgate = sector.gate + (i == 1 and 1 or 0)
        local sjump = sector.jump + (i == 2 and 1 or 0)
        local action = (i == 1 and "gates" or "jumps")

        for gxy, gate in pairs(set) do
          local g = closed[gxy] -- double check that this is a sector we can work with
          if g then
            -- if i == 1 then print("", sxy, gxy) end
            dests[sxy][action][gxy] = g.vec

            if not (g.gate and g.jump) or
            (not prefJumps and ( -- conditions that should promote using gates
              g.gate > sgate and g.jump >= sjump or -- less gates used while not jumping more
              g.gate >= sgate and g.jump > sjump or -- less jumps without skipping gates
              g.jump > sjump -- less jumps
            )) or (prefJumps and g.gate + g.jump > sgate + sjump) then
              -- if g.gate then
              --   print(sxy, "-->", gxy, g.gate, g.jump, "-->", sgate, sjump)
              -- end

              g.gate = sgate
              g.jump = sjump
              g.dist = sector.dist + gate.dist
              g.prev = sector.vec

              update = true
            end

          else
            if not dead[gxy] then
              -- if this gets printed, something fucked up, again...
              -- TODO remove all connections to 'dead' sectors?
              -- print("  sector "..gxy.." is not part of the result")
              dead[gxy] = true
            end
          end
        end
      end

      return update
    end

    function finalizePath(vFrom, vTo)
      local sector = closed[str(vTo)]
      if not sector then return end

      local dist = sector.dist -- total distance covered
      local limit = math.ceil(dist) -- fallback to prevent an infinite loop
      local path = {} -- temp chain for constructing the sector array
      local final = {
        path = {}, g_path = {}, j_path = {},
        gates = sector.gate, jumps = sector.jump
      }

      -- backtrack the path to note the gates and jumps for the map visualization
      while sector.prev and limit > 0 do
        local prev = closed[str(sector.prev)]
        path[str(prev.vec)] = sector.vec

        if prev.gates[str(sector.vec)] then
          final.g_path[str(prev.vec)] = sector.vec
        else
          final.j_path[str(prev.vec)] = sector.vec
        end

        if prev.vec == vFrom then break end
        sector = prev
        limit = limit - 1
      end

      local vSec = path[str(vFrom)]

      while vSec and limit > 0 do
        table.insert(final.path, vSec)
        vSec = path[str(vSec)]
        limit = limit - 1
      end

      return final
    end

    --== main code ==--
    function run(mapPaths, vFrom, vTo, range)
      local start = appTimeMs()
      local done = false -- note when the destination was reached to limit the search to nearby sectors for maybe better alternatives
      local maxDist = 0

      open[str(vFrom)] = { vec = vFrom, left = distance(vFrom, vTo) } --, gate = 0 }
      print("starting pathfinding: "..str(vFrom).." --> "..str(vTo))

      -- nextPath returns ivec2, gateIdx
      local vSec, gateIdx = nextPath()
      while vSec do
        local sxy = str(vSec)
        if not closed[sxy] then
          local result = { left = distance(vSec, vTo), vec = vSec } --, gate = gateIdx }

          maxDist = result.left > maxDist and result.left or maxDist
          local testDist = math.min(maxDist, math.sqrt(maxDist) * 10)

          local paths = mapPaths[sxy]
          if paths and (paths.gates or paths.nearby) then
            result.gates = {}
            result.nearby = {}

            for strXY, gate in pairs(paths.gates or {}) do -- fetch all gates in the sector
              result.gates[strXY] = {
                vec = gate.vec,
                left = distance(gate.vec, vTo),
                dist = distance(gate.vec, vSec),
              }
            end

            for _, jSec in ipairs(paths.nearby or {}) do
              if jSec.dist <= range then
                result.nearby[str(jSec.vec)] = {
                  vec = jSec.vec,
                  left = distance(jSec.vec, vTo),
                  dist = distance(jSec.vec, vSec),
                }
              end
            end

            for iSet, set in pairs({ result.gates, result.nearby }) do
              for gxy, gate in pairs(set) do
                -- keep checking other paths close to the destination if we're 'done'
                if not done or done and gate.left <= testDist then
                  if not closed[gxy] then
                    open[gxy] = gate
                    if gateIdx and iSet == 1 then
                      -- open[gxy].gate = gateIdx + 1
                    end
                  end

                  if gate.vec == vTo then
                    -- print("destination reachable from "..sxy..
                    --   " - ["..distance(vTo, vSec, 2).."]")
                    done = true
                  end
                end
              end
            end
          end

          closed[sxy] = result
        end
        open[sxy] = nil

        -- nextPath returns ivec2, gateIdx
        vSec, gateIdx = nextPath()
      end

      Azimuth.saveConfig("path_async_pre", {
        _from = vFrom, _to = vTo, closed = closed, dests = dests, dead = dead
      })

      local route = {} -- provide a base route to reach the target
      local limit = math.ceil(maxDist)
      local left = limit
      local vSec = vFrom
      local nxt, prev
      local gates = 0
      local jumps = 0

      for iter = 1, limit do
        if vSec == vTo then
          left = 0
          break
        end

        local sec = closed[str(vSec)]
        local isGate

        repeat
          nxt = nextPath(sec.gates, route, left * 1.5)
          isGate = nxt ~= nil

          -- try to find a nearby sector with a gate
          nxt = nxt or nextPath(sec.nearby, route, left * 1.5, true)

          -- just take a nearby sector...
          nxt = nxt or nextPath(sec.nearby, route, left * 1.5)

          if nxt then
            if closed[str(nxt)] then
              break
            else
              route[str(nxt)] = false
            end
          else
            break
          end
        until not nxt

        if nxt then
          left = distance(vSec, vTo)
          if isGate then
            gates = gates + 1
          else
            jumps = jumps + 1
          end
          print(iter, str(nxt), str(isGate), distance(vTo, nxt), "/ g-j:", gates, jumps)
          route[str(vSec)] = { vec = vSec, nxt = nxt, prev = prev, gates = gates, jumps = jumps }
          prev = vSec
          vSec = nxt

        else
          if prev then
            -- remove the data but keep the key
            route[str(vSec)] = false
            vSec = prev
            prev = route[str(vSec)]
            prev = prev and prev.prev -- if this isn't a false then use the .prev
          else
            eprint("something really fucked up at "..str(vSec))
            break
          end
        end
      end

      if not closed[str(vTo)] and left > 0 then
        print("couldn't find a path from "..str(vFrom).." to "..str(vTo))
      end

      -- at this point "gates" and "jumps" also hold the 'worst case' (max) results for a path
      -- BUT we could get a 'better' "gates" result by using less "jumps"

      -- find all paths from the sectors in the base route, beginning at the starting sector
      local sector = closed[str(vFrom)]
      sector.gate = 0
      sector.jump = 0
      sector.dist = 0

      -- local new_route = {}
      -- for _, _ in pairs(route) do -- just iterate this for as long as the base route has entries
      --   local sec = route[str(sector.vec)]
      --   if sector.left == 0 or not sec then
      --     break
      --   elseif not sec.nxt then
      --     printTable(sec)
      --   else
      --     sector = closed[str(sec.nxt)]
      --   end
      -- end


      -- find the path with the least jumps, then the path with the least sectors passed
      for _, pass in pairs { false, true } do
        for iter = 1, limit do
          local update = false

          for sxy, sector in pairs(closed) do
            if not sector.gate then goto continue end

            if optimizeSector(sector, pass) then
              update = true
            end

            ::continue::
          end

          if not update then
            print("Done after iteration "..iter)
            break
          end
        end

        routes[#routes + 1] = finalizePath(vFrom, vTo)
      end


      -- remove unneeded sectors, which is unneeded if this is done...
      local count = 0
      -- local removed = {}
      if removed then
        -- remove sectors reachable from processed sectors which aren't related to the result
        for sxy, sec in pairs(closed) do
          if sec.gates then
            for gxy, gate in pairs(sec.gates) do
              if not (closed[gxy] or route[gxy]) and gate.vec ~= vTo then
                if not removed[gxy] then
                  removed[gxy] = {}
                  count = count + 1
                end

                table.insert(removed[gxy], sec.vec)
                sec.gates[gxy] = nil
              end
            end

            for gxy, gate in pairs(sec.nearby or {}) do
              if not (closed[gxy] or route[gxy]) and gate.vec ~= vTo then
                if not removed[gxy] then
                  removed[gxy] = {}
                  count = count + 1
                end

                table.insert(removed[gxy], sec.vec)
                sec.nearby[gxy] = nil
              end
            end
          end
        end

        -- remove sectors which have no gates
        for sxy, sec in pairs(closed) do
          if not (sec.gates or sec.vec == vFrom or sec.vec == vTo) then
            if not removed[sxy] then
              removed[sxy] = {}
              count = count + 1
            end

            table.insert(removed[sxy], sec.vec)
            closed[sxy] = nil
          end
        end

        print("removed "..count.." unrelated sectors from result")
      end

      local dura = appTimeMs() - start
      print("pathfinding took "..dura.." ms")

      Azimuth.saveConfig("path_async", {
        _from = vFrom, _to = vTo, _dura = dura, closed = closed,
        dests = dests, route = route, routes = routes
      })

      return routes, { route = route, dead = dead, closed = closed, duration = dura, from = vFrom, to = vTo }
    end
    -- ]]

    async("onPathFindingDone", code, UseGateOrder.mapPaths, vFrom, vTo, range and range > 0 and range or 12)
  end

  function UseGateOrder.onPathFindingDone(routes, data)
    -- FUCK whatever screws up these variables during the async...
    pfFrom = data.from
    pfTo   = data.to

    pfResult = routes
    pfSelected = 1
    pfBtnTable = {}

    wndPathFinding:clear()
    cntArrows:clear()

    -- splitter names are swapped because I don't name them by their orientation but which orientation they split
    local h_split = UIVerticalSplitter(Rect(wndPathFinding.size), 10, 10, 0.5)
    -- local h_split = UIVerticalSplitter(v_split.top, 10, 10, 0.5)


    if pfResult then
      local lbl_font = 20

      if pfResult[1] then
        local path = pfResult[1]
        local v_split = UIHorizontalSplitter(h_split.left, 10, 10, 0.5)

        pfBtnTable[wndPathFinding:createButton(v_split.bottom, "Use Path", "onUsePathClicked").index] = 1

        local lbl = wndPathFinding:createLabel(v_split.top, "Gates: ${g}\nJumps: ${j}\nTotal: ${t}" % {g = path.gates, j = path.jumps, t = path.gates + path.jumps }, 20)
        lbl:setCenterAligned()
        lbl.fontSize = lbl_font
        -- wndPathFinding:createLabel(h_split.right, "Jumps: "..pfResult[pfSelected].jumps, 25):setCenterAligned()

        local arrColor = ColorARGB(0.7, 0.6, 0.8, 0.2)
        for sxy, vec in pairs(routes[1].g_path) do
          local arr = cntArrows:createMapArrowLine()
          arr.color = arrColor
          arr.from = ivec2(toXY(sxy))
          arr.to = vec
        end

        local arrColor = ColorARGB(0.7, 0.2, 0.6, 0.8)
        for sxy, vec in pairs(routes[1].j_path) do
          local arr = cntArrows:createMapArrowLine()
          arr.color = arrColor
          arr.from = ivec2(toXY(sxy))
          arr.to = vec
        end
      else
        local lbl = wndPathFinding:createLabel(h_split.left, "Route not\npossible", lbl_font)
        lbl:setCenterAligned()
        lbl.fontSize = lbl_font
      end


      if pfResult[2] then
        local path = pfResult[2]
        local v_split = UIHorizontalSplitter(h_split.right, 10, 10, 0.5)

        pfBtnTable[wndPathFinding:createButton(v_split.bottom, "Use Path", "onUsePathClicked").index] = 2

        local lbl = wndPathFinding:createLabel(v_split.top, "Gates: ${g}\nJumps: ${j}\nTotal: ${t}" % {g = path.gates, j = path.jumps, t = path.gates + path.jumps }, 20)
        lbl:setCenterAligned()
        lbl.fontSize = lbl_font
        -- wndPathFinding:createLabel(h_split.right, "Jumps: "..pfResult[pfSelected].jumps, 25):setCenterAligned()

        local arrColor = ColorARGB(0.7, 0.8, 0.6, 0.2)
        for sxy, vec in pairs(routes[2].g_path) do
          local arr = cntArrows:createMapArrowLine()
          arr.color = arrColor
          arr.from = ivec2(toXY(sxy))
          arr.to = vec
        end

        local arrColor = ColorARGB(0.7, 0.4, 0.3, 0.8)
        for sxy, vec in pairs(routes[2].j_path) do
          local arr = cntArrows:createMapArrowLine()
          arr.color = arrColor
          arr.from = ivec2(toXY(sxy))
          arr.to = vec
        end
      else
        local lbl = wndPathFinding:createLabel(h_split.right, "Route not\npossible", lbl_font)
        lbl:setCenterAligned()
        lbl.fontSize = lbl_font
      end
    end
  end

  function UseGateOrder.onUsePathClicked(button)
    local result = pfResult and pfResult[pfBtnTable[button.index]]
    if not (result and result.path) then return end

    MapCommands.clearOrdersIfNecessary(not enqueueNextOrder)
    local lastVec = str(pfFrom)

    for _, vSec in ipairs(result.path) do
      if result.j_path[lastVec] then
        MapCommands.enqueueOrder("addJumpOrder", vSec.x, vSec.y)
      else
        MapCommands.enqueueOrder("addFlyThroughWormholeOrder", _, vSec.x, vSec.y)
      end
      lastVec = str(vSec)
    end

    MapCommands.unlockWindow(wndPathFinding)
    wndPathFinding:hide()
    cntArrows:clear()
  end

  -- TODO remove --
  function iteratePathResult(result, options, vec)
    vec = vec or pfFrom
    local sxy = str(vec)
    local sec = result[sxy]
    local startTime
    if vec == pfFrom then
      startTime = appTimeMs()
      sec.gate = 0 -- gates used
      sec.jump = 0 -- jumps done
      sec.dist = 0 -- distance covered
    end
    print(sxy)
    for gxy, gate in pairs(sec.gates) do
      print("  "..gxy)
      local g = result[gxy]
      if g then
        if not g.gate then
          print("    passed")
          g.gate = sec.gate + 1
          g.jump = sec.jump
          g.dist = sec.dist + gate.dist
          g.prev = sec
          iteratePathResult(result, options, g.vec)

        elseif g.gate > sec.gate then
          print("    better route")
          g.gate = sec.gate + 1
          g.jump = sec.jump
          g.dist = sec.dist + gate.dist
          g.prev = sec
          iteratePathResult(result, options, g.vec)
        end

        -- if g.vec == pfTo then
          -- print("    destination reached")
          -- local p = g.prev
          -- while p do
            -- p.next = g.vec
            -- p = p.prev
          -- end
        -- end
      end
    end
    if startTime then print("iteration took "..(appTimeMs() - startTime).." ms") end
  end

  -- TODO remove --
  function pathDone_old()
    local sectors = {}
    for sxy, sec in pairs(result or {}) do sectors[#sectors + 1] = sec.vec end
    debugSectors(sectors, ColorARGB(0.5, 0.2, 0.6, 0.8), "result", 21)

    sectors = {}
    for sxy, sec in pairs(data.removed or {}) do sectors[#sectors + 1] = ivec2(toXY(sxy)) end
    debugSectors(sectors, ColorARGB(0.5, 0.8, 0.6, 0.2), "removed", 19)


    local path
    -- = optimizePathResult(result, data.route)
    -- iteratePathResult(result, { firstJump = false, lastJump = false })
    -- printTable(path or {})

    -- sectors = {}
    -- for sxy, sec in pairs(result) do sectors[sxy] = sec.prev end
    -- debugPath(sectors, arrColor, "prev")

    arrColor = ColorARGB(0.7, 0.2, 0.6, 0.2)
    if result and result[1] then
      nxt = result[1][str(pfTo)]
      if nxt and nxt.prev then
        local limit = 100
        while nxt.prev and limit > 0 do
          local arr = cntArrows:createMapArrowLine()
          arr.color = arrColor
          arr.from = nxt.vec
          arr.to = nxt.prev
          nxt = result[1][str(nxt.prev)]
          limit = limit - 1
        end
      end
    end

    arrColor = ColorARGB(0.7, 0.7, 0.7, 0.7)
    nxt = data.route[str(pfFrom)]
    if nxt and nxt.nxt then
      local limit = 100
      while nxt do
        local arr = cntArrows:createMapArrowLine()
        arr.color = arrColor
        arr.from = nxt.vec
        arr.to = nxt.nxt
        nxt = data.route[str(nxt.nxt)]
        limit = limit - 1
      end
    end

    sectors = {}
    for sxy, sec in pairs(data.dead or {}) do sectors[#sectors + 1] = ivec2(toXY(sxy)) end
    debugSectors(sectors, ColorARGB(0.5, 0.8, 0.2, 0.2), "dead", 25)
  end

  -- TODO remove --
  function exploreOld()
      local nxt
      local sxy = str(sector.vec)

      if sector.vec == pfTo then
        print("  destination reached")
        final = { _gates = sector.gate, _jumps = sector.jump, }

        local s = sector
        while s.prev do
          final[s.prev] = s.vec
          s = result[s.prev]
        end

        Azimuth.saveConfig("path_tracing_"..pathnum, {
          _from = pfFrom, _to = pfTo,
          result = result, final = final,
          done = done, dead = dead,
        })
        pathnum = pathnum + 1

        sector = result[startSec]
        done = {}
        -- TODO find maybe better path?
        colArrow.hue = colArrow.hue + 15
        colArrow.a = 0.35
        -- break

      elseif not sector.gates then
        print("  no gates at "..sxy)

      else
        if debug then print("  "..sxy) end
        for gxy, gate in pairs(sector.gates) do
          local g = result[gxy] -- double check that this is a sector we can work with
          if g then
            if debug then print("    "..gxy) end

            if not (g.gate and g.jump) or
            g.gate >  sector.gate + 1 and g.jump >= sector.jump + 1 or
            g.gate >= sector.gate + 1 and g.jump >  sector.jump + 1 then
              if debug then print("      "..(g.gate and "better route" or "passed")) end
              g.gate = sector.gate + 1
              g.jump = sector.jump
              g.dist = sector.dist + gate.dist
              g.prev = sxy

              -- local arr = cntArrows:createMapArrowLine()
              -- arr.color = colArrow
              -- arr.from = sector.vec
              -- arr.to = g.vec
            end

            if not dead[gxy] and not done[gxy] and g.gates and
            (not nxt or nxt.jump >= g.jump or nxt.gate >= g.gate) then -- or nxt.left > g.left) then
              if debug then print("      picked next") end
              nxt = g
            end
          else
            eprint("    sector "..gxy.." is not part of the result")
            -- dead[str(qxy)] = true
          end
        end

        if not nxt then
          if debug then print("  exploring nearby sectors") end
          for gxy, gate in pairs(sector.nearby) do
            local g = result[gxy] -- double check that this is a 'known' sector
            if g then
              if debug then print("    "..gxy) end

              if not (g.gate and g.jump) or
              g.gate >  sector.gate + 1 and g.jump >= sector.jump + 1 or
              g.gate >= sector.gate + 1 and g.jump >  sector.jump + 1 then
                if debug then print("    "..(g.gate and "better route" or "passed")) end
                g.gate = sector.gate
                g.jump = sector.jump + 1
                g.dist = sector.dist + gate.dist
                g.prev = sxy

                -- local arr = cntArrows:createMapArrowLine()
                -- arr.color = colArrow
                -- arr.from = sector.vec
                -- arr.to = g.vec
              end

              if not dead[gxy] and not done[gxy] and g.gates and
              (not nxt or nxt.jump >= g.jump or nxt.gate >= g.gate) then -- or nxt.left > g.left) then
                if debug then print("    picked next") end
                nxt = g
              end
            else
              eprint("    sector "..gxy.." is not part of the result")
              -- dead[str(qxy)] = true
            end
          end
        end
      end

      if nxt then
        local arr = cntArrows:createMapArrowLine()
        arr.color = colArrow
        arr.from = sector.vec
        arr.to = nxt.vec

      else
        -- done = {}
        if debug then print("  dead end") end
        nxt = result[sector.prev]

        colArrow.hue = colArrow.hue + 15
        colArrow.a = 0.35

        dead[sxy] = sector.prev or true
        -- printTable(dead)
      end

      done[sxy] = true -- only need to note THAT we went here
      sector = nxt
  end

  -- TODO remove --
  function optimizePathResult(result, route)
    if not (result and next(result)) then return end

    local start = appTimeMs()

    local prints = { "vec", "gate", "jump", "dist", "left", "prev", "nxt" }
    local sector = result[str(pfFrom)]
    local limit = math.ceil(distance(pfFrom, pfTo))
    local jumpPath = {} -- final path
    local gatePath = {} -- final path
    local check = {} -- track which sectors need to be (re)checked
    local dests = {} -- track from where we can get to somewhere
    local left = {}  -- track which sector we didn't process yet
    local done = {}  -- track where we've been
    local iter = 0

    sector.gate = 0
    sector.jump = 0
    sector.dist = 0

    function optimizeSector(sector)
      if not (sector.gate and sector.dist) then return false end
      local sxy = str(sector.vec)
      local update = false
      if not dests[sxy] then dests[sxy] = { gates = {}, jumps = {} } end

      for i, set in ipairs({ sector.gates, sector.nearby }) do
        local sgate = sector.gate + (i == 1 and 1 or 0)
        local sjump = sector.jump + (i == 2 and 1 or 0)
        local action = (i == 1 and "gates" or "jumps")

        for gxy, gate in pairs(set) do
          local g = result[gxy] -- double check that this is a sector we can work with
          if g then
            -- if i == 1 then print("", sxy, gxy) end
            dests[sxy][action][gxy] = g.vec

            if not (g.gate and g.jump) or
            ( -- conditions that should promote using gates
              g.gate > sgate and g.jump >= sjump or -- less gates used while not jumping more
              g.gate >= sgate and g.jump > sjump or -- less jumps without skipping gates
              g.jump > sjump -- less jumps
            ) then
              if g.gate then
                -- print(sxy, "-->", gxy, g.gate, g.jump, "-->", sgate, sjump)
              end

              g.gate = sgate
              g.jump = sjump
              g.dist = sector.dist + gate.dist
              g.prev = sector.vec

              update = true
            end

          else
            if not dead[gxy] then
              print("  sector "..gxy.." is not part of the result")
              dead[gxy] = true
            end
          end
        end
      end

      return update
    end

    -- find all paths from the sectors in the base route, beginning at the starting sector
    for _, _ in pairs(route) do
      local sec = route[str(sector.vec)]
      if sector.left == 0 or not sec then
        break
      elseif not sec.nxt then
        printTable(sec)
      else
        sector = result[str(sec.nxt)]
      end
    end

    for sxy, sector in pairs(result) do
      left[sxy] = sector.vec
    end

    for iter = 1, limit do
      local update = false

      for sxy, sector in pairs(result) do
        if not sector.gate then goto continue end

        if optimizeSector(sector) then
          update = true
        end

        ::continue::
      end

      if not update then
        -- print("I", iter)
        break
      end
    end

    for sxy, dsts in pairs(dests) do
      if not (next(dsts.gates) or next(dsts.jumps)) or not result[sxy] then
        dests[sxy] = nil
        print("removed destination "..sxy)
      end
    end
    Azimuth.saveConfig("path_dests", dests)

    print("path optimization took "..(appTimeMs() - start).." ms")

    return { jumpPath = jumpPath, gatePath = gatePath, dead = dead }
  end

  -- TODO remove --
  function post_optimize()
    while false do
      if done then
        if limit > 0 then
          print("done", iter)
          limit = 0
          goto final

        else
          for sxy, dsts in pairs(dests) do
            if not (next(dsts.gates) or next(dsts.jumps)) or not result[sxy] then
              dests[sxy] = nil
              print("removed destination "..sxy)
            end
          end
          Azimuth.saveConfig("path_dests", dests)
          break

          local prev
          local lmt = 100
          local sector = result[str(vTo)]
          local gatePath = {}

          while sector and sector.vec ~= vFrom and lmt > 0 do
            local sxy = str(sector.vec)

            -- iterate the sectors we can reach through gates
            for gxy, _ in pairs(dests[sxy].gates) do
              local gate = result[gxy]

              if not prev or prev.jump > gate.jump
              or prev.gate > gate.gate and prev.jump >= gate.jump then
                prev = gate
              end
            end

            -- iterate the sectors we can jump to, IF we didn't find a gate
            if not prev or prev.vec == sector.vec then
              for gxy, _ in pairs(dests[sxy].jumps) do
                local gate = result[gxy]

                if not prev or prev.jump > gate.jump
                or prev.gate > gate.gate and prev.jump >= gate.jump then
                  prev = gate
                end
              end
            end

            if not prev then
              print("fuck...")
              break

            elseif prev.vec == sector.vec then
              print("route found")
              break
            end

            gatePath[str(prev.vec)] = sector.vec

            sector = prev
            lmt = lmt - 1
          end

          print("finally done")
          break
        end
      end
      ::final::
    end
  end


  --== Fly Through Gate Order ==--
  function MapCommands.onFlyThroughGatePressed()
    enqueueNextOrder = MapCommands.isEnqueueing()

    local selected = MapCommands.getSelectedPortraits() -- .info.chain / .coordinates
    if #selected < 1 then
      wndUseGate:hide()
      return
    end

    lastCoords = selected[1] and selected[1].coordinates

    if enqueueNextOrder then
      -- printTable(selected)
      local chain = selected[1].info.chain
      if chain and chain[#chain] then
        -- printTable(chain and chain[#chain] or {})
        lastCoords = vec2(chain[#chain].x, chain[#chain].y)
      end
    end

    if not enqueueNextOrder or player:knowsSector(lastCoords.x, lastCoords.y) then
      lastPos = ivec2(map:getCoordinatesScreenPosition(ivec2(lastCoords.x, lastCoords.y)))
      -- UseGateOrder.findGates({ sector = coords, gates = GatesMap:getConnectedSectors(coords) })
      UseGateOrder.showGatesWindow(lastCoords)
    end
  end

  function UseGateOrder.chainGate()
    -- print("chain")
    MapCommands.onFlyThroughGatePressed()
  end

  function UseGateOrder.showGatesWindow(from)
    from = vec2(from.x, from.y)

    wndUseGate.caption = "Fly through Gate in ${x} : ${y}" % lastCoords
    wndUseGate.center = vec2(0, 120 + wndUseGate.size.y) + vec2(lastPos.x, lastPos.y)

    MapCommands.hideWindows()
    wndUseGate:show()

    local gates = {}
    local player = Player()
    local sector = player:getKnownSector(from.x, from.y)

    for _, dest in pairs({ sector:getGateDestinations() }) do
      table.insert(gates, { x = dest.x, y = dest.y })
    end
    for _, dest in ipairs({ sector:getWormHoleDestinations() }) do
      table.insert(gates, { x = dest.x, y = dest.y, wormhole = 1 })
    end

    table.sort(gates, function(a,b) return getAngle(from, a) < getAngle(from, b) end)


    gateTable = {}
    wndUseGate:clear()

    local hLister = UIHorizontalLister(wndUseGate.localRect, 10, 10)
    local inner = hLister.inner

    for idx, gate in ipairs(gates) do
      local size = (inner.width - 20) / 6
      local btn = wndUseGate:createRoundButton(Rect(), "", "onUseGateClicked")
      -- btn = hLister:placeElementCenter(btn)
      btn.size = vec2(size, size)
      btn.rect = hLister:placeCenter(btn.size)

      local lbl = wndUseGate:createLabel(vec2(), "${x} : ${y}" % gate, 10)
      lbl:setCenterAligned()
      lbl.size = vec2(btn.size.x, lbl.size.y)
      lbl.center = btn.center + vec2(0, size * (3 / 5))

      gateTable[btn.index] = gate

      local size = (btn.width + btn.height) / 5.5
      local target = vec2(gate.x, gate.y)
      local dir = from - target
      local dist = length(dir)
      local arrow = wndUseGate:createArrowLine()
      dir = dir / dist * vec2(1, -1) -- Y has to be flipped because 'fuck everything'
      arrow.from = btn.center + dir * size
      arrow.to   = btn.center - dir * size

      if gate.isWormhole then
        arrow.color = colors.wormhole
      else
        arrow.color = (player:knowsSector(gate.x, gate.y) and colors.known or colors.unknown)
      end
    end
    -- printTable(arrows)
  end

  function UseGateOrder.onUseGateClicked(button)
    MapCommands.clearOrdersIfNecessary(not enqueueNextOrder)
    MapCommands.enqueueOrder("addFlyThroughWormholeOrder", _, gateTable[button.index].x, gateTable[button.index].y)
    if enqueueNextOrder then
      -- enqueueNextOrder = false
      deferredCallback(0.2, "chainGate")
    else
      wndUseGate:hide()
    end
  end

  function MapCommands.hideUseGate(selected)
    if not selected or not selected[1] then return false end
    local chain = selected[1].info and selected[1].info.chain
    if not chain or #chain < 1 then return false end
    return MapCommands.isEnqueueing() and not Player():knowsSector(chain[#chain].x, chain[#chain].y)
  end


  --== general functions ==--
  function toXY(s) -- modified version of https://stackoverflow.com/a/37601779/1025177
    if type(s) ~= "string" then return s end
    local t = {}
    for m in s:gmatch("[^ ,()]+") do
      t[#t+1] = tonumber(m)
    end
    return t[1], t[2], t[3], t[4]
  end

  function distance(vFrom, vTo, round)
    local dx = vTo.x - vFrom.x
    local dy = vTo.y - vFrom.y
    dist = math.sqrt(dx * dx + dy * dy)
    local factor = 10
    for i = 2, (round or 0) do factor = factor * 10 end
    return round and (math.floor(dist * factor + 0.5) / factor) or dist
  end

  function getAngle(vFrom, vTo, round)
    -- normaly there'd be also an offset of 180 degree, but it's already added in the core, or forgotten, so this only works without it...
    local angle = math.atan2(vTo.x - vFrom.x, vTo.y - vFrom.y) / math.pi * 180
    while angle >  180 do angle = angle - 360 end
    while angle < -180 do angle = angle + 360 end
    local factor = 10
    for i = 2, (round or 0) do factor = factor * 10 end
    return round and (math.floor(angle * factor + 0.5) / factor) or angle
  end

  function debugSectors(sectors, color, name, size)
    player:invokeFunction("map_debug", "addSectorSet", sectors, color, name, size)
  end

  function debugPath(sectors, color, name)
    player:invokeFunction("map_debug", "addPathSet", sectors, color, name)
  end
end

return UseGateOrder
