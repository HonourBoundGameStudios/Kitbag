-- The .toc files and the files they load.
--
-- Most of Kitbag is covered by tests because the deciding parts are pure. The rest — the window, the
-- driver, the bootstrap — calls CreateFrame at load time and cannot run outside the client, so
-- nothing here has ever *compiled* it. A missing `end` in KitbagUI.lua therefore reaches the game.
-- Compiling is not testing, but it is the difference between finding a typo now and finding it after
-- a /reload.
--
-- Two gotchas are checked at the same time, both of which fail silently and only at runtime:
--   * both .toc files must list the same files, or one flavour breaks and only at runtime;
--   * a new module must be *in* the .toc, or it silently never loads.
--
-- Usage: lua Tests/toc_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")

H.start("Kitbag.toc")

local WINDOWS = package.config:sub(1, 1) == "\\"

local function readToc(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local files, order = {}, {}
    for line in f:lines() do
        -- Strip a UTF-8 BOM and the CR of a CRLF file; both are invisible and both would otherwise
        -- turn a legitimate filename into one that does not exist.
        line = line:gsub("^\239\187\191", ""):gsub("\r$", ""):match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            files[line] = true
            order[#order + 1] = line
        end
    end
    f:close()
    return files, order
end

-- Kitbag.toc is the reference; every other flavour must match it exactly.
local OTHER_FLAVOURS = { "Kitbag_Mists.toc", "Kitbag_Mainline.toc", "Kitbag_Cata.toc" }

local ERA, eraOrder = readToc("Kitbag.toc")

-- ---------------------------------------------------------------------------
-- The ## Interface number
-- ---------------------------------------------------------------------------
--
-- A stale interface number marks the addon out of date and, on some clients, stops it loading at
-- all — and it goes stale every patch without anything in the repo changing. Three of these four
-- were originally GUESSED, which is the failure this section exists to make impossible: a guess and
-- a reading look identical in a .toc file.
--
-- The numbers below were read off `<install>/.build.info` — the manifest Blizzard's own launcher
-- maintains, which names the exact version of every installed product. That file is on disk, so
-- this needs no client launched and no human. RE-READ IT each patch rather than editing the number
-- to whatever makes the test pass.

local function readInterface(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local found
    for line in f:lines() do
        found = found or line:match("^##%s*Interface%s*:%s*(%d+)")
    end
    f:close()
    return tonumber(found)
end

-- major.minor.patch packs as major*10000 + minor*100 + patch. Stated as an encoding rather than as a
-- second literal so the version and the number cannot disagree silently — a transposed digit in a
-- five-digit constant is invisible, and "1.15.9" is not.
local function encode(major, minor, patch)
    return major * 10000 + minor * 100 + patch
end

local INTERFACES = {
    { toc = "Kitbag.toc",          product = "wow_classic_era", version = { 1, 15, 9 } },
    { toc = "Kitbag_Mists.toc",    product = "wow_classic",     version = { 5, 5, 4 } },
    { toc = "Kitbag_Mainline.toc", product = "wow",             version = { 12, 1, 0 } },
    -- Cataclysm Classic is not installed here and CANNOT be: the `wow_classic` product has moved on
    -- to Mists (5.5.4 in `.build.info`), so that flavour no longer exists as a live client to read.
    -- The number is therefore argued rather than read — 4.4.2 was Cataclysm Classic's final build
    -- before the Mists upgrade, corroborated 2026-08-18 against the public addon record rather than
    -- against a client — and it stays LABELLED, because promoting an argument to a reading is how a
    -- guess stops looking like one. If Blizzard ever runs Cata Classic again, read it off .build.info
    -- and move it up to `product`.
    { toc = "Kitbag_Cata.toc",     product = nil,               version = { 4, 4, 2 },
      sourced = "public record: 4.4.2 was Cataclysm Classic's last build before Mists Classic "
          .. "replaced it; no Cata client exists to read" },
}

for _, entry in ipairs(INTERFACES) do
    local want = encode(entry.version[1], entry.version[2], entry.version[3])
    local got = readInterface(entry.toc)
    -- The label reports the provenance rather than a yes/no, so a run of this suite says which
    -- numbers are readings and which are arguments — that distinction is the point.
    local how = entry.product
        and ("(read off .build.info, product " .. entry.product .. ")")
        or ("(NOT read off a client — " .. tostring(entry.sourced) .. ")")
    H.eq(got, want, entry.toc .. " declares interface " .. want .. " " .. how)
end


-- Every number must SAY where it came from, and the three provenances are not equal. A number read
-- off `.build.info` is a reading of the installed client. A number corroborated against the public
-- record is an argument. A number with neither is a guess — and a guess and a reading look identical
-- in a `.toc` file, which is the whole reason this section exists. This asserts that no entry can be
-- added without declaring which of the three it is; the failure it prevents is a fourth flavour
-- arriving with a plausible five-digit constant and nobody able to tell later where it came from.
for _, entry in ipairs(INTERFACES) do
    H.ok(entry.product ~= nil or entry.sourced ~= nil,
        entry.toc .. " states where its interface number came from")
end
-- ---------------------------------------------------------------------------
-- Parity between the flavours
-- ---------------------------------------------------------------------------
--
-- Adding a module and forgetting one of the other .toc files breaks that flavour only, and only at
-- runtime, for someone who is not you. Load ORDER is checked too, not just membership: every module
-- reads its dependencies out of the Kitbag namespace at load time, so a reordered .toc is a
-- nil-index error on the flavour nobody launched.

for _, flavour in ipairs(OTHER_FLAVOURS) do
    local _, order = readToc(flavour)
    H.eq(#order, #eraOrder, flavour .. " lists the same number of files as Kitbag.toc")
    for i, name in ipairs(eraOrder) do
        H.eq(order[i], name, flavour .. " loads " .. name .. " in the same position")
    end
end

-- ---------------------------------------------------------------------------
-- Every listed file exists and compiles
-- ---------------------------------------------------------------------------

for _, name in ipairs(eraOrder) do
    local chunk, err = loadfile(name)
    H.ok(chunk ~= nil, name .. " exists and compiles" .. (chunk and "" or ": " .. tostring(err)))
end

-- ---------------------------------------------------------------------------
-- Every module at the root is listed
-- ---------------------------------------------------------------------------
--
-- The mirror of the check above, and the one that catches the genuinely silent failure: a file that
-- is never loaded produces no error at all, just a feature that quietly does nothing.

local list = io.popen(WINDOWS and "dir /b *.lua" or "ls *.lua")
if list then
    for name in list:lines() do
        name = name:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if name ~= "" then
            H.ok(ERA[name] == true, name .. " is listed in Kitbag.toc")
        end
    end
    list:close()
else
    -- Not fatal: the parity and compile checks above are the load-bearing ones, and a sandbox
    -- without io.popen should not turn the gate red over a directory listing.
    print("  # skipped: no io.popen, cannot list the project root")
end


-- ---------------------------------------------------------------------------
-- Which flavours the release zip actually ships (SHIP-4)
-- ---------------------------------------------------------------------------
--
-- A `.toc` in the repo is a file. A `.toc` in the zip is a promise: the client picks its flavour off
-- the suffix, so shipping `Kitbag_Mainline.toc` tells every Retail player this addon runs there. Two
-- of the four flavours have never had a single frame drawn on them — Retail was never launched, and
-- Cataclysm Classic no longer EXISTS as a client to launch — so the zip and the repo are deliberately
-- not the same set, and this is the check that keeps that deliberate rather than forgotten.
--
-- A flavour joins SHIPPED when there is evidence the addon has RUN on it, not when the file exists.
-- The held flavours stay in the repo and stay under every parity check above, so they cannot rot
-- while they wait.

local SHIPPED = {
    { toc = "Kitbag.toc",       label = "Classic Era",
      why = "loaded, drawn and equipping in a live 1.15.9 client, repeatedly" },
    { toc = "Kitbag_Mists.toc", label = "Mists Classic",
      why = "deployed to its AddOns folder, interface read off .build.info, identical file list" },
}

local HELD = {
    { toc = "Kitbag_Mainline.toc", label = "Retail",
      why = "never launched — the interface number is read, but the C_Item/C_Spell shims are "
          .. "reasoned rather than observed" },
    { toc = "Kitbag_Cata.toc",     label = "Cataclysm",
      why = "no client exists to run it on; the interface number is argued, not read" },
}

-- Nothing may be silently neither. A fifth flavour arriving with a plausible .toc must be sorted
-- into one list or the other, with a reason, before the gate goes green again.
for _, entry in ipairs(INTERFACES) do
    local sorted
    for _, s in ipairs(SHIPPED) do if s.toc == entry.toc then sorted = "shipped" end end
    for _, h in ipairs(HELD) do if h.toc == entry.toc then sorted = "held back" end end
    H.ok(sorted ~= nil, entry.toc .. " is either shipped or held back, deliberately")
end

for _, entry in ipairs(SHIPPED) do
    local f = io.open(entry.toc, "r")
    H.ok(f ~= nil, entry.toc .. " ships — " .. entry.why)
    if f then f:close() end
end

-- package.ps1 is what actually fills the zip, so the list is read out of it rather than restated
-- here. A restatement would agree with this test forever and with the zip never.
local function shippedTocsInPackager()
    local f = assert(io.open("package.ps1", "r"), "cannot open package.ps1")
    local body = f:read("*a")
    f:close()
    local block = body:match("%$SHIPPED_TOCS%s*=%s*@%((.-)%)")
    H.ok(block ~= nil, "package.ps1 declares $SHIPPED_TOCS")
    local found = {}
    for name in tostring(block):gmatch("Kitbag[%w_]*%.toc") do found[#found + 1] = name end
    return found
end

local packaged = shippedTocsInPackager()
H.eq(#packaged, #SHIPPED, "package.ps1 ships exactly " .. #SHIPPED .. " flavour(s)")
for _, entry in ipairs(SHIPPED) do
    local inZip = false
    for _, name in ipairs(packaged) do if name == entry.toc then inZip = true end end
    H.ok(inZip, "package.ps1 puts " .. entry.toc .. " in the zip")
end
for _, entry in ipairs(HELD) do
    local inZip = false
    for _, name in ipairs(packaged) do if name == entry.toc then inZip = true end end
    H.ok(not inZip, "package.ps1 keeps " .. entry.toc .. " OUT of the zip — " .. entry.why)
end

-- And the README must claim the same set. This is the drift that was actually found: the README said
-- two flavours while the zip carried four, and the reader who believes the README is the one who is
-- right. A support claim nobody can check is how an addon acquires a flavour it never tested.
local function supportLine()
    local f = assert(io.open("README.md", "r"), "cannot open README.md")
    local line
    for l in f:lines() do
        if l:match("^Supports%s") then line = l end
    end
    f:close()
    return line
end

local supports = supportLine()
H.ok(supports ~= nil, "README states which flavours are supported, on a line starting 'Supports'")
for _, entry in ipairs(SHIPPED) do
    H.ok(supports and supports:find(entry.label, 1, true) ~= nil,
        "README claims support for " .. entry.label)
end
for _, entry in ipairs(HELD) do
    H.ok(supports and supports:find(entry.label, 1, true) == nil,
        "README does not claim support for " .. entry.label .. " — " .. entry.why)
end

-- ---------------------------------------------------------------------------
-- The release notes, and the version they claim (SHIP-4)
-- ---------------------------------------------------------------------------
--
-- A tagged release is the point at which people start INSTALLING this rather than reading it, and
-- the first question an installer asks is "what is in it". `CHANGELOG.md` answers that — but it is
-- the second place a version number lives, and two version numbers that can disagree will. The
-- `.toc` is the one players actually see, so it is the reference and the changelog is checked
-- against it: a release prepared without its notes updated fails here rather than shipping notes
-- that describe the version before.

local function topChangelogVersion()
    local f = io.open("CHANGELOG.md", "r")
    if not f then return nil, nil end
    local version, date
    for line in f:lines() do
        -- `## [0.1.0] — 2026-08-18` — the heading is the record, not a separate metadata block that
        -- could be right while the prose above it is wrong.
        -- The separator is matched with `.-` rather than a character class: an em dash is three
        -- bytes in UTF-8 and Lua's classes are per-byte, so `[—-]` matches none of it.
        local v, d = line:match("^##%s*%[([%d%.]+)%]%s*.-(%d%d%d%d%-%d%d%-%d%d)")
        if v and not version then version, date = v, d end
    end
    f:close()
    return version, date
end

local function tocVersion(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local found
    for line in f:lines() do
        found = found or line:match("^##%s*Version%s*:%s*(.-)%s*$")
    end
    f:close()
    return found
end

local changelogVersion, changelogDate = topChangelogVersion()
H.ok(changelogVersion ~= nil, "CHANGELOG.md exists and its newest entry is a '## [version] — date' heading")
H.eq(changelogVersion, tocVersion("Kitbag.toc"),
    "the newest CHANGELOG entry is the version Kitbag.toc ships")
H.ok(changelogDate ~= nil and #changelogDate == 10, "…and that entry is dated")

-- Every flavour agrees on the version too. package.ps1 refuses to build otherwise — CurseForge reads
-- one .toc and would tell the players on the others they are running a version they are not — and
-- this says the same thing at the gate rather than only at packaging time, since the gate is what
-- runs on every commit.
for _, entry in ipairs(INTERFACES) do
    H.eq(tocVersion(entry.toc), tocVersion("Kitbag.toc"), entry.toc .. " declares the same version")
end

-- ---------------------------------------------------------------------------
-- The icebox
-- ---------------------------------------------------------------------------
--
-- The rule engine is shelved, not deleted: `Icebox/` holds the code so it can come back with its
-- history intact, and NOTHING loads it. Two failures this guards, both silent — a file that is still
-- listed in a `.toc` is still shipped and still running, and a file that is deleted instead of
-- shelved cannot come back at all.
--
-- `deploy.ps1` and `package.ps1` copy `*.lua` at the ROOT, so a shelved file being out of the root is
-- what actually keeps it out of the game; the `.toc` check below is the part a human could get wrong.

local ICED = { "KitbagRules.lua", "KitbagEvents.lua", "KitbagRulesUI.lua" }

for _, name in ipairs(ICED) do
    local shelved = io.open("Icebox/" .. name, "r")
    H.ok(shelved ~= nil, name .. " is shelved in Icebox/")
    if shelved then shelved:close() end

    local atRoot = io.open(name, "r")
    H.ok(atRoot == nil, name .. " is NOT at the project root, where deploy.ps1 would ship it")
    if atRoot then atRoot:close() end

    for _, entry in ipairs(INTERFACES) do
        local files = readToc(entry.toc)
        H.ok(files[name] ~= true, entry.toc .. " does not load " .. name)
    end
end

-- The tests for shelved code are shelved with it. run-all.ps1 globs `Tests/*_test.lua`, so a test
-- file left behind would go red against modules nothing loads any more — and deleting it instead
-- would throw away the one description of what the engine did.
H.ok(io.open("Tests/rules_test.lua", "r") == nil,
    "Tests/rules_test.lua is not in the suite the gate runs")
local shelvedTest = io.open("Icebox/Tests/rules_test.lua", "r")
H.ok(shelvedTest ~= nil, "…it is shelved in Icebox/Tests/ instead of deleted")
if shelvedTest then shelvedTest:close() end

H.done()
