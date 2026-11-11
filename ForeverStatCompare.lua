local ADDON = ...

local enabled = true
local cache = {}
local drawn = {}

local STAT_KEYS = {
    ITEM_MOD_STRENGTH_SHORT = "Strength",
    ITEM_MOD_AGILITY_SHORT = "Agility",
    ITEM_MOD_STAMINA_SHORT = "Stamina",
    ITEM_MOD_INTELLECT_SHORT = "Intellect",
    ITEM_MOD_SPIRIT_SHORT = "Spirit",
    ITEM_MOD_HEALTH_SHORT = "Health",
    ITEM_MOD_ATTACK_POWER_SHORT = "AttackPower",
    ITEM_MOD_MELEE_ATTACK_POWER_SHORT = "AttackPower",
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "RangedAttackPower",
    ITEM_MOD_CRIT_RATING_SHORT = "CritRating",
    ITEM_MOD_CRIT_MELEE_RATING_SHORT = "MeleeCritRating",
    ITEM_MOD_CRIT_RANGED_RATING_SHORT = "RangedCritRating",
    ITEM_MOD_CRIT_SPELL_RATING_SHORT = "SpellCritRating",
    ITEM_MOD_DODGE_RATING_SHORT = "DodgeRating",
    ITEM_MOD_PARRY_RATING_SHORT = "ParryRating",
    ITEM_MOD_HIT_RATING_SHORT = "HitRating",
    ITEM_MOD_HIT_MELEE_RATING_SHORT = "MeleeHitRating",
    ITEM_MOD_HIT_RANGED_RATING_SHORT = "RangedHitRating",
    ITEM_MOD_HASTE_RATING_SHORT = "HasteRating",
    ITEM_MOD_SPELL_POWER_SHORT = "SpellPower",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "SpellPower",
    ITEM_MOD_SPELL_HEALING_DONE_SHORT = "Healing",
    ITEM_MOD_MANA_REGENERATION_SHORT = "MP5",
}

local LABELS = {
    Strength = "Strength", Agility = "Agility", Stamina = "Stamina",
    Intellect = "Intellect", Spirit = "Spirit", Health = "Health",
    AttackPower = "Attack power", RangedAttackPower = "Ranged attack power",
    Crit = "Crit", SpellCrit = "Spell crit", Dodge = "Dodge", Parry = "Parry",
    Hit = "Hit", Haste = "Haste", SpellPower = "Spell power", Healing = "Healing",
    MP5 = "Mana per 5 sec", Mana = "Mana",
}

local function ItemLink(tooltip)
    if not tooltip then return end
    local link
    if TooltipUtil and TooltipUtil.GetDisplayedItem then
        local _, displayed = TooltipUtil.GetDisplayedItem(tooltip)
        link = displayed
    end
    -- ShoppingTooltip frames on Forever do not always expose their item
    -- through TooltipUtil; the installed working bag addons use GetItem().
    if not link and tooltip.GetItem then
        local _, fallback = tooltip:GetItem()
        link = fallback
    end
    return link
end

local function Stats(link)
    if type(link) ~= "string" or not C_Item or not C_Item.GetItemStats then return end
    local raw = C_Item.GetItemStats(link)
    if type(raw) ~= "table" then return end
    local out = {}
    for key, value in pairs(raw) do
        local stat = STAT_KEYS[key]
        if stat and type(value) == "number" then
            out[stat] = (out[stat] or 0) + value
        end
    end
    -- GetItemStats does not always include English Equip: effects such as
    -- Attack Power. Read the item's own tooltip so equipped effects are part
    -- of the replacement delta too.
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local data = C_TooltipInfo.GetHyperlink(link)
        for _, line in ipairs((data and data.lines) or {}) do
            local text = line.leftText
            if type(text) == "string" then
                local lower = text:lower()
                if lower:find("equip:", 1, true) then
                    local value = lower:match("%+(%d+)%s+attack power") or lower:match("attack power by (%d+)")
                    if value and not out.AttackPower then out.AttackPower = tonumber(value) end
                    value = lower:match("%+(%d+)%s+ranged attack power") or lower:match("ranged attack power by (%d+)")
                    if value and not out.RangedAttackPower then out.RangedAttackPower = tonumber(value) end
                end
            end
        end
    end
    return out
