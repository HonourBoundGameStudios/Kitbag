-- KitbagEvents — turn game events into a state snapshot and hand it to the rule engine.
--
-- The division of labour that ItemRack never had: this file knows about events and nothing about
-- which set should win; KitbagRules knows which set should win and nothing about events. So the
-- part that used to be untestable is now a table, and the part left here is a dozen lines of
-- wiring.

Kitbag = Kitbag or {}

local Rules = Kitbag.Rules
local Sets = Kitbag.Sets
local Compat = Kitbag.Compat

local Events = {}

local WATCHED = {
    "PLAYER_ENTERING_WORLD",
    "UPDATE_SHAPESHIFT_FORM",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "ZONE_CHANGED_NEW_AREA",
    "UPDATE_STEALTH",
    "PLAYER_UPDATE_RESTING",
    "PLAYER_MOUNT_DISPLAY_CHANGED",
    -- Coming back to life (RULE-6). A swap held off because the player was dead has to be woken by
    -- something, and these are the two the client offers: PLAYER_ALIVE for a resurrection or a
    -- release, PLAYER_UNGHOST for the end of a corpse run. `KitbagUI` watches the same pair to
    -- repaint its controls — same fact about the world, reached for two different reasons.
    "PLAYER_ALIVE",
    "PLAYER_UNGHOST",
    -- Buff and instance conditions (RULE-5). UNIT_AURA is noisy — it fires for every unit in the
    -- group — so OnEvent filters to the player before anything is evaluated.
    "UNIT_AURA",
    -- Spell-cast conditions (RULE-3). SENT rather than START: the pole has to be on before the cast
    -- resolves, and SENT is the earliest the client tells anyone. The four endings are all needed —
    -- a cast that fails must clear the condition exactly like one that succeeds, or the rule stays
    -- matched forever and the gear never comes back.
    "UNIT_SPELLCAST_SENT",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_CHANNEL_STOP",
}

-- The spell the player is currently casting, or nil. Kept here rather than read on demand because
-- there is nothing to read: by the time a swap has been decided the cast is usually already over.
local casting = nil

-- Named, unlike the addon's other unshown frames, because the engine is the one part of Kitbag with
-- nothing on screen: every other module can be reached through a window somebody can point at, and
-- this one is a file-local behind an event handler. A name gives a dump, /kit verify and the test
-- suite one handle on the wiring — the same reason KitbagInspectorTitle has one.
local frame = CreateFrame("Frame", "KitbagEventFrame")
-- The step a combat deferral is waiting on (RULE-7). A label for the dump, exactly like `held`
-- below: it is never replayed, because apply() clears it and decides again from the live world.
local pending = nil
-- What the engine declined to attempt because the player is dead (RULE-6). A label for the dump,
-- not a queue: unlike `pending` there is nothing here to replay — see apply().
local held = nil

-- The set the engine put on and has not undone yet. Deliberately NOT saved: after a reload the
-- engine has no idea whether the swap it remembers is still on, and re-deriving it from the first
-- event is both cheap and correct.
local active = nil

-- Which of WATCHED the client actually accepted, in order: { { name =, registered = }, … }.
-- Kept because Enable() registers inside pcall, which turns "this flavour has no such event" into
-- silence — and silence is indistinguishable from a rule that never matched (BUG-9).
local registered = {}

--- A flat snapshot of everything a rule may condition on. Flat on purpose: the rule engine compares
--- state[k] to when[k] and needs no knowledge of what any key means.
function Events.State()
    return {
        form = GetShapeshiftForm() or 0,
        combat = InCombatLockdown() and true or false,
        stealth = IsStealthed() and true or false,
        mounted = IsMounted() and true or false,
        resting = IsResting() and true or false,
        zone = GetRealZoneText() or "",
        -- false, not nil: a state key that is absent can never be compared against, and Rules
        -- compares state[k] to when[k] directly.
        spell = casting or false,
        -- A set, not a value: a buff condition names one of the thirty auras you have, so the
        -- matcher tests membership (see Rules.CONDITIONS).
        buff = Compat.PlayerBuffs(),
        instance = Compat.InstanceType(),
        -- Not a condition anyone can write a rule on (it is absent from Rules.CONDITIONS) — it is
        -- here because Rules.Defer reads the same snapshot the match was made from, and because
        -- ActionState is the one place that asks the client this (RULE-6).
        dead = Compat.ActionState().dead,
    }
end

-- Equipping is the only thing a step can ask for now that restore-previous is gone, so this is a
-- guard rather than a branch — an unknown action is a decision this function was never told about,
-- and doing nothing is the only safe reading of one.
local function perform(step)
    if step.action ~= "equip" then return end

    -- Held before the attempt as well as after it: the swap takes several frames, and without a
    -- claim in place every event arriving meanwhile would decide to equip the same set again.
    -- The claim is then settled by the outcome — a set that did NOT go on must not be held, or
    -- the rule that wants it never fires again (BUG-10).
    active = step.set
    Sets.Equip(step.set, true, function(ok)
        -- Settle only our own claim. A swap takes frames, and if something else has taken over in
        -- the meantime then this attempt's outcome is no longer what the engine is holding.
        if active == step.set then active = Rules.Held(active, step, ok) end
    end)
end

