local PreloadMovement={}

local function capture(pawn)
    local movement=pawn.PairedPawnMovementComponent
    return {pawn=pawn:GetAddress(),movement=movement:GetAddress(),dilation=pawn.CustomTimeDilation,
        ticking=movement:IsComponentTickEnabled(),restored=0}
end

function PreloadMovement.capture(adapter)
    return {host=capture(adapter:host().Pawn),guest=capture(adapter.actor)}
end

local function keep(pawn,previous)
    if not pawn or not pawn:IsValid() or pawn:GetAddress()~=previous.pawn then return end
    local movement=pawn.PairedPawnMovementComponent
    if not movement or not movement:IsValid() or movement:GetAddress()~=previous.movement then return end
    if pawn.CustomTimeDilation==0 and previous.dilation>0 then
        pawn.CustomTimeDilation=previous.dilation
        previous.restored=previous.restored+1
    end
    if previous.ticking and not movement:IsComponentTickEnabled() then
        movement:SetComponentTickEnabled(true)
        previous.restored=previous.restored+1
    end
end

function PreloadMovement.keep(adapter,previous)
    local host=adapter:host()
    if host and host:IsValid() then keep(host.Pawn,previous.host) end
    keep(adapter.actor,previous.guest)
end

return PreloadMovement