end

local function Difference(new, old)
    local out = {}
    for key, value in pairs(new or {}) do out[key] = value end
    for key, value in pairs(old or {}) do out[key] = (out[key] or 0) - value end
    return out
end

local function Number(v)
    if math.abs(v - math.floor(v + 0.5)) < 0.01 then return tostring(math.floor(v + 0.5)) end
    return string.format("%.2f", v)
end

local function Signed(v)
    return v > 0 and "+" .. Number(v) or Number(v)
end

local function AddDerived(delta, out)
    local str = delta.Strength or 0
    local agi = delta.Agility or 0
    local int = delta.Intellect or 0

    -- These are the live Forever conversion functions used by the installed
    -- Forever client and by the project's verified character model.
    local currentStr = select(2, UnitStat("player", 1)) or 0
    local currentAgi = select(2, UnitStat("player", 2)) or 0
    local currentInt = select(2, UnitStat("player", 4)) or 0
    if (delta.Stamina or 0) ~= 0 then
        local _, stamina = UnitStat("player", LE_UNIT_STAT_STAMINA or 3)
        local rate = UnitHPPerStamina("player")
        local breakpoint = STAMINA_BREAK or 20
        local function staminaHealth(value)
            return math.min(value, breakpoint) + math.max(0, value - breakpoint) * rate
        end
        out.Health = (delta.Health or 0) + staminaHealth(stamina + delta.Stamina) - staminaHealth(stamina)
    end
    if type(GetAttackPowerForStat) == "function" then
        local ap = GetAttackPowerForStat(1, currentStr + str) - GetAttackPowerForStat(1, currentStr)
        local agilityAP
        local _, class = UnitClass("player")
        if class == "DRUID" then
            -- Forever's form IDs are Cat=1, Bear=5, Dire Bear=8.
            local form = type(GetShapeshiftFormID) == "function" and GetShapeshiftFormID()
            agilityAP = form == 1 and agi or 0
        else
            -- Forever's class-aware conversion handles Rogue, Hunter, and
            -- the remaining classes here.
            agilityAP = GetAttackPowerForStat(2, currentAgi + agi) - GetAttackPowerForStat(2, currentAgi)
        end
        ap = ap + agilityAP
        ap = ap + (delta.AttackPower or 0)
        if ap ~= 0 then out.AttackPower = (out.AttackPower or 0) + ap end
    end
    if type(GetRangedAttackPowerForStat) == "function" then
        local rap = GetRangedAttackPowerForStat(2, currentAgi + agi) - GetRangedAttackPowerForStat(2, currentAgi)
        rap = rap + (delta.RangedAttackPower or 0)
        if rap ~= 0 then out.RangedAttackPower = (out.RangedAttackPower or 0) + rap end
    end
    if type(GetCritChanceFromStat) == "function" then
        local crit = (GetCritChanceFromStat(2, currentAgi + agi) - GetCritChanceFromStat(2, currentAgi)) * 100
        if crit ~= 0 then out.Crit = (out.Crit or 0) + crit end
    end
    if type(GetSpellCritChanceFromStat) == "function" then
        local crit = (GetSpellCritChanceFromStat(4, currentInt + int) - GetSpellCritChanceFromStat(4, currentInt)) * 100
        if crit ~= 0 then out.SpellCrit = (out.SpellCrit or 0) + crit end
    end
    if UnitPowerMax and Enum and Enum.PowerType and Enum.PowerType.Mana and UnitPowerMax("player", Enum.PowerType.Mana) > 0 then
        if int ~= 0 then out.Mana = int * 15 end
    end

    local rating = {
        { "Crit", 9, (delta.CritRating or 0) + (delta.MeleeCritRating or 0) },
        { "SpellCrit", 11, (delta.CritRating or 0) + (delta.SpellCritRating or 0) },
        { "Dodge", 3, delta.DodgeRating or 0 },
        { "Parry", 4, delta.ParryRating or 0 },
        { "Hit", 6, (delta.HitRating or 0) + (delta.MeleeHitRating or 0) },
        { "Haste", 18, delta.HasteRating or 0 },
    }
    if type(GetCombatRatingBonusForCombatRatingValue) == "function" then
        for _, r in ipairs(rating) do
            if r[3] ~= 0 then
                local pct = GetCombatRatingBonusForCombatRatingValue(r[2], r[3])
                if pct and pct ~= 0 then out[r[1]] = (out[r[1]] or 0) + pct end
            end
        end
    end
