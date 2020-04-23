-- Fleet Jump through Gate Command Mod by MassCraxx
-- v3
-- Modified by
-- by Kevin Gravier (MrKMG)
-- by BloodyRain2k
-- MIT License 2019

function OrderChain.replaceCurrent(order)
  if OrderChain.activeOrder == 0 then
    OrderChain.clear()
    table.insert(OrderChain.chain, order)
  else
    OrderChain.chain[OrderChain.activeOrder] = order
    if not (#OrderChain.chain == 1) then
      OrderChain.activateOrder(order)
    end
  end

  OrderChain.updateChain()
end

function OrderChain.undoOrder(x, y)
  if onClient() then
    invokeServerFunction("undoOrder", x, y)
    return
  end

  if callingPlayer then
    local owner, _, player = checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips)
    if not owner then return end
  end

  local chain = OrderChain.chain
  local i = OrderChain.activeOrder

  if i and i > 0 and i < #chain then
    OrderChain.chain[#OrderChain.chain] = nil
    OrderChain.updateChain()
  elseif i and i > 0 and i >= #chain and
	(chain[#chain].action == OrderType.Jump or chain[#chain].action == OrderType.FlyThroughWormhole) then
    OrderChain.clearAllOrders()
  else
    OrderChain.sendError("Cannot undo last order."%_T)
  end
end
callable(OrderChain, "undoOrder")

function OrderChain.sendError(msg, ...)
  if callingPlayer then
    Player(callingPlayer):sendChatMessage("", ChatMessageType.Error, msg, ...)
	else
		Faction(Entity().factionIndex):sendChatMessage("", ChatMessageType.Error, msg, ...)
  end
end

function OrderChain.addJumpOrder(x, y)
  if onClient() then
    invokeServerFunction("addJumpOrder", x, y)
    return
  end

  if callingPlayer then
    local owner, _, player = checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips)
    if not owner then
      local player = Player(callingPlayer)
      player:sendChatMessage("", ChatMessageType.Error, "You don't have permission to do that."%_T)
      return
    end
  end

  local shipX, shipY = Sector():getCoordinates()

  for _, action in pairs(OrderChain.chain) do
    if action.action == OrderType.Jump or action.action == OrderType.FlyThroughWormhole then
      shipX = action.x
      shipY = action.y
    end
  end

  local jumpValid, error = Entity():isJumpRouteValid(shipX, shipY, x, y)
  local order = {action = OrderType.Jump, x = x, y = y}

  if OrderChain.canEnchain(order) then
    OrderChain.enchain(order)
  end
  if not jumpValid and callingPlayer then
    local player = Player(callingPlayer)
    player:sendChatMessage("", ChatMessageType.Error, "Jump order may not be possible!")
  end
end
callable(OrderChain, "addJumpOrder")

function OrderChain.addLoop(a, b)
  if onClient() then
    invokeServerFunction("addLoop", a, b)
    return
  end

  if callingPlayer then
    local owner, _, player = checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips)
    if not owner then return end
  end

  local loopIndex
  if a and not b then
    -- interpret as action index
    loopIndex = a
  elseif a and b then
    -- interpret as coordinates
    local x, y = a, b
    local cx, cy = Sector():getCoordinates()
    local i = 1 --OrderChain.activeOrder
    local chain = OrderChain.chain

    while i > 0 and i <= #chain do
      local current = chain[i]

      if cx == x and cy == y then
        loopIndex = i
        break
      end

      if current.action == OrderType.Jump or current.action == OrderType.FlyThroughWormhole then
        cx, cy = current.x, current.y
      end

      i = i + 1
    end

    if not loopIndex then
      OrderChain.sendError("Could not find any orders at %1%:%1%!"%_T, x, y)
    end
  end

  if not loopIndex or loopIndex == 0 or loopIndex > #OrderChain.chain then return end

  local order = {action = OrderType.Loop, loopIndex = loopIndex}

  if OrderChain.canEnchain(order) then
    OrderChain.enchain(order)
  end
end
callable(OrderChain, "addLoop")

function OrderChain.addFlyThroughWormholeOrder(targetId, sx , sy, replace)
  if onClient() then
    invokeServerFunction("addFlyThroughWormholeOrder", targetId, sx , sy, replace)
    return
  end

  if callingPlayer then
    local owner, _, player = checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips)
    if not owner then return end
  end

	if not (sx and sy) and valid(Entity(targetId)) then
    sx, sy = Entity(targetId):getWormholeComponent():getTargetCoordinates()
  end

  -- don't pass an Id because it can screw with enchaining
	local order = { action = OrderType.FlyThroughWormhole, targetId = nil, x = sx, y = sy }

  if replace then
    OrderChain.replaceCurrent(order)
  elseif OrderChain.canEnchain(order) then
    OrderChain.enchain(order)
  end
end
callable(OrderChain, "addFlyThroughWormholeOrder")

function OrderChain.activateJump(x, y)
  local shipX, shipY = Sector():getCoordinates()
  local jumpValid, error = Entity():isJumpRouteValid(shipX, shipY, x, y)

  --print("activated jump to sector " .. x .. ":" .. y)
  if jumpValid then
    local ai = ShipAI()
    ai:setStatus("Jumping to ${x}:${y} /* ship AI status */"%_T, { x = x, y = y })
    ai:setJump(x, y)
  else
    local gates = { Sector():getEntitiesByComponent(ComponentType.WormHole) }
    for _, entity in pairs(gates) do
      local wh = entity:getWormholeComponent()
      local whX, whY = wh:getTargetCoordinates()
      if whX == x and whY == y then
        --print("replacing jump with wormhole order");
        OrderChain.addFlyThroughWormholeOrder(entity.id, x, y, true)
        return
      end
    end

    ShipAI():setStatus("Unable to jump /* ship AI status */"%_T, { x = x, y = y })
    OrderChain.chain[OrderChain.activeOrder].invalid = true
    OrderChain.updateShipOrderInfo()
    -- TODO Not translatable
    local text = error.." Standing by."
    print(text)

    OrderChain.sendError(text)
  end
end

function OrderChain.activateFlyThroughWormhole(targetId)
	local order = OrderChain.chain[OrderChain.activeOrder]
	local sx, sy = Sector():getCoordinates()

	ShipAI():setStatus("Jumping to ${x}:${y} /* ship AI status */"%_T, { x = order.x, y = order.y })

	if not (targetId and valid(targetId)) then
		local gates = { Sector():getEntitiesByComponent(ComponentType.WormHole) }

    for _, entity in pairs(gates) do
			tx, ty = entity:getWormholeComponent():getTargetCoordinates()
			if tx == order.x and ty == order.y then
				targetId = entity.id
				-- print("Target found:", tostring(targetId))
				break
			end
    end

		if not targetId or not valid(targetId) then
      OrderChain.sendError("No Wormhole or Gate to %i:%i found in Sector %i:%i!"%_T, order.x, order.y, sx, sy)
      -- order.action = OrderType.Jump
      OrderChain.addJumpOrder(order.x, order.y)
      OrderChain.replaceCurrent(OrderChain.chain[#OrderChain.chain])
			OrderChain.undoOrder(order.x, order.y)
			return
    end
  -- else
    -- print("Passed target:", tostring(targetId))
	end

	Entity():invokeFunction("data/scripts/entity/craftorders.lua", "flyThroughWormhole", targetId)
	-- print("activated fly through wormhole")
end
