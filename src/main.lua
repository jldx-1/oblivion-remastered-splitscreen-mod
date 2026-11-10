local root=assert(debug.getinfo(1,"S").source:sub(2):match("^(.*[/\\])"))
package.path=root.."?.lua;"..root.."?/init.lua;"..package.path
local config=require("config")
local log=function(message) print("[LocalSplitScreen] "..tostring(message).."\n") end
local native=assert(package.loadlib(root.."lss_native_v2.dll","luaopen_lss_native"))()
local simulator
if config.development and config.simulate_controllers then
    simulator=require("lib.simulator").new(native); simulator:install()
    log("Using two simulated controllers for development tests")
end
local Store=require("lib.store")
local Engine=require("lib.engine")
local HostTravel=require("lib.host_travel")
local HostCrossing=require("lib.host_crossing")
local Session=require("lib.session")
local UI=require("lib.ui")
local Layout=require("lib.layout")
local isolated_dir=config.development and os.getenv("LSS_PLAYTEST_USER_DIR")
local profiles=isolated_dir and isolated_dir.."/Profiles"
    or config.user_profiles and assert(native.profile_directory(),"Could not open the split-screen profile directory")
    or root.."../Profiles"
local store=Store.new(profiles,native)
local adapter=Engine.new(native,store,log)
local layout_path=store.root.."/layout.txt"
local layout_file=io.open(layout_path,"rb")
if layout_file then
    local saved=layout_file:read(2)
    layout_file:close()
    if saved=="0" then adapter.layout=Layout.stacked end
end
if isolated_dir then adapter.save_directory=isolated_dir.."/Saved/SaveGames/" end
adapter.experimental_saved_area=simulator~=nil and native.suppressed_transforms()~=nil
adapter.experimental_background_sewer=adapter.experimental_saved_area and isolated_dir
    and os.getenv("LSS_BACKGROUND_SEWER_FIXTURE")=="1"
adapter.experimental_door_travel=adapter.experimental_saved_area
adapter.experimental_in_place_hotel=adapter.experimental_background_sewer
    and os.getenv("LSS_IN_PLACE_HOTEL_FIXTURE")=="1" and os.getenv("LSS_KEEP_PLAZA_GRID_FIXTURE")=="1"
adapter.experimental_upstairs=adapter.experimental_in_place_hotel and os.getenv("LSS_PREPARE_UPSTAIRS_FIXTURE")=="1"
adapter.experimental_dialogue=simulator~=nil and isolated_dir and os.getenv("LSS_SCOPED_DIALOGUE_FIXTURE")=="1"
local session=Session.new(adapter)
local function apply_setup(first,second,choice,layout)
    if not config.companion_prototype then return false,"Split-screen is disabled in this launch." end
    if session.state=="idle" then
        if not session:begin() then return false,session.status end
    end
    if session.state=="pairing" then
        adapter.host_controller_slot=first
        local previous=adapter.layout
        adapter:set_layout(layout)
        local ok=session:pair(second,choice)
        if not ok then adapter:set_layout(previous) end
        return ok,session.status
    end
    if session.state=="active" or session.state=="suspended" then
        local ok,message=adapter:change_guest_race(choice.key)
        if not ok then return false,message end
        adapter.host_controller_slot=first
        if session.state=="suspended" then session:reconnect(second)
        elseif session.slot~=second then session.slot=second; adapter:resume(second) end
        adapter:set_layout(layout)
        return true
    end
    return false,"Wait for the current split-screen setup to finish."
end
local ui=UI.new(function(first,second,choice,layout)
    local ok,message=apply_setup(first,second,choice,layout or adapter.layout)
    if ok and not native.atomic_write(layout_path,tostring(adapter.layout)) then log("Could not save the layout preference") end
    return ok,message
end)
local function hook(name,callback)
    local function run(...)
        local success,message=pcall(callback,...)
        if not success then log(name..": "..tostring(message)) end
    end
    local ok,err=pcall(RegisterHook,name,run)
    if not ok then log("Unavailable hook "..name..": "..tostring(err)) end