end

-- Measure the marginal regen of Spirit from two gear states. Subtracting
-- readings cancels the character's base regen.
local sample, slopes
local function SampleRegen()
    local _, spirit = UnitStat("player", 5)
    local _, intellect = UnitStat("player", 4)
    local health = GetHealthRegenFromSpirit()
    local mana = GetManaRegenFromSpirit()
    for _, value in ipairs({ spirit, intellect, health, mana }) do
        if issecretvalue and issecretvalue(value) then return end
    end
    if not spirit or not health then return end
    local context = UnitLevel("player") .. "/" .. GetShapeshiftForm()
    if sample and context == sample.context and intellect == sample.intellect then
        local change = spirit - sample.spirit
        if change ~= 0 then
            slopes = { health = (health - sample.health) * 3.75 / change,
                mana = mana and sample.mana and (mana - sample.mana) * 5 / change }
        elseif health ~= sample.health or mana ~= sample.mana then
            slopes = nil
        end
    elseif sample then
        slopes = nil
    end
    sample = { spirit = spirit, intellect = intellect, health = health, mana = mana, context = context }
    wipe(cache)
end
local sampler = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "UPDATE_SHAPESHIFT_FORM" }) do
    sampler:RegisterEvent(event)
end
sampler:SetScript("OnEvent", function() C_Timer.After(0.25, SampleRegen) end)

