-- CreateFullActorCopy can give ordinary items temporary base forms. Those
-- forms disappear when the game loads a save. Match only pristine unequipped
-- copies with an unambiguous, stable original in the host's inventory.
local CloneInventory={}

local function signature(item)
    return table.concat({item.type,item.name,item.value,item.weight,item.icon_path or "",
        item.health or "",item.max_health or ""},"\0")
end

function CloneInventory.replacements(host,guest)
    local originals,copies,counts={},{},{}
    for _,item in ipairs(host.items) do
        if (item.form_id & 0xff000000)~=0xff000000 then
            local key=signature(item)
            if originals[key]==nil then originals[key]=item else originals[key]=false end
        end
    end
    for _,item in ipairs(guest.items) do
        counts[item.form_id]=item.count
        if (item.form_id & 0xff000000)==0xff000000 then
            local key=signature(item)
            if copies[key]==nil then copies[key]=item else copies[key]=false end
        end
    end
    local result={}
    for key,copy in pairs(copies) do
        local original=originals[key]
        if copy and original and not copy.equipped and (not copy.health or copy.health==100) then
            local existing=counts[original.form_id] or 0
            if copy.count+existing==original.count then
                result[#result+1]={temporary=copy.form_id,stable=original.form_id,count=copy.count,expected=original.count}
            end
        end
    end
    return result
end

return CloneInventory
