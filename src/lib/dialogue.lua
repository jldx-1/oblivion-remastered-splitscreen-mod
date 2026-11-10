-- Isolated dialogue panels. The backend validates gameplay effects before
-- applying them to the actor who owns the panel.
local Dialogue={}
Dialogue.__index=Dialogue
local json=require("lib.json")
local Layout=require("lib.layout")
local response_table="/Game/Localization/StringTables/ST_ResponseTexts.ST_ResponseTexts"
local dialogue_font="/Game/UI/CommonStyle/Fonts/Font_Kingthings_Localized.Font_Kingthings_Localized"
local topics={{0xC8,"Greeting"},{0x1FDA6,"Imperial City"},{0xD7,"Rumors"},
    {0x45F63,"Give two gold"},{0xD4,"Goodbye"}}
local races={[0x907]="imperial",[0xD43]="redguard",[0x191C0]="orc",[0x191C1]="dark_elf",
    [0x19204]="high_elf",[0x223C7]="khajiit",[0x223C8]="wood_elf",[0x224FC]="breton",
    [0x224FD]="nord",[0x23FE9]="argonian"}
local voice_types={[0]="",[1]="/altvoice",[2]="/beggar"}
local function valid(object) return object and object:IsValid() end

function Dialogue.new(adapter,canvas,tree)
    return setmetatable({adapter=adapter,canvas=canvas,tree=tree,panels={{},{}},
        request=1100000000+adapter.native.clock_ms()%800000000},Dialogue)
end

local function make(tree,class)
    return StaticConstructObject(StaticFindObject("/Script/UMG."..class),tree)
end

function Dialogue:mount(player,panel)
    if valid(panel.frame) then return end
    local frame=make(self.tree,"Border")
    frame:SetBrushColor({R=0.96,G=0.90,B=0.77,A=0.96})
    frame:SetPadding({Left=18,Top=12,Right=18,Bottom=12})
    local slot=self.canvas:AddChildToCanvas(frame)
    slot:SetOffsets({Left=18,Top=0,Right=18,Bottom=0})
    local box=make(self.tree,"VerticalBox")
    frame:AddChild(box)
    panel.frame,panel.title,panel.body=frame,make(self.tree,"TextBlock"),make(self.tree,"TextBlock")
    local stock_font=StaticFindObject(dialogue_font)
    if not valid(stock_font) then LoadAsset(dialogue_font); stock_font=StaticFindObject(dialogue_font) end
    for _,label in ipairs({panel.title,panel.body}) do
        label:SetColorAndOpacity({SpecifiedColor={R=0,G=0,B=0,A=1},ColorUseRule=0})
        local font=label.Font
        if valid(stock_font) then
            font.FontObject=stock_font
            font.TypefaceFontName=FName("Regular-Regular")
        end
        font.Size=24
        label:SetFont(font)
        label:SetAutoWrapText(true)
        box:AddChildToVerticalBox(label):SetPadding({Left=0,Top=0,Right=0,Bottom=4})
    end
end

local function set_text(panel,message)
    panel.body:SetText(FText(message))
end

function Dialogue:close(player)
    local panel=self.panels[player]
    if panel.session then self:stop_voice(panel.session) end
    panel.session=nil
    if valid(panel.frame) then panel.frame:SetVisibility(1) end
end

function Dialogue:destroy()
    for player,panel in ipairs(self.panels) do
        self:close(player)
        if valid(panel.frame) then panel.frame:RemoveFromParent() end
    end
end

local function actor_ref(actor)
    if not valid(actor) then return end
    local component=actor.TESRefComponent
    if valid(component) and component.bIsPaired then
        local value=component:GetHexFormRefID()
        return tonumber(type(value)=="string" and value or value:ToString(),16)
    end
end

