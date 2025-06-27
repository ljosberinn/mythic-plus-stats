---@type string, table
local AddOnName, Private = ...

---@alias KeyState "timed" | "completed" | "abandoned"

---@class MythicPlusStatsDB
---@field runsById table<number, table<number, table<KeyState, MythicPlusStatsEntry[]>>>

---@class MythicPlusStatsEntry
---@field countRequired number how much count was required
---@field countReached number how much count was seen
---@field encounters MythicPlusStatsEncounter[]
---@field deaths number total amount of deaths
---@field timeLoss number time loss in seconds, from death or other sources
---@field completionTime number overall run timer
---@field timer number the overall dungeon timer
---@field startTime number key start time
---@field fingerprint string party fingerprint

---@class MythicPlusStatsEncounter
---@field id number encounter id
---@field success boolean kill/wipe indication
---@field startTime number encounter start time
---@field endTime number encounter end time
---@field startCount number how much count was seen on encounter start
---@field endCount number how much count was seen on encounter end
---@field startLossOffset number seconds to offset the encounter starttimer against due to time loss
---@field endLossOffset number seconds to offset the encounter end timer against due to time loss

EventUtil.ContinueOnAddOnLoaded(AddOnName, function()
	---@type MythicPlusStatsDB
	MythicPlusStatsDB = MythicPlusStatsDB or {}
	MythicPlusStatsDB.runsById = MythicPlusStatsDB.runsById or {}
end)

---@class PendingMythicPlusStatsEntry: MythicPlusStatsEntry
---@field mapId number
---@field level number

---@return PendingMythicPlusStatsEntry
local function GetDefaultPendingEntry()
	return {
		countRequired = 0,
		countReached = 0,
		encounters = {},
		deaths = 0,
		mapId = 0,
		timeLoss = 0,
		level = 0,
		completionTime = 0,
		startTime = 0,
	}
end

---@alias LoggingColor "error"|"warning"|"info"|"success"

---@param kind LoggingColor
---@param message string
local function Log(kind, message)
	---@type table<LoggingColor, string>
	local colors = {
		error = "00FF0000",
		warning = "FFFFD900",
		info = "add8e600",
		success = "FF00FF00",
	}

	local color = colors[kind]

	local addonLabel = string.format("|T%s:0|t %s", C_AddOns.GetAddOnMetadata(AddOnName, "IconTexture"), AddOnName)

	print(string.format("[%s] %s", addonLabel, WrapTextInColorCode(message, color)))
end

---@param time number
---@return string
local function FormatToMinutes(time)
	Log("info", "FormatToMinutes: " .. time)
	if time < 60 then
		return string.format("00:%02d", time)
	end

	return string.format("%02d:%02d", math.floor(time / 60), time % 60)
end

---@class PartyMemberInfo
---@field name string
---@field realm string
---@field guid string
---@field class string

---@param unit string
---@return PartyMemberInfo?
local function GetPartyMemberInfo(unit)
	if not UnitExists(unit) then
		return
	end

	local name, realm = UnitName(unit)

	return {
		name = name,
		realm = realm or GetRealmName(),
		guid = UnitGUID(unit) or "unknown",
		class = UnitClass(unit),
	}
end

---@return string
local function CreatePartyFingerprint()
	local members = {}

	if UnitInParty("player") then
		for i = 1, 5 do
			local info = GetPartyMemberInfo("party" .. i)

			if info then
				table.insert(members, info)
			end
		end
	else
		local info = GetPartyMemberInfo("player")

		if info then
			table.insert(members, info)
		end
	end

	table.sort(members, function(a, b)
		if a.name == b.name then
			return a.realm < b.realm
		end
		return a.name < b.name
	end)

	return C_EncodingUtil.SerializeJSON(members)
end

