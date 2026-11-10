local Arrival=require("lib.door_arrival")
local Fixtures=require("lib.door_fixtures")
local BackgroundCell=require("lib.background_cell")
local json=require("lib.json")
local Hotel,Sewer,Upstairs=Fixtures.hotel,Fixtures.sewers,Fixtures.upstairs
local Crossing={}
local plaza="/Game/Maps/World/L_ICTalosPlazaDistrict.L_ICTalosPlazaDistrict"
local dungeon="/Game/Maps/VerticalSlice/L_PersistentDungeon.L_PersistentDungeon"
local hotel_routes={
    [Hotel.entrance]={destination=Hotel.exit,operation=5,fixture=Hotel,prepare=true},
    [Hotel.exit]={destination=Hotel.entrance,operation=6,fixture=Hotel},
}
local upstairs_routes={
    [0x3ade6]={destination=0x3adeb,operation=9,fixture=Upstairs,prepare=true},
    [0x3adeb]={destination=0x3ade6,operation=10,fixture=Hotel,prepare=true},
    [0x3c3c1]={destination=0x3c7ef,operation=11,fixture=Upstairs,prepare=true},
    [0x3c7ef]={destination=0x3c3c1,operation=12,fixture=Hotel,prepare=true},
}

local function valid(object) return object and object:IsValid() end

local function read(method,ref,request)
    local raw=method(ref)
    local result=raw and json.decode(raw)
    if result and result.actor_ref==ref and result.request==request then return result end
end

local function query(adapter,pending,now,command)
    pending.request=pending.request+1
    pending.next_query=now+220
    local request=pending.request
    local commands={"player.LSSActorPosition "..request,pending.guest..".LSSActorPosition "..request,
        ("LSSDoor %d %d"):format(pending.source,request)}
    if command then table.insert(commands,1,command) end
    adapter:command(commands)
end

local function fixture_command(pending,operation)
    local cell=pending.route.fixture.cell
    if operation>=9 then cell=Upstairs.cell end
    return ("LSSPrepareCellFixture %d %d %d"):format(cell,operation,tonumber(pending.guest,16)-0x100000000)
end

function Crossing.begin(adapter,source)
    if not adapter.experimental_in_place_hotel then return end
    local world=BackgroundCell.capture_world(adapter)
    local stairs=adapter.experimental_upstairs and upstairs_routes[source]
    local route=world==plaza and (hotel_routes[source] or stairs) or world==dungeon and stairs
    if not route or not Fixtures.visible(Sewer) then return end
    if adapter.host_crossing or adapter.guest_crossing then return true end
    local now=adapter.native.clock_ms()
    local host=adapter:host().Pawn
    local pending={host=host:GetAddress(),guest=adapter.actor_ref,source=source,route=route,stage="checking",
        deadline=now+9500,request=740000000+now%100000000}
    adapter.host_crossing=pending
    query(adapter,pending,now)
    return true
end

function Crossing.cancel(adapter,reason)
    local pending=adapter.host_crossing
    if not pending then return end
    adapter.host_crossing=nil
    if pending.component then adapter.native.transform_hold(pending.component,false) end
    if reason then adapter.log("Player 1 door: "..reason) end
end