local function BuildRows(newLink, oldLink)
    local incoming, equipped = Stats(newLink), Stats(oldLink)
    if not incoming or not equipped then return end
    local delta = Difference(incoming, equipped)
    local derived = {}
    AddDerived(delta, derived)
    local rows = {}
    -- Blizzard already shows the primary-stat deltas. Keep them in the
    -- calculation, but only display derived/direct values here.
    local order = { "Health", "AttackPower", "RangedAttackPower", "Crit", "SpellCrit", "Dodge",
        "Parry", "Hit", "Haste", "SpellPower", "Healing", "MP5", "Mana" }
    for _, key in ipairs(order) do
        local value = derived[key] or delta[key] or 0
        if key == "AttackPower" or key == "RangedAttackPower" or key == "Crit" or key == "SpellCrit"
            or key == "Dodge" or key == "Parry" or key == "Hit" or key == "Haste" then
            value = derived[key] or 0
        end
        if value ~= 0 then
            local suffix = (key == "Crit" or key == "SpellCrit" or key == "Dodge" or key == "Parry"
                or key == "Hit" or key == "Haste") and "%" or ""
            rows[#rows + 1] = { LABELS[key] .. ": " .. Signed(value) .. suffix, value > 0 and 0.35 or 1, value > 0 and 1 or 0.35, value > 0 and 0.5 or 0.35 }
        end
    end
    local spirit = delta.Spirit or 0
    if spirit ~= 0 then
        local _, class = UnitClass("player")
        local _, currentSpirit = UnitStat("player", 5)
        local function addRate(label, rate, readRegen, scale)
            -- A single reading gives an average per point, not a marginal
            -- rate. Use it until a gear swap measures the slope.
            if rate == nil then
                local regen = readRegen()
                if issecretvalue and (issecretvalue(currentSpirit) or issecretvalue(regen)) then return end
                if not currentSpirit or currentSpirit <= 0 or not regen then return end
                rate = regen * scale / currentSpirit
            end
            local value = spirit * rate
            rows[#rows + 1] = { label .. ": " .. Signed(value), value > 0 and 0.35 or 1,
                value > 0 and 1 or 0.35, value > 0 and 0.5 or 0.35 }
        end
        addRate("Health regen", slopes and slopes.health, GetHealthRegenFromSpirit, 3.75)
        if class ~= "WARRIOR" and class ~= "ROGUE" then
            addRate("Mana regen", slopes and slopes.mana, GetManaRegenFromSpirit, 5)
        end
    end
    return rows
end

local function OwnerOf(frame)
    if frame == ShoppingTooltip1 or frame == ShoppingTooltip2 then return GameTooltip end
    if frame == ItemRefShoppingTooltip1 or frame == ItemRefShoppingTooltip2 then return ItemRefTooltip end
end

local footers = {}
local function GetFooter(frame)
    if footers[frame] then return footers[frame] end
    local footer = CreateFrame("Frame", nil, frame)
    footer:SetPoint("TOPLEFT", frame, "BOTTOMLEFT")
    footer:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT")
    local skin = CreateFrame("Frame", nil, footer, "NineSlicePanelTemplate")
    skin:SetAllPoints()
    skin:SetFrameLevel(footer:GetFrameLevel())
    NineSliceUtil.DisableSharpening(skin)
    NineSliceUtil.ApplyLayout(skin, NineSliceUtil.GetLayout("TooltipDefaultLayout"))
    for _, name in ipairs({ "TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
        "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner" }) do
        local piece = skin[name]
        if piece then
            piece:SetDesaturated(true)
            piece:SetVertexColor(0.14, 0.14, 0.14)
        end
    end
    local center = frame.NineSlice and frame.NineSlice.Center
    if center then
        skin:SetCenterColor(center:GetVertexColor())
        skin.Center:SetAlpha(center:GetAlpha())
        skin:SetAlpha(frame.NineSlice:GetAlpha())
    else
        skin:SetCenterColor(TOOLTIP_DEFAULT_BACKGROUND_COLOR:GetRGB())
    end
    local label = footer:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    label:SetPoint("TOPLEFT", 10, -7)
    label:SetJustifyH("LEFT")
    footer.label = label
    footers[frame] = footer
    return footer
end

TooltipDataProcessor.AddTooltipPreCall(TooltipDataProcessor.AllTypes, function(frame)
    drawn[frame] = nil
    if footers[frame] then footers[frame]:Hide() end
end)

TooltipDataProcessor.AddLinePostCall(Enum.TooltipDataLineType.ItemName, function(frame)
    local owner = OwnerOf(frame)
    if not enabled or not owner or drawn[frame] or frame:IsForbidden() then return end
    local candidate, equipped = ItemLink(owner), ItemLink(frame)
    if issecretvalue and (issecretvalue(candidate) or issecretvalue(equipped)) then return end
    if not candidate or not equipped or candidate == equipped then return end
    local entry = cache[frame]
    if not entry or entry.candidate ~= candidate or entry.equipped ~= equipped then
        local rows = BuildRows(candidate, equipped)
        if not rows then return end
        entry = { candidate = candidate, equipped = equipped, rows = rows }
        cache[frame] = entry
    end
    drawn[frame] = entry
    if #entry.rows == 0 then return end
    local footer = GetFooter(frame)
    if footer.entry ~= entry then
        local lines = { "|cffffd100Forever stat changes|r" }
        for _, row in ipairs(entry.rows) do
            lines[#lines + 1] = (row[2] == 1 and "|cffff5959" or "|cff59ff80") .. row[1] .. "|r"
        end
        footer.label:SetText(table.concat(lines, "\n"))
        footer:SetHeight(footer.label:GetStringHeight() + 14)
        footer.entry = entry
    end
    footer:Show()
end)

for _, owner in ipairs({ GameTooltip, ItemRefTooltip }) do
    owner:HookScript("OnHide", function() wipe(cache) end)
end

SLASH_FOREVERSTATCOMPARE1 = "/fsc"
SlashCmdList.FOREVERSTATCOMPARE = function(msg)
    local command = (msg or ""):lower():match("^%s*(%S*)")
    if command == "on" then enabled = true
    elseif command == "off" then enabled = false
    else enabled = not enabled end
    print("Forever Stat Compare: " .. (enabled and "on" or "off"))
end