---@param mapId number
---@param level number
---@param requiredCount number
---@param timer number
---@return MythicPlusStatsEntry[]?, KeyState?
local function FindComparableRuns(mapId, level, requiredCount, timer)
	local history = MythicPlusStatsDB.runsById[mapId]

	if not history then
		return
	end

	local forThisLevel = history[level]

	if not forThisLevel then
		return
	end

	local relevantRuns = nil
	local keyState = nil

	if #forThisLevel.timed > 0 then
		relevantRuns = forThisLevel.timed
		keyState = "timed"
	elseif #forThisLevel.completed > 0 then
		relevantRuns = forThisLevel.completed
		keyState = "completed"
	elseif #forThisLevel.abandoned > 0 then
		relevantRuns = forThisLevel.abandoned
		keyState = "abandoned"
	end

	if relevantRuns == nil or keyState == nil then
		return
	end

	---@type MythicPlusStatsEntry[]
	local copy = {}
	for _, run in ipairs(relevantRuns) do
		if #run.encounters > 0 and requiredCount == run.countRequired and timer == run.timer then
			table.insert(copy, run)
		end
	end

	if #copy == 0 then
		return
	end

	-- sort by:
	-- 1. completionTime asc, faster better
	-- 2. countReached desc, more better
	-- 3. deaths asc, less better
	-- 4. startTime desc, more recent better
	table.sort(copy, function(a, b)
		if a.completionTime == b.completionTime then
			if a.countReached == b.countReached then
				if a.deaths == b.deaths then
					return a.startTime > b.startTime
				end

				return a.deaths < b.deaths
			end

			return a.countReached > b.countReached
		end

		return a.completionTime < b.completionTime
	end)

	return copy, keyState
end

---@param mapId number
---@param encounterId number
---@return number
local function GetTotalPullCountForEncounterId(mapId, encounterId)
	local history = MythicPlusStatsDB.runsById[mapId]

	if not history then
		return 0
	end

	local total = 0

	for _, levelData in pairs(history) do
		for _, run in pairs(levelData.timed) do
			for _, encounter in pairs(run.encounters) do
				if encounter.id == encounterId then
					total = total + 1
				end
			end
		end
	end

	return total
end

---@param mapId number
---@param encounterId number
---@return number
local function GetTotalKillCountForEncounterId(mapId, encounterId)
	local history = MythicPlusStatsDB.runsById[mapId]

	if not history then
		return 0
	end

	local total = 0

	for _, levelData in pairs(history) do
		for _, run in pairs(levelData.timed) do
			for _, encounter in pairs(run.encounters) do
				if encounter.id == encounterId and encounter.success then
					total = total + 1
				end
			end
		end
	end

	return total
end

