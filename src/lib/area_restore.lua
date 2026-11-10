local Background=require("lib.background_cell")
local Fixtures=require("lib.door_fixtures")
local json=require("lib.json")
local Restore={}

local function read(method,id,request)
    local raw=method(id)
    local data=raw and json.decode(raw)
    if data and data.actor_ref==id and data.request==request then return data end
end

local function request(adapter,pending,now)
    pending.request=pending.request+1
    pending.next_query=now+250
    local token=pending.request
    adapter:command({"player.LSSActorPosition "..token,pending.actor..".LSSActorPosition "..token,
        pending.actor..".LSSInventory "..token})
end

function Restore.begin(adapter,actor,save_id)
    if not actor:match("^FF%x%x%x%x%x%x$") then return false,"The saved character reference is invalid" end
    local now=adapter.native.clock_ms()
    local pending={modern=true,actor=actor,id=tonumber(actor,16),save_id=save_id,campaign=adapter.campaign_id,
        phase="origin",request=550000000+now%100000000,deadline=now+18000}
    adapter.saved_area=pending
    adapter.saved_area_status=nil
    request(adapter,pending,now)
    return "pending"
end

local function same_items(before,after,equipment)
    if #before~=#after then return false end
    for index,item in ipairs(before) do
        local current=after[index]
        if item.form_id~=current.form_id or item.count~=current.count then return false end
        if equipment and (item.equipped~=current.equipped or item.left~=current.left) then return false end
    end
    return true
end

function Restore.poll(adapter)
    local pending=adapter.saved_area
    local now=adapter.native.clock_ms()
    if now>=pending.deadline then return false,"Player 2 area restoration timed out at "..pending.phase end
    if not adapter:world_ready() then return "pending" end
    if adapter:save_id()~=pending.save_id or adapter:campaign()~=pending.campaign then
        return false,"The save changed during Player 2 area restoration"
    end
    local n=adapter.native
    local host=read(n.backend_actor_position,20,pending.request)
    local guest=read(n.backend_actor_position,pending.id,pending.request)
    local inventory=read(n.backend_inventory,pending.id,pending.request)
    if host and guest and inventory and inventory.items then
        if pending.phase=="origin" then
            if guest.cell_ref==host.cell_ref then
                pending.fixture,pending.items,pending.phase={cell=guest.cell_ref},inventory.items,"paired"
                request(adapter,pending,now)
                return "pending"
            end
            if not guest.interior or not guest.cell or not host.cell or not host.cell.attached then
                return false,"Player 2's saved area cannot be restored independently yet"
            end
            local fixture=Background.describe(guest.cell_ref)
            if not fixture then return false,"Player 2's saved area has no streaming package" end
            local stream=Background.stream(adapter:host().Pawn,fixture)
            if not stream then return false,"Could not stream Player 2's saved area" end
            pending.fixture,pending.stream,pending.items=fixture,stream,inventory.items
            pending.phase="streaming"
            adapter.area_streams=adapter.area_streams or {}
            adapter.area_streams[fixture.cell]={fixture=fixture,stream=stream}
        elseif guest.cell_ref~=pending.fixture.cell then
            return false,"Player 2's saved area changed during restoration"
        elseif pending.phase=="streaming" then
            local stream=pending.stream
            if not stream:IsValid() then return false,"Player 2's saved level was unloaded" end
            if stream:IsLevelVisible() and Background.registered(pending.fixture) then
                if guest.cell.state==0 and not guest.cell.paired and not guest.cell.has_native_root then
                    pending.phase="preparing"
                    adapter:command(("LSSPrepareCellFixture %d 2"):format(guest.cell_ref))
                elseif guest.cell.state==3 and guest.cell.paired and guest.cell.has_native_root then
                    pending.phase="attaching"
                    adapter:command(("LSSPrepareCellFixture %d 3"):format(guest.cell_ref))
                elseif guest.cell.attached and guest.actor_paired then
                    pending.phase="paired"
                else
                    return false,"Player 2's saved cell still belongs to an earlier world"
                end
            end
        elseif pending.phase=="preparing" and guest.cell.state==3 and guest.cell.paired and guest.cell.has_native_root then
            pending.phase="attaching"
            adapter:command(("LSSPrepareCellFixture %d 3"):format(guest.cell_ref))
        elseif pending.phase=="attaching" and guest.cell.attached and guest.actor_paired then
            pending.phase="paired"
        elseif pending.phase=="paired" then
            local actor=adapter:find_actor(pending.actor)
            if actor and actor:IsValid() then
                if not same_items(pending.items,inventory.items) then
                    return false,"Player 2's saved inventory changed during area restoration"
                end
                adapter.actor,adapter.actor_ref,adapter.transition=actor,pending.actor,nil
                adapter:create_view()
                adapter:finish_join()
                -- Native cell attachment can choose an NPC's preferred outfit.
                -- Restore the saved selection after possession stops that AI.
                local commands=adapter:guest_equipment_commands(pending.items,inventory.items)
                if #commands>0 then adapter:command(commands) end
                if guest.cell_ref==Fixtures.hotel.cell then adapter.hotel_guest_travel=true end
                pending.phase="verifying"
                request(adapter,pending,now)
                return "pending"
            end
        elseif pending.phase=="verifying" then
            if not same_items(pending.items,inventory.items) then
                return false,"Player 2's saved inventory changed while rejoining"
            end
            if not same_items(pending.items,inventory.items,true) then
                pending.equipment_attempts=(pending.equipment_attempts or 0)+1
                if pending.equipment_attempts>3 then return false,"Player 2's saved equipment could not be restored" end
                local commands=adapter:guest_equipment_commands(pending.items,inventory.items)
                if #commands>0 then adapter:command(commands) end
                request(adapter,pending,now)
                return "pending"
            end
            if not adapter.actor or not adapter.actor:IsValid() then return false,"Player 2's restored character was unloaded" end
            adapter.saved_area_status={actor=pending.actor,cell=guest.cell_ref,stacks=#pending.items,equipment_restored=true}
            adapter.saved_area=nil
            adapter.log("Player 2's saved area, inventory and equipment were restored")
            return true
        end
    end
    if now>=pending.next_query then request(adapter,pending,now) end
    return "pending"
end

return Restore
