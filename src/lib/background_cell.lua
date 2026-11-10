local Fixtures=require("lib.door_fixtures")
local json=require("lib.json")
local Hotel,Sewer=Fixtures.hotel,Fixtures.sewers
local BackgroundCell={}

local function supported_host_cell(adapter,id)
    return id==Hotel.cell or id==114110 or id==114111
        or adapter.experimental_upstairs and id==Fixtures.upstairs.cell
end

function BackgroundCell.matches(adapter,host,guest)
    return adapter.experimental_background_sewer
        and supported_host_cell(adapter,host.cell_ref) and host.cell and host.cell.state==6
        and guest.cell_ref==Sewer.cell and guest.cell and guest.cell.state==0
        and not guest.actor_paired and not guest.actor_has_pairing_entry
end

local function level_name(fixture)
    return assert(fixture.level:match("^(.+)_LevelInstance$"))
end

local function package_for(cell)
    local tables=StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary")
    if not tables:IsValid() then return end
    local table_asset="/Game/Tools/MapImporter/ST_CellsToMapPath.ST_CellsToMapPath"
    local table_id=FName(table_asset)
    if not tables:IsRegisteredTableId(table_id) then LoadAsset(table_asset) end
    local key=("Oblivion.esm_%08x"):format(cell)
    if not tables:IsRegisteredTableEntry(table_id,key) then return end
    local source=tables:GetTableEntrySourceString(table_id,key)
    local package_name=type(source)=="string" and source or source:ToString()
    if package_name:match("^/Game/Maps/Interiors/[^:]+$") then return package_name end
end

function BackgroundCell.describe(cell,entrance,exit)
    local package_name=package_for(cell)
    if package_name then
        return {cell=cell,entrance=entrance,exit=exit,level=package_name:match("([^/]+)$").."_LevelInstance"}
    end
end

function BackgroundCell.stream(host,fixture)
    local package_name=package_for(fixture.cell)
    if not package_name or package_name:match("([^/]+)$")~=level_name(fixture) then return end
    local loader=StaticFindObject("/Script/Engine.Default__LevelStreamingDynamic")
    local stream=loader:LoadLevelInstance(host,package_name,{X=0,Y=0,Z=0},
        {Pitch=0,Yaw=0,Roll=0},{},fixture.level.."_LSS",StaticFindObject("/Script/Altar.VLevelStreaming"),false)
    if stream:IsValid() then return stream end
end

function BackgroundCell.begin(adapter,host_cell)
    local host=adapter:host().Pawn
    local stream=BackgroundCell.stream(host,Sewer)
    if stream then return {host=host:GetAddress(),host_cell=host_cell,stream=stream,stage="streaming"} end
end

function BackgroundCell.registered(fixture)
    local cell_name=level_name(fixture)
    for _,levels in ipairs(FindAllOf("VLevelChangeData") or {}) do
        if levels:IsValid() and not levels:GetFullName():find("Default__",1,true) then
            local present=false
            levels.AltarCellToPrePlacedActors:ForEach(function(key,value)
                if key:get():ToString()==cell_name then
                    local actors=value:get()
                    present=actors:IsValid() and #actors.PrePlacedPairableActors>0
                    return true
                end
            end)
            if present then return true end
        end
    end
end

function BackgroundCell.poll(adapter,pending,host,guest,door)
    if adapter:host().Pawn:GetAddress()~=pending.host or host.cell_ref~=pending.host_cell
        or not host.cell or host.cell.state~=6 or guest.cell_ref~=Sewer.cell or not guest.cell then
        return false,"The primary world changed during Player 2 area restoration"
    end
    local state=guest.cell.state
    if pending.stage=="resetting" then
        if state==3 and not guest.actor_paired and not guest.actor_has_pairing_entry then
            pending.stream=BackgroundCell.stream(adapter:host().Pawn,Sewer)
            if not pending.stream then return false,"Could not stream Player 2's sewer after travel" end
            pending.stage="streaming"
        end
        return "pending"
    end
    local stream=pending.stream
    if not stream:IsValid() then return false,"The saved sewer stream was removed" end
    if not stream:IsLevelLoaded() or not stream:IsLevelVisible() then return "pending" end
    if pending.stage=="streaming" and BackgroundCell.registered(Sewer) then
        if pending.warm and state==3 and guest.cell.paired and guest.cell.has_native_root then
            pending.stage="attaching"
            adapter:command(("LSSPrepareCellFixture %d %d"):format(Sewer.cell,pending.host_cell==Hotel.cell and 3 or 1))
        elseif not pending.warm and state==0 then
            pending.stage="preparing"
            adapter:command(("LSSPrepareCellFixture %d 2"):format(Sewer.cell))
        end
    elseif pending.stage=="preparing" and state==3 and guest.cell.paired and guest.cell.has_native_root then
        pending.stage="attaching"
        adapter:command(("LSSPrepareCellFixture %d 3"):format(Sewer.cell))
    elseif pending.stage=="attaching" and state==6 and guest.actor_paired and guest.actor_has_pairing_entry
        and door.source_paired and door.source_cell.attached then
        return true
    end
    return "pending"