---@param mapId number
---@param encounterName string
---@param previousRun MythicPlusStatsEntry
---@param currentRun MythicPlusStatsEntry
---@param previousRunState KeyState
---@param currentEncounter MythicPlusStatsEncounter
---@param previousEncounter MythicPlusStatsEncounter
---@param isEncounterEnd boolean
local function GetEncounterComparisonLines(
	mapId,
	encounterName,
	previousRun,
	currentRun,
	previousRunState,
	currentEncounter,
	previousEncounter,
	isEncounterEnd
)
	local lines = {
		string.format("Previous best for %s %s:", isEncounterEnd and "finishing" or "pulling", encounterName),
	}

	local previousDiff = 0
	local currentDiff = 0

	if isEncounterEnd then
		previousDiff = (previousEncounter.endTime + previousEncounter.endLossOffset)
			- (previousEncounter.startTime + previousEncounter.startLossOffset)
		currentDiff = (currentEncounter.endTime + currentEncounter.endLossOffset)
			- (currentEncounter.startTime + currentEncounter.startLossOffset)
	else
		previousDiff = (previousEncounter.startTime + previousEncounter.startLossOffset) - previousRun.startTime
		currentDiff = (currentEncounter.startTime + currentEncounter.startLossOffset) - currentRun.startTime
	end

	if previousDiff == currentDiff then
		if isEncounterEnd then
			table.insert(lines, "-- encounter duration identical.")
		else
			table.insert(lines, "-- you pulled at the same second.")
		end
	elseif previousDiff > currentDiff then
		table.insert(lines, string.format("-- you are %s faster.", FormatToMinutes(previousDiff - currentDiff)))
	else
		table.insert(lines, string.format("-- you are %s slower.", FormatToMinutes(currentDiff - previousDiff)))
	end

	local previousCount = isEncounterEnd and previousEncounter.endCount or previousEncounter.startCount
	local currentCount = isEncounterEnd and currentEncounter.endCount or currentEncounter.startCount

	if previousCount == currentCount then
		table.insert(lines, string.format("-- you have the same count of %d.", currentEncounter.endCount))
	elseif previousCount > currentCount then
		table.insert(
			lines,
			string.format(
				"-- you have %d less count (%d current, %d before).",
				previousCount - currentCount,
				currentCount,
				previousCount
			)
		)
	else
		table.insert(
			lines,
			string.format(
				"-- you have %d more count (%d current, %d before).",
				currentCount - previousCount,
				currentCount,
				previousCount
			)
		)
	end

	if not isEncounterEnd then
		local previousCountGained = previousEncounter.endCount - previousEncounter.startCount

		if previousCountGained > 0 then
			table.insert(
				lines,
				string.format("-- last time, you gained %d count during the encounter.", previousCountGained)
			)
		end
	end

	local date = C_DateAndTime.GetCalendarTimeFromEpoch(previousRun.startTime * 1000 * 1000)

	table.insert(
		lines,
		string.format(
			"-- this is comparing against a run that was %s on %d-%d-%d",
			string.upper(previousRunState),
			date.year,
			date.month,
			date.monthDay
		)
	)

	if isEncounterEnd then
		table.insert(
			lines,
			string.format(
				"-- total kills across all key levels: %d",
				GetTotalKillCountForEncounterId(mapId, currentEncounter.id)
			)
		)
	else
		table.insert(
			lines,
			string.format(
				"-- total pulls across key levels: %d",
				GetTotalPullCountForEncounterId(mapId, currentEncounter.id)
			)
		)
	end

	return lines
end

---@param mapId number
---@param keyLevel number
---@return string[]
local function GetStatLinesForMapAndLevel(mapId, keyLevel)
	local stats = {
		total = 0,
		abandoned = 0,
		completed = 0,
		timed = 0,
	}

	local history = MythicPlusStatsDB.runsById[mapId]

	if history then
		if keyLevel then
			local keyLevelData = history[keyLevel]

			if keyLevelData ~= nil then
				stats.total = #keyLevelData.timed + #keyLevelData.completed + #keyLevelData.abandoned
				stats.abandoned = #keyLevelData.abandoned
				stats.completed = #keyLevelData.completed
				stats.timed = #keyLevelData.timed
			end
		else
			for _, data in pairs(history) do
				stats.total = stats.total + #data.timed + #data.completed + #data.abandoned
				stats.abandoned = stats.abandoned + #data.abandoned
				stats.completed = stats.completed + #data.completed
				stats.timed = stats.timed + #data.timed
			end
		end
	end

	local name = C_ChallengeMode.GetMapUIInfo(mapId)

	return {
		keyLevel and string.format("Stats for %s +%d:", name, keyLevel) or string.format("Stats for %s:", name),
		string.format("%d total", stats.total),
		string.format("%d abandoned (%.1f%%)", stats.abandoned, (stats.abandoned / stats.total) * 100),
		string.format("%d completed (%.1f%%)", stats.completed, (stats.completed / stats.total) * 100),
		string.format("%d timed (%.1f%%)", stats.timed, (stats.timed / stats.total) * 100),
	}
end

local inProgressRun = GetDefaultPendingEntry()

---@type FunctionContainer|nil
local abandonedKeyTimer = nil
---@type FunctionContainer|nil
local activityTimer = nil

