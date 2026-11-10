local Arrival=require("lib.door_arrival")
local Fixtures=require("lib.door_fixtures")
local json=require("lib.json")
local Travel={}

local function move(pending,target,offset)
    local guest=tonumber(pending.actor,16)-0x100000000
    if pending.sewer_transfer then
        local operation=target==Fixtures.sewers.entrance and 7 or 8
        return ("LSSPrepareCellFixture %d %d %d"):format(Fixtures.sewers.cell,operation,guest)
    end
    if pending.attached_transfer then
        local source=target==pending.source and pending.link.destination_ref or pending.source
        return ("LSSPrepareCellFixture %d 13 %d %d"):format(source,guest,target)
    end
    return ("%s.moveto %08X %.6f %.6f %.6f"):format(pending.actor,target,offset[1],offset[2],offset[3])
end
local function query(pending)
    return ("%s.LSSActorPosition %d"):format(pending.actor,pending.request)
end
local function clear_of_host(adapter,position)
    local host=adapter:host().Pawn
    local from=host:K2_GetActorLocation()
    local own,other=adapter.actor.CapsuleComponent,host.CapsuleComponent
    local height=own:GetScaledCapsuleHalfHeight()+other:GetScaledCapsuleHalfHeight()
    local radius=own:GetScaledCapsuleRadius()+other:GetScaledCapsuleRadius()+20
    return math.abs(position.Z-from.Z)>height or (position.X-from.X)^2+(position.Y-from.Y)^2>radius^2
end
local function release_hold(adapter,pending)
    if not pending.component then return end
    adapter.native.transform_hold(pending.component,false)
    pending.component=nil
end
local function finish(adapter,pending,reason)
    adapter.guest_crossing=nil
    local ok,err=pcall(function()
        if reason and pending.origin and (not pending.native_membership or pending.committed)
            and Fixtures.rendered_door(adapter,pending.source) then
            if pending.rendered then
                adapter.actor:K2_TeleportTo(pending.previous_position,pending.previous_rotation)
                adapter.yaw,adapter.pitch=pending.previous_yaw,pending.previous_pitch
                adapter:update_camera()
            end
            adapter:command(move(pending,pending.source,pending.origin))
        end
    end)
    release_hold(adapter,pending)
    if not ok then adapter.log("Player 2 door recovery failed "..tostring(err)) end
    adapter.log(reason or "Player 2 crossed the experimental loading door")
end

function Travel.cancel(adapter)
    local pending=adapter.guest_crossing
    if not pending then return end
    adapter.guest_crossing=nil
    release_hold(adapter,pending)
end

function Travel.begin(adapter,source,source_cell,link,guest_sewer_transfer,guest_attached_transfer)
    local fixture=Fixtures.match(source,link)
    local attached=guest_attached_transfer==true
    local sewer=not attached and fixture==Fixtures.sewers and guest_sewer_transfer==true
    if (not attached and not fixture) or (fixture and source==fixture.exit and source_cell~=fixture.cell) then return end
    local destination=Fixtures.rendered_door(adapter,link.destination_ref)
    if not destination then return end
    local half=adapter.actor.CapsuleComponent:GetScaledCapsuleHalfHeight()
    local position,rotation=Arrival.resolve(link,destination:K2_GetActorLocation(),destination:K2_GetActorRotation(),half)
    if not position or not clear_of_host(adapter,position) then return end
    local now=adapter.native.clock_ms()
    local pending={actor=adapter.actor_ref,source=source,source_cell=source_cell,link=link,
        position=position,rotation=rotation,request=800000000+now%100000000,deadline=now+650,
        sewer_transfer=sewer,attached_transfer=attached,native_membership=sewer or attached}
    adapter.guest_crossing=pending
    adapter:command(query(pending))
end

