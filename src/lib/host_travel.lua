local Arrival=require("lib.door_arrival")
local Fixtures=require("lib.door_fixtures")
local BackgroundCell=require("lib.background_cell")
local Crossing=require("lib.host_crossing")
local json=require("lib.json")
local HostTravel={}

local function snapshot(read,ref,request)
    local raw=read(ref)
    local data=raw and json.decode(raw)
    if data and data.actor_ref==ref and data.request==request then return data end
end

function HostTravel.begin(adapter,address)
    if not adapter.experimental_door_travel or not adapter.actor_ref then return end
    if adapter.experimental_in_place_hotel then
        local ref=adapter:host_door_target()
        if Crossing.begin(adapter,ref) then return true end
    end
    if not address then return end
    if adapter.host_door then return true end
    adapter.host_travel=nil
    for _,door in ipairs(FindAllOf("VDoor") or {}) do
        if door:IsValid() and door:GetAddress()==address and door.TESRefComponent:IsValid() and door.TESRefComponent.bIsPaired then
            local ref=tonumber(door.TESRefComponent:GetHexFormRefID():ToString():gsub("^0[xX]",""),16)
            if not Fixtures.includes(ref) then return end
            local now=adapter.native.clock_ms()
            local request=920000000+now%100000000
            adapter.host_door={address=address,ref=ref,actor=adapter.actor_ref,request=request,deadline=now+350}
            adapter:command({("LSSDoor %d %d"):format(ref,request),adapter.actor_ref..".LSSActorPosition "..request})
            return true
        end
    end
end

function HostTravel.poll(adapter,now)
    local pending=adapter.host_door
    if not pending then return end
    if adapter.actor_ref~=pending.actor or adapter:host_activation_target_address()~=pending.address then
        adapter.host_door=nil
        return
    end
    local n=adapter.native
    local data=snapshot(n.backend_door,pending.ref,pending.request)
    local guest=snapshot(n.backend_actor_position,tonumber(pending.actor,16),pending.request)
    if not (data and guest) and now<pending.deadline then return end
    adapter.host_door=nil
    local link=data and data.door
    local fixture=link and Fixtures.match(pending.ref,link)
    if guest and link and link.has_teleport and link.source_paired and link.source_cell.attached
        and not link.has_lock_data and not link.has_script and not link.has_random_destination
        and link.destination_cell~=data.cell_ref and fixture then
        -- A stock exit may point to an exterior door whose cell is unloaded.
        -- Only the known interior-to-exterior fixture links supply that type.
        if not link.target_cell and pending.ref==fixture.exit and link.destination_cell==0 then
            link.target_cell={interior=false}
        end
        adapter.host_travel={link=link,guest_cell=guest.cell_ref,actor=pending.actor,expires=now+2500,
            primary_world=BackgroundCell.capture_world(adapter)}
    end
    adapter.activation=1
    adapter:host():ActivateInput_Pressed()
end

function HostTravel.take(adapter)
    local travel=adapter.host_travel
    adapter.host_travel=nil
    if travel and travel.actor==adapter.actor_ref and adapter.native.clock_ms()<travel.expires then return travel end
end

local function stop(adapter,transition,reason)
    transition.door=nil
    adapter.guest_unloaded=nil
    adapter.log("Player 2 loading-door autosave: "..reason)
    return true
end

local function retain(adapter,transition,travel,id)
    transition.save_id=id
    transition.guest_area_restore=BackgroundCell.warm_ticket(adapter,travel,travel.host_area,travel.guest_area,id)
end

function HostTravel.resume(adapter,now)
    local transition=adapter.transition
    local travel=transition and transition.door
    if not travel then return true end
    if not adapter:world_ready() then return false end
    local id=adapter:save_id()
    if id==transition.save_id then return true end
    if not travel.deadline then travel.deadline=now+6500 end
    local campaign=adapter:campaign()
    if campaign and campaign~=transition.campaign then return stop(adapter,transition,"campaign changed") end
    if now>=travel.deadline then
        return stop(adapter,transition,travel.verified and "autosave did not settle" or "native arrival was not confirmed")
    end
    if not id or not campaign then return false end
    if not travel.request then
        travel.save_id=id
        travel.request=930000000+now%100000000
    end
    if id~=travel.save_id then return stop(adapter,transition,"save changed again") end
    if not travel.verified then
        local read=adapter.native.backend_actor_position
        local host=snapshot(read,20,travel.request)
        local guest=snapshot(read,tonumber(transition.actor_ref,16),travel.request)
        if not host or not guest then
            if now>=(travel.next_query or 0) then
                travel.next_query=now+250
                adapter:command({"player.LSSActorPosition "..travel.request,transition.actor_ref..".LSSActorPosition "..travel.request})
            end
            return false
        end
        if guest.cell_ref~=travel.guest_cell or not Arrival.matches_native(travel.link,host,160) then
            return stop(adapter,transition,"actor locations did not match the door")
        end
        travel.verified,travel.host_area,travel.guest_area=true,host,guest
        adapter.log("Confirmed both native actors after Player 1's loading door")
    end
    if now<(travel.next_save or 0) then return false end
    travel.next_save=now+250
    local existing=adapter.store:read(transition.campaign,id)
    if existing then
        transition.door=nil
        if existing.player.actor_ref==transition.actor_ref then retain(adapter,transition,travel,id) end
        return true
    end
    if adapter.store:exists(transition.campaign,id) then return stop(adapter,transition,"save already has a record") end
    adapter.actor_ref,adapter.guest_race,adapter.guest_spell_id=transition.actor_ref,transition.race,transition.spell_id
    adapter.guest_unloaded=true
    if not adapter:poll_save(now,true) then return false end
    adapter.guest_unloaded=nil
    retain(adapter,transition,travel,id)
    transition.door=nil
    adapter.log("Player 2 retained across the verified loading-door autosave")
    return true
end

return HostTravel