local frame = CreateFrame("Frame", "MythicPlusStatsListenerFrame", UIParent)
frame:Hide()
frame:SetScript(
	"OnEvent",
	---@param self Frame
	---@param event WowEvent
	function(self, event, ...)
		if event == "ZONE_CHANGED_NEW_AREA" or event == "LOADING_SCREEN_DISABLED" then
			if activityTimer ~= nil then
				activityTimer:Cancel()
				activityTimer = nil
			end

			activityTimer = C_Timer.NewTimer(1, function()
				local _, instanceType, difficultyId = GetInstanceInfo()

				local shouldRegister = instanceType == "party"
					and (
						difficultyId == DifficultyUtil.ID.DungeonMythic
						or difficultyId == DifficultyUtil.ID.DungeonChallenge
					)

				local eventsToRegister = {
					"ENCOUNTER_START",
					"ENCOUNTER_END",
					"CHALLENGE_MODE_START",
					"CHALLENGE_MODE_COMPLETED",
					"CHALLENGE_MODE_DEATH_COUNT_UPDATED",
					"SCENARIO_CRITERIA_UPDATE",
				}

				if shouldRegister then
					if abandonedKeyTimer ~= nil and C_ChallengeMode.IsChallengeModeActive() then
						Log("info", "Not abandoning run.")
						abandonedKeyTimer:Cancel()
						abandonedKeyTimer = nil
						return
					end

					local anyRegistered = false

					for _, eventToRegister in ipairs(eventsToRegister) do
						if not self:IsEventRegistered(eventToRegister) then
							self:RegisterEvent(eventToRegister)
							anyRegistered = true
						end
					end

					if anyRegistered then
						Log("info", "Waiting for key to start.")
					end
				else
					if inProgressRun.mapId > 0 then
						local abandonmentThreshold = 45

						if abandonedKeyTimer ~= nil then
							abandonedKeyTimer:Cancel()
							abandonedKeyTimer = nil
						else
							Log(
								"info",
								string.format(
									"Zoning out while a dungeon is in progress. Considering this run as abandoned if you don't zone in again within the next %d seconds.",
									abandonmentThreshold
								)
							)
						end

						abandonedKeyTimer = C_Timer.NewTimer(abandonmentThreshold, function()
							local map = inProgressRun.mapId
							local level = inProgressRun.level

							---@type MythicPlusStatsEntry
							local runData = {
								countRequired = inProgressRun.countRequired,
								countReached = inProgressRun.countReached,
								encounters = inProgressRun.encounters,
								deaths = inProgressRun.deaths,
								mapId = map,
								timeLoss = inProgressRun.timeLoss,
								level = level,
								completionTime = 0,
								startTime = inProgressRun.startTime,
								timer = inProgressRun.timer,
								fingerprint = inProgressRun.fingerprint,
							}

							local hasAnyProgress = runData.countReached > 0 or #runData.encounters > 0

							if hasAnyProgress then
								table.insert(MythicPlusStatsDB.runsById[map][level].abandoned, runData)

								Log("info", "Run abandoned.")
							else
								Log("info", "Ignoring run as count was 0 and no encounter was engaged.")
							end

							inProgressRun = GetDefaultPendingEntry()

							if hasAnyProgress then
								Log("info", table.concat(GetStatLinesForMapAndLevel(map, level), "\n"))
							end

							abandonedKeyTimer = nil
						end)

						return
					end

					if C_ChallengeMode.IsChallengeModeActive() then
						Log("warning", "Zoned into an in-progress key without info, ignoring.")
						return
					end

					local anyUnregistered = false

					for _, eventToRegister in ipairs(eventsToRegister) do
						if self:IsEventRegistered(eventToRegister) then
							self:UnregisterEvent(eventToRegister)
							anyUnregistered = true
						end
					end

					if anyUnregistered then
						Log("info", "Going into standby.")
					end
				end
			end)
		elseif event == "ENCOUNTER_START" then
			local encounterId, encounterName = ...

			---@type MythicPlusStatsEncounter
			local entry = {
				id = encounterId,
				success = false,
				startTime = GetServerTime(),
				endTime = 0,
				startCount = inProgressRun.countReached,
				endCount = 0,
				startLossOffset = inProgressRun.timeLoss,
				endLossOffset = 0,
			}

			table.insert(inProgressRun.encounters, entry)

			local relevantRuns, runKeyState = FindComparableRuns(
				inProgressRun.mapId,
				inProgressRun.level,
				inProgressRun.countRequired,
				inProgressRun.timer
			)

			if relevantRuns == nil or runKeyState == nil then
				return
			end

			for _, run in pairs(relevantRuns) do
				for _, encounter in pairs(run.encounters) do
					if encounter.id == encounterId then
						Log(
							"info",
							table.concat(
								GetEncounterComparisonLines(
									inProgressRun.mapId,
									encounterName,
									run,
									inProgressRun,
									runKeyState,
									entry,
									encounter,
									false
								),
								"\n"
							)
						)

						return
					end
				end
			end
		elseif event == "ENCOUNTER_END" then
			local encounterId, encounterName, _, _, success = ...

			for _, encounter in ipairs(inProgressRun.encounters) do
				-- important to check against end time to not modify possibly present previous wipes/resets
				if encounter.id == encounterId and encounter.endTime == 0 then
					encounter.endTime = GetServerTime()
					encounter.endLossOffset = inProgressRun.timeLoss
					encounter.endCount = inProgressRun.countReached
					encounter.success = success == 1

					-- don't report on wipes/resets
					if not success then
						return
					end

					local relevantRuns, runKeyState = FindComparableRuns(
						inProgressRun.mapId,
						inProgressRun.level,
						inProgressRun.countRequired,
						inProgressRun.timer
					)

					if relevantRuns == nil or runKeyState == nil then
						return
					end

					for _, run in pairs(relevantRuns) do
						for _, previousEncounter in pairs(run.encounters) do
							if previousEncounter.id == encounterId and previousEncounter.success then
								Log(
									"info",
									table.concat(
										GetEncounterComparisonLines(
											inProgressRun.mapId,
											encounterName,
											run,
											inProgressRun,
											runKeyState,
											encounter,
											previousEncounter,
											true
										),
										"\n"
									)
								)

								return
							end
						end
					end

					return
				end
			end
		elseif event == "CHALLENGE_MODE_START" then
			local mapId = C_ChallengeMode.GetActiveChallengeMapID()

			if mapId == nil then
				return
			end

			local level = C_ChallengeMode.GetActiveKeystoneInfo()

			MythicPlusStatsDB.runsById[mapId] = MythicPlusStatsDB.runsById[mapId] or {}
			MythicPlusStatsDB.runsById[mapId][level] = MythicPlusStatsDB.runsById[mapId][level] or {}
			MythicPlusStatsDB.runsById[mapId][level].completed = MythicPlusStatsDB.runsById[mapId][level].completed
				or {}
			MythicPlusStatsDB.runsById[mapId][level].abandoned = MythicPlusStatsDB.runsById[mapId][level].abandoned
				or {}
			MythicPlusStatsDB.runsById[mapId][level].timed = MythicPlusStatsDB.runsById[mapId][level].timed or {}

			if abandonedKeyTimer ~= nil and mapId == inProgressRun.mapId and level == inProgressRun.level then
				return
			end

			local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapId)

			inProgressRun.mapId = mapId
			inProgressRun.level = level
			inProgressRun.timer = timeLimit
			inProgressRun.startTime = GetServerTime() + 10
			inProgressRun.fingerprint = CreatePartyFingerprint()

			local attempts = 0
			local history = MythicPlusStatsDB.runsById[mapId]
			if history and history[level] then
				attempts = #history[level].timed + #history[level].completed + #history[level].abandoned
			end

			Log(
				"info",
				string.format("Started %s +%d. You were here before %d times. Best of luck!", name, level, attempts)
			)
		elseif event == "CHALLENGE_MODE_COMPLETED" then
			local info = C_ChallengeMode.GetChallengeCompletionInfo()

			if not info or info.practiceRun then
				return
			end

			if inProgressRun.mapId == 0 then
				Log(
					"error",
					string.format(
						"Saw %s but we're not aware of an ongoing run. As this info is only partial, we're discarding this.",
						event
					)
				)
				return
			end

			if inProgressRun.mapId ~= info.mapChallengeModeID then
				Log(
					"error",
					string.format(
						"Saw %s but '%s' doesn't match the most recently started key '%s'. This indicates partial info, so we're discarding this.",
						event,
						select(1, C_ChallengeMode.GetMapUIInfo(info.mapChallengeModeID)),
						select(1, C_ChallengeMode.GetMapUIInfo(inProgressRun.mapId))
					)
				)
				return
			end

			if inProgressRun.level ~= info.level then
				Log(
					"error",
					string.format(
						"Saw %s but the keystone level %d doesn't match the most recently started key of level %d. This indicates partial info, so we're discarding this.",
						event,
						info.level,
						inProgressRun.level
					)
				)
				return
			end

			if #inProgressRun.encounters == 0 then
				Log(
					"error",
					string.format(
						"Saw %s but no encounters. This indicates partial info, so we're discarding this.",
						event
					)
				)
				return
			end

			---@type MythicPlusStatsEntry
			local runData = {
				countRequired = inProgressRun.countRequired,
				countReached = inProgressRun.countReached,
				encounters = inProgressRun.encounters,
				deaths = inProgressRun.deaths,
				timeLoss = inProgressRun.timeLoss,
				completionTime = info.time,
				startTime = inProgressRun.startTime,
				timer = inProgressRun.timer,
				fingerprint = inProgressRun.fingerprint,
			}

			if info.onTime then
				table.insert(MythicPlusStatsDB.runsById[inProgressRun.mapId][inProgressRun.level].timed, runData)
			else
				table.insert(MythicPlusStatsDB.runsById[inProgressRun.mapId][inProgressRun.level].completed, runData)
			end

			inProgressRun = GetDefaultPendingEntry()

			Log("info", table.concat(GetStatLinesForMapAndLevel(info.mapChallengeModeID, info.level), "\n"))
		elseif event == "CHALLENGE_MODE_DEATH_COUNT_UPDATED" then
			local count, timeLost = C_ChallengeMode.GetDeathCount()
			inProgressRun.deaths = count
			inProgressRun.timeLoss = timeLost
		elseif event == "SCENARIO_CRITERIA_UPDATE" then
			-- while zoned out, ignore updates irrelevant to key progress
			if not C_ChallengeMode.IsChallengeModeActive() then
				return
			end

			local _, _, steps = C_Scenario.GetStepInfo()

			if not steps or steps <= 0 then
				return
			end

			-- assuming the last step is always the Enemy Forces step, this prevents having to iterate over all
			for i = steps, 1, -1 do
				local criteriaInfo = C_ScenarioInfo.GetCriteriaInfo(i)

				if criteriaInfo.isWeightedProgress and criteriaInfo.quantityString then
					local progress = tonumber(
						string.sub(criteriaInfo.quantityString, 1, string.len(criteriaInfo.quantityString) - 1)
					)

					if criteriaInfo.totalQuantity ~= nil and progress ~= nil then
						inProgressRun.countRequired = criteriaInfo.totalQuantity
						-- on CHALLENGE_MODE_COMPLETED, progress will get spammed with 0
						if progress > inProgressRun.countReached then
							inProgressRun.countReached = progress
						end
						return
					end
				end
			end
		end
	end
)
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("LOADING_SCREEN_DISABLED")