end
-- OnAsyncSaveComplete_Delegate runs on a Foreground Worker in this build.
-- Never enter this mod's Lua state from that worker; poll completed saves below.
hook("/Script/Altar.VEnhancedAltarPlayerController:OnLoadStarted",function()
    local preload=adapter.experimental_door_preload
    local host=preload and adapter.host_pc
    local pawn=host and host:IsValid() and host.Pawn
    local expected=preload and ((session.state=="active"
        and (not preload.save_id or (adapter.door_preload and adapter.door_preload.token==preload)))
        or (session.state=="joining" and adapter.saved_area and adapter.saved_area.preload==preload))
    if simulator and expected and not preload.started and native.clock_ms()<preload.deadline
        and adapter:save_id()==(preload.save_id)
        and pawn and pawn:IsValid() and pawn:GetAddress()==preload.host then
        preload.started=native.clock_ms()
        return
    end
    local transition=adapter.transition
    if (session.state=="active" or session.state=="suspended") and adapter.actor_ref then
        transition={actor_ref=adapter.actor_ref,campaign=adapter.campaign_id,save_id=adapter:save_id(),
            race=adapter.guest_race,spell_id=adapter.guest_spell_id,door=HostTravel.take(adapter)}
    end
    adapter.loading=true
    adapter:suspend()
    if session.state=="active" or session.state=="suspended" or session.state=="character" or session.state=="joining" then
        adapter:rollback(); session.state="armed"; session.status="Waiting for the loaded world"
    end
    adapter.actor=nil; adapter.host_pc=nil; adapter.spawn_unresolved=false
    adapter.transition=transition
end)
hook("/Script/Altar.VEnhancedAltarPlayerController:OnLoadFinished",function()
    local preload=adapter.experimental_door_preload
    if preload and preload.started then preload.finished=native.clock_ms() end
    adapter.loading=false
end)
local previous,previous_instances={},{}
local previous_f10=false
local last_time=native.clock_ms()
local next_ui=0
local next_system=0
local next_probe=0
local next_save=0
local last_error=""
local function tick()
    local now=native.clock_ms()
    -- Keep development callbacks on this same Lua/game thread. Scheduling them
    -- from LoopAsync can race UE4SS's Lua callback registry during collection.
    if config.development and now>=next_probe then
        next_probe=now+300
        local path=root.."probe.lua"
        local file=io.open(path,"rb")
        if file then
            file:close()
            local chunk,err=loadfile(path); os.remove(path)
            local ok,result=pcall(function() assert(chunk,err); return chunk() end)
            log("PROBE "..tostring(ok)..": "..tostring(result))
        end
    end
    local dt=math.min(0.05,math.max(0.001,(now-last_time)/1000)); last_time=now
    local pads,error=native.poll()
    if not pads then session.status=error; return end
    if native.focused() or simulator then
        local f10=native.focused() and native.key_down(0x79)
        if f10 and not previous_f10 and not adapter.host_downed and adapter:gameplay_input_enabled() then
            adapter:host():OpenOptionsMenuInput_Pressed()
        end
        previous_f10=f10
        if now>=next_system then
            next_system=now+120
            ui:poll_system_menu(session,pads)
        end
        for _,pad in ipairs(pads) do
            if previous_instances[pad.slot]~=pad.instance then previous[pad.slot]=0 end
            session:character_input(pad,previous[pad.slot])
            ui:system_input(pad,(pad.buttons or 0) & ~(previous[pad.slot] or 0))
            previous[pad.slot]=pad.buttons or 0
            previous_instances[pad.slot]=pad.instance
        end
        if ui.system_requested then
            ui:poll_system_menu(session,pads)
        end
        if session.state~="armed" or HostTravel.resume(adapter,now) then session:tick() end
        if adapter.door_preload then require("lib.door_preload").poll(adapter,now) end
        if adapter.guest_crossing then require("lib.door_travel").poll(adapter,now) end
        if adapter.host_crossing then HostCrossing.poll(adapter,now) end
        adapter:poll_shared_journal(now)
        if (session.state=="active" or session.state=="suspended") and now>=next_save then
            next_save=now+500
            adapter:poll_save(now)
        end
        if session.state=="active" then
            local preload=adapter.experimental_door_preload
            if simulator and preload and preload.movement and preload.started and not preload.finished
                and now-preload.started<6500 then
                require("lib.preload_movement").keep(adapter,preload.movement)
            end
            adapter:input_host(pads[adapter:host_slot()+1],dt)
            local pad=pads[session.slot+1]
            if not pad or not pad.connected then session:disconnect()
            elseif not adapter:input(pad,dt) then
                adapter:rollback(); session.state="armed"; session.status="Waiting for Player 2's character"
            end
        end
    else
        previous_f10=false
        if session.state=="active" then adapter:suspend() end
        for _,pad in ipairs(pads) do previous[pad.slot]=pad.buttons or 0 end
    end
    if session.state=="active" and ui.hud then ui.hud:update_compass(adapter.yaw) end
    if now>=next_ui then ui:update(session); next_ui=now+250 end
end
LoopInGameThreadWithDelay(16,function()
        local ok,err=pcall(tick)
        if not ok then
            local message=tostring(err)
            session.status="Split-screen setup stopped. See LocalSplitScreen log."
            if message~=last_error then log(message); last_error=message end
        end
end)
-- Development-only command runner, used for this local integration test. Not needed to play.
if config.development then
    _G.LSS={native=native,adapter=adapter,session=session,ui=ui,simulator=simulator}
    _G.LSS.test_pair=function(first,second)
        assert(first~=second,"Controllers must be distinct")
        local pads=assert(native.poll())
        assert(pads[first+1].connected and pads[second+1].connected,"Both controllers must be connected")
        assert(session.state=="idle" or session.state=="pairing","A session is already joining or active")
        adapter.host_controller_slot=first
        if session.state=="idle" then assert(session:begin()) end
        return session:pair(second)
    end
end
log("Split Screen menu and HUD loaded")
