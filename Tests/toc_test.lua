-- The .toc files and the files they load.
--
-- Most of Kitbag is covered by tests because the deciding parts are pure. The rest — the window, the
-- driver, the bootstrap — calls CreateFrame at load time and cannot run outside the client, so
-- nothing here has ever *compiled* it. A missing `end` in KitbagUI.lua therefore reaches the game.
-- Compiling is not testing, but it is the difference between finding a typo now and finding it after
-- a /reload.
--
-- Two gotchas are checked at the same time, both of which fail silently and only at runtime:
--   * a new module must be *in* the .toc, or it silently never loads;
--   * there must be exactly ONE .toc — see the flavour section below for why that is now the check.
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

-- Classic Era is the only flavour as of 2026-09-03. The other three .toc files are DELETED rather
-- than held back, at the Admiral's word: two had never had a frame drawn on them, the third has no
-- client left to draw on, and a `.toc` in the repo is a promise that a parity check then has to keep
-- forever against a flavour nobody runs. What replaces that parity check is a stronger claim — that
-- there is exactly one `.toc` — because a flavour cannot fall out of step with Era if it does not
-- exist. The list below is what must STAY gone; it is the guard against a support claim drifting
-- back in one file at a time.
local DROPPED = {
    { toc = "Kitbag_Mists.toc",    label = "Mists Classic",
      why = "deployed to its AddOns folder for three weeks and never once launched" },
    { toc = "Kitbag_Mainline.toc", label = "Retail",
      why = "never launched — the C_Item/C_Spell shims were reasoned, never observed" },
    { toc = "Kitbag_Cata.toc",     label = "Cataclysm",
      why = "no client exists to run it on; its interface number was argued, not read" },
}

local ERA, eraOrder = readToc("Kitbag.toc")

-- ---------------------------------------------------------------------------
-- The ## Interface number
-- ---------------------------------------------------------------------------
--
-- A stale interface number marks the addon out of date and, on some clients, stops it loading at
-- all — and it goes stale every patch without anything in the repo changing. This one was originally
-- GUESSED, which is the failure this section exists to make impossible: a guess and a reading look
-- identical in a .toc file. The three flavours whose numbers could never be read off a running
-- client are gone (see DROPPED above) — one fewer place for a guess to hide.
--
-- The number below was read off `<install>/.build.info` — the manifest Blizzard's own launcher
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
    { toc = "Kitbag.toc", product = "wow_classic_era", version = { 1, 15, 9 } },
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
-- One flavour, and only one
-- ---------------------------------------------------------------------------
--
-- What stood here was a parity check: four .toc files compared line by line, membership and ORDER,
-- because adding a module and forgetting one of the others broke that flavour only, at runtime, for
-- someone who is not you. Nothing is left to fall out of step. The check that replaces it is the one
-- that keeps it that way — a second .toc reappearing is exactly how the old failure would come back,
-- and it would come back with no parity check watching it.

