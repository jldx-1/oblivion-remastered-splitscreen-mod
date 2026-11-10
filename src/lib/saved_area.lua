local json=require("lib.json")
local Fixtures=require("lib.door_fixtures")
local BackgroundCell=require("lib.background_cell")
local Hotel=Fixtures.hotel
local SavedArea={}
local hotel,entrance=Hotel.cell,Hotel.entrance

local function snapshot(read,id,request)
    local raw=read(id)
    local data=raw and json.decode(raw)
    if data and data.actor_ref==id and data.request==request then return data end
end

local function matches_inventory(expected,items)
    if #expected~=#items then return false end
    for i,before in ipairs(expected) do
        local item=items[i]
        if before.form_id~=item.form_id or before.count~=item.count
            or before.equipped~=item.equipped or before.left~=item.left then return false end
    end
    return true
end

local function request(adapter,pending,now)
    pending.request=pending.request+1
    pending.next_query=now+250
    local key=pending.request
    if pending.phase=="origin" or pending.phase=="background" then
        local commands={"player.LSSActorPosition "..key,pending.actor..".LSSActorPosition "..key}
        if pending.phase=="origin" then
            commands[#commands+1]="LSSDoor "..entrance.." "..key
            commands[#commands+1]=pending.actor..".LSSInventory "..key
        end
        if adapter.experimental_background_sewer then
            commands[#commands+1]="LSSDoor "..Fixtures.sewers.exit.." "..key
        end
        adapter:command(commands)
    elseif pending.phase=="preparing" or pending.phase=="attaching" then
        adapter:command("LSSDoor "..entrance.." "..key)
    else
        adapter:command(pending.actor..".LSSInventory "..key)
    end
end

function SavedArea.begin(adapter,actor,save_id)
    if adapter.native.backend_protocol and adapter.native.backend_protocol()==2 then
        return require("lib.area_restore").begin(adapter,actor,save_id)
    end
    if not actor:match("^FF%x%x%x%x%x%x$") then return false,"The saved companion reference is unsupported" end
    local now=adapter.native.clock_ms()
    local pending={actor=actor,id=tonumber(actor,16),save_id=save_id,campaign=adapter.campaign_id,
        phase="origin",deadline=now+18000,request=550000000+now%100000000}
    adapter.saved_area=pending
    adapter.saved_area_status=nil
    request(adapter,pending,now)
    return "pending"
end

function SavedArea.cancel(adapter)
    local pending=adapter.saved_area
    if pending and adapter.experimental_door_preload==pending.preload then
        adapter.experimental_door_preload=nil
    end
    adapter.saved_area=nil
end

local function attach_view(adapter,pending,now)
    local guest=adapter:find_actor(pending.actor)
    if not guest or not guest:IsValid() then return end
    adapter.actor=guest
    adapter.transition=nil
    adapter:create_view()
    adapter:finish_join()
    pending.phase="recovering"
    request(adapter,pending,now)
    return "pending"
end

function SavedArea.poll(adapter)
    if adapter.saved_area.modern then return require("lib.area_restore").poll(adapter) end
    local n=adapter.native
    local pending=adapter.saved_area
    local now=n.clock_ms()
    local phase,key=pending.phase,pending.request
    if now>=pending.deadline then return false,"Saved Player 2 area restoration timed out at "..phase end
    if not adapter:world_ready() then return "pending" end
    if adapter:save_id()~=pending.save_id or adapter:campaign()~=pending.campaign then
        return false,"The save changed during Player 2 area restoration"
    end
    local door
    if phase=="origin" or phase=="preparing" or phase=="attaching" then
        local state=snapshot(n.backend_door,entrance,key)
        door=state and state.door
    end
    if phase=="origin" then
        local host=snapshot(n.backend_actor_position,20,key)
        local guest=snapshot(n.backend_actor_position,pending.id,key)
        local inventory=snapshot(n.backend_inventory,pending.id,key)
        if host and guest and inventory and inventory.items and BackgroundCell.matches(adapter,host,guest) then
            pending.background=BackgroundCell.begin(adapter,host.cell_ref)
            if not pending.background then return false,"Could not stream Player 2's saved sewer area" end
            pending.items,pending.cell,pending.phase=inventory.items,Fixtures.sewers.cell,"background"
            request(adapter,pending,now)
            return "pending"
        end
        if host and guest and door and inventory and inventory.items then
            if host.interior or (host.cell_ref~=114110 and host.cell_ref~=114111)
                or not guest.interior or guest.cell_ref~=hotel or door.destination_cell~=hotel
                or not door.source_paired or not door.source_cell.attached then
                return false,"The saved companion is outside the supported test area"
            end
            pending.items,pending.cell=inventory.items,hotel
            pending.phase="preparing"
            if door.target_cell.state==0 then
                pending.preload={host=adapter:host().Pawn:GetAddress(),save_id=pending.save_id,deadline=now+4000}
                adapter.experimental_door_preload=pending.preload
                adapter:command(("LSSPrepareCellFixture %d 0"):format(hotel))
            end
            request(adapter,pending,now)
            return "pending"
        end
    elseif phase=="preparing" then
        local preload=pending.preload
        if door and Fixtures.visible(Hotel) and (not preload or preload.finished) then
            if door.target_cell.state==3 then adapter:command(("LSSPrepareCellFixture %d 1"):format(hotel))
            elseif not door.target_cell.attached then return false,"The saved hotel could not be prepared" end
            pending.phase="attaching"
            request(adapter,pending,now)
            return "pending"
        end
    elseif phase=="attaching" then
        if door and door.source_paired and door.destination_paired and door.target_cell.attached then
            if attach_view(adapter,pending,now) then return "pending" end
        end
    elseif phase=="background" then
        local host=snapshot(n.backend_actor_position,20,key)
        local guest=snapshot(n.backend_actor_position,pending.id,key)
        local exit=snapshot(n.backend_door,Fixtures.sewers.exit,key)
        if host and guest and exit and exit.door then
            local result,reason=BackgroundCell.poll(adapter,pending.background,host,guest,exit.door)
            if result==false then return false,reason end
            if result==true and attach_view(adapter,pending,now) then
                return "pending"
            end
        end
    else
        local inventory=snapshot(n.backend_inventory,pending.id,key)
        if inventory and inventory.items then
            if not adapter.actor or not adapter.actor:IsValid() or adapter.actor_ref~=pending.actor
                or inventory.cell_ref~=pending.cell then return false,"The restored Player 2 reference or area changed" end
            if matches_inventory(pending.items,inventory.items) then
                adapter.saved_area_status={actor=pending.actor,cell=pending.cell,stacks=#inventory.items,equipment_restored=true}
                SavedArea.cancel(adapter)
                adapter.log("Player 2's saved area and equipment were restored")
                return true
            end
            if phase=="recovering" then
                local commands=adapter:guest_equipment_commands(pending.items,inventory.items)
                if #commands==0 then return false,"The saved Player 2 loadout could not be matched" end
                pending.phase="verifying"
                adapter:command(commands)
                request(adapter,pending,now)
                return "pending"
            end
        end
    end
    if now>=pending.next_query then request(adapter,pending,now) end
    return "pending"
end

return SavedArea
