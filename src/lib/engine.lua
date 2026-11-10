-- Remastered-specific runtime adapter. All object access runs on the game thread.
local Engine = {}
Engine.__index = Engine
local Actions=require("lib.actions")
local Races=require("lib.races")
local CloneInventory=require("lib.clone_inventory")
local FirstPerson=require("lib.native_first_person")
local HostBody=require("lib.host_body")
local HostTravel=require("lib.host_travel")
local HostCrossing=require("lib.host_crossing")
local BackgroundCell=require("lib.background_cell")
local DoorFixtures=require("lib.door_fixtures")
local Layout=require("lib.layout")
local json=require("lib.json")
local function valid(o) return o and o:IsValid() end
local function paired(pawn)
    if not valid(pawn) then return false end
    local ref=pawn.TESRefComponent
    return valid(ref) and ref.bIsPaired
end
local function str(value)
    if type(value)=="string" then return value end
    local ok,result=pcall(function() return value:ToString() end)
    return ok and result or tostring(value)
end
local function runtime(class,match)
    for _,o in ipairs(FindAllOf(class) or {}) do
        local name=o:GetFullName() or ""
        if not name:find("Default__",1,true) and (name:find(":PersistentLevel.",1,true) or name:find("/Engine/Transient.",1,true))
            and (not match or match(o)) then return o end
    end
end
local function guid(g)
    return string.format("%08X%08X%08X%08X",g.A & 0xffffffff,g.B & 0xffffffff,g.C & 0xffffffff,g.D & 0xffffffff)
end
local function token(value)
    local hash=0xcbf29ce484222325
    for i=1,#value do hash=(hash ~ value:byte(i))*0x100000001b3 end
    return string.format("%016x",hash)
end
function Engine.new(native,store,log)
    return setmetatable({native=native,store=store,log=log,host_controller_slot=0,pitch=-10,yaw=0,
        loading=false,layout=Layout.side_by_side},Engine)
end
function Engine:host()
    if not valid(self.host_pc) then
        local engine=runtime("GameEngine") or FindFirstOf("Engine")
        if valid(engine) and valid(engine.GameViewport) then
            local gs=StaticFindObject("/Script/Engine.Default__GameplayStatics")
            self.host_pc=gs:GetPlayerController(engine.GameViewport,0)
        end
    end
    return self.host_pc
end
function Engine:host_slot() return self.host_controller_slot end
function Engine:can_pair()
    if not valid(self:host()) then return false,"Waiting for game initialization" end
    return true
end
function Engine:world_ready()
    if not self:gameplay_input_enabled() then return false end
    local menu=runtime("VLegacyMainMenu")
    if valid(menu) and menu:IsVisible() then return false end
    return paired(self:host().Pawn)
end
function Engine:gameplay_input_enabled()
    local host=self:host()
    if self.loading or not valid(host) or not valid(host.Pawn) then return false end
    local gs=StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return host:IsInGameConfiguration() and not gs:IsGamePaused(host)
end
function Engine:set_system_fullscreen(fullscreen)
    if fullscreen==(self.system_fullscreen==true) or not valid(self.pc) then return end
    local host=self:host()
    if not valid(host) then return end
    StaticFindObject("/Script/Engine.Default__GameplayStatics"):SetForceDisableSplitscreen(host,fullscreen)
    self.system_fullscreen=fullscreen
end
function Engine:set_layout(layout)
    self.layout=layout
    if valid(self.pc) then
        StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings").TwoPlayerSplitscreenLayout=layout
    end
end
function Engine:has_inventory_backend()
    if not self.inventory_backend then
        local _,reason=self.native.backend_inventory(20)
        self.inventory_backend=reason~="Native inventory backend is not loaded"
    end
    return self.inventory_backend
end
local backend_op={LSSDoor="d",LSSPrepareCellFixture="h",LSSDialogue="t",LSSBlockDeathLoad="b",
    LSSActorPosition="p",LSSInventory="i"}
