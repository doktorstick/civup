-- Lua Script1
-- Author: Sneaks/alpaca
-- DateCreated: 1/31/2011 12:07:40 PM
--------------------------------------------------------------

------------------------------------------------------------------
--Debugging Print Namespace Addin
------------------------------------------------------------------
include("AlpacaUtils.lua")
VERBOSITY = 0
include("ModTools.lua")
local log = Events.LuaLogger:New()
log:SetLevel("WARN")

------------------------------------------------------------------
--Notification Addins
------------------------------------------------------------------
include("CustomNotification.lua");

LuaEvents.NotificationAddin({ name = "CityGrowth", type = "CNOTIFICATION_CITY_GROWTH"})
LuaEvents.NotificationAddin({ name = "CityTile", type = "CNOTIFICATION_CULTURE_GROWTH"})
LuaEvents.NotificationOverrideAddin({
	type = "NOTIFICATION_CITY_GROWTH",
	override = 
	function(toolTip,summary,value1,value2) 
		--print("Overriding",toolTip,summary,value1,value2); 
		return; 
	end})
------------------------------------------------------------------

------------------------------------------------------------------
--	City Growth notification (also above pop 5)
------------------------------------------------------------------

-- initialise city sizes
local citySizes = {}

function SetCitySize(playerID, initialPopulation)
  return { owner = playerID, population = initialPopulation }
end

--aprint("Initializing City Sizes")
for playerID, pPlayer in pairs(Players) do
  for pCity in pPlayer:Cities() do
    citySizes[pCity:Plot()] = SetCitySize(playerID, pCity:GetPopulation())

    print(string.format("Initializing city sizes %s [%d] = %d",
      pCity:GetName(), playerID, pCity:GetPopulation()))
  end
end

--[[--
  There's a period of time between initial capture of
  a city and the completion of that capture where the
  population swings wildly, generating two or more
  notifications for the human player.
  
  Here's an example of a capture:

  [1389208.575] ImprovedEvents: Madrid [237588] population 1 (+1)
  [1389208.575] ImprovedEvents: Madrid [237588] population 12 (+11)
  [1389215.922] ImprovedEvents: Madrid [237588] population 0 (-12)
  [1389216.936] ImprovedEvents: Madrid [237588] population 10 (+10)

  The goal then is to broadcast only the last event to the player.

  Here are the different situations that need to be accounted for:
  o ActivePlayer's Turn - conquers enemy city;
  o ActivePlayer's Turn - occupies/puppets 1+ cities via trade;
  o AI's Turn - trades 1+ cities to ActivePlayer
--]]--

local CityGrowthQueueNotifications = false
local CityGrowthQueue = {}

