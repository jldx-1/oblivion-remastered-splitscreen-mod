local json = require("lib.json")
local Races = require("lib.races")
local Store = {}
Store.__index = Store

local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 160 and value:match("^[%w_-]+$")
end
local function valid(document, campaign, slot)
    if type(document) ~= "table" or document.schema ~= 1 then return false end
    if document.campaign ~= campaign or document.slot ~= slot then return false end
    local player = document.player
    if type(player) ~= "table" or not identifier(player.id) then return false end
    if type(player.actor_ref) ~= "string" or not player.actor_ref:match("^%x%x%x%x%x%x%x%x$") then return false end
    if type(player.name) ~= "string" or #player.name > 128 then return false end
    if player.race~=nil and not Races.contains(player.race) then return false end
    local spell=player.spell_id
    if spell~=nil and (math.type(spell)~="integer" or spell<1 or spell>0xffffffff) then return false end
    -- The complete inventory/equipment remains on this actor inside the native game save.
    -- This sidecar preserves identity; it must never fabricate an inventory snapshot.
    return player.persistence == "native_actor"
end
function Store.new(root, native)
    return setmetatable({root = root, native = native}, Store)
end
function Store:path(campaign, slot)
    assert(identifier(campaign) and identifier(slot), "Invalid save identifier")
    return self.root .. "/" .. campaign .. "__" .. slot .. ".json"
end
function Store:read(campaign, slot)
    local path = self:path(campaign, slot)
    for _, suffix in ipairs({"", ".bak"}) do
        local file = io.open(path .. suffix, "rb")
        if file then
            local bytes = file:read(4 * 1024 * 1024 + 1); file:close()
            if bytes and #bytes <= 4 * 1024 * 1024 then
                local ok, document = pcall(json.decode, bytes)
                if ok and valid(document, campaign, slot) then return document, suffix == ".bak" end
            end
        end
    end
    return nil, "No valid player-two record for this save"
end
function Store:exists(campaign,slot)
    local path=self:path(campaign,slot)
    for _,suffix in ipairs({"",".bak"}) do
        local file=io.open(path..suffix,"rb")
        if file then file:close(); return true end
    end
    return false
end
function Store:write(campaign, slot, player)
    local document = {schema = 1, campaign = campaign, slot = slot, player = player}
    assert(valid(document, campaign, slot), "Refusing incomplete player-two save record")
    return self.native.atomic_write(self:path(campaign, slot), json.encode(document))
end
Store.valid = valid
return Store
