-- KitbagDebug — write the whole world into SavedVariables so it can be read outside the game.
--
-- The addon has no way to talk to anything outside the client: no sockets, no HTTP, no file IO. The
-- one sanctioned channel out is SavedVariables, which the client writes on /reload and on logout.
-- So diagnosis goes: click Dump, /reload, and the file on disk holds everything that was true at the
-- moment of the click.
--
-- This exists because the alternative is asking the player to read numbers out of their chat frame
-- and type them to someone else. Every round trip through a human loses detail and costs a session,
-- and the detail that gets lost is reliably the one that mattered — "the off hand is empty" and
-- "the SET says the off hand should be empty" are different facts that sound identical when relayed.
--
-- Report() is PURE: a plain reading of the world in, text out. The format is the load-bearing part,
-- so it is tested exhaustively in Tests/debug_test.lua rather than by taking a dump and squinting.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Rules = Kitbag.Rules

local Debug = {}

-- How many dumps to keep. More than one because the interesting comparison is usually "working" then
-- "broken"; few enough that SavedVariables does not grow without bound, since nothing ever prunes it
-- but this line.
local KEEP = 5

Debug.KEEP = KEEP

local function label(slotId)
    local slot = Core and Core.SlotById(slotId)
    return slot and slot.label or ("slot " .. tostring(slotId))
end

-- What a set stores for one slot, in words that keep the three states apart. They are the states the
-- whole planner turns on: an item to put on, a deliberate empty, and no opinion at all.
local function stored(value)
    if value == false then return "(empty)" end
    if value == nil then return "(not named)" end
    return tostring(value)
end