function Travel.poll(adapter,now)
    local pending=adapter.guest_crossing
    if not pending then return end
    if adapter.actor_ref~=pending.actor or not adapter.actor or not adapter.actor:IsValid()
        or not adapter.actor.TESRefComponent:IsValid() or not adapter.actor.TESRefComponent.bIsPaired then
        return Travel.cancel(adapter)
    end
    if now>=pending.deadline then return finish(adapter,pending,"Player 2 door position confirmation timed out") end
    if pending.check_at then
        if now<pending.check_at then return end
        pending.check_at=nil
        pending.request=pending.request+1
        pending.deadline=now+650
        if not pending.committed then
            pending.committed=true
            adapter:command({move(pending,pending.link.destination_ref,pending.link.arrival_offset),query(pending)})
        else
            adapter:command(query(pending))
        end
        return
    end
    local id=tonumber(pending.actor,16)
    local raw=adapter.native.backend_actor_position(id)
    local actor=raw and json.decode(raw)
    if not actor or actor.actor_ref~=id or actor.request~=pending.request then return end
    if not pending.origin then
        if adapter:guest_door_target()~=pending.source or not clear_of_host(adapter,pending.position)
            or ((actor.interior or pending.link.source_cell.interior or pending.sewer_transfer)
                and actor.cell_ref~=pending.source_cell) then
            return finish(adapter,pending,"Player 2 door approach changed")
        end
        local origin=Arrival.origin_offset(pending.link,actor)
        if not origin then return finish(adapter,pending,"Player 2 door origin could not be verified") end
        local movement=adapter.actor.PairedPawnMovementComponent
        movement:ResetOffsetMovementInput()
        movement:StopMovementImmediately()
        local previous_position=adapter.actor:K2_GetActorLocation()
        local previous_rotation=adapter.actor:K2_GetActorRotation()
        pending.previous_position={X=previous_position.X,Y=previous_position.Y,Z=previous_position.Z}
        pending.previous_rotation={Pitch=previous_rotation.Pitch,Yaw=previous_rotation.Yaw,Roll=previous_rotation.Roll}
        pending.previous_yaw,pending.previous_pitch=adapter.yaw,adapter.pitch
        local component=adapter.actor.TransformPairingComponent
        if not component:IsValid() or not adapter.native.transform_hold(component:GetAddress(),true) then
            return finish(adapter,pending,"Player 2 door transform guard is unavailable")
        end
        pending.component=component:GetAddress()
        pending.origin=origin
        -- Let already queued transforms drain before changing the native cell.
        pending.check_at=now+180
        pending.deadline=now+850
        return
    end
    if not pending.rendered then
        if not Arrival.matches_native(pending.link,actor) or not clear_of_host(adapter,pending.position)
            or not Fixtures.rendered_door(adapter,pending.link.destination_ref) or not adapter.actor:K2_TeleportTo(pending.position,pending.rotation) then
            return finish(adapter,pending,"Player 2 door arrival was blocked")
        end
        pending.rendered=true
        adapter.yaw,adapter.pitch=pending.rotation.Yaw,0
        adapter:update_camera()
        pending.check_at=now+220
        pending.deadline=now+850
        return
    end
    local rendered=adapter.actor:K2_GetActorLocation()
    local destination=pending.position
    local drift=(rendered.X-destination.X)^2+(rendered.Y-destination.Y)^2+(rendered.Z-destination.Z)^2
    -- Allow collision-aware placement to adjust the authored landing point.
    if Arrival.matches_native(pending.link,actor,90) and drift<140^2 then
        if pending.confirming then
            adapter.dirty=true
            return finish(adapter,pending)
        end
        if not adapter.native.check_transform_landing(pending.component,rendered.X,rendered.Y,rendered.Z) then
            return finish(adapter,pending,"Player 2 landing guard was unavailable")
        end
        pending.confirming=true
    elseif not pending.native_membership and pending.component and not pending.retried
        and Fixtures.rendered_door(adapter,pending.link.destination_ref) then
        pending.retried=true
        pending.committed=false
        pending.confirming=false
    else
        adapter.log("Rejected settled door position "..raw)
        return finish(adapter,pending,"Player 2 door position changed after rendering")
    end
    pending.check_at=now+240
    pending.deadline=now+850
end

return Travel