local function tocsAtRoot()
    local list = io.popen(WINDOWS and "dir /b *.toc" or "ls *.toc")
    if not list then return nil end
    local found = {}
    for name in list:lines() do
        name = name:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if name ~= "" then found[#found + 1] = name end
    end
    list:close()
    return found
end

local atRoot = tocsAtRoot()
if atRoot then
    H.eq(#atRoot, 1, "the project root holds exactly one .toc")
    H.eq(atRoot[1], "Kitbag.toc", "…and it is Kitbag.toc — Classic Era")
else
    print("  # skipped: no io.popen, cannot list the project root")
end

-- Named individually as well, so a failure says WHICH flavour came back rather than only that the
-- count is wrong — and so this still holds in a sandbox without io.popen.
for _, entry in ipairs(DROPPED) do
    local f = io.open(entry.toc, "r")
    H.ok(f == nil, entry.toc .. " is gone — " .. entry.why)
    if f then f:close() end
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
-- What the release zip actually ships (SHIP-4)
-- ---------------------------------------------------------------------------
--
-- A `.toc` in the repo is a file. A `.toc` in the zip is a promise: the client picks its flavour off
-- the suffix, so shipping `Kitbag_Mainline.toc` told every Retail player this addon runs there. It
-- had never drawn a frame on that client. The zip and the repo used to be deliberately different
-- sets for that reason; as of 2026-09-03 they are the same set of ONE, which is the simplest form
-- the promise can take — what is in the repo is what ships, and what ships has been run.

local SHIPPED = {
    { toc = "Kitbag.toc", label = "Classic Era",
      why = "loaded, drawn and equipping in a live 1.15.9 client, repeatedly" },
}

-- Every .toc the interface section knows about must be one that ships. The old version of this
-- sorted each flavour into shipped-or-held-back so that none could be silently neither; with one
-- flavour left, the equivalent guard is that the two lists cannot disagree about what exists.
for _, entry in ipairs(INTERFACES) do
    local sorted
    for _, ship in ipairs(SHIPPED) do if ship.toc == entry.toc then sorted = true end end
    H.ok(sorted == true, entry.toc .. " is a flavour the zip ships")
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
for _, entry in ipairs(DROPPED) do
    local inZip = false
    for _, name in ipairs(packaged) do if name == entry.toc then inZip = true end end
    H.ok(not inZip, "package.ps1 does not mention " .. entry.toc .. " — " .. entry.why)
end

-- And the README must claim the same set. This is the drift that was actually found once already:
-- the README said two flavours while the zip carried four, and the reader who believes the README is
-- the one who is right. A support claim nobody can check is how an addon acquires a flavour it never
-- tested — which is precisely how three of them got here.
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
for _, entry in ipairs(DROPPED) do
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

-- …and the entry is the WHOLE of what ships. The check above only looks at the newest *versioned*
-- heading, so work parked under `## [Unreleased]` slips past it: the version number still matches,
-- the notes are still dated, and the release goes out describing a subset of itself. That is not
-- hypothetical — 0.1.0's notes were written on 2026-08-18 and twenty commits then landed on top of
-- them under the same version number, including a change (the shelved rule engine) that made a
-- feature the notes ADVERTISE untrue.
--
-- So: an `## [Unreleased]` heading may exist as a place to collect work, but it must be empty at the
-- gate. Anything under it belongs in the version being shipped, or in a version number of its own.
local function unreleasedContent()
    local f = io.open("CHANGELOG.md", "r")
    -- Returns an empty list rather than nil for a missing file: the assertion above already reports
    -- that, and a nil here would crash the file instead of failing one line.
    if not f then return {} end
    local inSection, content = false, {}
    for line in f:lines() do
        if line:match("^##%s*%[[Uu]nreleased%]") then
            inSection = true
        elseif inSection and line:match("^##%s") then
            inSection = false
        elseif inSection and line:match("%S") then
            content[#content + 1] = line
        end
    end
    f:close()
    return content
end

local parked = unreleasedContent()
H.eq(#parked, 0, "nothing is parked under '## [Unreleased]' — the shipped version's notes are all of it")

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

-- ---------------------------------------------------------------------------
-- Media (UI-32)
-- ---------------------------------------------------------------------------
--
-- The About page draws the studio logo, and a texture path is a claim about what is in the deployed
-- folder rather than a reference the loader can check. Three things have to agree — the path in
-- KitbagUI, the file on disk, and the two scripts that copy the addon — and NONE of them fails
-- loudly on its own: a missing texture renders missing-texture magenta in the client, which nobody
-- sees until they open the page, and the suite would stay green the whole time.
--
-- This is also the first thing Kitbag ships that is not a .lua or a .toc, which is exactly why both
-- scripts had to grow a line. `deploy.ps1` and `package.ps1` copy `*.lua` at the root — that glob is
-- what keeps Icebox/ out of the game and it is what would have left Media/ out of it too.

local LOGO_FILE = "Media/HBGS-Logo.tga"

local logo = io.open(LOGO_FILE, "r")
H.ok(logo ~= nil, LOGO_FILE .. " exists, which is the file the About page names")
if logo then logo:close() end

local function fileBody(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local body = f:read("*a")
    f:close()
    return body
end

-- The path as the CLIENT will resolve it. Taken out of the source rather than restated — a test that
-- writes the path down a second time passes when the two copies agree with each other and disagree
-- with the folder — and then EVALUATED, because the source text is not the string. A Windows path
-- written with single backslashes compiles happily in Lua 5.1 and silently loses every one of them:
-- that is exactly the mistake this check was written against, and comparing source text to source
-- text did not catch it.
local uiBody = fileBody("KitbagUI.lua")
local logoLiteral = uiBody:match('local LOGO = (".-")')
H.ok(logoLiteral ~= nil, "KitbagUI names the logo in one place, as a constant")
local logoPath = logoLiteral and assert(loadstring("return " .. logoLiteral))()
H.eq(logoPath, "Interface\\AddOns\\Kitbag\\Media\\HBGS-Logo",
    "…and it resolves to the deployed folder's path, without the extension the client appends")

for _, script in ipairs({ "deploy.ps1", "package.ps1" }) do
    H.ok(fileBody(script):find("Media", 1, true) ~= nil,
        script .. " copies Media/ — the glob it had would have shipped everything BUT the logo")
end

-- ---------------------------------------------------------------------------
-- The addon's own icon (UI-33)
-- ---------------------------------------------------------------------------
--
-- Kitbag wore `INV_Chest_Plate06` — one of Blizzard's own inventory icons — in FOUR places at once:
-- the `## IconTexture` a player sees in the AddOns list, the minimap launcher, the Broker launcher
-- and the Equip button. It is a breastplate, so it was never wrong; it was simply not Kitbag's, and
-- four copies of a borrowed path is four places to forget when it stops being borrowed.
--
-- Three were known and the Broker's was not: it was the sweep at the bottom of this section that
-- found it, which is the argument for sweeping rather than for listing the sites. A list of sites is
-- written by the same person who is about to forget one.
--
-- The new icon is a file this addon ships, which changes what can go wrong. A Blizzard path either
-- exists on every client or on none; a shipped TGA can be missing from the zip, be the wrong shape,
-- or be written in a form the client will not decode — and ALL THREE render as missing-texture
-- magenta rather than as an error. So the header is read here, not just the filename: WoW loads an
-- UNCOMPRESSED 32-bit TGA and quietly refuses an RLE one, and that refusal looks exactly like a
-- typo in the path.

local ICON_FILE = "Media/Kitbag-Icon.tga"
-- Doubled backslashes, for the reason the logo check above gives: Lua 5.1 compiles `"\A"` happily
-- and keeps only the `A`. This constant was written singly first and the test failed comparing
-- `InterfaceAddOnsKitbagMediaKitbag-Icon` against the real path — the exact mistake the comment
-- warning about it is attached to, made while writing the check for it.
local ICON_PATH = "Interface\\AddOns\\Kitbag\\Media\\Kitbag-Icon"

local function tgaHeader(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(18)
    f:close()
    if not head or #head < 18 then return nil end
    local byte = function(i) return head:byte(i) end
    return {
        imageType = byte(3),
        width  = byte(13) + byte(14) * 256,
        height = byte(15) + byte(16) * 256,
        bpp    = byte(17),
    }
end

local header = tgaHeader(ICON_FILE)
H.ok(header ~= nil, ICON_FILE .. " exists and is a readable TGA")
if header then
    -- Type 2 is uncompressed true-colour. Type 10 is the same picture RLE-packed, which every image
    -- editor offers and the client will not draw.
    H.eq(header.imageType, 2, "…uncompressed true-colour (type 2), not RLE — the client refuses RLE")
    H.eq(header.bpp, 32, "…32-bit, so it carries the alpha channel a round icon mask needs")
    -- Powers of two, and the same 128 the studio logo uses. A non-power-of-two texture is the other
    -- silent magenta.
    H.eq(header.width, 128, "…128 wide")
    H.eq(header.height, 128, "…128 tall")
end

-- The path lives in ONE constant and the Lua call sites read it, rather than string literals that
-- agree today. Evaluated rather than compared as source text, for the reason the logo check above
-- spells out: single backslashes compile fine in Lua 5.1 and silently vanish.
local skinBody = fileBody("KitbagSkin.lua")
local iconLiteral = skinBody:match("Skin%.ICON%s*=%s*(\".-\")")
H.ok(iconLiteral ~= nil, "KitbagSkin names the addon icon in one place, as Skin.ICON")
local iconPath = iconLiteral and assert(loadstring("return " .. iconLiteral))()
H.eq(iconPath, ICON_PATH, "…and it resolves to the deployed folder's path, extension omitted")

-- The `.toc` cannot read a Lua constant, so this is the one genuine second copy. It is checked
-- against the constant rather than restated.
local function tocIcon(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local found
    for line in f:lines() do
        found = found or line:match("^##%s*IconTexture%s*:%s*(.-)%s*$")
    end
    f:close()
    return found
end

H.eq(tocIcon("Kitbag.toc"), ICON_PATH, "Kitbag.toc's ## IconTexture is the shipped icon")

for _, site in ipairs({ "KitbagUI.lua", "KitbagMinimap.lua", "KitbagBroker.lua" }) do
    H.ok(fileBody(site):find("Skin.ICON", 1, true) ~= nil,
        site .. " draws the addon icon from Skin.ICON rather than a path of its own")
end

-- The borrowed icon must be gone from every file that ships, not merely unused in the two above.
-- A leftover copy is not a broken picture — it is the OLD picture, in one control, forever.
local sources = io.popen(WINDOWS and "dir /b *.lua *.toc" or "ls *.lua *.toc")
if sources then
    for name in sources:lines() do
        name = name:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if name ~= "" then
            H.ok(fileBody(name):find("INV_Chest_Plate06", 1, true) == nil,
                name .. " no longer wears the borrowed INV_Chest_Plate06")
        end
    end
    sources:close()
else
    print("  # skipped: no io.popen, cannot sweep the root for the borrowed icon")
end

-- ---------------------------------------------------------------------------
-- What CurseForge ships, which is not what package.ps1 ships (SHIP-8)
-- ---------------------------------------------------------------------------
--
-- The CurseForge project was connected to this repository on 2026-09-03, and that moved the decision
-- about what players receive OUT of package.ps1. CurseForge's automatic packaging builds the zip
-- from the REPOSITORY SOURCE — it does not take a zip attached to a GitHub release — so
-- `dist/Kitbag-0.2.0.zip` is now a local artefact nobody installs, and every tracked file at the
-- root ships unless something says otherwise.
--
-- Nothing said otherwise. `Tests/`, `Icebox/`, `CLAUDE.md`, `deploy.ps1` and `package.ps1` would all
-- have landed in players' AddOns folders. Icebox is the shelved rule engine: no `.toc` loads it, so
-- it would not RUN — but the point of shelving it into a folder was that it leaves the product, and
-- "the addon ships only what has been run" stops being true the moment the zip is built by something
-- that has never read package.ps1.
--
-- `.pkgmeta` is what says otherwise, and this section holds it to package.ps1 in BOTH directions:
-- nothing extra may ship, and nothing the client needs may be dropped. The second direction is the
-- one worth having — an `ignore` entry that swallowed `Media/` would take the icon and the logo out
-- of the zip and render them magenta for everyone except the developer, whose deployed folder still
-- has them.

local PKGMETA = ".pkgmeta"

-- A deliberately small YAML reader: `key: value` at the left margin, then either `- item` lines or
-- indented `key: value` lines under it. `.pkgmeta` is two levels deep at most, and a real YAML
-- parser would be a dependency this addon does not have.
local function readPkgmeta(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local scalars, lists, maps, current = {}, {}, {}, nil
    for line in f:lines() do
        line = line:gsub("^\239\187\191", ""):gsub("\r$", "")
        if not line:match("^%s*#") and line:match("%S") then
            local key, value = line:match("^([%w%-_]+):%s*(.-)%s*$")
            local item = line:match("^%s+%-%s*(.-)%s*$")
            local nestedKey, nestedValue = line:match("^%s+([%w%-_]+):%s*(.-)%s*$")
            if key then
                current = key
                if value ~= "" then scalars[key] = value else lists[key], maps[key] = {}, {} end
            elseif item and current and lists[current] then
                table.insert(lists[current], item)
            elseif nestedKey and current and maps[current] then
                maps[current][nestedKey] = nestedValue
            end
        end
    end
    f:close()
    return scalars, lists, maps
end

local pkgScalars, pkgLists, pkgMaps = readPkgmeta(PKGMETA)
H.ok(pkgScalars ~= nil, PKGMETA .. " exists — without it CurseForge ships the whole repository")

if pkgScalars then
    -- The folder inside the zip. CurseForge names it after the project's URL SLUG when this is
    -- omitted, and a slug is not required to match the addon: the client resolves Kitbag.toc by
    -- looking for a folder called Kitbag, so a mismatch is an addon that installs and never loads.
    H.eq(pkgScalars["package-as"], "Kitbag",
        PKGMETA .. " names the folder Kitbag — the client finds Kitbag.toc by that folder name")

    -- Otherwise CurseForge compiles the changelog players read out of this repository's COMMIT
    -- MESSAGES. The commit bodies here explain reasoning to the next agent; they are not release
    -- notes, and CHANGELOG.md already is — held to the .toc's version by the section above.
    --
    -- The map form rather than the `manual-changelog: CHANGELOG.md` shorthand, which is also legal:
    -- the shorthand leaves `markup-type` at `plain`, and a markdown file rendered as plain text puts
    -- the literal `##` and `-` on the project page for every reader.
    local changelog = (pkgMaps or {})["manual-changelog"] or {}
    H.eq(changelog["filename"], "CHANGELOG.md",
        PKGMETA .. " points the changelog at CHANGELOG.md rather than at commit messages")
    H.eq(changelog["markup-type"], "markdown",
        "…and says it is markdown, so the page renders it instead of printing the hashes")
end

-- What package.ps1 puts in the zip, READ OUT OF THE SCRIPT rather than restated here. A second list
-- would agree with this test forever and with the zip never — the same reason $SHIPPED_TOCS is
-- parsed above instead of copied. The concrete drift it prevents: a fourth document added to
-- package.ps1 would ship from the local zip and be missing from CurseForge's, and only a player
-- would find out.
local function packagedTopLevel()
    local body = fileBody("package.ps1")
    local shipped = {}
    -- `foreach ($doc in @("README.md", "CHANGELOG.md", "LICENSE"))`
    local docs = body:match("%$doc%s+in%s+@%((.-)%)")
    H.ok(docs ~= nil, "package.ps1 lists the documents it ships, in a foreach over @(...)")
    for name in tostring(docs):gmatch('"([^"]+)"') do shipped[name] = true end
    -- `$media = Join-Path $root "Media"`
    local media = body:match('%$media%s*=%s*Join%-Path%s+%$root%s+"([^"]+)"')
    H.ok(media ~= nil, "package.ps1 names the media folder it copies")
    if media then shipped[media] = true end
    for _, toc in ipairs(packaged) do shipped[toc] = true end
    local list = io.popen(WINDOWS and "dir /b *.lua" or "ls *.lua")
    if not list then return nil end
    for name in list:lines() do
        name = name:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if name ~= "" then shipped[name] = true end
    end
    list:close()
    return shipped
end

-- What git would hand CurseForge: every tracked path, reduced to its top-level entry. Asked of GIT
-- rather than of the working tree, for the reason the gitignore fleetcast gives — a check that reads
-- the same state the bug lives in cannot see the bug, and the question here is precisely "what does
-- a clone receive", not "what is on this disk".
local function trackedTopLevel()
    local list = io.popen("git ls-files 2>&1")
    if not list then return nil end
    local top, any = {}, false
    for line in list:lines() do
        line = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if line ~= "" and not line:find("fatal", 1, true) then
            any = true
            top[line:match("^([^/]+)") or line] = true
        end
    end
    list:close()
    return any and top or nil
end

local shippedSet = packagedTopLevel()
local tracked = trackedTopLevel()

if not shippedSet or not tracked then
    print("  # skipped: no io.popen or no git, cannot ask what a clone receives")
else
    local ignored = {}
    for _, entry in ipairs((pkgLists or {}).ignore or {}) do
        -- A trailing slash is allowed in .pkgmeta and names the same folder.
        ignored[entry:gsub("/$", "")] = true
    end

    for name in pairs(tracked) do
        if not shippedSet[name] then
            -- CurseForge drops dot-prefixed entries itself, so .github and .gitignore need no line.
            local hidden = name:sub(1, 1) == "."
            H.ok(hidden or ignored[name] == true,
                name .. " is tracked but not shipped, so " .. PKGMETA .. " must ignore it")
        end
    end

    -- The other direction. An ignore entry naming something the client needs is the failure that
    -- LOOKS like a working release right up until somebody who is not the developer installs it.
    for name in pairs(ignored) do
        H.ok(shippedSet[name] ~= true,
            PKGMETA .. " does not ignore " .. name .. ", which package.ps1 ships to the client")
    end
end

H.done()
