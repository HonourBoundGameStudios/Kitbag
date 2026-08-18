-- KitbagSkin — one recessed panel, drawn the same way in every window.
--
-- Kitbag draws six regions that hold a list or a grid: the set list, the character preview, the rule
-- list, the rule editor, and the two pickers' grids. Each of them used to sit directly on whatever
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

Kitbag.Skin = Skin
return Skin
