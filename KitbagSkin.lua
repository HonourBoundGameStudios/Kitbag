-- KitbagSkin — one recessed panel, drawn the same way in every window.
--
-- Kitbag draws four regions that hold a list or a grid: the set list, the character preview, and
-- the two pickers' grids. Each of them used to sit directly on whatever
-- `BasicFrameTemplateWithInset` had painted behind it, so a window read as a heading, some controls,
-- and content floating on an empty plate with no edge to say where the content began.
--
-- The addon already knew how to draw a recess — every doll cell has one — but it was written out by
-- hand at each site and therefore only existed where somebody had remembered to write it. That is
-- the failure this module is for, and it is not the two textures: it is that a seventh region cannot
-- arrive looking like none of the other six.
--
-- Textures rather than `SetBackdrop`: the backdrop API moved onto a template in Dragonflight and a
-- frame created without `BackdropTemplate` simply has no `SetBackdrop` method there, so the same
-- three lines are a working panel on Era and a nil-index error on Retail. Two flat textures behave
-- identically on every flavour Kitbag targets and cost less than the tiling backdrop would.

Kitbag = Kitbag or {}

local Skin = {}

-- The palette, in one place so the six regions cannot drift apart by a hundredth. The edge is the
-- game's own worn-brass rather than a grey: it has to read as part of the frame around it, and a
-- neutral border on a Blizzard window looks like a mistake rather than a choice.
Skin.EDGE   = { 0.33, 0.30, 0.24, 1 }
Skin.GROUND = { 0.05, 0.05, 0.06, 0.85 }

-- The addon's own icon (UI-33). Four controls draw it — the `## IconTexture` in the AddOns list, the
-- minimap button, the Broker launcher and the Equip button — and it used to be one of Blizzard's own
-- breastplate icons, written out as a path four times. That is one borrowed literal per place to
-- forget, and three of the four were found by a sweep rather than by remembering.
--
-- Here rather than in KitbagUI because the minimap button and the Broker object are not the window
-- and must not have to load it to know what Kitbag looks like. The extension is omitted: the client
-- appends it, and naming `.tga` explicitly is how a texture path stops working the day it becomes a
-- `.blp`.
Skin.ICON = "Interface\\AddOns\\Kitbag\\Media\\Kitbag-Icon"

--- Recess a frame: a one-pixel tinted edge with a dark ground inside it.
---
--- Returns the frame, so it can wrap the `CreateFrame` call that made it rather than needing a line
--- of its own several lines later — which is how the two hand-written recesses ended up worded
--- differently in the first place.
---
--- The textures are kept ON the frame under names of Kitbag's own, so a region can be asked whether
--- it was skinned. `kitbag`-prefixed because these hang off Blizzard's widget tables and a bare
--- `border` is a field several Blizzard templates already use.
function Skin.Inset(frame, edge, ground)
    if not frame or not frame.CreateTexture then return frame end

    edge = edge or Skin.EDGE
    ground = ground or Skin.GROUND

    -- rawget, not `frame.kitbagEdge`. A widget's metatable answers for keys the frame does not have,
    -- so a plain read can hand back something truthy that is not a texture — and the failure is not a
    -- second texture, it is a method call on whatever came back. rawget asks the frame itself.
    local border = rawget(frame, "kitbagEdge") or frame:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetTexture("Interface\\Buttons\\WHITE8X8")
    border:SetVertexColor(edge[1], edge[2], edge[3], edge[4] or 1)
    frame.kitbagEdge = border

    -- Inset by a pixel on every side, which is the whole of the edge: one texture over another is
    -- cheaper than four one-pixel strips and cannot leave a corner unpainted.
    local fill = rawget(frame, "kitbagGround") or frame:CreateTexture(nil, "BORDER")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetVertexColor(ground[1], ground[2], ground[3], ground[4] or 1)
    frame.kitbagGround = fill

    return frame
end

--- A square button whose whole label is a picture.
---
--- The recess is the same one every panel gets, so an icon button reads as part of the window rather
--- than as a floating tile, and the icon is inset inside it: a texture drawn edge to edge on a small
--- button loses its outline against a dark panel and stops being recognisable at 24 pixels, which is
--- the only size that matters.
---
--- The CALLER must give it an OnEnter. That is not a convention this function can enforce, but it is
--- the thing an icon costs: a text button that nobody explains is still readable, and an icon button
--- that nobody explains is a square. `/kit verify` and Tests/load_test both assert it rather than
--- trusting it, for exactly that reason.
function Skin.IconButton(parent, name, texture, width, height)
    width = width or 24

    local button = Skin.Inset(CreateFrame("Button", name, parent))
    button:SetSize(width, height or width)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexture(texture)
    button.kitbagIcon = icon

    -- Something clickable has to look clickable, and on a button with no text the highlight is the
    -- only affordance there is. Same texture the doll cells use, for the same reason.
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    -- Greying has to reach the PICTURE, because on a button with no words there is nothing else to
    -- grey. `Disable()` on its own stops the clicks and changes nothing anybody can see, which is a
    -- worse state than the one UI-19 fixed: the control goes on looking pressable and then silently
    -- does nothing, where before it at least explained itself late.
    --
    -- The flag is recorded as well as drawn. Alpha and desaturation are calls into the client that a
    -- test outside the game cannot read back, so without it the assertion would be about whether the
    -- code ran rather than about what it decided — and this is the half that must not regress.
    --
    -- SetDesaturated is old but not universal, so it is feature-detected: a flavour without it
    -- should draw a bright icon on a dead button rather than take the window down at build time.
    -- The alpha drop is what actually carries the meaning; desaturation is the polish on top.
    button.SetIconEnabled = function(self, on)
        on = on and true or false
        if on then self:Enable() else self:Disable() end
        if icon.SetDesaturated then pcall(icon.SetDesaturated, icon, not on) end
        icon:SetAlpha(on and 1 or 0.35)
        self.kitbagDimmed = not on
    end
    button:SetIconEnabled(true)

    return button
end

Kitbag.Skin = Skin
return Skin
