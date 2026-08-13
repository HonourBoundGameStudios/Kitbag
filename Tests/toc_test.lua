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
