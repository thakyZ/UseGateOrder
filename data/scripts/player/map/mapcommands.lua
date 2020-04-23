-- Fleet Jump through Gate Command Mod by MassCraxx
-- v3
-- Modified by
-- by Kevin Gravier (MrKMG)
-- MIT License 2019

package.path = package.path .. ";data/scripts/lib/?.lua"
include("data/scripts/player/map/common")
include("stringutility")
include("utility")
include("goods")

if onClient() then
  -- include ("ordertypes")
  -- local OrderChain = include("data/scripts/entity/orderchain")

  MapCommands.windows = {}
  MapCommands.lockedWindows = {}

  function MapCommands.addWindow(window)
    MapCommands.windows[window.index] = window
  end

  function MapCommands.lockWindow(window)
    MapCommands.lockedWindows[window.index] = window
  end

  function MapCommands.unlockWindow(window)
    MapCommands.lockedWindows[window.index] = nil
  end

  function MapCommands.hideWindows()
    for idx, window in pairs(MapCommands.windows) do
      if not MapCommands.lockedWindows[idx] then
        window:hide()
      end
    end
  end


  --== Craft Order Lib overrides ==--
  local col_initUI = MapCommands.initUI
  function MapCommands.initUI()
    col_initUI()

    windows = { buyWindow, sellWindow, escortWindow }
    for _, window in pairs(windows) do
      window.showCloseButton = 1
      -- window.moveable = 1
      MapCommands.addWindow(window)
    end

    MapCommands.hideWindows()
  end

  function MapCommands.hideOrderButtons()
    for _, button in pairs(orderButtons) do
      button:hide()
    end
    MapCommands.hideWindows()
  end


  --== order overrides ==--
  function MapCommands.onEscortPressed()
    enqueueNextOrder = MapCommands.isEnqueueing()

    MapCommands.fillEscortCombo()

    MapCommands.hideWindows()
    escortWindow:show()
  end

  function MapCommands.onBuyGoodsPressed()
    enqueueNextOrder = MapCommands.isEnqueueing()

    -- buyFilterTextBox:clear()
    -- buyAmountTextBox:clear()
    MapCommands.fillTradeCombo(buyCombo, buyFilterTextBox.text)

    MapCommands.hideWindows()
    buyWindow:show()
  end

  function MapCommands.onSellGoodsPressed()
    enqueueNextOrder = MapCommands.isEnqueueing()

    -- sellFilterTextBox:clear()
    -- sellAmountTextBox:clear()
    MapCommands.fillTradeCombo(sellCombo, sellFilterTextBox.text)

    MapCommands.hideWindows()
    sellWindow:show()
  end


  --== Fleet Jump Order leftovers ==--
  function MapCommands.getCommandsFromInfo(info, x, y)
    if not info or not info.chain or not info.coordinates then return {} end

    local cx, cy = info.coordinates.x, info.coordinates.y
    local i = info.currentIndex

    local result = {}
    while i > 0 and i <= #info.chain do
      local current = info.chain[i]

      if cx == x and cy == y then
        table.insert(result, current)
      end

      if current.action == OrderType.Jump or current.action == OrderType.FlyThroughWormhole then
        cx, cy = current.x, current.y
      end

      i = i + 1
    end

    return result
  end

  function MapCommands.setPortraits(portraits)
    craftPortraits = portraits
  end
end