-- A state value in words. A membership condition holds a SET rather than a value (thirty buffs, the
-- rule names one), and pairs() order would make two identical dumps look different — so it is sorted
-- and joined rather than printed as a table address nobody can read.
local function shown(value)
    if type(value) ~= "table" then return tostring(value) end
    local members = {}
    for k, held in pairs(value) do
        if held then members[#members + 1] = tostring(k) end
    end
    table.sort(members)
    if #members == 0 then return "(none)" end
    return table.concat(members, ", ")
end

-- Numbers compare as numbers, so form 10 sorts after form 2 rather than between 1 and 3. Mixed or
-- non-numeric keys fall back to their text, which is enough to make the order stable — and stable is
-- the whole requirement: two dumps must differ only where the world did.
local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == "number" and type(b) == "number" then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

--- The dump, as lines. PURE — see Tests/debug_test.lua.
--
-- Everything is stated, including the absences: a slot with nothing in it prints "(nothing)" rather
-- than being left out, because "the dump did not mention the off hand" and "the off hand is empty"
-- are indistinguishable to the reader and only one of them is a fact.
function Debug.Report(world)
    world = world or {}
    local out = {}
    local function add(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    -- Which build produced this. First, because a dump from a stale deploy is worse than no dump —
    -- it sends the reader hunting for a bug in source the client never loaded (see UI-15).
    add("Kitbag dump — %s", tostring(world.when))
    add("addon %s | %s | interface %s",
        tostring(world.version), tostring(world.flavour), tostring(world.interface))
    if world.character then add("character: %s", tostring(world.character)) end
    -- The 1 -> 2 migration runs exactly once, on data nobody can regenerate. Whether it ran is a
    -- fact about the file, so it is read off the file rather than inferred from the shape of a set.
    add("db schema: %s", tostring(world.schema))
    add("bank open: %s", tostring(world.bankOpen))

    -- The world the planner was handed. Every slot in slot order, present or not.
    add("")
    add("WORN")
    for _, s in ipairs(Core and Core.SLOTS or {}) do
        local key = world.worn and world.worn[s.id]
        add("  %-12s %2d: %s", s.label, s.id, key and tostring(key) or "(nothing)")
    end

    add("")
    add("BAGS")
    if not world.bags or #world.bags == 0 then
        add("  (not read)")
    else
        for _, bag in ipairs(world.bags) do
            -- family is why a bag with room still refuses a helmet, so it is dumped beside the count
            -- rather than folded into a single "free slots" total.
            add("  bag %s: %s free, family %s",
                tostring(bag.id), tostring(bag.free), tostring(bag.family))
        end
    end

    -- The forms the CLIENT reported, verbatim. GetShapeshiftFormInfo's signature differs between
    -- flavours and reading it wrong does not error — it silently labels every form "form <n>". That
    -- fallback string is the fingerprint of the bug, so it is passed through untouched.
    add("")
    add("FORMS")
    local formIndices = sortedKeys(world.forms or {})
    if #formIndices == 0 then
        add("  (no forms)")
    else
        for _, i in ipairs(formIndices) do
            add("  %s: %s", tostring(i), tostring(world.forms[i]))
        end
    end

    -- The snapshot the rule engine matched against, which is the other half of "why am I wearing
    -- this". Absent and false are kept apart here for the same reason they are in a set's slots.
    add("")
    add("STATE")
    if not world.state then
        add("  (not read)")
    else
        for _, k in ipairs(sortedKeys(world.state)) do
            add("  %s = %s", tostring(k), shown(world.state[k]))
        end
    end

    -- Every rule and why it did or didn't fire — `/kit why`, written to disk. The question a rule
    -- bug asks is never "what are my rules" but "why did THAT one win", so the verdict sits on each
    -- row rather than being left for the reader to derive from priorities.
    local explain = world.explain or {}
    local rules = world.rules or {}
    add("")
    add("RULES — chosen: %s", tostring(explain.chosen or "(none)"))
    if #rules == 0 then
        -- Stated, because "no rules" is the likeliest explanation for "it never swapped" and a
        -- missing section cannot be told apart from a dump taken before the rules were read.
        add("  (no rules)")
    else
        -- Numbered by list position: that order is the documented tiebreak between equal priorities,
        -- so a reader comparing this to the rule list needs the same numbers on both.
        for i, rule in ipairs(rules) do
            local entry = explain.considered and explain.considered[i]
            local verdict
            if not entry then
                verdict = "(not explained)"
            elseif not entry.matched then
                verdict = "no: " .. tostring(entry.reason)
            elseif explain.chosen == rule.set then
                verdict = "MATCHED (winner)"
            else
                verdict = "MATCHED"
            end
            -- Described with the client's own form labels, so a rule the player wrote as "Cat Form"
            -- reading back as "in form 3" is itself the bug report.
            local describe = Rules and Rules.Describe
            local words = describe and describe(rule, { form = world.forms }) or "(cannot describe)"
            add('  %d. "%s" priority %s — %s — %s',
                i, tostring(rule.set), tostring(rule.priority or 0), words, verdict)
        end
    end

    -- What the ENGINE remembers, which is a different question from what the world holds and the
    -- only one that can explain a swap that never happened at all. Two states in here are invisible
    -- everywhere else: a set the engine believes it already put on (no rule re-fires while it is
    -- held) and a step parked until combat ends. Both look exactly like "the rule didn't match",
    -- and the RULES section above will cheerfully say MATCHED while nothing moves.
    local engine = world.engine
    add("")
    add("ENGINE")
    if not engine then
        add("  (not read)")
    elseif engine.failed then
        -- Reported, not swallowed: a debug tool that hides its own failure hides the bug behind it.
        add("  (could not be read: %s)", tostring(engine.failed))
    else
        -- First, because it is the one switch that turns every rule off at once.
        add("  auto-swap: %s", tostring(engine.autoSwap))
        add("  holding: %s", engine.active and tostring(engine.active) or "(nothing)")
        add("  deferred: %s", engine.deferred and tostring(engine.deferred) or "(nothing)")
        add("  restore point: %s", engine.restorePoint and "held" or "(none)")
    end

    -- Whether each event actually registered. Events.Enable() registers inside pcall because no
    -- flavour has every event, and the cost of that is silence: an event this flavour does not have
    -- is indistinguishable from a rule that never matched. Stating it is the whole point — the
    -- absent one is shouted rather than merely listed, because a reader scanning fifteen "ok" lines
    -- for one missing word will not find it.
    add("")
    add("EVENTS")
    local events = engine and engine.events
    if not events then
        add("  (not read)")
    elseif #events == 0 then
        add("  (no events registered)")
    else
        for _, e in ipairs(events) do
            add("  %-32s %s", tostring(e.name), e.registered and "registered" or "NOT REGISTERED")
        end
    end

    -- What the driver last actually DID, which no other section can say. The engine's memory above
    -- explains a swap that never started; this explains one that started and did not finish — and
    -- the two send a reader to opposite files. The reason is the client's own wording, captured by
    -- Equip and otherwise printed once to a chat frame nobody was watching (BUG-9).
    add("")
    add("LAST SWAP")
    local swap = world.lastSwap
    if not swap then
        add("  (nothing attempted since login)")
    else
        add("  %s — %s%s", tostring(swap.set), swap.ok and "succeeded" or "failed",
            swap.when and (" at " .. tostring(swap.when)) or "")
        -- A success has a reason too, and it is the one BUG-10 turned on: "succeeded" covers both a
        -- set that was equipped and a set that had nothing to do, and those are the two halves of
        -- "the rule fired and nothing moved". A failure with no reason is stated as such rather than
        -- omitted — the client having said nothing is itself a different suspect list.
        if swap.reason then
            add("  reason: %s", tostring(swap.reason))
        elseif not swap.ok then
            add("  reason: (not recorded)")
        end
    end

    -- Sorted, so two dumps differ only where the world differed. pairs() order would make every
    -- line look changed and hide the one that did.
    local sets = {}
    for _, set in ipairs(world.sets or {}) do sets[#sets + 1] = set end
    table.sort(sets, function(a, b) return tostring(a.name) < tostring(b.name) end)

    for _, set in ipairs(sets) do
        add("")
        add('set "%s"%s', tostring(set.name),
            set.parent and (" — inherits " .. tostring(set.parent)) or "")

        -- Only the slots the set names, in slot order. A set is a patch, not an outfit, so listing
        -- the nineteen it says nothing about would bury the two it does.
        local named = false
        for _, s in ipairs(Core and Core.SLOTS or {}) do
            local value = set.slots and set.slots[s.id]
            if value ~= nil then
                named = true
                add("  %s = %s", s.label, stored(value))
            end
        end
        if not named then add("  (names no slots — an empty set)") end

        local plan = set.plan
        if not plan then
            add("  plan: (none — it could not be built)")
        else
            add("  plan: %d action(s), needs %s bag slot(s), blocked: %s",
                #(plan.actions or {}), tostring(plan.needsBagSlots or 0), tostring(plan.blocked))
            for i, action in ipairs(plan.actions or {}) do
                add("    %d. %s -> %s%s", i, tostring(action.kind), label(action.to),
                    action.key and ("  " .. tostring(action.key)) or "")
            end
            for _, m in ipairs(plan.missing or {}) do
                add("    missing: %s  %s  (%s)", label(m.slot), tostring(m.key),
                    m.where or "not found anywhere")
            end
        end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Reading the client (the part that is not pure)
-- ---------------------------------------------------------------------------

-- Anything that reads the client is guarded, because the two calls most likely to be WRONG on a
-- given flavour — FormLabels and the state snapshot — are precisely the two this dump exists to
-- inspect. A probe that dies on them hides the bug behind its own failure. The error is returned
-- rather than swallowed so it appears in the dump as the answer.
local function attempt(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return { failed = tostring(value) }
end

local function failed(value)
    return type(value) == "table" and value.failed ~= nil
end

--- Read the world and hand it to Report. Everything the planner sees, from ONE reading, so the dump
--- cannot show a set planned against bags that had already changed by the time the next set was read.
function Debug.Capture()
    local Sets, Inventory, Compat = Kitbag.Sets, Kitbag.Inventory, Kitbag.Compat
    -- Looked up at call time, not held as a load-time local: KitbagEvents loads AFTER this file, so
    -- a local captured at load would be nil forever (the lesson UI-17 paid for with the minimap).
    local Events = Kitbag.Events

    -- One reading, shared by the snapshot and the explanation below it. Asking Events.Explain() for
    -- the second would re-read the world, and a dump whose "why" disagrees with its own STATE is a
    -- false lead of exactly the kind this file exists to prevent.
    local state = Events and attempt(Events.State)
    local rules = Kitbag.char and Kitbag.char.rules

    local world = {
        when = date("%Y-%m-%d %H:%M:%S"),
        version = GetAddOnMetadata and GetAddOnMetadata("Kitbag", "Version") or
            (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("Kitbag", "Version")),
        flavour = Compat and (Compat.IS_MAINLINE and "Retail" or "Classic"),
        interface = select(4, GetBuildInfo()),
        -- The same key the DB files this character's sets under, not a second spelling of it: a dump
        -- that names the character differently from the bucket it read is a false lead.
        character = Compat and Compat.CharacterKey(),
        schema = Kitbag.db and Kitbag.db.schema,
        bankOpen = Inventory and Inventory.IsBankOpen(),
        worn = Inventory and Inventory.Equipped(),
        bags = Inventory and Inventory.Bags(),
        forms = Compat and attempt(Compat.FormLabels),
        state = state,
        rules = rules,
        -- Explained only against a state that was actually read. Handing the error table to Explain
        -- would produce a full RULES section in which every rule missed on some condition — a
        -- confident, detailed and entirely fictional answer to "why did nothing fire".
        explain = (Rules and rules and state and not failed(state))
            and attempt(Rules.Explain, rules, state) or nil,
        sets = {},
    }

    -- The engine's own memory, and whether its events exist at all. Read here rather than inside
    -- Events so the two facts that only the DB knows — the master switch and the restore point —
    -- arrive in the same table as the two only Events knows, and the section cannot half-answer.
    local engine = Events and attempt(Events.Diagnostics)
    if engine and not failed(engine) then
        engine.autoSwap = Kitbag.db and Kitbag.db.options and Kitbag.db.options.autoSwap
        engine.restorePoint = Kitbag.char and Kitbag.char.restorePoint ~= nil
    end
    world.engine = engine

    -- Read straight off the character bucket rather than through Events.Diagnostics: the dump is
    -- asked for when something is already wrong, and an engine read that throws must not take the
    -- record of the last failed swap down with it.
    world.lastSwap = Kitbag.char and Kitbag.char.lastSwap

    for _, name in ipairs(Sets and Sets.Names() or {}) do
        local plan, set = Sets.Preview(name)
        world.sets[#world.sets + 1] = {
            name = name,
            parent = Sets.ParentOf(name),
            -- The RESOLVED slots: what the set will actually put on, parent included. The stored
            -- delta alone would show a child as almost empty and send the reader after a set that
            -- looks broken and is not.
            slots = set and set.slots,
            plan = plan,
        }
    end

    return Debug.Report(world)
end

--- Take a dump and keep it in SavedVariables. Returns how many are now stored.
--
-- Written into the DB rather than printed: the chat frame truncates, scrolls away, and cannot be
-- read by anyone who is not sitting at the machine. The file survives all three.
function Debug.Dump()
    local db = Kitbag.db
    if not db then return 0 end

    db.dumps = db.dumps or {}
    table.insert(db.dumps, 1, Debug.Capture())
    while #db.dumps > KEEP do table.remove(db.dumps) end
    return #db.dumps
end

--- Throw the dumps away. They are the only part of the DB that is pure noise once read.
function Debug.Clear()
    local count = Kitbag.db and Kitbag.db.dumps and #Kitbag.db.dumps or 0
    if Kitbag.db then Kitbag.db.dumps = nil end
    return count
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------
--
-- Buttons rather than a slash command, because a dump is asked for when something has just gone
-- wrong and the player is mid-fight with a bug — that is the worst moment to be typing an exact
-- incantation. The panel also has room to say what happens NEXT, which a chat line does not: a dump
-- that is never flushed to disk helps nobody, and /reload is the step that flushes it.

local frame

local function status()
    local count = Kitbag.db and Kitbag.db.dumps and #Kitbag.db.dumps or 0
    if count == 0 then return "No dumps stored." end
    return string.format("%d dump(s) stored — |cffffd100/reload|r to write them to disk.", count)
end

local function build()
    frame = CreateFrame("Frame", "KitbagDebugFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(420, 210)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    -- Above the main window, which is where the bug being dumped usually is. See KitbagUI's note.
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:Hide()
    tinsert(UISpecialFrames, "KitbagDebugFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
    frame.title:SetText("Kitbag — debug")

    frame.blurb = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.blurb:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -34)
    frame.blurb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -34)
    frame.blurb:SetJustifyH("LEFT")
    frame.blurb:SetText("Dump takes a full reading of your gear, bags, every set and the plan " ..
        "each one would run. Nothing leaves your machine — it is written into Kitbag's saved " ..
        "variables, which the game flushes to disk on |cffffd100/reload|r or logout.")

    frame.where = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.where:SetPoint("TOPLEFT", frame.blurb, "BOTTOMLEFT", 0, -10)
    frame.where:SetPoint("TOPRIGHT", frame.blurb, "BOTTOMRIGHT", 0, -10)
    frame.where:SetJustifyH("LEFT")
    frame.where:SetText("WTF\\Account\\<ACCOUNT>\\SavedVariables\\Kitbag.lua")

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 46)

    local dump = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    dump:SetSize(150, 22)
    dump:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 14)
    dump:SetText("Dump everything")
    dump:SetScript("OnClick", function()
        local count = Debug.Dump()
        frame.status:SetText(status())
        Kitbag.Sets.Say("dumped. |cffffd100/reload|r to write it to disk (%d stored).", count)
    end)

    -- Reload from the panel, because the dump is worthless until the file is written and the step is
    -- easy to forget when the reason you opened this was that something else was going wrong.
    local reload = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reload:SetSize(110, 22)
    reload:SetPoint("LEFT", dump, "RIGHT", 6, 0)
    reload:SetText("Dump + reload")
    reload:SetScript("OnClick", function()
        Debug.Dump()
        ReloadUI()
    end)

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(110, 22)
    clear:SetPoint("LEFT", reload, "RIGHT", 6, 0)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        Debug.Clear()
        frame.status:SetText(status())
    end)

    return frame
end

--- Open or close the panel.
function Debug.Toggle()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame.status:SetText(status())
        frame:Show()
    end
end

Kitbag.Debug = Debug
return Debug