local function apply()
    local db, char = Kitbag.db, Kitbag.char
    -- Both cleared before anything is decided, and before the master switch: each describes a WAIT,
    -- and this call is about to work out afresh whether there still is one. A hold the engine will
    -- never revisit because auto-swap was turned off is a diagnostic outliving the wait it
    -- describes, and a `pending` that outlives the rule that owed it names a set nobody is waiting
    -- for. Clearing `pending` here is also what makes a combat deferral a re-decision rather than a
    -- replay (RULE-7).
    held, pending = nil, nil
    if not db.options.autoSwap then return end

    local state = Events.State()
    local winner = Rules.Match(char.rules, state)
    local step = Rules.Next(active, winner)
    if step.action == "none" then return end

    local defer = Rules.Defer(step, state, db.options)
    if defer == "combat" then
        pending = step
        return
    end
    if defer == "dead" then
        -- Nothing is stored to replay. Combat keeps its step because it clears in seconds and the
        -- world it matched in is still recognisably the same one; a corpse run is minutes long and
        -- ends somewhere else entirely — you died in bear form, released, and are now a ghost in no
        -- form at all. PLAYER_ALIVE/PLAYER_UNGHOST run apply() like any other event, so the step is
        -- decided from the world the player actually came back to (RULE-6).
        held = step.set or step.action
        return
    end
    perform(step)
end

-- Spell casts only matter for the player, and UNIT_SPELLCAST_* fires for every unit in range.
--
-- Two things about this feature are worth being plain about, because both look like bugs.
--
-- First, equipping cancels a cast in progress, so the attempt that triggers the swap is the one that
-- pays for it: you click Fishing, the pole goes on, that cast is lost, and the next one works.
-- SENT is the earliest hook the client offers, so this is inherent rather than a shortcut, and
-- ItemRack behaved the same way for the same reason.
--
-- Second, the grace window. It was built for a behaviour that no longer exists: a cancelled cast
-- fires FAILED immediately, and while rules could restore-previous, clearing the condition there
-- made the rule stop matching, the restore fire, and the pole come straight back off — the feature
-- undid itself within a frame of working. Restore-previous is gone, so nothing takes the pole off
-- any more and the window no longer prevents that.
--
-- It is kept deliberately rather than left in by omission: expiring the condition the instant a cast
-- ends would flap `active` on every cast, and re-deciding on a state that changes twice a second is
-- how an engine ends up fighting itself. But the ORIGINAL reason is now false, and a comment that
-- goes on claiming it would be the next reader's wrong premise.
local CAST_GRACE = 12

local castExpiry = nil

local function usesBuffs()
    for _, rule in ipairs(Kitbag.char.rules) do
        if rule.when and rule.when.buff ~= nil then return true end
    end
    return false
end

local function onCast(event, unit, ...)
    if unit ~= "player" then return false end

    if event == "UNIT_SPELLCAST_SENT" then
        casting, castExpiry = Compat.CastSpellName(unit, ...), nil
        return true
    end

    if not casting then return false end
    castExpiry = GetTime() + CAST_GRACE
    -- Nothing has changed yet — the condition still holds until the window closes.
    return false
end

-- Checked on a frame handler rather than a timer so it needs nothing from the flavour, and so a
-- reload cannot leave a scheduled callback holding a stale set name.
frame:SetScript("OnUpdate", function()
    if castExpiry and GetTime() >= castExpiry then
        casting, castExpiry = nil, nil
        apply()
    end
end)

function frame:OnEvent(event, unit, ...)
    -- UNIT_AURA fires for every unit in the group and a raid produces a torrent of it. Anyone
    -- else's buffs cannot change what this character should be wearing.
    if event == "UNIT_AURA" then
        if unit ~= "player" then return end
        -- Your own auras change several times a second in combat, and evaluating every rule each
        -- time to conclude nothing has changed is the kind of cost that gets an addon blamed for
        -- frame drops. If no rule asks about a buff, this event cannot change the answer.
        if not usesBuffs() then return end
        apply()
        return
    end

    if string.sub(event, 1, 15) == "UNIT_SPELLCAST_" then
        if not onCast(event, unit, ...) then return end
        apply()
        return
    end

    -- No case for PLAYER_REGEN_ENABLED, deliberately, and that absence is RULE-7's whole fix. It
    -- used to perform the step it had been holding since the fight started — a step decided in a
    -- world that has since moved on, so you entered in bear form, dropped form mid-fight, and the
    -- set went on at the end of the fight for a condition that expired a minute ago. apply()
    -- re-decides from the live world like every other path here, and answers `none` when nothing
    -- matches any more.
    --
    -- It also subsumes RULE-6's guard, which used to be written out here: combat most often ends
    -- because you DIED, and that path reached perform() through the one door that skipped apply()
    -- and therefore skipped Rules.Defer with it.
    apply()
end

function Events.Enable()
    for i, e in ipairs(WATCHED) do
        -- Not every event exists on every flavour; registering an unknown one is a hard error.
        local ok = pcall(frame.RegisterEvent, frame, e)
        -- Asked of the frame afterwards rather than inferred from that pcall: the question is
        -- whether the client is going to SEND the event, and only the frame can answer it. Both
        -- results are kept apart on purpose — a pcall that itself failed must not read as a yes.
        local asked, on = pcall(frame.IsEventRegistered, frame, e)
        registered[i] = { name = e, registered = (ok and asked and on) and true or false }
    end
    frame:SetScript("OnEvent", frame.OnEvent)
end

--- What the engine is holding, for the dump (BUG-9). Nothing here is readable any other way: both
--- of these states make a MATCHED rule do nothing at all, and look exactly like it never matched.
function Events.Diagnostics()
    return {
        active = active,
        deferred = pending and pending.set or nil,
        -- The corpse-run hold. Without this the dump shows a matched rule doing nothing and looking
        -- exactly like a rule that never fired — which is the whole reason this table exists.
        heldWhileDead = held,
        events = registered,
    }
end

--- Why is the current state producing the set it is? Backs `/kit why`.
function Events.Explain()
    return Rules.Explain(Kitbag.char.rules, Events.State())
end

Kitbag.Events = Events
return Events