end

local function primary_world(pawn)
    return pawn:GetFullName():match(" (/Game/[^:]+):PersistentLevel%.")
end

function BackgroundCell.capture_world(adapter)
    if adapter.experimental_background_sewer then return primary_world(adapter:host().Pawn) end
end

function BackgroundCell.warm_ticket(adapter,travel,host,guest,save_id)
    local current=BackgroundCell.capture_world(adapter)
    local linked_hotel=travel.link.destination_ref==Hotel.entrance or travel.link.destination_ref==Hotel.exit
    if not linked_hotel or not travel.primary_world or not current or current==travel.primary_world
        or not supported_host_cell(adapter,host.cell_ref) or guest.cell_ref~=Sewer.cell
        or not guest.cell or guest.cell.state~=6 or not guest.actor_paired or not guest.actor_has_pairing_entry then return end
    local now=adapter.native.clock_ms()
    return {host=adapter:host().Pawn:GetAddress(),host_cell=host.cell_ref,save_id=save_id,
        actor=travel.actor,warm=true,stage="stale",deadline=now+14000,request=940000000+now%100000000}
end

local function read(method,id,request)
    local raw=method(id)
    local data=raw and json.decode(raw)
    if data and data.request==request and data.actor_ref==id then return data end
end

function BackgroundCell.resume(adapter,now)
    local pending=adapter.guest_area_restore
    if not pending then return end
    if now>=pending.deadline or adapter:save_id()~=pending.save_id or adapter.actor_ref~=pending.actor then
        adapter.guest_area_restore=nil
        adapter.log("Player 2 area recovery expired at "..pending.stage)
        return
    end
    local n=adapter.native
    local guest_id=tonumber(pending.actor,16)
    local host=read(n.backend_actor_position,20,pending.request)
    local guest=read(n.backend_actor_position,guest_id,pending.request)
    local door=read(n.backend_door,Sewer.exit,pending.request)
    if host and guest and door and door.door then
        local result,reason
        if pending.stage=="stale" then
            local inventory=read(n.backend_inventory,guest_id,pending.request)
            if adapter:find_actor(pending.actor) then
                result=true
            elseif host.cell_ref~=pending.host_cell or adapter:host().Pawn:GetAddress()~=pending.host
                or guest.cell_ref~=Sewer.cell or not guest.cell or guest.cell.state~=6
                or not guest.actor_paired or not guest.actor_has_pairing_entry or Fixtures.visible(Sewer) then
                result,reason=false,"The old sewer pairing is no longer safe to clear"
            elseif inventory and inventory.items then
                adapter.parked_inventory=inventory
                pending.stage="resetting"
                adapter:command(("LSSPrepareCellFixture %d 4 %d"):format(Sewer.cell,guest_id-0x100000000))
            end
        else
            result,reason=BackgroundCell.poll(adapter,pending,host,guest,door.door)
        end
        if result==true or result==false then
            adapter.guest_area_restore=nil
            if reason then adapter.log(reason) end
            return
        end
    end
    if now>=(pending.next_query or 0) then
        pending.request=pending.request+1
        pending.next_query=now+250
        local key=pending.request
        local commands={"player.LSSActorPosition "..key,pending.actor..".LSSActorPosition "..key,
            "LSSDoor "..Sewer.exit.." "..key}
        if pending.stage=="stale" then commands[#commands+1]=pending.actor..".LSSInventory "..key end
        adapter:command(commands)
    end
end

return BackgroundCell
