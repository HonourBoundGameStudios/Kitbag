-- The publish whitelist (SHIP-6).
--
-- `publish.ps1` copies a whitelist of this repository into a SEPARATE public history. It is the one
-- guard in the project whose failure cannot be taken back: publishing is one-way, and a working note
-- that reaches the public repo is there permanently, in a history no later commit can undo. Both
-- lists it holds — `$filePatterns`/`$directories` (what may go public) and `$forbidden` (what must
-- never arrive) — are maintained by hand, and until now neither was covered by the gate.
--
-- THE POINT OF THIS FILE IS THAT IT DERIVES THE EXPECTATION RATHER THAN REPEATING IT. A test that
-- hardcoded "Process, Research and Design must be forbidden" would be a third hand-maintained list
-- rotting alongside the other two, and it would say nothing at all about the folder somebody adds
-- next year. Instead: every top-level entry that actually exists must be classified by one side or
-- the other, read off the filesystem. Add a new private folder and the suite goes red until someone
-- has decided which side it is on — which turns "did anyone remember" into "the gate says no".
--
-- Usage: lua Tests/publish_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")

H.start("publish.ps1")

local WINDOWS = package.config:sub(1, 1) == "\\"

local function slurp(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

-- This test file is itself published — `Tests/` is a whitelisted directory — so it also runs in the
-- public repository's CI, where `publish.ps1` deliberately does not exist. It must skip there rather
-- than fail on a missing file it is right to be missing.
--
-- The skip is conditional on which checkout this is, NOT simply on the script being absent: a guard
-- that quietly turns itself off the moment its subject disappears is no guard at all. `Process/` is
-- private by construction and can only exist in the workshop, so in the workshop the script must be
-- there and its absence is a failure.
local SCRIPT = slurp("publish.ps1")
if not SCRIPT then
    local workshop = io.open("Process/Backlog.md", "r")
    if workshop then
        workshop:close()
        H.ok(false, "publish.ps1 exists (this is the workshop checkout: Process/ is present)")
    else
        print("  # skipped: no publish.ps1 — this is the published checkout, which has none")
    end
    H.done()
end

-- ---------------------------------------------------------------------------
-- Read the lists out of the script
-- ---------------------------------------------------------------------------
--
-- Parsed rather than restated, so the test is talking about the array that actually runs. If a
-- variable is renamed the parse comes back empty, which is asserted below — an empty list would
-- otherwise make every check that follows vacuously true, and a test that passes because it stopped
-- looking is worse than no test.

local function readList(name)
    local body = SCRIPT:match("%$" .. name .. "%s*=%s*@%((.-)%)")
    local items = {}
    if body then
        for item in body:gmatch('"([^"]*)"') do
            items[#items + 1] = item
        end
    end
    return items
end

local filePatterns = readList("filePatterns")
local directories  = readList("directories")
local forbidden    = readList("forbidden")

H.ok(#filePatterns > 0, "publish.ps1 still defines $filePatterns (" .. #filePatterns .. " patterns)")
H.ok(#directories > 0, "publish.ps1 still defines $directories (" .. #directories .. " entries)")
H.ok(#forbidden > 0, "publish.ps1 still defines $forbidden (" .. #forbidden .. " entries)")

local function has(list, want)
    for _, item in ipairs(list) do
        if item == want then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The whitelist is matched the way PowerShell matches it
-- ---------------------------------------------------------------------------
--
-- `Get-ChildItem $root -Filter $pattern -File` is a NON-RECURSIVE scan of files only, so the two
-- lists mean different things: a file is published only if it matches a glob in $filePatterns, and a
-- directory only if it is named outright in $directories. Getting that distinction wrong here would
-- make the test agree with a script that does something else.

local function globToPattern(glob)
    -- Escape every Lua pattern magic character, then let `*` through as `.*`. `*` is the only
    -- wildcard the whitelist uses, and treating one as a literal would silently under-match.
    local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*")
    return "^" .. escaped .. "$"
end

local function fileIsWhitelisted(name)
    for _, glob in ipairs(filePatterns) do
        if name:match(globToPattern(glob)) then return true end
    end
    return false
end

-- The scan being non-recursive is load-bearing and invisible. `Process/*.md` cannot match the
-- `*.md`-shaped entries in $filePatterns today ONLY because the scan never descends; add -Recurse
-- and the whitelist changes meaning entirely, publishing working notes that no list ever named.
H.ok(SCRIPT:match("Get%-ChildItem %$root %-Filter %$pattern %-File") ~= nil,
    "the root file scan is still `Get-ChildItem $root -Filter $pattern -File`")
H.ok(SCRIPT:match("Get%-ChildItem %$root %-Filter %$pattern %-File[^\n]*%-Recurse") == nil,
    "the root file scan is still NON-recursive (-Recurse would publish every matching file at any depth)")

-- ---------------------------------------------------------------------------
-- The two lists cannot contradict each other
-- ---------------------------------------------------------------------------
--
-- $forbidden is the belt to the whitelist's braces: it aborts the publish if a named thing reached
-- the tree. So a name on both lists is not a double guard, it is a script that copies the file and
-- then refuses to publish anything ever again — a whitelist edit that breaks publishing outright
-- rather than leaking. Cheap to check, and it fails at exactly the moment the mistake is made.

for _, name in ipairs(forbidden) do
    local asFile = fileIsWhitelisted(name)
    local asDir = has(directories, name)
    H.ok(not asFile and not asDir,
        "forbidden '" .. name .. "' is not also matched by the whitelist")
end

-- ---------------------------------------------------------------------------
-- Every top-level entry has been classified
-- ---------------------------------------------------------------------------
--
-- The check this item exists for. The source of truth is the FILESYSTEM, because that is what
-- publish.ps1 copies from — not the git index, which would quietly exempt an untracked file that
-- would nonetheless be published. Entries git ignores are excluded, since they are not part of this
-- repository at all; `.git` itself is git's own store rather than repository content.

local function popen(cmd)
    local pipe = io.popen(cmd)
    if not pipe then return nil end
    local names = {}
    for line in pipe:lines() do
        line = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if line ~= "" then names[#names + 1] = line end
    end
    pipe:close()
    return names
end

local entries = popen(WINDOWS and "dir /b /a" or "ls -A")
local dirList = popen(WINDOWS and "dir /b /a /ad" or "ls -Ap | grep /")

-- The classification below excludes what git ignores, so a git that cannot answer would mark every
-- ignored entry unclassified and report a fistful of failures that are really one missing tool.
-- Ask it plainly first and say so, rather than letting the noise stand in for the diagnosis.
local inWorkTree = popen("git rev-parse --is-inside-work-tree 2>" .. (WINDOWS and "NUL" or "/dev/null"))
local haveGit = inWorkTree and inWorkTree[1] == "true"

if not entries or not dirList then
    -- Not fatal: a sandbox without io.popen should not turn the gate red over a directory listing.
    -- The list-parsing checks above still ran and are the ones that catch a renamed variable.
    print("  # skipped: no io.popen, cannot list the project root")
elseif not haveGit then
    print("  # skipped: git could not report what it ignores, so the root cannot be classified")
else
    local isDir = {}
    for _, name in ipairs(dirList) do
        isDir[(name:gsub("/$", ""))] = true
    end

    -- Ask git which of these it ignores, in one call, rather than reimplementing .gitignore here —
    -- a second parser for those rules would be a fourth list to keep in sync.
    local quoted = {}
    for _, name in ipairs(entries) do quoted[#quoted + 1] = '"' .. name .. '"' end
    local ignoredList = popen("git check-ignore -- " .. table.concat(quoted, " ") ..
        (WINDOWS and " 2>NUL" or " 2>/dev/null"))
    local ignored = {}
    for _, name in ipairs(ignoredList or {}) do
        ignored[(name:gsub("[\\/]$", ""))] = true
    end

    local classified = 0
    for _, name in ipairs(entries) do
        if name ~= ".git" and not ignored[name] then
            local whitelisted = isDir[name] and has(directories, name) or
                (not isDir[name] and fileIsWhitelisted(name))
            local blocked = has(forbidden, name)
            classified = classified + 1
            H.ok(whitelisted or blocked,
                (isDir[name] and "directory '" or "file '") .. name ..
                "' is either whitelisted for publishing or named in $forbidden")
        end
    end

    -- A listing that came back empty would pass the loop above without checking anything.
    H.ok(classified > 0, "the root listing found " .. classified .. " entries to classify")
end

-- ---------------------------------------------------------------------------
-- The workshop branch cannot be pushed to the public remote
-- ---------------------------------------------------------------------------
--
-- Everything above guards the COPY that publish.ps1 makes. This guards the other route to the same
-- public repository, which is the one that actually failed: between 2026-08-13 and 2026-08-16 the
-- workshop branch itself was pushed to it, and Process/, Research/, Design/ and CLAUDE.md sat on a
-- public GitHub repo for three days. The whitelist never got it wrong — it never got ASKED.
--
-- What had been holding that shut was the absence of a remote, recorded in publish.ps1's header as
-- "it cannot, because there is nothing here to push to". An absence is not a control: it is enforced
-- by nobody, it is invisible when it changes, and it reverted the moment somebody ran
-- `git remote add`. Nothing went red. So the replacement has to be a thing that RUNS.
--
-- The hook lives in Process/ deliberately. It is workshop machinery, and Process/ is already private
-- by construction and already named in $forbidden — so the guard sits inside the thing it guards and
-- adds no new root entry for the classification check above to have an opinion about.

local HOOK = "Process/hooks/pre-push"

if not haveGit then
    print("  # skipped: git could not answer, so the push guard cannot be checked")
else
    H.ok(slurp(HOOK) ~= nil, "the pre-push guard exists at " .. HOOK)

    -- A hook that is not wired up is not a hook. Git only runs hooks from core.hooksPath, and that is
    -- local config rather than repository content — which makes it exactly the kind of thing that is
    -- true on one machine and silently false everywhere else, so the gate has to ask.
    local configured = popen("git config core.hooksPath 2>" .. (WINDOWS and "NUL" or "/dev/null"))
    local hooksPath = configured and configured[1] or ""
    H.ok(hooksPath:gsub("\\", "/") == "Process/hooks",
        "git is configured to run it (core.hooksPath = '" .. hooksPath .. "', want 'Process/hooks')")

    -- Derived, not restated. Every private path publish.ps1 refuses to publish must also be a path
    -- the hook refuses to push — the two guards cover one public repository by two different routes,
    -- and a name protected on only one of them is a hole. Untracked entries are skipped because they
    -- can never appear in a commit's tree, so blocking them would be noise.
    local hookText = slurp(HOOK) or ""
    for _, name in ipairs(forbidden) do
        local tracked = popen('git ls-files --error-unmatch "' .. name ..
            '" 2>' .. (WINDOWS and "NUL" or "/dev/null"))
        if tracked and #tracked > 0 then
            H.ok(hookText:match("%f[%w_]" .. name:gsub("%.", "%%.") .. "%f[^%w_]") ~= nil,
                "the hook also refuses to push '" .. name .. "' (publish.ps1 forbids it)")
        end
    end
end

-- Run the hook for real. Reading the script would only prove it CONTAINS the right words; the thing
-- worth knowing is what it does when git hands it a push, and this is cheap enough to just do.
local head = popen("git rev-parse HEAD 2>" .. (WINDOWS and "NUL" or "/dev/null"))
local NULL_SHA = string.rep("0", 40)

local function runHook(localSha)
    local input = "Tests/hook_input.tmp"   -- *.tmp is gitignored
    local f = io.open(input, "w")
    if not f then return nil end
    f:write("refs/heads/master " .. localSha .. " refs/heads/master " .. NULL_SHA .. "\n")
    f:close()
    local cmd = "sh " .. HOOK .. " origin https://github.com/HonourBoundGameStudios/Kitbag.git < " ..
        input .. " >" .. (WINDOWS and "NUL" or "/dev/null") .. " 2>&1"
    local a, _, c = os.execute(cmd)
    os.remove(input)
    -- Lua 5.1 hands back the raw status; 5.2+ returns ok, "exit", code.
    if type(a) == "number" then return a end
    return c or (a and 0 or 1)
end

if not head or #head == 0 or not slurp(HOOK) then
    print("  # skipped: no HEAD or no hook, cannot exercise the guard")
else
    local refused = runHook(head[1])
    if refused == nil then
        print("  # skipped: could not run sh, so the hook's behaviour was not exercised")
    else
        -- HEAD is the workshop tree. If pushing it is allowed, the guard is decorative.
        H.ok(refused ~= 0, "pushing the workshop tree is REFUSED (hook exited " .. tostring(refused) .. ")")

        -- Deleting a remote branch pushes the null sha and carries no tree with it. Refusing that
        -- would have blocked the very command that cleaned this mess up, which is the shape of guard
        -- that gets switched off within a week.
        local del = runHook(NULL_SHA)
        H.ok(del == 0, "deleting a remote branch is still allowed (hook exited " .. tostring(del) .. ")")
    end
end

H.done()