local function distance_squared(p,q)
    return (p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2
end

local function check_link(pending,data)
    local link=data.door
    return data.host_hotel_transfer and link and link.has_teleport and link.source_paired
        and link.source_cell and link.source_cell.attached and not link.has_lock_data
        and not link.has_script and not link.has_random_destination
        and link.destination_ref==pending.route.destination
end

local function hold(adapter,pending,host,link,now)
    local target=Fixtures.rendered_door(adapter,link.destination_ref)
    if not target then return Crossing.cancel(adapter,"The destination door did not appear") end
    local position,rotation=Arrival.resolve(link,target:K2_GetActorLocation(),target:K2_GetActorRotation(),
        host.CapsuleComponent:GetScaledCapsuleHalfHeight())
    if not position or distance_squared(position,adapter.actor:K2_GetActorLocation())<160^2 then
        return Crossing.cancel(adapter,"The landing point is unavailable")
    end
    local component=host.TransformPairingComponent
    if not valid(component) or not adapter.native.transform_hold(component:GetAddress(),true) then
        return Crossing.cancel(adapter,"The transform guard is unavailable")
    end
    pending.component=component:GetAddress()
    pending.position,pending.rotation,pending.link=position,rotation,link
    pending.stage,pending.next_step,pending.deadline="draining",now+200,now+1550
    local movement=host.PairedPawnMovementComponent
    movement:ResetOffsetMovementInput()
    movement:StopMovementImmediately()
    local controller=adapter:host()
    controller:AttackInput_Released()
    controller:BlockInput_Released()
    adapter.host_attack,adapter.host_block=false,false
end

function Crossing.poll(adapter,now)
    local pending=adapter.host_crossing
    if not pending then return end
    local controller=adapter:host()
    local host=valid(controller) and controller.Pawn
    if not valid(host) or host:GetAddress()~=pending.host or adapter.actor_ref~=pending.guest
        or not valid(adapter.actor) or not adapter:gameplay_input_enabled() then
        return Crossing.cancel(adapter,"Gameplay changed during the transfer")
    end
    if now>=pending.deadline then return Crossing.cancel(adapter,"Timed out at "..pending.stage) end
    local n=adapter.native
    if pending.stage=="draining" then
        if now<pending.next_step then return end
        pending.stage="moving"
        query(adapter,pending,now,fixture_command(pending,pending.route.operation))
        return
    end
    if pending.stage=="placed" then
        if now<pending.next_step then return end
        n.transform_hold(pending.component,false)
        pending.component=nil
        pending.stage,pending.deadline="settling",now+1000
        query(adapter,pending,now)
        return
    end
    local h=read(n.backend_actor_position,20,pending.request)
    local g=read(n.backend_actor_position,tonumber(pending.guest,16),pending.request)
    local data=read(n.backend_door,pending.source,pending.request)
    if not (h and g and data) then
        if now>=pending.next_query then query(adapter,pending,now) end
        return
    end
    if g.cell_ref~=Sewer.cell or not g.actor_paired or not g.cell.attached then
        return Crossing.cancel(adapter,"Player 2 is no longer in the attached sewer")
    end
    if pending.stage=="moving" then
        if not Arrival.matches_native(pending.link,h,90) then return Crossing.cancel(adapter,"Native arrival was rejected") end
        if distance_squared(host:K2_GetActorLocation(),pending.position)>120^2
            and not host:K2_TeleportTo(pending.position,pending.rotation) then
            return Crossing.cancel(adapter,"The rendered landing was blocked")
        end
        controller:SetControlRotation(pending.rotation)
        local p=host:K2_GetActorLocation()
        if distance_squared(p,pending.position)>140^2
            or not n.check_transform_landing(pending.component,p.X,p.Y,p.Z) then
            return Crossing.cancel(adapter,"The rendered landing could not be confirmed")
        end
        pending.stage,pending.next_step="placed",now+260
        return
    end
    if pending.stage=="settling" then
        if not Arrival.matches_native(pending.link,h,125) then return Crossing.cancel(adapter,"Arrival changed after placement") end
        adapter.dirty=true
        Crossing.cancel(adapter)
        adapter.log("Player 1 crossed the in-place hotel door")
        return
    end
    if not check_link(pending,data) then return Crossing.cancel(adapter,"The linked door is unavailable") end
    local link=data.door
    local origin=Arrival.origin_offset(link,h)
    if not origin or origin[1]^2+origin[2]^2+origin[3]^2>290^2 then
        return Crossing.cancel(adapter,"Player 1 moved away from the door")
    end
    local fixture=pending.route.fixture
    if link.destination_paired and link.target_cell and link.target_cell.attached and Fixtures.visible(fixture) then
        return hold(adapter,pending,host,link,now)
    end
    if not pending.route.prepare then return Crossing.cancel(adapter,"The destination is unavailable") end
    if not valid(pending.stream) then
        adapter.host_background_streams=adapter.host_background_streams or {}
        local streams=adapter.host_background_streams
        if not valid(streams[fixture.cell]) then
            streams[fixture.cell]=BackgroundCell.stream(host,fixture)
        end
        pending.stream=streams[fixture.cell]
        if not pending.stream then return Crossing.cancel(adapter,"Could not stream the destination") end
    elseif pending.stage=="checking" and pending.stream:IsLevelLoaded() and pending.stream:IsLevelVisible()
        and BackgroundCell.registered(fixture) then
        pending.stage="preparing"
        query(adapter,pending,now,fixture_command(pending,2))
        return
    elseif pending.stage=="preparing" and link.target_cell and link.target_cell.state==3 then
        pending.stage="attaching"
        query(adapter,pending,now,fixture_command(pending,3))
        return
    end
    if now>=pending.next_query then query(adapter,pending,now) end
end

return Crossing