function Dialogue:start(player,speaker)
    if not valid(speaker) or not speaker:IsA(StaticFindObject("/Script/Altar.VPairedCharacter"))
        or speaker:IsDead() or speaker:IsUnconscious() then return false end
    local listener=player==1 and self.adapter:host().Pawn or self.adapter.actor
    local speaker_id,listener_id=actor_ref(speaker),actor_ref(listener)
    if not speaker_id or not listener_id or speaker_id==0x14 or speaker_id==tonumber(self.adapter.actor_ref,16) then return false end
    local a,b=speaker:K2_GetActorLocation(),listener:K2_GetActorLocation()
    if (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2>450^2 then return false end
    local other=self.panels[3-player].session
    if other and other.speaker_id==speaker_id then return true end

    local panel=self.panels[player]
    self:mount(player,panel)
    panel.frame.Slot:SetAnchors(Layout.anchors(self.adapter.layout,player,0.60,0.94))
    local session={speaker=speaker,listener=listener,speaker_id=speaker_id,listener_id=listener_id,
        pending={},choices={},index=1,deadline=self.adapter.native.clock_ms()+3000,
        read_only=not self.adapter.experimental_dialogue}
    panel.session=session
    local base=speaker.TESRefComponent.TESForm
    local name=valid(base) and base.FullName:ToString() or "Conversation"
    if name:sub(1,7)=="LOC_FN_" then
        local texts=StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        local label=texts:TextFromStringTable(FName("/Game/Localization/StringTables/ST_FullNames.ST_FullNames"),name):ToString()
        if not label:find("MISSING STRING",1,true) then name=label end
    end
    panel.title:SetText(FText(name))
    set_text(panel,"Finding topics…")
    panel.frame:SetVisibility(4)

    local signed=listener_id>=0x80000000 and listener_id-0x100000000 or listener_id
    local commands={}
    for _,topic in ipairs(topics) do
        if not session.read_only or topic[1]~=0x45F63 then
            self.request=self.request+1
            session.pending[#session.pending+1]={id=self.request,topic=topic}
            commands[#commands+1]=("LSSDialogue %d %d %d %d"):format(self.request,speaker_id,signed,topic[1])
        end
    end
    self.adapter:command(commands)
    return true
end

function Dialogue:responses(session)
    local choices={}
    for _,pending in ipairs(session.pending) do
        local raw=self.adapter.native.backend_dialogue(pending.id)
        if not raw then return false end
        local reply=json.decode(raw)
        if reply.request~=pending.id or reply.speaker_ref~=session.speaker_id
            or reply.listener_ref~=session.listener_id or reply.topic_ref~=pending.topic[1] then return false end
        if #reply.choices>0 then choices[#choices+1]={id=pending.topic[1],name=pending.topic[2],infos=reply.choices} end
    end
    session.choices,session.pending=choices,nil
    return true
end

function Dialogue:response_text(infos)
    local id=FName(response_table)
    if not self.response_keys then
        local strings=StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary")
        if not strings:IsRegisteredTableId(id) then LoadAsset(response_table) end
        if not strings:IsRegisteredTableId(id) then return end
        local keys={}
        for _,key in ipairs(strings:GetKeysFromStringTable(id)) do
            local name=key:get():ToString()
            local info,line=name:match("_([%da-fA-F]+)_Oblivion_RESP(%d+)$")
            if info then
                local ref=tonumber(info,16)
                keys[ref]=keys[ref] or {}
                keys[ref][tonumber(line)]=name
            end
        end
        self.response_keys=keys
    end
    local text=StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    for _,info in ipairs(infos) do
        local keys=self.response_keys[info.info_ref]
        if keys and keys[1] then
            local lines={}
            for index,key in ipairs(keys) do
                local line=text:TextFromStringTable(id,key):ToString()
                if line~="" and not line:find("MISSING STRING",1,true) then
                    lines[#lines+1]={text=line,index=index}
                end
            end
            if #lines>0 then return lines,info.info_ref end
        end
    end
end

function Dialogue:voice_path(speaker,info,line)
    local race=speaker:GetRace()
    local folder=valid(race) and races[race:GetBPFormID()]
    local variant=voice_types[speaker:GetVoiceType()]
    local sex=({[0]="m",[1]="f"})[speaker:GetSex()]
    if not folder or not variant or not sex then return end
    local path="/Game/WwiseAudio/Events/Voice/oblivion/"..folder.."/"..sex..variant
    self.voices=self.voices or {}
    if not self.voices[path] then
        local helpers=StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        local registry=helpers:GetAssetRegistry()
        if not valid(registry) then return end
        local assets,paths={},{}
        if registry:GetAssetsByPath(FName(path),assets,false,false) then
            for _,asset in ipairs(assets) do
                local package=asset:get().PackageName:ToString()
                local name=package:match("/(Play_[^/]+)$")
                local key=name and name:match("_([%da-fA-F]+_%d+)$")
                if key then
                    key=key:lower()
                    if paths[key]==nil then paths[key]=package.."."..name else paths[key]=false end
                end
            end
        end
        self.voices[path]=paths
    end
    return self.voices[path][("%08x_%d"):format(info,line)]
end

function Dialogue:stop_voice(session)
    local voice=session.voice
    if not voice then return end
    session.voice=nil
    local function stop()
        if valid(voice.event) then voice.event:ExecuteAction(0,nil,voice.id,0,4) end
    end
    local delay=250-(self.adapter.native.clock_ms()-voice.posted_at)
    -- Wait until Wwise has registered the playing ID before issuing Stop.
    if delay>0 then ExecuteInGameThreadWithDelay(delay,stop) else stop() end
end

function Dialogue:play_voice(session,line)
    if not line then return end
    local pairing=session.speaker.PawnSoundPairingComponent
    local component=valid(pairing) and pairing.DialogueComponent
    if not valid(component) then return end
    local path=self:voice_path(session.speaker,session.selected_info,line.index)
    if not path then return end
    local event=StaticFindObject(path)
    if not valid(event) then LoadAsset(path); event=StaticFindObject(path) end
    if not valid(event) then return end
    local id=event:PostOnComponent(component,nil,0,true)
    if id and id~=0 then
        session.voice={id=id,event=event,posted_at=self.adapter.native.clock_ms()}
    end
end

local function render_choices(panel,session)
    local rows={}
    for i,choice in ipairs(session.choices) do
        rows[#rows+1]=(i==session.index and ">  " or "    ")..choice.name
    end
    if #rows==0 then rows[1]="No topics available" end
    rows[#rows+1]="D-pad  Select     Cross  Listen     Circle  Close"
    set_text(panel,table.concat(rows,"\n"))
end

function Dialogue:show_line(panel,session)
    self:stop_voice(session)
    local line=session.lines and session.lines[session.line_index]
    local hint=session.lines and session.line_index<#session.lines and "Cross  Next     Circle  Back" or "Cross  Continue     Circle  Back"
    set_text(panel,(line and line.text or "Response text is unavailable").."\n\n"..hint)
    self:play_voice(session,line)
end

function Dialogue:request_selection(panel,session,commit)
    self:stop_voice(session)
    self.request=self.request+1
    session.commit_request=self.request
    session.deadline=self.adapter.native.clock_ms()+3000
    local listener=session.listener_id
    if listener>=0x80000000 then listener=listener-0x100000000 end
    self.adapter:command(("LSSDialogue %d %d %d %d %d %d"):format(self.request,session.speaker_id,listener,
        session.choices[session.index].id,session.selected_info,commit and 1 or 0))
    set_text(panel,"Finishing reply…")
end

function Dialogue:poll_commit(player,panel,session)
    local request=session.commit_request
    local raw=self.adapter.native.backend_dialogue(request)
    local reply=raw and json.decode(raw)
    if reply and reply.request==request and reply.speaker_ref==session.speaker_id
        and reply.listener_ref==session.listener_id and reply.topic_ref==session.choices[session.index].id
        and reply.info_ref==session.selected_info then
        local status=reply.effect.status
        if status=="gift" or status=="payment" then
            if player==2 then self.adapter.dirty=true end
            self:request_selection(panel,session,true)
            return
        end
        session.commit_request,session.reading,session.selected_info=nil,nil,nil
        render_choices(panel,session)
        local messages={applied="Item received.",already_owned="You already have this item.",
            paid=("%d gold given."):format(reply.effect.count or 0),insufficient_gold="You do not have enough gold.",
            unsupported="This reply’s gameplay effect is unavailable in split-screen.",
            ineligible="This reply is no longer available.",out_of_range="Move closer to the speaker and try again.",
            unavailable="The game could not confirm the effect."}
        if messages[status] then set_text(panel,panel.body:GetText():ToString().."\n"..messages[status]) end
    elseif self.adapter.native.clock_ms()>=session.deadline then
        self:close(player)
    end
end

function Dialogue:input(player,pressed)
    local panel=self.panels[player]
    local session=panel.session
    if not session then return false end
    if actor_ref(session.speaker)~=session.speaker_id or actor_ref(session.listener)~=session.listener_id
        or session.speaker:IsDead() or session.speaker:IsUnconscious() then
        self:close(player)
    elseif session.pending then
        if pressed & 8192~=0 then self:close(player)
        elseif self:responses(session) then render_choices(panel,session)
        elseif self.adapter.native.clock_ms()>=session.deadline then
            session.pending=nil
            set_text(panel,"Dialogue unavailable. Circle to close.")
        end
    elseif session.commit_request then
        self:poll_commit(player,panel,session)
    elseif session.reading then
        if pressed & 4096~=0 and session.lines and session.line_index<#session.lines then
            session.line_index=session.line_index+1
            self:show_line(panel,session)
        elseif pressed & 4096~=0 and session.selected_info and not session.read_only then
            self:request_selection(panel,session,false)
        elseif pressed & (4096 | 8192)~=0 then
            self:stop_voice(session)
            session.reading,session.selected_info=nil,nil
            render_choices(panel,session)
        end
    elseif pressed & 8192~=0 then
        self:close(player)
    elseif #session.choices>0 then
        if pressed & 3~=0 then
            local direction=pressed & 2~=0 and 1 or -1
            session.index=(session.index-1+direction)%#session.choices+1
            render_choices(panel,session)
        elseif pressed & 4096~=0 then
            local lines,info=self:response_text(session.choices[session.index].infos)
            session.reading,session.selected_info=true,info
            session.lines,session.line_index=lines,1
            self:show_line(panel,session)
        end
    end
    return true
end

return Dialogue
