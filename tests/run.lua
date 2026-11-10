package.path = "src/?.lua;src/?/init.lua;" .. package.path
local load = assert(package.loadlib("build/Release/lss_native_v2.dll", "luaopen_lss_native"))
local native = load()
local Store = require("lib.store")
local Session = require("lib.session")
local json = require("lib.json")
local passed = 0
local function test(name, run)
    run(); passed = passed + 1; print("PASS " .. name)
end
local testRoot = "tests/data"
local store = Store.new(testRoot, native)
local player = {id = "player2", name = "A\"B\n\233\190\153", actor_ref = "FF000123", persistence = "native_actor"}
local function cleanup()
    for _, name in ipairs({"campaign__slot.json", "campaign__slot.json.bak", "campaign__other.json", "atomic.txt", "atomic.txt.bak"}) do
        os.remove(testRoot .. "/" .. name)
    end
end
test("held block supplies its native input condition and releases only its own tag",function()
    local Actions=require("lib.actions")
    local old_name=FName; FName=function(name) return name end
    local held=false; local requested
    local actor={Role=3,IsValid=function() return true end,IsDeadFromKilled=function() return false end,
        IsUnconscious=function() return false end,IsWeaponDrawn=function() return true end,
        HasGameplayTag=function() return held end,AddGameplayTag=function() held=true end,
        RemoveGameplayTag=function() held=false end,SendBlock=function() end,SetOblivionAnimAction=function() end,
        OblivionActorStatePairingComponent={}}
    actor.StateMachineComponent={GetActionState=function() return {ToString=function() return "Idle" end} end,
        GetStateFromTag=function() return {IsValid=function() return true end} end,
        SendStateChangeListToServer=function(_,tags)
            requested=tags[1].TagName
            if requested=="State.Character.Action.Block" then assert(held,"Native block entry condition requires held input") end
        end}
    local state={}
    Actions.update(actor,{lt=200},state,100)
    assert(held and requested=="State.Character.Action.Block")
    Actions.release(actor,state); assert(not held and requested=="State.Character.Action.Idle")
    held=true; state={}
    Actions.update(actor,{lt=200},state,200)
    Actions.release(actor,state); assert(held,"A tag supplied by another native owner must survive release")
    FName=old_name
end)
test("host travel adopts only the completed autosave for the verified door arrival",function()
    local Travel=require("lib.host_travel")
    local json=require("lib.json")
    local id,complete="new",false
    local snapshots={}
    local saved={}
    local transition={campaign="campaign",save_id="old",actor_ref="FF001093",door={guest_cell=617155,
        link={arrival={943,810,173},destination_cell=175850,target_cell={interior=true}}}}
    local adapter={transition=transition,native={backend_actor_position=function(ref)
        return snapshots[ref] and json.encode(snapshots[ref])
    end},store={read=function() return nil end,exists=function() return false end},
        world_ready=function() return true end,save_id=function() return id end,campaign=function() return "campaign" end,
        command=function() end,log=function() end,
        poll_save=function(self,now,autosave_only)
            assert(autosave_only and self.actor_ref==transition.actor_ref and self.guest_unloaded)
            if complete then saved[#saved+1]=id; return true end
        end}
    assert(not Travel.resume(adapter,10))
    local request=transition.door.request
    snapshots[20]={request=request,actor_ref=20,cell_ref=175850,interior=true,native_position={943,810,173}}
    snapshots[0xFF001093]={request=request,actor_ref=0xFF001093,cell_ref=617155}
    assert(not Travel.resume(adapter,20) and #saved==0 and transition.save_id=="old")
    complete=true
    snapshots[20].request=request+1
    assert(Travel.resume(adapter,270) and saved[1]=="new" and transition.save_id=="new")
    assert(not transition.door and not adapter.guest_unloaded)
    transition.door={guest_cell=617155,link={arrival={943,810,173},destination_cell=175850,target_cell={interior=true}}}
    id="another"
    assert(not Travel.resume(adapter,280))
    request=transition.door.request
    snapshots[20].request=request
    snapshots[0xFF001093].request=request
    snapshots[0xFF001093].cell_ref=114113
    assert(Travel.resume(adapter,290) and #saved==1 and transition.save_id=="new")
end)
test("verified hotel exit can identify the arrival while its exterior cell is unloaded",function()
    local Travel=require("lib.host_travel")
    local Arrival=require("lib.door_arrival")
    local door={actor_ref=0x2b092,cell_ref=0x2aeea,request=17,door={has_teleport=true,source_paired=true,
        source_cell={attached=true},destination_ref=0x2c3ac,destination_cell=0,arrival={20582,62746,3536}}}
    local guest={actor_ref=0xFF00D0A2,request=17,cell_ref=0x96ac3}
    local pressed=false
    local adapter={actor_ref="FF00D0A2",host_door={address=24,ref=door.actor_ref,actor="FF00D0A2",request=17,deadline=500},
        native={backend_door=function() return json.encode(door) end,backend_actor_position=function() return json.encode(guest) end},
        host_activation_target_address=function() return 24 end,
        host=function() return {ActivateInput_Pressed=function() pressed=true end} end}
    Travel.poll(adapter,200)
    assert(pressed and adapter.host_travel.guest_cell==0x96ac3)
    local link=adapter.host_travel.link
    assert(Arrival.matches_native(link,{cell_ref=114110,interior=false,native_position={20582,62746,3538}}))
    assert(not Arrival.matches_native(link,{cell_ref=0x2aeea,interior=true,native_position={20582,62746,3538}}))
end)
test("warm sewer recovery requires a verified hotel link across distinct worlds",function()
    local Background=require("lib.background_cell")
    local pawn={GetFullName=function() return "Pawn /Game/Maps/World/Talos.Talos:PersistentLevel.Pawn" end,
        GetAddress=function() return 79 end}
    local adapter={experimental_background_sewer=true,host=function() return {Pawn=pawn} end,
        native={clock_ms=function() return 100 end}}
    local travel={primary_world="/Game/Maps/VerticalSlice/Dungeon.Dungeon",actor="FF00D0A2",
        link={destination_ref=0x2c3ac}}
    local host={cell_ref=114110}
    local guest={cell_ref=0x96ac3,cell={state=6},actor_paired=true,actor_has_pairing_entry=true}
    local ticket=assert(Background.warm_ticket(adapter,travel,host,guest,"save"))
    assert(ticket.host==79 and ticket.actor==travel.actor and ticket.save_id=="save" and ticket.stage=="stale")
    guest.actor_has_pairing_entry=false
    assert(not Background.warm_ticket(adapter,travel,host,guest,"save"))
    guest.actor_has_pairing_entry=true
    travel.primary_world=Background.capture_world(adapter)
    assert(not Background.warm_ticket(adapter,travel,host,guest,"save"))
end)
cleanup()
test("native controller packets have distinct stable slot identifiers", function()
    local pads = native.poll(); assert(#pads == 4)
    for i, pad in ipairs(pads) do assert(pad.slot == i - 1); assert(type(pad.connected) == "boolean") end
end)
test("transform hold fails closed without the fixture backend",function()
    assert(not native.transform_hold(1,true))
    assert(native.suppressed_transforms()==nil)
end)
test("leaving a pending door transfer releases only that player's transform hold",function()
    local Travel=require("lib.door_travel")
    local calls=0
    local adapter={guest_crossing={component=99},native={transform_hold=function(component,enabled)
        calls=calls+1
        assert(component==99 and not enabled)
    end}}
    Travel.cancel(adapter)
    Travel.cancel(adapter)
    assert(not adapter.guest_crossing and calls==1)
end)
test("preload locomotion restores settings only for the captured players and components",function()
    local Movement=require("lib.preload_movement")
    local function pawn(id)
        local component={ticking=true,IsValid=function() return true end,GetAddress=function() return id+100 end,
            IsComponentTickEnabled=function(self) return self.ticking end,
            SetComponentTickEnabled=function(self,value) self.ticking=value end}
        return {CustomTimeDilation=0.8,IsValid=function() return true end,GetAddress=function() return id end,
            PairedPawnMovementComponent=component}
    end
    local host={Pawn=pawn(1),IsValid=function() return true end}
    local adapter={actor=pawn(2),host=function() return host end}
    local prior=Movement.capture(adapter)
    adapter.actor=pawn(3)
    for _,p in ipairs({host.Pawn,adapter.actor}) do
        p.CustomTimeDilation=0
        p.PairedPawnMovementComponent.ticking=false
    end
    Movement.keep(adapter,prior)
    assert(host.Pawn.CustomTimeDilation==0.8 and host.Pawn.PairedPawnMovementComponent.ticking)
    assert(adapter.actor.CustomTimeDilation==0 and not adapter.actor.PairedPawnMovementComponent.ticking)
    assert(prior.host.restored==2 and prior.guest.restored==0)
end)
test("cancelling a crossing leaves the in-flight preload intact",function()
    local Preload=require("lib.door_preload")
    local token={}
    local adapter={door_preload={token=token},experimental_door_preload=token}
    Preload.cancel_crossing(adapter)
    assert(adapter.door_preload.cancelled and adapter.experimental_door_preload==token)
    Preload.stop(adapter)
    assert(not adapter.door_preload and not adapter.experimental_door_preload)
end)
test("durable replacement retains previous file as recovery copy", function()
    assert(native.atomic_write(testRoot .. "/atomic.txt", "old"))
    assert(native.atomic_write(testRoot .. "/atomic.txt", "new"))
    local f = assert(io.open(testRoot .. "/atomic.txt.bak", "rb")); assert(f:read("a") == "old"); f:close()
end)
test("player identity roundtrips without changing text", function()
    assert(store:write("campaign", "slot", player))
    local record = assert(store:read("campaign", "slot")); assert(record.player.name == player.name)
end)
test("sidecar cannot be applied to a different native save", function()
    assert(not store:read("campaign", "other"))
    assert(not Store.valid({schema=1,campaign="campaign",slot="slot",player=player}, "other", "slot"))
end)
test("partial records and path traversal are rejected", function()
    assert(not pcall(store.write, store, "campaign", "slot", {id="player2"}))
    assert(not pcall(store.path, store, "../escape", "slot"))
end)
test("corrupt primary recovers the last valid player record", function()
    assert(store:write("campaign", "slot", player))
    local f = assert(io.open(store:path("campaign", "slot"), "wb")); f:write("{partial"); f:close()
    local record, recovered = store:read("campaign", "slot")
    assert(record and recovered and record.player.actor_ref == player.actor_ref)
end)
test("damaged metadata remains distinguishable from a new co-op save", function()
    local path=store:path("campaign","slot")
    for _,suffix in ipairs({"",".bak"}) do local f=assert(io.open(path..suffix,"wb")); f:write("broken"); f:close() end
    assert(store:exists("campaign","slot")); assert(not store:read("campaign","slot"))
    assert(not store:exists("campaign","other"))
end)
test("saved text is decoded as data, never Lua code", function()
    local marker = "os.execute('should never run')"
    assert(json.decode(json.encode({name=marker})).name == marker)
    assert(not pcall(json.decode, "return os.execute('should never run')"))
end)
local function adapter()
    return {
        ready=true, rollbacks=0, joins=0,
        can_pair=function() return true end,
        host_slot=function() return 0 end,
        world_ready=function(self) return self.ready end,
        join=function(self) self.joins=self.joins+1; return self.result or true end,
        poll_join=function(self) return self.poll_result or "pending", "bridge failed" end,
        rollback=function(self) self.rollbacks=self.rollbacks+1 end,
        suspend=function() end, resume=function() end, leave=function() return true end
    }
end
test("host controller cannot claim the second character", function()
    local a=adapter(); local s=Session.new(a); assert(s:begin()); assert(not s:pair(0)); assert(a.joins == 0)
end)
test("pairing from main menu waits for a loaded world", function()
    local a=adapter(); a.ready=false; local s=Session.new(a); s:begin(); assert(s:pair(1)); assert(s.state=="armed" and a.joins==0)
    a.ready=true; s:tick(); assert(s.state=="active" and a.joins==1)
end)
test("the in-menu appearance survives waiting for gameplay", function()
    local a=adapter()
    a.ready=false
    a.needs_character_setup=function() return true end
    local chosen
    a.join=function(_,slot,race) assert(slot==1); chosen=race; return true end
    local s=Session.new(a)
    assert(s:begin() and s:pair(1,{key="Argonian"}) and s.state=="armed")
    a.ready=true
    s:tick()
    assert(s.state=="active" and chosen=="Argonian")
end)
test("the engine waits for the System menu pause to end before joining", function()
    local Engine=require("lib.engine")
    local previous_find,previous_static=FindAllOf,StaticFindObject
    local paused=true
    FindAllOf=function() return {} end
    StaticFindObject=function()
        return {IsGamePaused=function() return paused end}
    end
    local pawn={IsValid=function() return true end,
        TESRefComponent={IsValid=function() return true end,bIsPaired=true}}
    local e=Engine.new(nil,nil,nil)
    e.host_pc={IsValid=function() return true end,IsInGameConfiguration=function() return true end,Pawn=pawn}
    assert(not e:world_ready())
    paused=false
    assert(e:world_ready())
    pawn.TESRefComponent.bIsPaired=false
    assert(not e:world_ready())
    FindAllOf,StaticFindObject=previous_find,previous_static
end)
test("guest object activation waits for the confirmed target and leaves doors to travel",function()
    local Engine=require("lib.engine")
    local original_find=StaticFindObject
    local cached,door,pressed=10,false,0
    local object={IsValid=function() return true end,GetAddress=function() return 10 end,
        TESRefComponent={IsValid=function() return true end,bIsPaired=true},
        IsA=function(_,class) return class=="/Script/Altar.VActor" or (door and class=="/Script/Altar.VDoor") end}
    local actor={IsValid=function() return true end,GetAttachedActors=function() end,
        GetAimingStartPosition=function() return {X=0,Y=0,Z=0} end}
    local traces={LineTraceSingle=function(_,_,_,_,_,_,_,_,hit)
        hit.HitObjectHandle={Actor={Get=function() return object end}}
        hit.Location={X=50,Y=0,Z=0}
        return true
    end}
    StaticFindObject=function(path)
        if path:match("KismetSystemLibrary") then return traces end
        return path
    end
    local e=Engine.new({clock_ms=function() return 0 end},nil,nil)
    e.actor=actor
    local rotation={Yaw=90,Pitch=0,Roll=0}
    local host={Pawn=actor,IsValid=function() return true end,
        ActivateInput_Pressed=function() pressed=pressed+1 end,
        GetControlRotation=function() return rotation end,
        SetControlRotation=function(_,value) rotation=value end}
    e.host=function() return host end
    e.gameplay_input_enabled=function() return true end
    e.host_activation_target_address=function() return cached end
    e.guest_aim=function() return {X=0,Y=0,Z=0},{X=1,Y=0,Z=0} end
    assert(e:activate_shared_object() and e.activation==2 and pressed==1)
    assert(not e:activate_shared_object() and pressed==1)
    e.activation=nil
    cached=11
    assert(e:activate_shared_object() and pressed==1 and rotation.Yaw==0)
    e:poll_guest_interaction()
    assert(pressed==1)
    cached=10
    e:poll_guest_interaction()
    assert(pressed==2 and rotation.Yaw==90)
    e.activation=nil
    door=true
    assert(not e:activate_shared_object() and pressed==2)
    StaticFindObject=original_find
end)
test("settings require two distinct live controller instances",function()
    local UI=require("lib.ui")
    local chosen
    local ui=UI.new(function(first,second,race,layout)
        chosen={first=first,second=second,race=race.key,layout=layout}
        return true
    end)
    ui.system_enabled=true
    ui.system_original={}
    local s=Session.new(adapter())
    local one={slot=0,instance=32,connected=true}
    local two={slot=1,instance=51,connected=true}
    local pads={one,two}
    ui.system_enabled=false
    ui:system_input(two,16)
    ui.system_enabled=true
    ui:open_setup(s,pads)
    ui:system_input(two,16)
    assert(ui.setup.slots[1]==two and not ui.setup.slots[2])
    ui:system_input(two,2)
    ui:system_input(two,8)
    assert(ui.setup.race==2)
    ui:system_input(two,2)
    ui:system_input(two,8)
    assert(ui.setup.layout==0)
    ui:system_input(one,16)
    assert(ui.system_requested=="pair")
    local replacement={slot=0,instance=88,connected=true}
    assert(not ui:system_action("pair",s,{replacement,two}) and not chosen)
    assert(ui:system_action("pair",s,pads))
    assert(chosen.first==1 and chosen.second==0 and chosen.race=="Argonian" and chosen.layout==0)
end)
test("only the assigned guest can choose the first character's race",function()
    local a=adapter()
    a.needs_character_setup=function() return true end
    local chosen
    a.join=function(_,slot,race)
        assert(slot==1)
        chosen=race
        return true
    end
    local s=Session.new(a)
    assert(s:begin() and s:pair(1) and s.state=="character")
    s:character_input({slot=0,connected=true,buttons=2},0)
    assert(s.race_index==1)
    s:character_input({slot=1,connected=true,buttons=2},0)
    s:character_input({slot=1,connected=true,buttons=2},2)
    assert(s.race_index==2)
    s:character_input({slot=1,connected=true,buttons=4096},0)
    assert(s.state=="active" and chosen=="Argonian")
end)
test("only a unique pristine temporary item can use its stable original",function()
    local clone=require("lib.clone_inventory")
    local original={form_id=0x22B04,type=21,name="Commentaries",count=2,value=40,weight=5}
    local temporary={form_id=0xFF001098,type=21,name="Commentaries",count=2,value=40,weight=5}
    local host,guest={items={original}},{items={temporary}}
    local result=clone.replacements(host,guest)
    assert(#result==1 and result[1].stable==original.form_id and result[1].count==2)
    temporary.equipped=true
    assert(#clone.replacements(host,guest)==0)
    temporary.equipped=false
    original.count=3
    assert(#clone.replacements(host,guest)==0)
end)
test("joining is transactional and cannot report success early", function()
    local a=adapter(); a.result="pending"; local s=Session.new(a); s:begin(); s:pair(1)
    assert(s.state=="joining"); s:tick(); assert(s.state=="joining")
    a.poll_result=true; s:tick(); assert(s.state=="active")
end)
test("join failure rolls back and preserves the host session", function()
    local a=adapter(); a.join=function() error("test failure") end
    local s=Session.new(a); s:begin(); assert(not s:pair(1)); assert(s.state=="pairing" and a.rollbacks==1)
end)
test("join errors keep technical details out of the player banner", function()
    local a=adapter(); a.join=function() error("C:/internal.lua:22 stack traceback: native failure") end
    local s=Session.new(a); s:begin(); s:pair(1)
    assert(not s.status:find("internal",1,true)); assert(not s.status:find("traceback",1,true))
    assert(s.last_error:find("native failure",1,true))
end)
test("reconnect keeps the same actor instead of spawning duplicates", function()
    local a=adapter(); local s=Session.new(a); s:begin(); s:pair(1); s:disconnect()
    assert(s.state=="suspended"); assert(not s:reconnect(0)); assert(s:reconnect(2)); assert(a.joins==1)
end)
test("duplicate join requests are ignored", function()
    local a=adapter(); local s=Session.new(a); s:begin(); s:pair(1); assert(not s:pair(2)); assert(a.joins==1)
end)
test("player one rejects input from the other physical controller", function()
    local Engine=require("lib.engine")
    local calls={}
    local host=setmetatable({IsValid=function() return true end,Pawn={IsValid=function() return false end}},{__index=function(_,name)
        return function() calls[#calls+1]=name end
    end})
    local e=Engine.new(native,store,function() end)
    e.host_pc=host; e.host_controller_slot=1
    assert(e:input_host({slot=0,connected=true,lx=32767,ly=32767,buttons=4096})==false)
    assert(#calls==0)
end)
test("player two rejects input from player one's controller", function()
    local Engine=require("lib.engine")
    local e=Engine.new(native,store,function() end); e.slot=0
    assert(e:input({slot=1,connected=true,lx=32767,buttons=4096},0.016)==false)
end)
test("an older save's companion is never used as a fallback for a different save", function()
    local Engine=require("lib.engine")
    local previous_find=FindAllOf
    FindAllOf=function() return {} end
    local e=Engine.new(native,{read=function() return nil end,exists=function() return false end},function() end)
    e.world_ready=function() return true end
    e.campaign=function() return "campaign" end
    e.save_id=function() return "another_save" end
    e.create_view=function() end
    e.command=function() end
    e.loaded_record={campaign="campaign",player={actor_ref="FF000999"}}
    assert(e:join(1)=="pending"); assert(e.loaded_record==nil)
    FindAllOf=previous_find
end)
test("host travel keeps the exact companion in place until the engine pairs it again",function()
    local Engine=require("lib.engine")
    local record={campaign="campaign",player={actor_ref="FF0010B1"}}
    local e=Engine.new(native,{read=function() return record end},function() end)
    e.world_ready=function() return true end; e.campaign=function() return "campaign" end
    e.gameplay_input_enabled=function() return true end
    e.save_id=function() return "exact-save" end
    e.begin_save_tracking=function(self) assert(self.actor_ref=="FF0010B1" and self.guest_unloaded) end
    local actor
    e.find_actor=function(_,ref) assert(ref=="FF0010B1"); return actor end
    local created=false
    e.create_view=function() created=true end
    e.command=function() error("Host travel must never move or replace the guest") end
    e.transition={campaign="campaign",save_id="exact-save",actor_ref="FF0010B1"}
    assert(e:join(1)==true and e.guest_unloaded and not e.transition and not created)
    assert(e:wait_for_guest() and not created)
    e.next_guest_lookup=0
    actor={IsValid=function() return true end,TESRefComponent={IsValid=function() return true end,bIsPaired=true}}
    e.finish_join=function(self) assert(self.actor==actor and self.actor_ref=="FF0010B1"); return true end
    assert(e:wait_for_guest() and created and not e.guest_unloaded)
end)

test("a different save or companion never becomes the waiting guest",function()
    local Engine=require("lib.engine")
    for _,transition in ipairs({{campaign="other",save_id="exact-save",actor_ref="FF0010B1"},
        {campaign="campaign",save_id="old-save",actor_ref="FF0010B1"},
        {campaign="campaign",save_id="exact-save",actor_ref="FF009999"}}) do
        local e=Engine.new(native,{read=function() return {campaign="campaign",player={actor_ref="FF0010B1"}} end},function() end)
        e.world_ready=function() return true end; e.campaign=function() return "campaign" end
        e.save_id=function() return "exact-save" end; e.find_actor=function() return nil end
        e.create_view=function() error("Wrong-save travel must not create a view") end
        e.command=function() error("Wrong-save travel must not move an actor") end
        e.transition=transition
        local ok,reason=e:join(1)
        assert(ok==false and reason:find("not loaded",1,true))
        assert(not e.guest_unloaded)
    end
end)

test("an active companion survives area travel before the first co-op save",function()
    local Engine=require("lib.engine")
    local e=Engine.new(native,{read=function() return nil end,exists=function() return false end},function() end)
    e.world_ready=function() return true end; e.campaign=function() return "campaign" end
    e.save_id=function() return "single-player-save" end; e.find_actor=function() return nil end
    e.create_view=function() error("Cannot create a view for an unloaded actor") end
    e.command=function() error("Host travel must never move or replace the guest") end
    e.begin_save_tracking=function() end
    e.transition={campaign="campaign",save_id="single-player-save",actor_ref="FF0010B1"}
    assert(e:join(1)==true and e.guest_unloaded)
    assert(e.actor_ref=="FF0010B1" and e.dirty)
    assert(not e.spawn_unresolved,"Travel must not create a replacement copy")
end)

test("the guest can close only the conversation claimed by its own activation",function()
    local Engine=require("lib.engine")
    local now=100
    local e=Engine.new({clock_ms=function() return now end},store,function() end)
    local previous_find=FindAllOf
    local closed,visible=0,true
    local menu={IsValid=function() return true end,GetFullName=function() return "/Engine/Transient.Dialog" end,
        IsActivated=function() return visible end,IsVisible=function() return visible end,
        VDialogueMenuViewModel={IsValid=function() return true end,ButtonsVisibility={bGoodbye=true},
            RegisterSendClickedCloseIcon=function() closed=closed+1 end}}
    FindAllOf=function() return {menu} end
    e:input_shared_dialogue(8192)
    assert(closed==0)
    e.guest_dialogue={deadline=now+2000}
    e:input_shared_dialogue(0)
    assert(e.guest_dialogue.menu==menu)
    e:input_shared_dialogue(8192)
    assert(closed==1)
    visible=false
    e:input_shared_dialogue(0)
    assert(not e.guest_dialogue)
    visible=true
    e:input_shared_dialogue(8192)
    e.guest_dialogue={deadline=now}
    e:input_shared_dialogue(8192)
    assert(closed==1 and not e.guest_dialogue)

    local request,speaker
    e.command=function(_,command) request=tonumber(command:match("^LSSDialogue (%d+)$")) end
    e.native.backend_dialogue=function(id)
        if speaker and id==request then return json.encode({speaker_ref=speaker,request=id}) end
        return nil,"Snapshot pending"
    end
    e.guest_dialogue={deadline=now+2000,speaker_ref=0x1c4c5}
    e:input_shared_dialogue(8192)
    assert(request and not e.guest_dialogue.menu and closed==1)
    speaker=0x14
    e:input_shared_dialogue(8192)
    assert(not e.guest_dialogue and closed==1)

    now=now+1
    e.guest_dialogue={deadline=now+2000,speaker_ref=0x1c4c5}
    speaker=0
    e:input_shared_dialogue(8192)
    local first_request=request
    e:input_shared_dialogue(0)
    assert(e.guest_dialogue and not e.guest_dialogue.menu and closed==1)
    now=now+50
    e:input_shared_dialogue(0)
    assert(request==first_request)
    now=now+50
    e:input_shared_dialogue(0)
    assert(request~=first_request)
    speaker=0x1c4c5
    menu.IsUpdating=true
    e:input_shared_dialogue(0)
    assert(e.guest_dialogue.menu==menu and closed==1)
    menu.IsUpdating=false
    e:input_shared_dialogue(0)
    assert(closed==2)
    FindAllOf=previous_find
end)

test("guest dialogue ignores the host's body while walls and spell targeting still use collision",function()
    local Engine=require("lib.engine")
    local previous_static=StaticFindObject
    local function pawn(id)
        return {IsValid=function() return true end,GetAttachedActors=function() end,BaseEyeHeight=60,
            K2_GetActorLocation=function() return {X=0,Y=0,Z=0} end,
            GetAimingStartPosition=function() return {X=0,Y=0,Z=60} end,
            IsA=function() return true end,IsDead=function() return false end,IsUnconscious=function() return false end,
            GetAddress=function() return id end,
            TESRefComponent={IsValid=function() return true end,bIsPaired=true,
                GetHexFormRefID=function() return {ToString=function() return id end} end}}
    end
    local first,guest,npc=pawn("00000014"),pawn("FF001093"),pawn("0001C4C5")
    local wall,started=true,0
    local traces={
        SphereTraceSingleForObjects=function(_,_,_,_,_,_,_,ignore,_,hit)
            local target=ignore[2]==first and npc or first
            hit.HitObjectHandle={Actor={Get=function() return target end}}
            return true
        end,
        LineTraceSingle=function() return wall end,
    }
    StaticFindObject=function() return traces end
    local cached
    local dialogue_native={clock_ms=native.clock_ms,activation_target_address=function() return cached end}
    local e=Engine.new(dialogue_native,store,function() end)
    e.actor,e.actor_ref=guest,"FF001093"
    e.host=function() return {Pawn=first,IsValid=function() return true end,
        ActivateInput_Pressed=function() started=started+1 end,
        GetControlRotation=function() return {Yaw=0,Pitch=0,Roll=0} end,
        SetControlRotation=function() end} end
    e.gameplay_input_enabled=function() return true end
    e:begin_shared_dialogue()
    assert(started==0)
    wall=false
    assert(e:guest_target(350)=="00000014")
    cached=first:GetAddress()
    e:begin_shared_dialogue()
    assert(started==0 and not e.guest_dialogue)
    cached=npc:GetAddress()
    e:poll_guest_interaction()
    assert(started==1 and e.activation==2 and e.guest_dialogue)

    StaticFindObject=previous_static
end)

test("guest door travel uses one fresh, unlocked link in the same attached cell",function()
    local Engine=require("lib.engine")
    local target,now,snapshot=0x384f,100
    local e=Engine.new({clock_ms=function() return now end,backend_door=function()
        return snapshot and json.encode(snapshot)
    end},store,function() end)
    e.actor_ref="FF001093"
    e.guest_door_target=function() return target end
    local commands={}
    e.command=function(_,command) commands[#commands+1]=command end
    local function request(change)
        target=0x384f
        snapshot=nil
        e:begin_guest_door()
        local pending=assert(e.guest_door)
        snapshot={request=pending.request,actor_ref=target,cell_ref=13920,door={
            has_teleport=true,source_paired=true,destination_paired=true,destination_ref=0x3854,
            destination_cell=13920,source_cell={attached=true},target_cell={attached=true},
            arrival_offset={4.5,78.5,6.5}}}
        if change then change(snapshot) end
        e:poll_guest_door()
    end
    request(function(s) s.door.has_lock_data=true end)
    request(function(s) s.door.has_script=true end)
    request(function(s) s.door.destination_cell=175850 end)
    request(function(s) s.door.target_cell.attached=false end)
    request(function() target=0x2c3ac end)
    request(function() now=now+501 end)
    assert(#commands==6 and not e.dirty)
    request()
    assert(#commands==8 and e.dirty and not e.guest_door)
    assert(commands[8]=="FF001093.moveto 00003854 4.500000 78.500000 6.500000")
    e:poll_guest_door()
    assert(#commands==8)
end)

test("save metadata waits for a new snapshot and a stable completed native file",function()
    local Engine=require("lib.engine")
    local find,open=FindAllOf,io.open
    local identity={A=1,B=2,C=3,D=4}
    local function save(slot,hash)
        return {IsValid=function() return true end,GetFullName=function() return "VAltarSaveGame /Engine/Transient.Test" end,
            SaveGameDetails={CharacterId=identity,SlotName=slot,SaveHash=hash},OblivionData={1,2,3}}
    end
    local snapshots={save("loaded","old")}
    FindAllOf=function(class) assert(class=="VAltarSaveGame"); return snapshots end
    local e=Engine.new(native,store,function() end)
    e.actor={IsValid=function() return true end}; e.actor_ref="FF000123"
    e.campaign_id="00000001000000020000000300000004"
    e.save_directory="test/"
    local id="loaded-id"; e.save_id=function() return id end
    local writes=0; e.on_save=function(_,s) assert(s==snapshots[2]); writes=writes+1 end
    local length=nil
    io.open=function(path) assert(path=="test/new.sav"); if length then return {seek=function() return length end,close=function() end} end end
    e:begin_save_tracking()
    id="new-id"; e:poll_save(1000); assert(writes==0)
    snapshots[2]=save("new","new-hash")
    e:poll_save(2000); assert(writes==0)
    length=100; e:poll_save(3000); e:poll_save(4500); assert(writes==0)
    length=101; e:poll_save(5000); e:poll_save(6500); assert(writes==0)
    e:poll_save(7001); assert(writes==1)
    e:poll_save(10000); assert(writes==1)
    FindAllOf,io.open=find,open
end)
test("inventory refuses another actor's or a stale snapshot before equipping",function()
    local Inventory=require("lib.inventory")
    local commands={}
    local adapter={actor_ref="FF0010B1",command=function(_,cmd) commands[#commands+1]=cmd end}
    local menu=Inventory.new(adapter,nil,nil,2)
    menu.request_id=12; menu.items={{form_id=141757,count=1,type=33,equipped=false}}
    menu.snapshot={actor_ref=20,request=12}; assert(not menu:activate())
    menu.snapshot={actor_ref=0xFF0010B1,request=11}; assert(not menu:activate())
    assert(#commands==0)
end)
test("inventory targets the verified owning actor and uses the native player alias",function()
    local Inventory=require("lib.inventory")
    local commands={}
    local adapter={actor_ref="FF0010B1",native={clock_ms=function() return 100 end},command=function(_,cmd) commands[#commands+1]=cmd end}
    local menu=Inventory.new(adapter,nil,nil,2)
    menu.request_id=12; menu.items={{form_id=141757,count=1,type=33,equipped=false}}
    menu.snapshot={actor_ref=0xFF0010B1,request=12}; assert(menu:activate())
    assert(commands[1]=="FF0010B1.equipitem 000229BD")
    local host=Inventory.new(adapter,nil,nil,1)
    host.request_id=13; host.items={{form_id=141752,count=1,type=33,equipped=true}}
    host.snapshot={actor_ref=20,request=13}; assert(host:activate())
    assert(commands[2]=="player.unequipitem 000229B8")
end)
test("simulation supplies two independent neutral controllers without reading hardware",function()
    local Simulator=require("lib.simulator")
    local source=Simulator.new({poll=function() error("Hardware must not be polled in simulation") end})
    local pads=source:poll()
    assert(pads[1].connected and pads[2].connected and not pads[3].connected)
    assert(pads[1].instance~=pads[2].instance and pads[1].simulated)
    source:set(2,{lx=24000,buttons=4096})
    pads=source:poll(); assert(pads[1].lx==0 and pads[1].buttons==0)
    assert(pads[2].lx==24000 and pads[2].buttons==4096)
    source:reset(); assert(source:poll()[2].buttons==0)
end)
test("standalone combat requests use the authority action path",function()
    local Actions=require("lib.actions")
    local old_name=FName; FName=function(name) return name end
    local requested
    local actor={Role=3,IsValid=function() return true end,IsDeadFromKilled=function() return false end,IsUnconscious=function() return false end,
        StateMachineComponent={GetStateFromTag=function() return {IsValid=function() return true end} end,
            RegisterStateChange=function() error("Autonomous-only requests are ignored in standalone") end,
            SendStateChangeListToServer=function(_,tags) requested=tags[1].TagName end}}
    assert(Actions.request(actor,"LightAttack")); assert(requested=="State.Character.Action.LightAttack")
    actor.WeaponsPairingComponent={GetEquippedWeaponForm=function() return {IsValid=function() return true end} end,
        SetWeaponDrawn=function() error("The animation notify must own the draw transition") end}
    actor.IsWeaponDrawn=function() return false end
    assert(Actions.draw(actor,true)); assert(requested=="State.Character.Action.DrawWeapon")
    FName=old_name
end)
test("door arrival mirrors native Y and follows the paired door's level rotation",function()
    local DoorArrival=require("lib.door_arrival")
    local link={arrival_offset={10,20,-30},arrival_rotation={0,0,math.rad(160)},destination_rotation={0,0,math.rad(45)}}
    local p,r=DoorArrival.resolve(link,{X=100,Y=200,Z=300},{Pitch=0,Yaw=135,Roll=0},90)
    assert(math.abs(p.X-128.575)<1e-6 and math.abs(p.Y-214.2875)<1e-6 and math.abs(p.Z-347.1375)<1e-6)
    assert(math.abs(r.Yaw-(-110))<1e-6)
    assert(not DoorArrival.resolve(link,{X=0,Y=0,Z=0},{Pitch=45,Yaw=0,Roll=0},90))
    link.arrival_offset[1]=math.huge
    assert(not DoorArrival.resolve(link,{X=0,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0},90))
end)
test("native door arrival accepts the adjacent exterior cell only at the actual landing point",function()
    local DoorArrival=require("lib.door_arrival")
    local link={arrival={20582.27,62746.58,3536},destination_cell=114111,target_cell={interior=false}}
    local actor={cell_ref=114110,native_position={20582,62747,3537}}
    assert(DoorArrival.matches_native(link,actor))
    link.target_cell.interior=true
    assert(not DoorArrival.matches_native(link,actor))
    actor.cell_ref=114111
    assert(DoorArrival.matches_native(link,actor))
    actor.interior=false
    assert(not DoorArrival.matches_native(link,actor))
    actor.interior=true
    actor.native_position={20582,63000,3537}
    assert(not DoorArrival.matches_native(link,actor))
    link.source_position={100,200,300}
    actor.native_position={110,180,330}
    local offset=DoorArrival.origin_offset(link,actor)
    assert(offset[1]==10 and offset[2]==-20 and offset[3]==30)
    actor.native_position[1]=900
    assert(not DoorArrival.origin_offset(link,actor))
end)
cleanup()
print(string.format("%d tests passed", passed))
