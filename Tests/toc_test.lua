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

H.done()
