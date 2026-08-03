--[[
    FilterGate — The one filterFor() chokepoint.
    ───────────────────────────────────────────────
    Every AI-generated string that will be shown to a player MUST pass
    through FilterGate.filterFor(). Fail-closed: on any error, return
    nil (display nothing) rather than unfiltered text.

    This is the single boundary between "model output" and "player-visible
    string." There is no second path. If a string hasn't passed filterFor(),
    it does not render.

    Usage:
        local FilterGate = require(ReplicatedStorage.Lucineer.FilterGate)
        -- For AI-generated broadcast text (signs, NPCs, global displays):
        --   Pass the authoring player's UserId if a player triggered it,
        --   or a configured server UserId for pure AI output.
        local filtered = FilterGate.filterFor(modelText, authorUserId)
        if filtered then
            UIManager.displayChatResponse(filtered)
        else
            -- filter failed → display nothing (fail-closed)
        end
]]

local TextService = game:GetService("TextService")

local FilterGate = {}

--[[
    Filter a string for broadcast display (non-chat).

    Calls Roblox TextService:FilterStringAsync, which performs the
    platform-standard text moderation pass. On success, returns the
    filtered string suitable for broadcast to all players. On ANY error
    — HTTP failure, timeout, malformed input — returns nil, meaning
    "display nothing."

    The contract is simple: never return the unfiltered text.
    If the filter breaks, the string doesn't show. That's fail-closed.

    BUG FIX (BUG-F2): The parameter was documented as "the player who
    will see it" (the viewer/recipient), but FilterStringAsync expects
    the AUTHOR's UserId — the player who created or triggered the text.
    For AI-generated text with no human author, pass the UserId of the
    player whose request triggered the generation (this gives Roblox
    the correct filtering context based on account age/settings).
    If truly no triggering player exists, pass a configured server UserId.

    @param text string — the text to filter
    @param authorUserId number — UserId of the player who authored or
        triggered this text (NOT the viewer). FilterStringAsync uses
        this to apply age-appropriate filtering.
    @return string? — the filtered string, or nil on any failure
]]
function FilterGate.filterFor(text: string, authorUserId: number): string?
    if type(text) ~= "string" or text == "" then
        return nil
    end

    if typeof(authorUserId) ~= "number" or authorUserId <= 0 then
        return nil
    end

    local ok, filterResult = pcall(function()
        return TextService:FilterStringAsync(text, authorUserId)
    end)

    if not ok then
        -- Filter failed — fail closed. No unfiltered text reaches the player.
        warn(string.format("[FilterGate] FilterStringAsync failed for author %d: %s",
            authorUserId, tostring(filterResult)))
        return nil
    end

    -- GetNonChatStringForBroadcastAsync is the correct method for
    -- non-chat displayed text (UI labels, notifications, etc.).
    -- For chat messages, use filterForChat instead.
    local ok2, filteredText = pcall(function()
        return filterResult:GetNonChatStringForBroadcastAsync()
    end)

    if not ok2 then
        warn(string.format("[FilterGate] GetNonChatStringForBroadcastAsync failed for author %d: %s",
            authorUserId, tostring(filteredText)))
        return nil
    end

    return filteredText
end

--[[
    Filter a string intended as a chat message from one specific user
    to another. Use this for chat-style messages where the sender
    identity matters for the filtering context.

    @param text string — the text to filter
    @param fromUserId number — UserId of the message sender
    @param toUserId number — UserId of the recipient
    @return string? — filtered text, or nil on failure
]]
function FilterGate.filterForChat(text: string, fromUserId: number, toUserId: number): string?
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local ok, filterResult = pcall(function()
        return TextService:FilterStringAsync(text, fromUserId)
    end)

    if not ok then
        warn(string.format("[FilterGate] FilterStringAsync (chat) failed: %s", tostring(filterResult)))
        return nil
    end

    local ok2, filteredText = pcall(function()
        return filterResult:GetChatForUserAsync(toUserId)
    end)

    if not ok2 then
        warn(string.format("[FilterGate] GetChatForUserAsync failed: %s", tostring(filteredText)))
        return nil
    end

    return filteredText
end

return FilterGate
