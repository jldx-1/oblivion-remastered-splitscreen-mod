-- Use the existing game action states; animation notifies handle normal combat.
local Actions={}
local function valid(o) return o and o:IsValid() end
local function held_input(actor,state,key,name,held)
    if not held and not state[key] then return end
    local tag={TagName=FName(name)}
    if held then
        if not actor:HasGameplayTag(tag) then actor:AddGameplayTag(tag); state[key]=true end
    else
        actor:RemoveGameplayTag(tag,false); state[key]=nil
    end
end
local function block_input(actor,state,held) held_input(actor,state,"block_tag_added","Input.Action.Combat.Block",held) end
local function bow_input(actor,state,held) held_input(actor,state,"bow_tag_added","Input.Action.Combat.Bow.Draw",held) end
function Actions.request(actor,name)
    if not valid(actor) or actor:IsDeadFromKilled() or actor:IsUnconscious() then return false end
    local tag={TagName=FName("State.Character.Action."..name)}
    local machine=actor.StateMachineComponent
    if not valid(machine:GetStateFromTag(tag)) then return false end
    if actor.Role==3 then machine:SendStateChangeListToServer({tag})
    else machine:RegisterStateChange(tag) end
    return true
end
function Actions.draw(actor,drawn)
    if not valid(actor.WeaponsPairingComponent:GetEquippedWeaponForm()) then return false end
    if actor:IsWeaponDrawn()==drawn then return true end
    -- The normal DrawWeapon state's animation notify changes the drawn flag
    -- and attachment. Pre-setting it here would make that state sheath again.
    return Actions.request(actor,"DrawWeapon")
end
function Actions.update(actor,pad,state,now)
    local buttons=pad.buttons or 0
    if state.drawn==nil then state.drawn=actor:IsWeaponDrawn() end
    if (buttons & 32768)~=0 and ((state.buttons or 0)&32768)==0 then
        state.drawn=not state.drawn; Actions.draw(actor,state.drawn)
    end
    local action=actor.StateMachineComponent:GetActionState():ToString()
    -- A copied NPC can receive an automatic native sheath update after the
    -- draw animation. Retain the assigned player's intent once it finishes.
    if action=="Idle" and actor:IsWeaponDrawn()~=state.drawn then
        actor.WeaponsPairingComponent:SetWeaponDrawn(state.drawn)
        if state.drawn then actor:SwitchToCombatMoveset() else actor:SwitchToPassiveMoveset() end
    end
    local attack=(pad.rt or 0)>60
    local block=(pad.lt or 0)>60
    local form=attack and actor.WeaponsPairingComponent:GetEquippedWeaponForm() or nil
    local bow=valid(form) and form.Type==6 -- reflected EOblivionWeaponType::MARKSMAN_BOW
    bow_input(actor,state,attack and bow and actor:IsWeaponDrawn())
    if not attack and state.attack and action=="BowDraw" then
        local draw=actor.StateMachineComponent:GetStateFromTag({TagName=FName("State.Character.Action.BowDraw")})
        local ammo=actor.WeaponsPairingComponent:GetEquippedQuiverForm()
        if valid(draw) and draw:IsCurrentlyActive() and draw.bReadyToShoot and valid(ammo)
            and not actor.PairedPawnMovementComponent:IsSwimming() then
            if state.fire_bow then
                local duration=math.min(5,math.max(0,(now-state.attack_at)/1000))
                state.fire_bow(actor,duration,ammo)
                Actions.request(actor,"Idle")
            else
                actor:AddBufferedInputTagWithCustomTime({TagName=FName("Input.Action.Combat.Bow.Shoot")},0.25)
            end
        else
            Actions.request(actor,"Idle")
        end
    end
    -- Block's native entry condition requires the held input tag. The actor
    -- pairing flag alone can animate a pose without entering the block action.
    block_input(actor,state,block)
    if block~=(state.block==true) then
        actor:SendBlock(block)
        actor.OblivionActorStatePairingComponent.bIsBlocking=block
        actor:SetOblivionAnimAction(block and 7 or 0)
        Actions.request(actor,block and "Block" or "Idle")
    elseif block then
        actor:SendBlock(true)
        actor.OblivionActorStatePairingComponent.bIsBlocking=true
        actor:SetOblivionAnimAction(7)
        if action=="Idle" then Actions.request(actor,"Block") end
    end
    if attack and not state.attack then
        state.attack_at=now; state.power=false
        if not actor:IsWeaponDrawn() then state.drawn=true; Actions.draw(actor,true)
        else
            Actions.request(actor,bow and "BowDraw" or "LightAttack")
        end
    elseif attack and now-(state.attack_at or now)>500 and not state.power then
        if valid(form) and not bow and actor.StateMachineComponent:GetActionState():ToString()=="Idle" then
            state.power=Actions.request(actor,"PowerAttack")
        end
    end
    state.attack,state.block,state.buttons=attack,block,buttons
end
function Actions.release(actor,state)
    if not valid(actor) then return end
    if state then
        block_input(actor,state,false)
        bow_input(actor,state,false)
        if actor.StateMachineComponent:GetActionState():ToString()=="BowDraw" then Actions.request(actor,"Idle") end
    end
    if state and state.block then
        actor:SendBlock(false); actor.OblivionActorStatePairingComponent.bIsBlocking=false
        actor:SetOblivionAnimAction(0); Actions.request(actor,"Idle")
    end
    if state then state.attack=false; state.block=false; state.buttons=0 end
end
return Actions
