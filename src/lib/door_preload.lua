local Fixtures=require("lib.door_fixtures")
local Movement=require("lib.preload_movement")
local json=require("lib.json")
local Preload={}

local function request(adapter,pending,now)
    pending.request=pending.request+1
    pending.next_query=now+200
    adapter:command(("LSSDoor %d %d"):format(pending.fixture.entrance,pending.request))
end

function Preload.begin(adapter,source,source_actor,link,background)
    local fixture=Fixtures.match(source,link)
    if not fixture and background and adapter.experimental_door_travel
        and link.target_cell and link.target_cell.interior then
        fixture=require("lib.background_cell").describe(link.destination_cell,source,link.destination_ref)
    end
    if not fixture or source~=fixture.entrance or not link.target_cell or link.target_cell.state~=0
        or adapter.experimental_door_preload then return end
    local save_id=adapter:save_id()
    if not save_id then return end
    local now=adapter.native.clock_ms()
    local point=source_actor:K2_GetActorLocation()
    local pending={actor=adapter.actor_ref,save_id=save_id,origin={X=point.X,Y=point.Y,Z=point.Z},
        request=430000000+now%100000000,deadline=now+14000,fixture=fixture}
    if background then
        local cells=require("lib.background_cell")
        pending.stream=cells.stream(adapter:host().Pawn,fixture)
        if not pending.stream then return end
        adapter.area_streams=adapter.area_streams or {}
        adapter.area_streams[fixture.cell]={fixture=fixture,stream=pending.stream}
    else
        pending.token={host=adapter:host().Pawn:GetAddress(),save_id=save_id,deadline=now+4000,
            movement=Movement.capture(adapter)}
        adapter.experimental_door_preload=pending.token
        adapter:command(("LSSPrepareCellFixture %d 0"):format(fixture.cell))
    end
    adapter.door_preload=pending
    adapter.door_preload_status=nil
    request(adapter,pending,now)
end

function Preload.stop(adapter,reason)
    local pending=adapter.door_preload
    if not pending then return end
    adapter.door_preload=nil
    if adapter.experimental_door_preload==pending.token then adapter.experimental_door_preload=nil end
    if reason then adapter.door_preload_status={result=reason}; adapter.log(reason) end
end

function Preload.cancel_crossing(adapter)
    if adapter.door_preload then adapter.door_preload.cancelled=true end
end

function Preload.poll(adapter,now)
    local pending=adapter.door_preload
    if not pending then return end
    if now>=pending.deadline then return Preload.stop(adapter,"Player 2 door preparation timed out") end
    if not adapter:world_ready() then return end
    local guest=adapter.actor
    if not guest or not guest:IsValid() or adapter.actor_ref~=pending.actor or adapter:save_id()~=pending.save_id then
        return Preload.stop(adapter,"Player 2 door preparation was interrupted")
    end
    local point=guest:K2_GetActorLocation()
    local origin=pending.origin
    if (point.X-origin.X)^2+(point.Y-origin.Y)^2+(point.Z-origin.Z)^2>350^2 then pending.cancelled=true end
    local fixture=pending.fixture
    local raw=adapter.native.backend_door(fixture.entrance)
    local state=raw and json.decode(raw)
    local door=state and state.actor_ref==fixture.entrance and state.request==pending.request and state.door
    local background=pending.stream~=nil
    if door and door.source_paired and door.source_cell.attached and door.destination_ref==fixture.exit
        and door.destination_cell==fixture.cell and not door.has_lock_data and not door.has_script
        and not door.has_random_destination and (background or pending.token.finished) then
        if background and not pending.preparing and door.target_cell.state==0
            and pending.stream:IsValid() and pending.stream:IsLevelVisible()
            and require("lib.background_cell").registered(fixture) then
            pending.preparing=true
            adapter:command(("LSSPrepareCellFixture %d 2"):format(fixture.cell))
            request(adapter,pending,now)
            return
        end
        if not pending.attaching and door.target_cell.state==3 and Fixtures.visible(fixture) then
            pending.attaching=true
            adapter:command(("LSSPrepareCellFixture %d %d"):format(fixture.cell,background and 3 or 1))
            request(adapter,pending,now)
            return
        end
        if door.destination_paired and door.target_cell.attached then
            local cross=not pending.cancelled and adapter:guest_door_target()==fixture.entrance
            local token=pending.token
            Preload.stop(adapter)
            adapter.door_preload_status={result=cross and "ready" or "cancelled"}
            if token then
                adapter.door_preload_status.duration=token.finished-token.started
                adapter.door_preload_status.host_settings=token.movement.host.restored
                adapter.door_preload_status.guest_settings=token.movement.guest.restored
            end
            if cross then
                require("lib.door_travel").begin(adapter,fixture.entrance,state.cell_ref,door,
                    state.guest_sewer_transfer,state.guest_attached_transfer)
            end
            return
        end
    end
    if now>=pending.next_query then request(adapter,pending,now) end
end

return Preload