--[[
	Detects city growth and fires a notification
]]--
function CityGrowthNotificationOnSerialEventCityPopulationChanged(iHexX, iHexY, iNewPop, iUnknown)
	--aprint("Received a growth event at coordinates ", iHexX, iHexY)
	local pPlot = Map.GetPlot(ToGridFromHex(iHexX, iHexY))
	local pCity = pPlot:GetPlotCity()

	--aprint("plot and city ", pPlot, pCity)

	if not pCity then
    -- DS: This is likely not a bug.  When the city gets destroyed,
    -- particularly from razing, the population event fires for
    -- population 0 asynchronously to its destruction.
		log:Fatal("CityGrowthNotification pCity=nil %s %s", iHexX, iHexY)
		return
	end
	
  --[[
    The city is owned by the player, but this doesn't mean
    notifications get fired. First, check to see if our city 
    tracker has updated the owner (based on the
    "SerialEventCityCaptured" event).
    
    Oh, and construct the "citySizes" entry if it doesn't exist
    (new cities). Which reminds me, there's going to be
    corner case when a city is fully destroyed and a new one
    rebuilt on the same plot; the first growth may be missed
    because "oldpop" is likely greater than "newpop" (but, likely
    isn't an issue since new cities are usually size 1, and they
    don't notify anyway).
  --]]
  
  if not citySizes[pPlot] then
    citySizes[pPlot] = SetCitySize(pCity:GetOwner(), 0)
  end
     
  if pCity:GetOwner() == Game.GetActivePlayer() 
    and pCity:GetOwner() == citySizes[pPlot].owner then

    local iOldPop = citySizes[pPlot].population or 0
    citySizes[pPlot].population = iNewPop

    print(string.format("%s [%d] population %d (%+d)", pCity:GetName(), pCity:GetID(), iNewPop, iNewPop - iOldPop))
    if iNewPop > 1 and iNewPop > iOldPop then
      -- Handle the notifications.
      local args = 
      {
        "CityGrowth", Locale.ConvertTextKey("TXT_KEY_NOTIFICATION_SUMMARY_CITY_GROWTH_2", pCity:GetName()), Locale.ConvertTextKey("TXT_KEY_NOTIFICATION_CITY_GROWTH_2", pCity:GetName(), iNewPop), pPlot, pCity, "Green", 0
      }

      if CityGrowthQueueNotifications then
        print("- queueing notification")
        CityGrowthQueue[pCity:GetID()] = args
      else
        print("- firing notification")
        CustomNotification(unpack(args))
      end
    end
  end
end
Events.SerialEventCityPopulationChanged.Add(CityGrowthNotificationOnSerialEventCityPopulationChanged)

function CityGrowthOnCapture(hexPos, lostPlayerID, cityID, wonPlayerID)
	print("CityGrowthOnCapture")
	local pPlot = Map.GetPlot(ToGridFromHex(hexPos.x, hexPos.y))
	local pCity = pPlot:GetPlotCity()

	if pCity then
    print(string.format("CityGrowthOnCapture: %s (owned by %s) population=%d",
      pCity:GetName(), Players[pCity:GetOwner()]:GetName(), pCity:GetPopulation()))

      --[[
        By time this event comes in, the population should have settled down
        and will fire 1-2 more times. If it fires twice, the first one is
        set to 1, from what I guess is the pseudo-creation of a new city,
        and then it gets set to its target population. Set the population to 0, 
        however, to ensure that the new ownership fires the growth notification.
        
        I need an event that is guaranteed to fire only after all calculations
        on a captured city are 100% complete.
        
        NOTE: Damnit. After some 100 turns with perfect post-capture population
              notification, three captures in one turn all had the wrong size
              in the notification. In all cases, the "*PopulationChanged" event
              sent sizes 1, N, N-2, and we fire on size N.
      --]]
      citySizes[pPlot] = SetCitySize(pCity:GetOwner(), 0)
    end
end
Events.SerialEventCityCaptured.Add(CityGrowthOnCapture)

function CityGrowthOnActivePlayerFix()
    print("CityGrowthOnActivePlayerFix")
    CityGrowthQueueNotifications = false
    
    for id, args in pairs(CityGrowthQueue) do
      print("NEW TURN: notification:", unpack(args))
      CustomNotification(unpack(args))
    end

    -- And zap them all.
    CityGrowthQueue = {}
end

function CityGrowthOnTurnFix(iPlayer)
  if iPlayer ~= Game.GetActivePlayer() then
    CityGrowthQueueNotifications = true
  end
end
GameEvents.PlayerDoTurn.Add(CityGrowthOnTurnFix);
-- This next event is when we need to dump the events to the screen
-- since population changes occur before during this "upkeep".
Events.ActivePlayerTurnStart.Add(CityGrowthOnActivePlayerFix)

------------------------------------------------------------------
--	Border Growth notification
------------------------------------------------------------------
-- initialise culture levels
cityCultureLevels = cityCultureLevels or {}

-- initialise culture levels for player cities
--aprint("Initializing Culture Levels")
for pCity in Players[Game.GetActivePlayer()]:Cities() do
	cityCultureLevels[pCity:GetID()] = pCity:GetJONSCultureLevel()
end

--[[
	Detects border growth and fires a notification
]]--
function CLNOnPlotAcquired(pPlot, iPlayerID)
	local pCity = pPlot:GetWorkingCity()
	if iPlayerID == 0 then
		if pCity then
			-- detect a culture level change
			local newLevel = pCity:GetJONSCultureLevel()
			if cityCultureLevels[pCity:GetID()] ~= newLevel then
				--aprint("Hex culture level. Owner is: ", pPlot:GetOwner())
				cityCultureLevels[pCity:GetID()] = newLevel
				if newLevel == 0 then
					return
				end
				--aprint("Firing Culture Change City")
				CustomNotification("CityTile", Locale.ConvertTextKey("TXT_KEY_NOTIFICATION_SUMMARY_CITY_TILE", pCity:GetName()), Locale.ConvertTextKey("TXT_KEY_NOTIFICATION_CITY_TILE", pCity:GetName()), pPlot, pCity, "Magenta", 0)
			end
		else
			-- this means a tile was grabbed outside the territory; I'm not checking for culture bomb yet so it triggers.
			--aprint("Firing Culture Change Empire")
			CustomNotification("CityTile", Locale.ConvertTextKey("TXT_KEY_NOTIFICATION_SUMMARY_EMPIRE_TILE"), Locale.ConvertTextKey("TXT_KEY_NOTIFICATION_EMPIRE_TILE"), pPlot, 0, "Magenta", 0)
		end
	end
end


LuaEvents.PlotAcquired.Add(CLNOnPlotAcquired)

--Alternate Override Method. Unused for Now
--[[
function VanillaCityGrowthOverride()
	return
end
LuaEvents.ImprovedEventsCityGrowth.Add(VanillaCityGrowthOverride)
]]--