local function plugin_command(command)
    local name,args=command:match("^(LSS%a+)%s+(.+)$")
    local ref
    if not name then
        local target
        target,name,args=command:match("^(%w+)%.(LSS%a+)%s+(.+)$")
        ref=target=="player" and 20 or target and tonumber(target,16)
    end
    local op=backend_op[name]
    if not op then return command end
    if (op=="p" or op=="i") and not ref then return nil end
    local packet={"LSS2",op}
    if ref then packet[#packet+1]=("%u"):format(ref) end
    for arg in args:gmatch("%S+") do
        local value=math.tointeger(tonumber(arg))
        if not value or value < -0x80000000 or value > 0xffffffff then return nil end
        packet[#packet+1]=("%u"):format(value & 0xffffffff)
    end
    return 'GetINISetting "'..table.concat(packet,":")..'"'
end
function Engine:command(command)
    local host=assert(self:host())
    if not valid(host.CheatManager) then
        host.CheatManager=StaticConstructObject(StaticFindObject("/Script/Altar.AltarCheatManager"),host)
    end
    assert(valid(host.CheatManager),"Oblivion command bridge unavailable")
    local commands=type(command)=="table" and command or {command}
    if self.native.backend_protocol and self.native.backend_protocol()==2 then
        local translated={}
        for _,entry in ipairs(commands) do
            local item=plugin_command(entry)
            if item then translated[#translated+1]=item end
        end
        commands=translated
    end
    if #commands>0 then host.CheatManager:SendMultipleOblivionCommand(commands) end
end
function Engine:campaign()
    local identity=runtime("VAltarSaveIdentificationData")
    if valid(identity) then return guid(identity.CharacterId) end
    local vm=runtime("VSaveLoadMenuViewModel")
    if valid(vm) then return guid(vm:GetCurrentPlayerCharacterId()) end
    return nil
end
function Engine:save_id()
    local identity=runtime("VAltarSaveIdentificationData")
    if valid(identity) then
        local id=guid(identity.SaveID)
        if id~=string.rep("0",32) then return id end
    end
end
function Engine:find_actor(ref)
    for _,pawn in ipairs(FindAllOf("VPairedPawn") or {}) do
        if paired(pawn) then
            local id=str(pawn.TESRefComponent:GetHexFormRefID()):upper():gsub("^0X","")
            if id==ref then return pawn end
        end
    end
end
function Engine:create_view()
    local host=self:host()
    local gs=StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local maps=StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
    local mode=gs:GetGameMode(host)
    assert(valid(mode),"Game mode unavailable")
    local old_controller,old_pawn,old_hud=mode.PlayerControllerClass,mode.DefaultPawnClass,mode.HUDClass
    local original_host_pawn=host.Pawn
    local host_pawn=original_host_pawn:GetAddress()
    local ok,result=pcall(function()
        -- A generic Unreal controller avoids creating a second campaign player singleton.
        mode.PlayerControllerClass=StaticFindObject("/Script/Engine.PlayerController")
        mode.DefaultPawnClass=StaticFindObject("/Script/Engine.SpectatorPawn")
        mode.HUDClass=StaticFindObject("/Script/Engine.HUD")
        return gs:CreatePlayer(host,1,true)
    end)
    mode.PlayerControllerClass,mode.DefaultPawnClass,mode.HUDClass=old_controller,old_pawn,old_hud
    if not ok then error(result) end
    self.pc=result
    assert(valid(self.pc),"The game refused a second local view")
    if not valid(host.Pawn) or host.Pawn:GetAddress()~=host_pawn or (valid(self.pc.Pawn) and self.pc.Pawn:GetAddress()==host_pawn) then
        self.pc:UnPossess()
        host:Possess(original_host_pawn)
        error("Second view attempted to reuse the host character")
    end
    assert(self.pc:GetClass():GetFName():ToString()=="PlayerController","Unexpected second controller class")
    if valid(self.pc.Pawn) then
        local pawn=self.pc.Pawn
        self.pc:UnPossess()
        pawn:K2_DestroyActor()
    end
    self.pc:SetIgnoreMoveInput(true)
    self.pc:SetIgnoreLookInput(true)
    -- Let the guest camera request visible Unreal cells from its own position.
    self.pc.bEnableStreamingSource=true
    self.pc.bStreamingSourceShouldActivate=true
    self.pc.StreamingSourcePriority=host:GetStreamingSourcePriority()
    self.previous_split=maps.bUseSplitscreen
    self.previous_offset=maps.bOffsetPlayerGamepadIds
    self.previous_layout=maps.TwoPlayerSplitscreenLayout
    maps.bUseSplitscreen=true
    maps.bOffsetPlayerGamepadIds=false
    maps.TwoPlayerSplitscreenLayout=self.layout
    gs:SetForceDisableSplitscreen(host,false)
    return self.pc
end
function Engine:needs_character_setup()
    if valid(self.actor) or self.spawn_unresolved then return false end
    local campaign,save_id=self:campaign(),self:save_id()
    if not campaign or campaign==string.rep("0",32) then return false end
    local travel=self.transition
    if travel and travel.campaign==campaign and travel.save_id==save_id then return false end
    return not save_id or not self.store:exists(campaign,save_id)
end
function Engine:join(slot,race)
    assert(self:world_ready(),"Load a game before joining")
    assert(not valid(self.pc),"A second view already exists")
    if self.spawn_unresolved then return false,"Reload the test save before creating another copy" end
    self.slot=slot
    self.campaign_id=assert(self:campaign(),"Cannot identify this campaign for saving")
    assert(self.campaign_id~=string.rep("0",32),"Campaign identity is not ready")
    local save_id=self:save_id()
    local saved=nil
    if save_id then
        saved=self.store:read(self.campaign_id,save_id)
        if not saved and self.store:exists(self.campaign_id,save_id) then
            return false,"The saved companion record could not be recovered"
        end
    end
    self.loaded_record=saved
    if saved and saved.campaign~=self.campaign_id then saved=nil end
    local travel=self.transition
    local travelling=travel and travel.campaign==self.campaign_id and travel.save_id==save_id
        and (not saved or travel.actor_ref==saved.player.actor_ref)
    self.dirty=not saved or (travelling and self.dirty==true) or false
    local wanted_ref=(saved and saved.player.actor_ref) or (travelling and travel.actor_ref)
    self.actor=valid(self.actor) and self.actor or (wanted_ref and self:find_actor(wanted_ref))
    if saved then
        self.guest_race=saved.player.race
        self.guest_spell_id=saved.player.spell_id
    elseif travelling then
        self.guest_race=travel.race
        self.guest_spell_id=travel.spell_id
    elseif not valid(self.actor) then
        self.guest_race=race
        self.guest_spell_id=nil
    end
    if race and race~=self.guest_race then
        self.guest_race=race
        self.dirty=true
    end
    if wanted_ref and not valid(self.actor) then
        if travelling then
            -- Keep the native actor in its own cell. Rebind the same reference
            -- when the engine pairs it again.
            self.actor_ref,self.transition=wanted_ref,nil
            self.guest_unloaded=true
            self.guest_area_restore=travel.guest_area_restore
            self:begin_save_tracking()
            self.log("Player 2 kept in the original area while the host travelled.")
            return true
        end
        if saved and self.experimental_saved_area then
            return require("lib.saved_area").begin(self,wanted_ref,save_id)
        end
        return false,"The saved companion is not loaded. Return to the area where you saved."
    end
    self.transition=nil
    self:create_view()
    if valid(self.actor) then return self:finish_join() end
    self.before={}
    for _,pawn in ipairs(FindAllOf("VPairedPawn") or {}) do self.before[pawn:GetAddress()]=true end
    self.deadline=self.native.clock_ms()+8000
    -- The native full-copy operation creates a separate base and reference, including
    -- appearance, actor state and inventory. It is used only for the first join.
    self.spawn_unresolved=true
    self:command("player.createfullactorcopy")
    return "pending"
end
function Engine:change_guest_race(race)
    if not race or race==self.guest_race then return true end
    if not paired(self.actor) or self.guest_unloaded then return false,"Player 2's area is unavailable." end
    local ok,err=pcall(Races.apply,self.actor,race)
    if not ok then
        self.log("Cannot change Player 2 appearance: "..tostring(err))
        return false,"Appearance could not be applied."
    end
    self.guest_race,self.dirty=race,true
    return true
end
function Engine:poll_join()
    if self.saved_area then return require("lib.saved_area").poll(self) end
    if self.clone_inventory then return self:poll_clone_inventory() end
    for _,pawn in ipairs(FindAllOf("VPairedPawn") or {}) do
        if valid(pawn) and not self.before[pawn:GetAddress()] and valid(pawn.TESRefComponent) and pawn.TESRefComponent.bIsPaired then
            -- Full actor copies have a new dynamic base, unlike ordinary NPC spawns.
            local form=pawn.TESRefComponent.TESForm
            if valid(form) and (form:GetBPFormID() & 0xff000000)==0xff000000 then
                self.actor=pawn; self.created_here=true; self.spawn_unresolved=false
                return self:prepare_clone_inventory()
            end
        end
    end
    if self.native.clock_ms()>self.deadline then return false,"Companion creation did not produce a paired actor" end
    return "pending"
end
function Engine:prepare_clone_inventory()
    local ref=str(self.actor.TESRefComponent:GetHexFormRefID()):upper():gsub("^0X","")
    assert(ref:match("^FF%x%x%x%x%x%x$"),"Invalid copied actor reference")
    self.actor_ref=ref
    if not self:has_inventory_backend() then return self:finish_join() end
    local now=self.native.clock_ms()
    self.clone_inventory={request=now%1000000000,deadline=now+2500}
    self:command("player.LSSInventory "..self.clone_inventory.request)
    self:command(ref..".LSSInventory "..self.clone_inventory.request)
    return "pending"
end
function Engine:poll_clone_inventory()
    local stage=self.clone_inventory
    if self.native.clock_ms()>stage.deadline then
        self.clone_inventory=nil
        self.log("Could not verify temporary items in Player 2's first inventory")
        return self:finish_join()
    end
    local ref=tonumber(self.actor_ref,16)
    local raw=self.native.backend_inventory(ref)
    if not raw then return "pending" end
    local guest=json.decode(raw)
    if guest.actor_ref~=ref or guest.request~=stage.request then return "pending" end
    if not stage.replacements then
        local source=self.native.backend_inventory(20)
        if not source then return "pending" end
        local host=json.decode(source)
        if host.actor_ref~=20 or host.request~=stage.request then return "pending" end
        stage.replacements=CloneInventory.replacements(host,guest)
        if #stage.replacements==0 then
            self.clone_inventory=nil
            return self:finish_join()
        end
        local commands={}
        for _,item in ipairs(stage.replacements) do
            commands[#commands+1]=string.format("%s.additem %08X %d",self.actor_ref,item.stable,item.count)
        end
        stage.request=(stage.request+1)%1000000000
        commands[#commands+1]=self.actor_ref..".LSSInventory "..stage.request
        self:command(commands)
        return "pending"
    end
    local counts={}
    for _,item in ipairs(guest.items) do counts[item.form_id]=item.count end
    local commands={}
    for _,item in ipairs(stage.replacements) do
        if counts[item.stable]==item.expected and counts[item.temporary]==item.count then
            commands[#commands+1]=string.format("%s.removeitem %08X %d",self.actor_ref,item.temporary,item.count)
        end
    end
    if #commands>0 then self:host().CheatManager:SendMultipleOblivionCommand(commands) end
    self.log("Preserved "..#commands.." temporary item stacks using their stable native forms")
    self.clone_inventory=nil
    return self:finish_join()
end
function Engine:finish_join()
    self.host_actions={}
    self.guest_actions={fire_bow=function(actor,duration,ammo) self:fire_guest_bow(actor,duration,ammo) end}
    local ref=str(self.actor.TESRefComponent:GetHexFormRefID()):upper():gsub("^0X","")
    assert(ref:match("^%x%x%x%x%x%x%x%x$"),"Invalid persistent companion reference")
    self.actor_ref=ref
    self.guest_spellbook=nil
    self.next_guest_cast=nil
    if self.guest_race then Races.apply(self.actor,self.guest_race) end
    self:command(ref..".setrestrained 1")
    self:command(ref..".setav aggression 0")
    self.pc:Possess(self.actor)
    assert(self.pc.Pawn:GetAddress()==self.actor:GetAddress(),"Companion possession failed")
    if self.experimental_saved_area then
        self.guest_torch_controlled=self.native.control_guest_torch(tonumber(ref,16))
    end
    -- The paired state machine otherwise replaces local action states with
    -- incoming NPC idle updates. This Unreal flag leaves the native NPC type
    -- and persistent reference intact; restore it when local control ends.
    self.previous_player_flag=self.actor:IsPlayerCharacter()
    self.actor:SetIsPlayerCharacter(true)
    self.actor.PairedPawnMovementComponent:SetIsMovementLocked(false)
    local movement=self.actor.PairedPawnMovementComponent
    self.guest_rotation_policy={yaw=self.actor.bUseControllerRotationYaw,
        desired=movement.bUseControllerDesiredRotation}
    movement:SetUseControllerRotation(false)
    self.previous_melee_restriction=self.actor.bRestrictedMeleeTargeting
    self.actor.bRestrictedMeleeTargeting=false
    self:configure_local_animation()
    self.yaw=self:host().Pawn:K2_GetActorRotation().Yaw
    self.pitch=-10
    self:set_guest_pov(self.guest_pov or self:host().POV)
    local gs=StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation=self.actor:K2_GetActorLocation(),Scale3D={X=1,Y=1,Z=1}}
    local camera=gs:BeginDeferredActorSpawnFromClass(self:host(),StaticFindObject("/Script/Engine.CameraActor"),transform,2,self.pc,0)
    assert(valid(camera),"Cannot create the companion camera")
    self.camera=gs:FinishSpawningActor(camera,transform,0)
    self.camera:SetOwner(self.actor)
    self.camera.CameraComponent.bConstrainAspectRatio=false
    self.pc:SetViewTargetWithBlend(self.camera,0,0,0,false)
    self:start_host_routing()
    self:update_camera()
    self.log("Second character and camera created; native save verification still required")
    self:begin_save_tracking()
    return true
end
function Engine:guest_spell()
    for _,spell in ipairs(self.guest_spellbook or {}) do
        if spell.form_id==self.guest_spell_id then return spell end
    end
end
local function ignore_actor(ignore,actor)
    ignore[#ignore+1]=actor
    local attached={}
    actor:GetAttachedActors(attached,true,true)
    for _,entry in ipairs(attached) do
        local child=entry:get()
        if valid(child) then ignore[#ignore+1]=child end
    end
end
local function aimed_pawn(actor,start,direction,distance,other_player)
    local stop={
        X=start.X+distance*direction.X,
        Y=start.Y+distance*direction.Y,
        Z=start.Z+distance*direction.Z,
    }
    local ignore={}
    ignore_actor(ignore,actor)
    if valid(other_player) then ignore_actor(ignore,other_player) end
    local traces=StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local hit={}
    local color={R=0,G=0,B=0,A=0}
    if not traces:SphereTraceSingleForObjects(actor,start,stop,10,{2},false,ignore,0,hit,true,color,color,0) then return end
    local target=hit.HitObjectHandle.Actor:Get()
    if not valid(target) or not target:IsA(StaticFindObject("/Script/Altar.VPairedPawn")) then return end
    if not valid(target.TESRefComponent) or not target.TESRefComponent.bIsPaired then return end
    ignore[#ignore+1]=target
    if traces:LineTraceSingle(actor,start,hit.Location,0,false,ignore,0,{},true,color,color,0) then return end
    return target
end
function Engine:guest_aim(use_pawn_eye)
    local actor=self.actor
    local location=actor:K2_GetActorLocation()
    local yaw,pitch=math.rad(self.yaw),math.rad(self.pitch)
    -- Use the pawn's eye height. The animated head can dip below the
    -- capsule during running or transitions.
    local start={X=location.X,Y=location.Y,Z=location.Z+actor.BaseEyeHeight+12}
    local direction={X=math.cos(yaw)*math.cos(pitch),Y=math.sin(yaw)*math.cos(pitch),Z=math.sin(pitch)}
    if not use_pawn_eye and self.first_person_eye then start=self.first_person_eye end
    return start,direction
end
function Engine:guest_target(distance,other_player)
    local start,direction=self:guest_aim()
    local target=aimed_pawn(self.actor,start,direction,distance,other_player)
    if not valid(target) then return end
    local ref=str(target.TESRefComponent:GetHexFormRefID()):upper():gsub("^0X","")
    if ref:match("^%x%x%x%x%x%x%x%x$") and ref~=self.actor_ref then return ref,target end
end
function Engine:host_interaction_target()
    local pawn=self:host().Pawn
    return aimed_pawn(pawn,pawn:GetAimingStartPosition(),pawn:GetInteractionAimingDirectionVector(),350)
end
function Engine:host_activation_target_address()
    local pawn=self:host().Pawn
    if self.native.activation_target_address and pawn:IsA(StaticFindObject("/Script/Altar.VOblivionPlayerCharacter")) then
        return self.native.activation_target_address(pawn:GetAddress())
    end
end
function Engine:press_guest_activation(speaker)
    local host=self:host()
    host:ActivateInput_Pressed()
    if not self.loading then
        self.activation=2
        if speaker then self.guest_dialogue={deadline=self.native.clock_ms()+2000,speaker_ref=speaker} end
    end
    return true
end
function Engine:request_guest_activation(target,point,speaker)
    if self.activation or self.guest_dialogue or self.guest_interaction then return false end
    local cached=self:host_activation_target_address()
    if cached==target:GetAddress() then return self:press_guest_activation(speaker) end
    if cached==nil then return false end
    local host=self:host()
    local start=host.Pawn:GetAimingStartPosition()
    local x,y,z=point.X-start.X,point.Y-start.Y,point.Z-start.Z
    if x*x+y*y+z*z>350^2 then return false end
    local rotation=host:GetControlRotation()
    self.guest_interaction={host=host,target=target,speaker=speaker,deadline=self.native.clock_ms()+300,
        rotation={Yaw=rotation.Yaw,Pitch=rotation.Pitch,Roll=rotation.Roll}}
    host:SetControlRotation({Yaw=math.deg(math.atan(y,x)),Pitch=math.deg(math.atan(z,math.sqrt(x*x+y*y))),Roll=0})
    return true
end
function Engine:cancel_guest_interaction()
    local pending=self.guest_interaction
    self.guest_interaction=nil
    if pending and valid(pending.host) then pending.host:SetControlRotation(pending.rotation) end
end
function Engine:poll_guest_interaction()
    local pending=self.guest_interaction
    if not pending then return end
    if not valid(pending.target) or not self:gameplay_input_enabled() then return self:cancel_guest_interaction() end
    if self.native.clock_ms()>=pending.deadline then
        self:cancel_guest_interaction()
        self:guest_interaction_notice("The target did not respond.")
        return
    end
    if self:host_activation_target_address()~=pending.target:GetAddress() then return end
    self.guest_interaction=nil
    self:press_guest_activation(pending.speaker)
    if not self.loading and valid(pending.host) then pending.host:SetControlRotation(pending.rotation) end
end

local pickup_forms={"TESObjectMISC","TESObjectWEAP","TESObjectARMO","TESObjectCLOT",
    "TESAmmo","TESIngredientItem","TESAlchemyItem","TESObjectAPPA","TESKey"}

function Engine:guest_interaction_target()
    local start,direction=self:guest_aim()
    local stop={X=start.X+350*direction.X,Y=start.Y+350*direction.Y,Z=start.Z+350*direction.Z}
    local host=self:host()
    local ignore={}
    ignore_actor(ignore,self.actor)
    ignore_actor(ignore,host.Pawn)
    local trace=StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local hit,color={},{R=0,G=0,B=0,A=0}
    if trace:LineTraceSingle(self.actor,start,stop,0,false,ignore,0,hit,true,color,color,0) then
        local object=hit.HitObjectHandle and hit.HitObjectHandle.Actor:Get()
        if valid(object) and object:IsA(StaticFindObject("/Script/Altar.VDoor")) then
            local ref=DoorFixtures.door_reference(self,object)
            if ref and ref~=0 and not object.bIsDestroyed then return {actor=object,kind="door",ref=ref} end
            return
        end
        if valid(object) and object:IsA(StaticFindObject("/Script/Altar.VActor"))
            and not object:IsA(StaticFindObject("/Script/Altar.VPairedPawn")) then
            local component=object.TESRefComponent
            if valid(component) and component.bIsPaired then
                local form=component.TESForm
                if valid(form) then
                    for _,name in ipairs(pickup_forms) do
                        local class=StaticFindObject("/Script/Altar."..name)
                        if valid(class) and form:IsA(class) then
                            local ref=str(component:GetHexFormRefID()):upper():gsub("^0X","")
                            if ref:match("^%x%x%x%x%x%x%x%x$") and ref~="00000000" then
                                return {actor=object,kind="pickup",ref=ref}
                            end
                            break
                        end
                    end
                end
                return {actor=object,kind="object",point=hit.Location}
            end
        end
    end
    local ref,speaker=self:guest_target(350,host.Pawn)
    if valid(speaker) and speaker:IsA(StaticFindObject("/Script/Altar.VPairedCharacter"))
        and not speaker:IsDead() and not speaker:IsUnconscious() then
        local p=speaker:K2_GetActorLocation()
        return {actor=speaker,kind="npc",ref=tonumber(ref,16),point={X=p.X,Y=p.Y,Z=p.Z+50}}
    end
end

function Engine:guest_interaction_notice(message)
    self.interaction_notice=message
    self.interaction_notice_until=self.native.clock_ms()+2400
end

function Engine:interact_guest()
    if self.activation or self.guest_dialogue or self.guest_door or self.door_preload then return end
    local target=self:guest_interaction_target()
    if not target then return end
    self.interaction_notice=nil
    if target.kind=="door" then
        self:begin_guest_door(target.ref)
    elseif target.kind=="pickup" then
        self:command(("%s.activate %s 1"):format(target.ref,self.actor_ref))
        self.dirty=true
    elseif target.kind=="npc" and self.dialogues and self.dialogues:start(2,target.actor) then
        return
    elseif not self:request_guest_activation(target.actor,target.point,target.ref) then
        self:guest_interaction_notice("This target cannot be activated from Player 2’s view.")
    end
end
function Engine:has_guest_dialogue()
    if self.experimental_dialogue then return true end
    if self.guest_dialogue_available~=nil then return self.guest_dialogue_available end
    local now=self.native.clock_ms()
    if not self.guest_dialogue_capability then
        local _,reason=self.native.backend_dialogue(0)
        if reason=="Native dialogue backend is not loaded" then
            self.guest_dialogue_available=false
            return false
        end
        self.guest_dialogue_capability={request=2000000000+now%100000000,deadline=now+2000}
        self:command("LSSDialogue "..self.guest_dialogue_capability.request)
        return false
    end
    local capability=self.guest_dialogue_capability
    local raw=self.native.backend_dialogue(capability.request)
    if raw then
        local reply=json.decode(raw)
        self.guest_dialogue_available=reply.request==capability.request and reply.guest_read_only==true
    elseif now>=capability.deadline then self.guest_dialogue_available=false end
    return self.guest_dialogue_available
end
local function aimed_door(adapter,pawn,other,start,direction)
    local stop={X=start.X+350*direction.X,Y=start.Y+350*direction.Y,Z=start.Z+350*direction.Z}
    local ignore={}
    ignore_actor(ignore,pawn)
    ignore_actor(ignore,other)
    local traces=StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local color={R=0,G=0,B=0,A=0}
    local hit={}
    if not traces:LineTraceSingle(pawn,start,stop,0,false,ignore,0,hit,true,color,color,0) then return end
    local door=hit.HitObjectHandle.Actor:Get()
    if not valid(door) or not door:IsA(StaticFindObject("/Script/Altar.VDoor")) then return end
    local ref=DoorFixtures.door_reference(adapter,door)
    if ref and ref~=0 then return ref,door end
end
function Engine:guest_door_target()
    local start,direction=self:guest_aim()
    return aimed_door(self,self.actor,self:host().Pawn,start,direction)
end
function Engine:host_door_target()
    local pawn=self:host().Pawn
    return aimed_door(self,pawn,self.actor,pawn:GetAimingStartPosition(),pawn:GetInteractionAimingDirectionVector())
end
function Engine:begin_guest_door(ref)
    if self.guest_door or self.door_preload or self.guest_crossing or not self.native.backend_door then return end
    ref=ref or self:guest_door_target()
    if not ref then return end
    local _,reason=self.native.backend_door(ref)
    if reason=="Native door backend is not loaded" then
        return self:guest_interaction_notice("Launch through the split-screen OBSE64 backend to use supported doors.")
    end
    local now=self.native.clock_ms()
    local request=1000000000+now%1000000000
    self.guest_door={ref=ref,request=request,deadline=now+500}
    self:command(("LSSDoor %d %d"):format(ref,request))
end
function Engine:poll_guest_door()
    local pending=self.guest_door
    if not pending then return end
    if self.native.clock_ms()>=pending.deadline then
        self.guest_door=nil
        return self:guest_interaction_notice("The door did not respond.")
    end
    local raw=self.native.backend_door(pending.ref)
    local snapshot=raw and json.decode(raw)
    if not snapshot or snapshot.request~=pending.request or snapshot.actor_ref~=pending.ref then return end
    self.guest_door=nil
    local target,source_actor=self:guest_door_target()
    if target~=pending.ref then return end
    local door=snapshot.door
    if door and door.source_paired and not door.has_teleport and not door.has_random_destination then
        if not self:request_guest_activation(source_actor,source_actor:K2_GetActorLocation()) then
            self:guest_interaction_notice("This door cannot be activated from Player 2’s view.")
        end
        return
    end
    if not door or not door.has_teleport or not door.source_paired
        or door.has_lock_data or door.has_script or door.has_random_destination
        or snapshot.cell_ref==0
        or not door.source_cell or not door.source_cell.attached or not door.target_cell
        or not door.arrival_offset or not door.destination_ref or door.destination_ref==0 then
        return self:guest_interaction_notice("Player 2 cannot travel through this door.")
    end
    if door.destination_cell~=snapshot.cell_ref then
        local hotel=snapshot.guest_hotel_travel and DoorFixtures.match(pending.ref,door)==DoorFixtures.hotel
        if hotel then self.hotel_guest_travel=true end
        if self.experimental_door_travel or hotel then
            if door.destination_paired and door.target_cell.attached then
                require("lib.door_travel").begin(self,pending.ref,snapshot.cell_ref,door,
                    snapshot.guest_sewer_transfer,not hotel and snapshot.guest_attached_transfer)
            else
                require("lib.door_preload").begin(self,pending.ref,source_actor,door,hotel)
            end
        end
        if not self.guest_crossing and not self.door_preload then
            self:guest_interaction_notice("This destination is unavailable for independent travel.")
        end
        return
    end
    if not door.destination_paired or not door.target_cell.attached then
        return self:guest_interaction_notice("The destination is not loaded.")
    end
    local offset=door.arrival_offset
    self:command(("%s.moveto %08X %.6f %.6f %.6f"):format(self.actor_ref,door.destination_ref,offset[1],offset[2],offset[3]))
    self.dirty=true
end
function Engine:cast_guest_spell()
    local spell=self:guest_spell()
    if not spell or self.actor:IsDeadFromKilled() or self.actor:IsUnconscious() then return end
    local now=self.native.clock_ms()
    if self.next_guest_cast and now<self.next_guest_cast then return end
    local target=self.actor_ref
    if spell.range~=0 then target=self:guest_target(spell.range==1 and 200 or 3500) end
    if not target then return end
    self.next_guest_cast=now+850
    self:command(string.format("%s.cast %08X %s",self.actor_ref,spell.form_id,target))
    self.dirty=true
end
function Engine:open_shared_journal(player)
    if self.journal_release then return end
    self:host():OpenQuestMenuInput_Pressed()
    local now=self.native.clock_ms()
    self.journal_release=now+150
    self.journal={player=player,deadline=now+5000,next_scan=now}
end
function Engine:reset_shared_journal()
    local journal=self.journal
    self.journal=nil
    if journal and journal.scale and valid(journal.widget) then
        journal.widget:SetRenderScale(journal.scale)
    end
end
function Engine:poll_shared_journal(now)
    if self.journal_release and now>=self.journal_release then
        self.journal_release=nil
        local host=self:host()
        if not self.loading and valid(host) then host:OpenQuestMenuInput_Released() end
    end
    local journal=self.journal
    if not journal then return end
    if journal.widget then
        if not valid(journal.widget) or not journal.widget:IsActivated() then self:reset_shared_journal() end
        return
    end
    if now>=journal.deadline then self:reset_shared_journal(); return end
    if now<journal.next_scan or self:gameplay_input_enabled() then return end
    journal.next_scan=now+100
    local widget=runtime("WBP_Modern_MapQuestMenu_C",function(o) return o:IsActivated() end)
    if not valid(widget) then return end
    local vm=widget.VMapMenuViewModel
    if not valid(vm) or vm.CurrentPage~=3 then return end
    journal.widget,journal.vm=widget,vm
    local scale=widget.RenderTransform.Scale
    journal.scale={X=scale.X,Y=scale.Y}
    -- The native journal retains its full-width book layout in Player 1's half.
    widget:SetRenderScale({X=scale.X*0.5,Y=scale.Y*0.5})
end
function Engine:input_shared_journal(player,buttons,previous)
    local journal=self.journal
    if not journal or journal.player~=player or not valid(journal.widget) or not valid(journal.vm) then return end
    if journal.neutral then
        if buttons==0 then journal.neutral=false end
        return
    end
    local pressed=buttons & ~previous
    if pressed & (1 | 2 | 4096 | 8192 | 16384)==0 or journal.vm.CurrentPage~=3 then return end
    local page=journal.widget.QuestPage
    if not valid(page) then return end
    local state={}
    page:IsOnQuestListPage(state)
    if pressed & 8192~=0 then
        if state.IsOnQuestListPage then
            local menu=runtime("VPlayerMenuViewModel")
            if valid(menu) then
                self.guest_modal_closing=true
                menu:RegisterCloseMenuHandler()
            end
        else
            page:OnBackFromHistoric()
        end
        return
    end
    if not state.IsOnQuestListPage then return end
    if pressed & 16384~=0 then page:OnRequestQuestDetail(); return end
    local panel=page.QuestListPanel
    if not valid(panel) or not valid(panel.QuestListView) then return end
    local list=panel.QuestListView:GetListView()
    if not valid(list) then return end
    local count=list:GetNumItems()
    if count==0 then return end
    local selected=list:BP_GetSelectedItem()
    local index=valid(selected) and list:GetIndexForItem(selected) or -1
    local direction=pressed & 1~=0 and -1 or 1
    if index<0 and direction<0 then index=0 end
    local confirm=pressed & 4096~=0
    if confirm and valid(selected) and selected:GetQuestId()>=0 then
        panel:BndEvt__WBP_Modern_QuestListPanel_QuestListView_K2Node_ComponentBoundEvent_3_OnItemClicked__DelegateSignature(selected)
        return
    end
    for _=1,count do
        index=(index+direction)%count
        local item=list:GetItemAt(index)
        if valid(item) and item:GetQuestId()>=0 then
            list:SetSelectedIndex(index)
            list:ScrollIndexIntoView(index)
            panel:BndEvt__WBP_Modern_QuestListPanel_QuestListView_K2Node_ComponentBoundEvent_0_OnItemHovered__DelegateSignature(item)
            if confirm then
                panel:BndEvt__WBP_Modern_QuestListPanel_QuestListView_K2Node_ComponentBoundEvent_3_OnItemClicked__DelegateSignature(item)
            end
            return
        end
    end
end
function Engine:input_shared_dialogue(pressed)
    local dialogue=self.guest_dialogue
    if not dialogue then return end
    local menu=dialogue.menu
    if menu then
        if not valid(menu) or not menu:IsActivated() or not menu:IsVisible() then
            self.guest_dialogue=nil
            return
        end
    else
        local now=self.native.clock_ms()
        if now>=dialogue.deadline then self.guest_dialogue=nil; return end
        menu=runtime("WBP_ModernMenu_Dialog_C",function(o) return o:IsActivated() and o:IsVisible() end)
        if not valid(menu) then return end
        if self.native.backend_dialogue and dialogue.speaker_ref then
            local raw,reason=self.native.backend_dialogue(dialogue.request or 0)
            if reason~="Native dialogue backend is not loaded" then
                dialogue.pending_buttons=(dialogue.pending_buttons or 0) | (pressed & (1 | 2 | 4096 | 8192))
                if not dialogue.request then
                    if not dialogue.next_request or now>=dialogue.next_request then
                        dialogue.request=1000000000+now%1000000000
                        self:command("LSSDialogue "..dialogue.request)
                    end
                    return
                end
                if not raw then return end
                local snapshot=json.decode(raw)
                if snapshot.speaker_ref==0 then
                    -- The Unreal widget can be visible while the native menu
                    -- is still opening. Wait for the actual speaker identity.
                    dialogue.request,dialogue.next_request=nil,now+100
                    return
                end
                if snapshot.speaker_ref~=dialogue.speaker_ref then
                    self.guest_dialogue=nil
                    return
                end
            end
        end
        dialogue.menu=menu
    end
    if menu.IsUpdating then return end
    pressed=pressed | (dialogue.pending_buttons or 0)
    dialogue.pending_buttons=nil
    if pressed & (1 | 2 | 4096 | 8192)==0 then return end
    local vm=menu.VDialogueMenuViewModel
    if not valid(vm) then return end
    if pressed & 8192~=0 then
        if vm.ButtonsVisibility.bGoodbye then
            self.guest_modal_closing=true
            vm:RegisterSendClickedCloseIcon()
        end
        return
    end
    if pressed & 4096~=0 and valid(menu.dialog_skip_button) and menu.dialog_skip_button:IsVisible() then
        vm:RegisterSendClickedSkip()
        return
    end
    local list=menu.dialog_scrollbox
    if not valid(list) or not list:IsVisible() or list:GetSize()==0 then return end
    if pressed & 1~=0 then list:NavigateToPrevElement()
    elseif pressed & 2~=0 then list:NavigateToNextElement()
    else
        local index=list:GetFocusElementIndex()
        if index>=0 and index<#vm.Responses then vm:RegisterSendClickedResponse(index) end
    end
end
function Engine:release_activation(player)
    if self.activation==player then
        self.activation=nil
        local host=self:host()
        if not self.loading and valid(host) and valid(host.Pawn) then host:ActivateInput_Released() end
    end
end
function Engine:fire_guest_bow(actor,duration,ammo)
    if not valid(self.actor) or actor:GetAddress()~=self.actor:GetAddress() then return end
    local id=ammo:GetBPFormID()
    if math.type(id)~="integer" or id<=0 or id>0xffffffff then return end
    local weapon=actor.WeaponsPairingComponent:GetEquippedWeaponForm()
    if not valid(weapon) or weapon.Type~=6 then return end
    local bow=weapon:GetBPFormID()
    -- The native NPC shot spawns a real arrow but leaves its ammunition stack
    -- unchanged. Spend one arrow on this reference. Its native equipment
    -- update can clear the quiver after the command, so reselect it after
    -- the removal settles, while this player still owns the same bow.
    actor:SendBowAttack(duration,false)
    local ref=self.actor_ref
    self:host().CheatManager:SendMultipleOblivionCommand({
        string.format("%s.removeitem %08X 1",ref,id),
        string.format("%s.equipitem %08X",ref,bow),
    })
    self.pending_quiver={ref=ref,bow=bow,ammo=id,at=self.native.clock_ms()+650}
    self.dirty=true
end
function Engine:restore_guest_quiver()
    local pending=self.pending_quiver
    if not pending or self.native.clock_ms()<pending.at then return end
    self.pending_quiver=nil
    if self.actor_ref~=pending.ref or not valid(self.actor) then return end
    local pairing=self.actor.WeaponsPairingComponent
    local weapon=pairing:GetEquippedWeaponForm()
    if valid(weapon) and weapon:GetBPFormID()==pending.bow and not valid(pairing:GetEquippedQuiverForm()) then
        self:command(string.format("%s.equipitem %08X",pending.ref,pending.ammo))
    end
end
function Engine:configure_local_animation()
    self.animation_policies=self.animation_policies or {}
    for _,actor in ipairs({self:host().Pawn,self.actor}) do
        local mesh=actor.MainSkeletalMeshComponent
        if valid(mesh) then
            local known=false
            for _,record in ipairs(self.animation_policies) do
                if valid(record.mesh) and record.mesh:GetAddress()==mesh:GetAddress() then known=true; break end
            end
            if not known then
                self.animation_policies[#self.animation_policies+1]={mesh=mesh,visibility=mesh.VisibilityBasedAnimTickOption,optimized=mesh.bEnableUpdateRateOptimizations}
            end
            mesh.VisibilityBasedAnimTickOption=0 -- AlwaysTickPoseAndRefreshBones
            mesh.bEnableUpdateRateOptimizations=false
        end
    end
end
function Engine:begin_save_tracking()
    self.tracked_save_id=self:save_id()
    self.save_snapshots={}
    self.pending_save=nil
    for _,save in ipairs(FindAllOf("VAltarSaveGame") or {}) do
        if valid(save) and not save:GetFullName():find("Default__",1,true) then
            local details=save.SaveGameDetails
            self.save_snapshots[str(details.SlotName).."|"..str(details.SaveHash)]=true
        end
    end
end
function Engine:poll_save(now,autosave_only)
    if self.loading or not self.actor_ref or (not valid(self.actor) and not self.guest_unloaded) then return end
    local id=self:save_id()
    if not id or id==self.tracked_save_id then return end
    local directory=self.save_directory or ((os.getenv("USERPROFILE") or "").."/Documents/My Games/Oblivion Remastered/Saved/SaveGames/")
    for _,save in ipairs(FindAllOf("VAltarSaveGame") or {}) do
        if valid(save) and not save:GetFullName():find("Default__",1,true) then
            local details=save.SaveGameDetails
            local slot,hash=str(details.SlotName),str(details.SaveHash)
            local snapshot=slot.."|"..hash
            if (not autosave_only or slot:lower():match("^autosave %d+ %- "))
                and guid(details.CharacterId)==self.campaign_id and not self.save_snapshots[snapshot] and #save.OblivionData>0 then
                -- Open only an exact native slot name and wait for a stable, closed file.
                if not slot:find("[/\\]") and not slot:find("..",1,true) then
                    local file=io.open(directory..slot..".sav","rb")
                    local length=file and file:seek("end")
                    if file then file:close() end
                    if length and length>0 then
                        local pending=self.pending_save
                        if pending and pending.snapshot==snapshot and pending.id==id and pending.length==length then
                            if now-pending.since>=2000 then
                                self:on_save(save)
                                self.save_snapshots[snapshot]=true
                                self.tracked_save_id=id
                                self.pending_save=nil
                                return true
                            end
                        else self.pending_save={snapshot=snapshot,id=id,length=length,since=now} end
                    end
                end
            end
        end
    end
end
local function clip_to_other_player(start,finish,pawn)
    local capsule=pawn.CapsuleComponent
    if not valid(capsule) then return end
    local center=pawn:K2_GetActorLocation()
    -- The game's camera collision channel can ignore another pawn. Treat its
    -- padded capsule as an obstruction so armour cannot fill the guest pane.
    local radius=capsule:GetScaledCapsuleRadius()+35
    local height=capsule:GetScaledCapsuleHalfHeight()+24
    local dx,dy,dz=finish.X-start.X,finish.Y-start.Y,finish.Z-start.Z
    local x,y,z=start.X-center.X,start.Y-center.Y,start.Z-center.Z
    local low,high=0,1
    if math.abs(dz)<0.001 then
        if math.abs(z)>height then return end
    else
        local a,b=(-height-z)/dz,(height-z)/dz
        low,high=math.max(low,math.min(a,b)),math.min(high,math.max(a,b))
    end
    local a,b,c=dx*dx+dy*dy,2*(x*dx+y*dy),x*x+y*y-radius*radius
    if a<0.001 then
        if c>0 then return end
    else
        local disc=b*b-4*a*c
        if disc<0 then return end
        local root=math.sqrt(disc)
        low,high=math.max(low,(-b-root)/(2*a)),math.min(high,(-b+root)/(2*a))
    end
    if low>high then return end
    local t=math.max(0,low-0.02)
    return {X=start.X+t*dx,Y=start.Y+t*dy,Z=start.Z+t*dz}
end
function Engine:restore_guest_npc_animation(keep)
    for address,record in pairs(self.guest_npc_animation or {}) do
        if not keep or not keep[address] then
            local mesh=record.mesh
            if valid(mesh) then
                mesh:SetAutoRegisterWithBudgetAllocator(true)
                mesh.VisibilityBasedAnimTickOption=record.visibility
                mesh.bEnableUpdateRateOptimizations=record.optimized
            end
            self.guest_npc_animation[address]=nil
        end
    end
end
function Engine:update_guest_npc_animation(host,guest_position)
    local now=self.native.clock_ms()
    if self.next_guest_npc_animation and now<self.next_guest_npc_animation then return end
    self.next_guest_npc_animation=now+500
    local host_position=host.Pawn:K2_GetActorLocation()
    local function distance_squared(a,b)
        return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2
    end
    self.trace_library=self.trace_library or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local class=StaticFindObject("/Script/Altar.VPairedCharacter")
    local budgeted=StaticFindObject("/Script/AnimationBudgetAllocator.SkeletalMeshComponentBudgeted")
    local nearby,candidates,keep={},{},{}
    self.trace_library:SphereOverlapActors(self.actor,guest_position,1000,{2},class,{self.actor,host.Pawn},nearby)
    self.guest_npc_animation=self.guest_npc_animation or {}
    for _,entry in ipairs(nearby) do
        local npc=entry:get()
        if paired(npc) and not npc:IsDead() then
            local mesh=npc.MainSkeletalMeshComponent
            if valid(mesh) and mesh:IsA(budgeted) then
                local address=mesh:GetAddress()
                local p=npc:K2_GetActorLocation()
                local distance=distance_squared(guest_position,p)
                if distance_squared(host_position,p)>distance+600^2 and
                    (self.guest_npc_animation[address] or (mesh.bEnable and mesh.bAutoRegisterWithBudgetAllocator)) then
                    candidates[#candidates+1]={mesh=mesh,address=address,distance=distance}
                end
            end
        end
    end
    table.sort(candidates,function(a,b) return a.distance<b.distance end)
    for index=1,math.min(4,#candidates) do
        local candidate=candidates[index]
        local mesh,address=candidate.mesh,candidate.address
        keep[address]=true
        if not self.guest_npc_animation[address] then
            self.guest_npc_animation[address]={mesh=mesh,visibility=mesh.VisibilityBasedAnimTickOption,
                optimized=mesh.bEnableUpdateRateOptimizations}
            mesh:SetAutoRegisterWithBudgetAllocator(false)
            mesh.VisibilityBasedAnimTickOption=0
            mesh.bEnableUpdateRateOptimizations=false
        end
    end
    self:restore_guest_npc_animation(keep)
end
function Engine:update_camera()
    if not valid(self.actor) or not valid(self.camera) then return end
    local location=self.actor:K2_GetActorLocation()
    local yaw,pitch=math.rad(self.yaw),math.rad(self.pitch)
    local host=self:host()
    local first_person=self.guest_pov==0
    local eye=self:guest_aim(true)
    local position=eye
    local actors={self.actor}
    local attached={}
    self.actor:GetAttachedActors(attached,true,true)
    for _,element in ipairs(attached) do
        local actor=element:get()
        if valid(actor) then actors[#actors+1]=actor end
    end
    local hide_self=first_person
    if not first_person then
        self.trace_library=self.trace_library or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local pivot={X=location.X,Y=location.Y,Z=location.Z+100}
        local distance=self.guest_pov==1 and 200 or 320
        position={X=pivot.X-math.cos(yaw)*math.cos(pitch)*distance,
            Y=pivot.Y-math.sin(yaw)*math.cos(pitch)*distance,Z=pivot.Z-math.sin(pitch)*distance}
        local pawn_clip=clip_to_other_player(pivot,position,host.Pawn)
        if pawn_clip then position=pawn_clip end
        local hit={}
        local blocked=self.trace_library:SphereTraceSingle(self.actor,pivot,position,12,1,false,actors,0,hit,true,
            {R=0,G=0,B=0,A=0},{R=0,G=0,B=0,A=0},0)
        if blocked and hit.Location then
            position={X=hit.Location.X,Y=hit.Location.Y,Z=hit.Location.Z}
        end
        if pawn_clip or (blocked and hit.Location) then
            self.camera_obstructed=true
            hide_self=(position.X-pivot.X)^2+(position.Y-pivot.Y)^2+(position.Z-pivot.Z)^2<80^2
            if hide_self then position=eye end
        else self.camera_obstructed=false end
    end
    self.camera.CameraComponent:SetFieldOfView(host.PlayerCameraManager:GetFOVAngle())
    if hide_self then
        -- Only the guest controller should hide this world body and its gear.
        -- Owner visibility alone leaves some head meshes visible at eye level.
        local addresses={}
        for index,actor in ipairs(actors) do addresses[index]=actor:GetAddress() end
        local key=table.concat(addresses,",")
        if self.hidden_guest_actors~=key then
            self.pc.HiddenActors=actors
            self.hidden_guest_actors=key
        end
    elseif self.hidden_guest_actors then
        self.pc.HiddenActors={}
        self.hidden_guest_actors=nil
    end
    local control_rotation={Pitch=self.pitch,Yaw=self.yaw,Roll=0}
    self.pc:SetControlRotation(control_rotation)
    self:update_guest_npc_animation(host,location)
    if not self.host_body_failed and self.native.set_weak_component then
        self.host_body=self.host_body or HostBody.new(self.native)
        local ok,err=pcall(self.host_body.update,self.host_body,host,self.pc,self.native.clock_ms())
        if not ok then
            pcall(self.host_body.destroy,self.host_body)
            self.host_body_failed=true
            self.log("Player 1 world body unavailable: "..tostring(err))
        end
    end
    local rotation=control_rotation
    self.first_person_eye=nil
    if first_person and not self.first_person_failed then
        self.first_person=self.first_person or FirstPerson.new()
        local ok,eye_position,eye_rotation=pcall(self.first_person.update,self.first_person,host,
            self.actor,self.camera,eye,control_rotation,self.native.clock_ms(),self.force_run)
        if not ok then
            pcall(self.first_person.destroy,self.first_person)
            self.first_person_failed=true
            self.log("Player 2 native first-person rig unavailable: "..tostring(eye_position))
        elseif eye_position then
            self.first_person_eye=eye_position
            position,rotation=eye_position,eye_rotation
        end
    elseif self.first_person then self.first_person:destroy() end
    self.camera:K2_SetActorLocationAndRotation(position,rotation,false,{},true)
end
local function axis(value)
    value=(value or 0)/32768
    if math.abs(value)<0.17 then return 0 end
    return (math.abs(value)-0.17)/0.83*(value<0 and -1 or 1)
end
local function movement_stick(pad)
    local x,y=(pad.lx or 0)/32768,(pad.ly or 0)/32768
    local magnitude=math.sqrt(x*x+y*y)
    if magnitude<=0.17 then return 0,0,false end
    local strength=(math.min(magnitude,1)-0.17)/0.83
    local scale=strength/magnitude
    return x*scale,y*scale,strength>0.5
end
local function move_from_view(pawn,x,y,yaw)
    local angle=math.rad(yaw)
    local forward_x,forward_y=math.cos(angle),math.sin(angle)
    pawn.PairedPawnMovementComponent:SetOffsetMovementInput({
        X=forward_x*y-forward_y*x,Y=forward_y*y+forward_x*x,Z=0})
    pawn:AddMovementInput({X=forward_x,Y=forward_y,Z=0},y,true)
    pawn:AddMovementInput({X=-forward_y,Y=forward_x,Z=0},x,true)
end
function Engine:set_guest_pov(pov)
    self.guest_pov=pov
    self.first_person_eye=nil
    self.actor.bUseControllerRotationYaw=pov==0
end
function Engine:start_host_routing()
    local host=self:host()
    host:ExitVanityCamera()
    host.PlayerCameraManager:StopVanityCameraTimer()
    self.vanity_timer_stopped=true
    host:DisableInput(host)
    self.host_input_disabled=true
    self.host_buttons,self.host_attack,self.host_block=0,false,false
    self.host_axes={}
end
local function pawn_distance_squared(first,second)
    local a,b=first:K2_GetActorLocation(),second:K2_GetActorLocation()
    return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2
end

local revive_window=30000
local revive_hold_time=10000

function Engine:poll_hotel_life(now)
    if not self.hotel_guest_travel or self.guest_crossing or self.door_preload
        or not self.native.backend_actor_position then return end
    local id=tonumber(self.actor_ref,16)
    if not id then return end
    local raw=self.native.backend_actor_position(id)
    local snapshot=raw and json.decode(raw)
    if snapshot and snapshot.request==self.hotel_life_request then self.hotel_life=snapshot end
    if now>=(self.hotel_life_next or 0) then
        self.hotel_life_request=650000000+now%100000000
        self.hotel_life_next=now+250
        self:command(self.actor_ref..".LSSActorPosition "..self.hotel_life_request)
    end
end

function Engine:guest_is_dead()
    return self.actor:IsDead() or self.hotel_life and self.hotel_life.dead==true
end

function Engine:poll_hotel_respawn(recovery,now)
    local snapshot=self.hotel_life
    if not snapshot or snapshot.dead~=false then return end
    if recovery.phase=="hotel_raise" and snapshot.cell_ref==DoorFixtures.hotel.cell then
        recovery.door_request=640000000+now%100000000
        self:command(("LSSDoor %d %d"):format(DoorFixtures.hotel.exit,recovery.door_request))
        recovery.phase="hotel_door"
    elseif recovery.phase=="hotel_door" then
        local raw=self.native.backend_door(DoorFixtures.hotel.exit)
        local door=raw and json.decode(raw)
        if not door or door.request~=recovery.door_request then return end
        local link=door.door
        if not door.guest_hotel_travel or not link or not link.destination_paired
            or not link.target_cell or not link.target_cell.attached then return end
        recovery.crossing=require("lib.door_travel").begin(self,DoorFixtures.hotel.exit,
            DoorFixtures.hotel.cell,link,false,false,true)
        recovery.phase="hotel_cross"
    elseif recovery.phase=="hotel_cross" and recovery.crossing and recovery.crossing.completed then
        if self.actor:IsDead() then self.actor:SetLifeState(1) end
        -- The stock mover can now reach Player 1 from the attached exterior.
        recovery.phase=nil
    end
end

function Engine:can_revive_guest()
    if self.guest_recovery or self.guest_unloaded or not paired(self.actor) or not self:guest_is_dead() then return false end
    local host=self:host()
    return valid(host) and paired(host.Pawn) and not host.Pawn:IsDead()
        and pawn_distance_squared(host.Pawn,self.actor)<=240^2
end

function Engine:request_guest_recovery(respawn)
    local ref=self.actor_ref
    if self.guest_recovery or self.guest_unloaded or not paired(self.actor) or not self:guest_is_dead()
        or not ref or not ref:match("^FF%x%x%x%x%x%x$")
        or (not respawn and not self:can_revive_guest()) then return false end
    self.interaction_notice=nil
    self.guest_recovery={respawn=respawn,deadline=self.native.clock_ms()+6000}
    -- Raise the original actor first. Moving a dead actor out of the
    -- background hotel can discard its native scene pairing.
    self:command(ref..".resurrect 1")
    if respawn and self.hotel_life and self.hotel_life.dead and self.hotel_life.cell_ref==DoorFixtures.hotel.cell then
        self.guest_recovery.phase="hotel_raise"
    end
    return true
end

function Engine:input_guest_recovery(buttons)
    local actor=self.actor
    local now=self.native.clock_ms()
    self:poll_hotel_life(now)
    local dead=self:guest_is_dead()
    local recovery=self.guest_recovery
    if not dead and not recovery and not self.guest_downed then return false end
    if self.revive_hold and self.revive_hold.by==2 then self.revive_hold=nil end
    if not self.guest_downed then
        self.guest_downed=true
        self.guest_revive_until=now+revive_window
        self:cancel_guest_interaction()
        self:release_activation(2)
        self.guest_dialogue=nil
        if self.dialogues then self.dialogues:close(2) end
        if self.inventories then self.inventories[2]:close() end
        self.guest_door=nil
        if self.door_preload then require("lib.door_preload").stop(self) end
        if self.guest_crossing then require("lib.door_travel").cancel(self) end
        Actions.release(actor,self.guest_actions)
        self.blocking,self.attacking=false,false
        local movement=actor.PairedPawnMovementComponent
        movement:ResetOffsetMovementInput()
        movement:StopSprint()
        self:set_guest_speed()
        self.dirty=true
    end
    local host=self:host().Pawn
    if recovery then
        if recovery.phase then
            self:poll_hotel_respawn(recovery,now)
        elseif not dead and not actor:IsUnconscious() then
            if not recovery.respawn then
                self.guest_recovery=nil
            elseif not recovery.move_sent then
                -- Skip the move if the host's area is out of reach. Separate
                -- interiors can have distant render coordinates even next to a door.
                if host:IsDead() or pawn_distance_squared(host,actor)>8000^2 then
                    self.guest_recovery=nil
                    self:guest_interaction_notice("Player 2 recovered where they fell.")
                else
                    -- Use a native move so the save and render positions agree.
                    self:command(self.actor_ref..".moveto player 0 90 0")
                    recovery.move_sent=true
                    recovery.deadline=now+3500
                    recovery.confirm_after=now+200
                end
            elseif now>=recovery.confirm_after and pawn_distance_squared(host,actor)<=360^2 then
                self.guest_recovery=nil
            end
        end
        if self.guest_recovery and now>=recovery.deadline then
            self.guest_recovery=nil
            self:guest_interaction_notice(dead and "Recovery failed. Try again."
                or "Player 2 recovered where they fell.")
        end
    elseif dead then
        local expired=self.guest_revive_until and now>=self.guest_revive_until
        if expired then self.guest_revive_until=nil end
        if (expired and not (self.revive_hold and self.revive_hold.by==1))
            or buttons & 4096~=0 and (self.last_buttons or 0) & 4096==0 then
            self:request_guest_recovery(true)
        end
        if expired and self.revive_hold and self.revive_hold.by==1 then self.guest_revive_until=now end
    end
    if not dead and not self.guest_recovery then
        self.guest_downed,self.guest_revive_until=nil,nil
        actor.PairedPawnMovementComponent:SetIsMovementLocked(false)
        self.dirty=true
    end
    self.last_buttons=buttons
    self:update_camera()
    return true
end

function Engine:can_revive_host()
    local host=self:host()
    return self.host_downed and not self.host_recovery and valid(host) and paired(host.Pawn)
        and host.Pawn:IsDead() and paired(self.actor) and not self:guest_is_dead()
        and pawn_distance_squared(host.Pawn,self.actor)<=240^2
end

function Engine:request_host_recovery(respawn)
    local host=self:host().Pawn
    if self.host_recovery or not host:IsDead() or (not respawn and not self:can_revive_host()) then return false end
    self:command("player.resurrect 1")
    self.host_recovery={respawn=respawn,deadline=self.native.clock_ms()+6000}
    return true
end

function Engine:close_stock_death_menu()
    -- The same widget also handles normal Save and Load. Close only the
    -- instance opened by the stock death timer (FromDeath = 3).
    for _,menu in ipairs(FindAllOf("WBP_ModernMenu_SaveLoad_C") or {}) do
        if valid(menu) and menu:IsActivated() then
            local model=menu.VSaveLoadMenuViewModel
            if valid(model) and model.CachedOpeningSource==3 then menu:DeactivateWidget() end
        end
    end
end

function Engine:input_host_recovery(host,buttons)
    local pawn=host.Pawn
    if self.loading or not paired(pawn) then return false end
    local dead=pawn:IsDead()
    if not dead and not self.host_downed then return false end
    if not self:gameplay_input_enabled() then self:close_stock_death_menu() end
    if self.revive_hold and self.revive_hold.by==1 then self.revive_hold=nil end
    local now=self.native.clock_ms()
    local values=pawn.ActorValuesPairingComponent
    if dead and now>=(self.next_death_load_block or 0) then
        self.next_death_load_block=now+500
        if self.native.backend_protocol and self.native.backend_protocol()==2 then
            self:command("LSSBlockDeathLoad 1")
        end
    end
    if not self.host_downed then
        self.host_downed=true
        self.host_revive_until=now+revive_window
        self.host_health=math.max(1,math.floor(values:GetFloatBaseActorValue(8)))
        if self.dialogues then self.dialogues:close(1) end
        if self.inventories then self.inventories[1]:close() end
        self:release_activation(1)
        Actions.release(pawn,self.host_actions)
        pawn.PairedPawnMovementComponent:ResetOffsetMovementInput()
        pawn.PairedPawnMovementComponent:StopSprint()
    end
    local recovery=self.host_recovery
    if recovery then
        if not dead and values:GetFloatModifiedActorValue(8)>0 then
            self.host_downed,self.host_revive_until,self.host_recovery=nil,nil,nil
            self.next_death_load_block=nil
        elseif not dead and not recovery.healing then
            self:command("player.forceav health "..self.host_health)
            recovery.healing=true
        elseif now>=recovery.deadline then
            self.host_recovery=nil
        end
    elseif dead then
        local expired=self.host_revive_until and now>=self.host_revive_until
        if expired then self.host_revive_until=nil end
        if (expired and not (self.revive_hold and self.revive_hold.by==2))
            or buttons & 4096~=0 and (self.host_buttons or 0) & 4096==0 then
            self:request_host_recovery(true)
        end
        if expired and self.revive_hold and self.revive_hold.by==2 then self.host_revive_until=now end
    elseif values:GetFloatModifiedActorValue(8)>0 then
        self.host_downed,self.host_revive_until=nil,nil
        self.next_death_load_block=nil
    end
    self.host_buttons=buttons
    return true
end

function Engine:input_revive(player,buttons)
    local hold=self.revive_hold
    local eligible=buttons & 16384~=0 and (player==1 and self:can_revive_guest()
        or player==2 and self:can_revive_host())
    if not eligible then
        if hold and hold.by==player then self.revive_hold=nil end
        return false
    end
    local now=self.native.clock_ms()
    if not hold or hold.by~=player then
        self:release_activation(player)
        if player==2 then self:cancel_guest_interaction() end
        self.revive_hold={by=player,until_time=now+revive_hold_time}
    elseif now>=hold.until_time then
        self.revive_hold=nil
        if player==1 then self:request_guest_recovery(false) else self:request_host_recovery(false) end
    end
    return true
end

function Engine:input_host(pad,dt)
    local host=self:host()
    if not valid(host) then return false end
    local connected=pad and pad.connected and pad.slot==self:host_slot()
    if connected then self.host_controller_name=pad.simulated and "DualSense" or pad.name end
    local buttons=connected and (pad.buttons or 0) or 0
    if self:input_host_recovery(host,buttons) then return true end
    if not connected then return false end
    if self.guest_interaction and (buttons~=0 or math.abs(pad.rx or 0)>5000 or math.abs(pad.ry or 0)>5000
        or math.abs(pad.lx or 0)>5000 or math.abs(pad.ly or 0)>5000) then self:cancel_guest_interaction() end
    if buttons & 16384==0 then self:release_activation(1) end
    if not self:gameplay_input_enabled() then
        if self.revive_hold and self.revive_hold.by==1 then self.revive_hold=nil end
        self.host_door=nil
        host.Pawn.PairedPawnMovementComponent:ResetOffsetMovementInput()
        Actions.release(host.Pawn,self.host_actions)
        if self.host_input_disabled then host:EnableInput(host); self.host_input_disabled=false end
        self.host_buttons=buttons
        return
    end
    if not self.host_input_disabled then host:DisableInput(host); self.host_input_disabled=true end
    if self.host_crossing and self.host_crossing.component then
        self.host_buttons=buttons
        return true
    end
    local previous=self.host_buttons or 0
    local function pressed(mask) return (buttons & mask)~=0 and (previous & mask)==0 end
    local function released(mask) return (buttons & mask)==0 and (previous & mask)~=0 end
    if pressed(16) then
        host.Pawn.PairedPawnMovementComponent:ResetOffsetMovementInput()
        Actions.release(host.Pawn,self.host_actions)
        host:OpenOptionsMenuInput_Pressed()
        self.host_buttons=buttons
        return true
    end
    -- Scripted pad routing bypasses the native input event that resets idle
    -- orbit. Keep the normal gameplay camera while split-screen owns input.
    host.PlayerCameraManager:StopVanityCameraTimer()
    if (self.dialogues and self.dialogues:input(1,buttons & ~previous))
        or (self.inventories and self.inventories[1]:input(pad)) then
        Actions.release(host.Pawn,self.host_actions)
        host.Pawn.PairedPawnMovementComponent:ResetOffsetMovementInput()
        host:AttackInput_Released(); host:BlockInput_Released()
        self.host_attack,self.host_block=false,false; self.host_buttons=pad.buttons or 0
        return true
    end
    local rotation=host:GetControlRotation()
    dt=dt or 1/60
    local turn,look=axis(pad.rx),axis(pad.ry)
    local pitch=(rotation.Pitch+180)%360-180
    local yaw=rotation.Yaw+turn*130*dt
    host:SetControlRotation({Yaw=yaw,Pitch=math.max(-65,math.min(60,pitch+look*100*dt)),Roll=0})
    local x,y,running=movement_stick(pad)
    host.Pawn.OblivionActorStatePairingComponent.bIsRunning=running
    move_from_view(host.Pawn,x,y,yaw)
    if pressed(4096) then host.Pawn:Jump() end
    if released(4096) then host.Pawn:StopJumping() end
    local reviving=self:input_revive(1,buttons)
    if pressed(16384) and not reviving and not self.activation and not self.guest_dialogue then
        local address=self:host_activation_target_address()
        local target
        if self.experimental_dialogue or address==nil then target=self:host_interaction_target() end
        if address==nil then
            if valid(target) then address=target:GetAddress() end
        end
        local talking=self.experimental_dialogue and self.dialogues and valid(target)
            and address==target:GetAddress() and self.dialogues:start(1,target)
        if not talking and (not valid(self.actor) or address~=self.actor:GetAddress()) and not HostTravel.begin(self,address) then
            host:ActivateInput_Pressed()
            self.activation=1
        end
    end
    if self.host_door then HostTravel.poll(self,self.native.clock_ms()) end
    if pressed(8192) and not self.inventories then host:OpenInventoryMenuInput_Pressed() end
    if pressed(32) then host:TogglePOVInput_Pressed() end
    if released(32) then host:TogglePOVInput_Released() end
    if pressed(128) then host:CrouchInput_Pressed() end
    if pressed(64) then host.Pawn.PairedPawnMovementComponent:StartSprint() end
    if released(64) then host.Pawn.PairedPawnMovementComponent:StopSprint() end
    if pressed(512) then host:CastInput_Pressed() end
    if released(512) then host:CastInput_Released() end
    if pressed(4) then host:OpenMagicMenuInput_Pressed() end
    if released(4) then host:OpenMagicMenuInput_Released() end
    if pressed(8) then self:open_shared_journal(1) end
    self.host_actions=self.host_actions or {}
    Actions.update(host.Pawn,pad,self.host_actions,self.native.clock_ms())
    self.host_buttons=buttons
end
function Engine:input(pad,dt)
    if not pad or pad.slot~=self.slot then return false end
    self.guest_controller_name=pad.simulated and "DualSense" or pad.name
    if self.guest_unloaded or not paired(self.actor) then return self:wait_for_guest() end
    if not valid(self.pc) or not valid(self.camera) then return false end
    local buttons=pad.buttons or 0
    local gameplay_enabled=self:gameplay_input_enabled()
    if not self.loading and (gameplay_enabled or self.host_downed or self.guest_downed or self.actor:IsDead())
        and self:input_guest_recovery(buttons) then return true end
    local reviving=self:input_revive(2,not self.loading and (gameplay_enabled or self.host_downed) and buttons or 0)
    if reviving then
        self.actor.PairedPawnMovementComponent:ResetOffsetMovementInput()
        self.last_buttons=buttons
        self:update_camera()
        return true
    end
    if self.recover_equipment then self:poll_guest_equipment(); return true end
    if self.guest_crossing then self.last_buttons=buttons; return true end
    if buttons & 16384==0 then self:release_activation(2) end
    self:poll_guest_interaction()
    self:restore_guest_quiver()
    if not gameplay_enabled then
        self.guest_door=nil
        if self.door_preload then require("lib.door_preload").cancel_crossing(self) end
        self.actor.PairedPawnMovementComponent:ResetOffsetMovementInput()
        self:set_guest_speed()
        Actions.release(self.actor,self.guest_actions)
        local previous=self.last_buttons or 0
        if self.journal then self:input_shared_journal(2,buttons,previous)
        elseif not self.guest_modal_closing then self:input_shared_dialogue(buttons & ~previous) end
        self.last_buttons=buttons
        return true
    end
    local dialogue=self.guest_dialogue
    if dialogue and (dialogue.menu or self.native.clock_ms()>=dialogue.deadline) then
        self.guest_dialogue=nil
        if not dialogue.menu then self:guest_interaction_notice("The character did not respond.") end
    end
    if self.guest_modal_closing then
        if buttons==0 then self.guest_modal_closing=nil end
        self.last_buttons=buttons
        return true
    end
    if not self.host_downed and buttons & 16~=0 and (self.last_buttons or 0) & 16==0 then
        if self.door_preload then require("lib.door_preload").cancel_crossing(self) end
        self.actor.PairedPawnMovementComponent:ResetOffsetMovementInput()
        self:set_guest_speed()
        Actions.release(self.actor,self.guest_actions)
        self:host():OpenOptionsMenuInput_Pressed()
        self.last_buttons=buttons
        return true
    end
    local previous=self.last_buttons or 0
    if (self.dialogues and self.dialogues:input(2,buttons & ~previous))
        or (self.inventories and self.inventories[2]:input(pad)) then
        self.guest_door=nil
        if self.door_preload then require("lib.door_preload").cancel_crossing(self) end
        Actions.release(self.actor,self.guest_actions)
        self.actor.PairedPawnMovementComponent:ResetOffsetMovementInput()
        self:set_guest_speed()
        self.actor:SendBlock(false); self.blocking=false; self.attacking=false
        self.last_buttons=pad.buttons or 0; self:update_camera()
        return true
    end
    self.yaw=(self.yaw+axis(pad.rx)*130*dt)%360
    self.pitch=math.max(-65,math.min(60,self.pitch+axis(pad.ry)*100*dt))
    self.pc:SetControlRotation({Yaw=self.yaw,Pitch=self.pitch,Roll=0})
    local x,y,running=movement_stick(pad)
    self.actor.OblivionActorStatePairingComponent.bIsRunning=running
    -- Set the native actor's run state as well as its Unreal animation state.
    if self.force_run~=running then
        self:command(self.actor_ref..".setforcerun "..(running and "1" or "0"))
        self.force_run=running
    end
    local movement=self.actor.PairedPawnMovementComponent
    local speed
    if (x~=0 or y~=0) and movement:IsMovingOnGround() and not self.sneaking then
        if movement:IsSprinting() then speed=movement:GetMaxGroundSprintSpeed()
        elseif running then speed=movement:GetMaxGroundRunSpeed()
        else speed=movement:GetMaxGroundWalkSpeed() end
    end
    self:set_guest_speed(speed)
    -- NPC locomotion consumes the paired component's offset, rather than the
    -- normal player input queue alone. This keeps movement on the paired actor.
    move_from_view(self.actor,x,y,self.yaw)
    if (buttons & 32)~=0 and (previous & 32)==0 then
        self:set_guest_pov((self.guest_pov+1)%3)
    end
    if (buttons & 512)~=0 and (previous & 512)==0 then self:cast_guest_spell() end
    if (buttons & 8)~=0 and (previous & 8)==0 then self:open_shared_journal(2) end
    self:poll_guest_door()
    if (buttons & 16384)~=0 and (previous & 16384)==0 then self:interact_guest() end
    if (buttons & 128)~=0 and (previous & 128)==0 then
        self.sneaking=not self.sneaking; self.actor:SetSneak(self.sneaking)
        self:command(self.actor_ref..".setforcesneak "..(self.sneaking and "1" or "0"))
    end
    if (buttons & 64)~=0 and (previous & 64)==0 then self.actor.PairedPawnMovementComponent:StartSprint() end
    if (buttons & 64)==0 and (previous & 64)~=0 then self.actor.PairedPawnMovementComponent:StopSprint() end
    if (buttons & 4096)~=0 and (previous & 4096)==0 then self.actor:Jump() end
    if (buttons & 4096)==0 and (previous & 4096)~=0 then self.actor:StopJumping() end
    local attack=(pad.rt or 0)>60
    local block=(pad.lt or 0)>60
    self.guest_actions=self.guest_actions or {}
    Actions.update(self.actor,pad,self.guest_actions,self.native.clock_ms())
    local changed_actor=buttons & ~previous & (64 | 128 | 4096 | 32768)~=0
    if x~=0 or y~=0 or changed_actor or attack or block then self.dirty=true end
    self.last_buttons=buttons
    self:update_camera()
    return true
end
function Engine:set_guest_speed(speed)
    if self.guest_speed==speed then return end
    local movement=self.actor.PairedPawnMovementComponent
    if speed then movement:SetOverrideMaxSpeed(speed)
    else movement:ResetOverrideMaxSpeed() end
    self.guest_speed=speed
end
function Engine:guest_inventory_snapshot()
    local id=self.actor_ref and tonumber(self.actor_ref,16)
    local raw=id and self.native.backend_inventory(id)
    local data=raw and json.decode(raw)
    if data and data.actor_ref==id then return data end
end
function Engine:guest_equipment_commands(expected,items)
    local wanted={}
    for _,item in ipairs(expected) do wanted[item.form_id]=item.equipped or item.left end
    local commands,wear={},{}
    for _,item in ipairs(items) do
        local original=wanted[item.form_id]
        if original~=nil then
            local equipped=item.equipped or item.left
            if equipped and not original then
                commands[#commands+1]=string.format("%s.unequipitem %08X",self.actor_ref,item.form_id)
            elseif original and not equipped then
                wear[#wear+1]=string.format("%s.equipitem %08X",self.actor_ref,item.form_id)
            end
        end
    end
    for _,command in ipairs(wear) do commands[#commands+1]=command end
    return commands
end
function Engine:poll_guest_equipment()
    local recovery=self.recover_equipment
    local data=self:guest_inventory_snapshot()
    if not data or data.request~=recovery.request then
        if self.native.clock_ms()>=recovery.deadline then
            self.recover_equipment=nil
            self.log("Player 2's equipment could not be checked after streaming.")
        end
        return
    end
    local commands=self:guest_equipment_commands(recovery.items,data.items)
    if #commands>0 then self:host().CheatManager:SendMultipleOblivionCommand(commands) end
    self.recover_equipment=nil
end
function Engine:wait_for_guest()
    if not self.guest_unloaded then
        self:restore_guest_npc_animation()
        -- Remove the local view while its controller still exists. Once the
        -- game destroys that controller, RemovePlayer cannot release its slot.
        local before=self:guest_inventory_snapshot()
        self:rollback()
        self.guest_unloaded=true
        self.parked_inventory=before
        self.actor,self.force_run,self.pending_quiver,self.guest_speed=nil,nil,nil,nil
        self.log("Player 2's area unloaded. Waiting for the same character to become available.")
    end
    local now=self.native.clock_ms()
    if now<(self.next_guest_lookup or 0) or not self:world_ready() or not self:gameplay_input_enabled() then return true end
    self.next_guest_lookup=now+500
    if self.guest_area_restore then
        BackgroundCell.resume(self,now)
        if self.guest_area_restore then return true end
    end
    local actor=self:find_actor(self.actor_ref)
    if not paired(actor) then return true end
    local before=self.parked_inventory
    self.actor=actor
    local ok,err=pcall(function() self:create_view(); self:finish_join() end)
    if not ok then
        self:rollback()
        self.actor,self.guest_unloaded,self.next_guest_lookup=nil,true,now+1500
        self.parked_inventory=before
        if self.guest_rebind_error~=tostring(err) then self.log(tostring(err)) end
        self.guest_rebind_error=tostring(err)
        return true
    end
    self.guest_rebind_error=nil
    self.guest_unloaded,self.next_guest_lookup=nil,nil
    self.guest_area_restore=nil
    self.parked_inventory=nil
    if before then
        local request=now%1000000000
        self:command(self.actor_ref..".LSSInventory "..request)
        self.recover_equipment={items=before.items,request=request,deadline=now+3000}
    end
    self.log("Player 2 reattached to the same character after streaming.")
    return true
end
function Engine:suspend()
    self.revive_hold=nil
    self.interaction_notice=nil
    self:cancel_guest_interaction()
    self:restore_guest_npc_animation()
    self.host_door,self.guest_door=nil,nil
    if self.dialogues then self.dialogues:close(1); self.dialogues:close(2) end
    if self.door_preload then require("lib.door_preload").cancel_crossing(self) end
    if self.journal then self.journal.neutral=true end
    if self.first_person then self.first_person:destroy() end
    self.first_person_eye=nil
    if self.host_body then self.host_body:destroy() end
    if self.activation then self:release_activation(self.activation) end
    if paired(self.actor) then
        Actions.release(self.actor,self.guest_actions)
        if self.force_run then self:command(self.actor_ref..".setforcerun 0"); self.force_run=false end
        self.actor:SendBlock(false)
        self.actor.PairedPawnMovementComponent:ResetOffsetMovementInput()
        self:set_guest_speed()
        self.actor.PairedPawnMovementComponent:StopSprint()
        self.actor.PairedPawnMovementComponent:StopMovementImmediately()
    end
    self.last_buttons,self.blocking,self.attacking=0,false,false
    local host=self:host()
    if self.host_input_disabled and valid(host) then
        Actions.release(host.Pawn,self.host_actions)
        host.Pawn.PairedPawnMovementComponent:ResetOffsetMovementInput()
        host.Pawn.PairedPawnMovementComponent:StopSprint()
        host:MovementForwardInput_Released(); host:MovementBackwardInput_Released()
        host:MovementLeftInput_Released(); host:MovementRightInput_Released()
        host:AttackInput_Released(); host:BlockInput_Released()
        self.host_axes={}
    end
end
function Engine:resume(slot) self.slot=slot; self.last_buttons=0 end
function Engine:rollback()
    self.interaction_notice=nil
    self.guest_downed,self.guest_revive_until,self.guest_recovery=nil,nil,nil
    self.host_downed,self.host_revive_until,self.host_recovery=nil,nil,nil
    self.next_death_load_block=nil
    self.revive_hold=nil
    self.hotel_life,self.hotel_life_request,self.hotel_life_next=nil,nil,nil
    self:cancel_guest_interaction()
    self:restore_guest_npc_animation()
    self.host_door,self.host_travel=nil,nil
    HostCrossing.cancel(self)
    self.host_background_streams=nil
    if self.guest_torch_controlled then
        self.native.control_guest_torch(0)
        self.guest_torch_controlled=nil
    end
    self.guest_door=nil
    if self.door_preload then require("lib.door_preload").stop(self) end
    if self.saved_area then require("lib.saved_area").cancel(self) end
    if self.guest_crossing then require("lib.door_travel").cancel(self) end
    self:set_system_fullscreen(false)
    self.system_fullscreen=nil
    if self.first_person then self.first_person:destroy() end
    self.first_person,self.first_person_failed,self.first_person_eye=nil,nil,nil
    if self.host_body then self.host_body:destroy() end
    self.host_body,self.host_body_failed=nil,nil
    self.transition=nil
    self.guest_unloaded,self.next_guest_lookup=nil,nil
    self.guest_area_restore=nil
    self.parked_inventory,self.recover_equipment=nil,nil
    self.pending_quiver=nil
    self.journal_release=nil
    self.guest_dialogue,self.guest_modal_closing,self.activation=nil,nil,nil
    self:reset_shared_journal()
    self.clone_inventory=nil
    if valid(self.actor) then
        if self.previous_player_flag~=nil then self.actor:SetIsPlayerCharacter(self.previous_player_flag) end
        if self.previous_melee_restriction~=nil then self.actor.bRestrictedMeleeTargeting=self.previous_melee_restriction end
        local rotation=self.guest_rotation_policy
        if rotation then
            self.actor.bUseControllerRotationYaw=rotation.yaw
            local movement=self.actor.PairedPawnMovementComponent
            if valid(movement) then movement:SetUseControllerRotation(rotation.desired) end
        end
    end
    self.guest_rotation_policy=nil
    self.previous_player_flag,self.previous_melee_restriction=nil,nil
    for _,record in ipairs(self.animation_policies or {}) do
        if valid(record.mesh) then record.mesh.VisibilityBasedAnimTickOption=record.visibility; record.mesh.bEnableUpdateRateOptimizations=record.optimized end
    end
    self.animation_policies=nil
    if paired(self.actor) then Actions.release(self.actor,self.guest_actions) end
    if valid(self:host()) and valid(self:host().Pawn) then Actions.release(self:host().Pawn,self.host_actions) end
    if self.inventories then for _,menu in ipairs(self.inventories) do menu:destroy() end; self.inventories=nil end
    if self.dialogues then self.dialogues:destroy(); self.dialogues=nil end
    if paired(self.actor) then
        if self.force_run then pcall(self.command,self,self.actor_ref..".setforcerun 0"); self.force_run=false end
        self.actor.PairedPawnMovementComponent:ResetOffsetMovementInput()
        self:set_guest_speed()
    end
    local gs=StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if valid(self.pc) then self.pc:UnPossess(); gs:RemovePlayer(self.pc,false) end
    if valid(self.camera) then self.camera:K2_DestroyActor() end
    local maps=StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
    if self.previous_split~=nil then
        maps.bUseSplitscreen=self.previous_split
        maps.bOffsetPlayerGamepadIds=self.previous_offset
        maps.TwoPlayerSplitscreenLayout=self.previous_layout
    end
    if self.actor_ref and paired(self.actor) then pcall(self.command,self,self.actor_ref..".setrestrained 0") end
    local host=self:host()
    if self.vanity_timer_stopped and not self.loading and valid(host) and valid(host.PlayerCameraManager) then
        host.PlayerCameraManager:SetVanityCameraTimer()
    end
    self.vanity_timer_stopped=nil
    if self.host_input_disabled and valid(host) then
        host.Pawn.PairedPawnMovementComponent:ResetOffsetMovementInput()
        host.Pawn.PairedPawnMovementComponent:StopSprint()
        host:EnableInput(host)
    end
    self.host_input_disabled=false
    self.pc,self.camera,self.before,self.hidden_guest_actors=nil,nil,nil,nil
end
function Engine:leave()
    if self.dirty then return false,"Save your game first to keep Player 2's belongings." end
    self:rollback(); return true
end
function Engine:on_save(save)
    if not self.actor_ref or (not valid(self.actor) and not self.guest_unloaded) then return end
    local details=save.SaveGameDetails
    local campaign=guid(details.CharacterId)
    if campaign~=self.campaign_id then return end
    local slot=str(details.SlotName)
    local hash=str(details.SaveHash)
    local key=assert(self:save_id(),"Native save identifier is not ready")
    local player={id="player2_"..campaign,name="Player 2",actor_ref=self.actor_ref,persistence="native_actor",
        native_slot=slot,native_hash=hash,race=self.guest_race,spell_id=self.guest_spell_id}
    local ok,err=self.store:write(campaign,key,player)
    assert(ok,"Player 2 metadata could not be saved: "..tostring(err))
    self.loaded_record={campaign=campaign,player=player}
    self.dirty=false
    self.log("Player 2 reference saved for native slot "..slot)
end
function Engine:select_load(vm,slot)
    slot=str(slot)
    self.loaded_record=nil
    local metadata=vm:GetSavesMetaData()
    local function inspect(key,details)
        if str(key)==slot then
            local campaign=guid(details.CharacterId)
            local hash=str(details.SaveHash)
            local record=self.store:read(campaign,token(slot.."|"..hash))
            if record and record.player.native_slot==slot and record.player.native_hash==hash then self.loaded_record=record end
        end
    end
    if type(metadata)=="table" then
        for key,value in pairs(metadata) do inspect(key,value) end
    else
        metadata:ForEach(function(key,value) inspect(key:get(),value:get()) end)
    end
end
Engine.runtime=runtime
return Engine
