-- Identical native widgets and pane geometry; independent models per character.
local HUD={}; HUD.__index=HUD
local json=require("lib.json")
local Icons=require("lib.icons")
local Layout=require("lib.layout")
local function valid(o) return o and o:IsValid() end
local assets={
 main="/Game/UI/Modern/HUD/Main/WBP_ModernHud_Main.WBP_ModernHud_Main_C",
 reticle="/Game/UI/Modern/HUD/Reticle/WBP_ModernHud_Reticle.WBP_ModernHud_Reticle_C",
}
-- Values from the game's ELegacyHudReticleIcon enum.
local interaction_icons={none=0,pickup=1,object=4,npc=7,door=8}
local button_textures={
 square="/Game/Art/UI/Icons/Icons_Inputs/Prospero/T_Icon_Prospero_Square.T_Icon_Prospero_Square",
 x="/Game/Art/UI/Icons/Icons_Inputs/Xbox/T_Icon_Xbox_X.T_Icon_Xbox_X",
}
local function controller_style(controller)
 local name=(controller or ""):lower()
 if name:find("dualsense",1,true) or name:find("dualshock",1,true) or name:find("playstation",1,true) then
  return "playstation"
 end
 if name:find("xbox",1,true) or name:find("xinput",1,true) then return "xbox" end
end
function HUD.new(_,canvas) return setmetatable({canvas=canvas,screens={},reticles={}},HUD) end
local function owned(widget,screen)
 for _=1,32 do
  if not valid(widget) then return false end
  if widget:GetAddress()==screen:GetAddress() then return true end
  widget=widget:GetOuter()
 end
 return false
end
local function original(class)
 for _,widget in ipairs(FindAllOf(class) or {}) do
  if valid(widget) and widget:GetFullName():find(":PersistentLevel.",1,true) then return widget end
 end
end
local function source_model(mvvm,screen,class)
 if not valid(screen) then return end
 local view=mvvm:K2_GetViewFromUserWidget(screen)
 local model
 if valid(view) then view.Sources:ForEach(function(_,entry)
  local source=entry:get().Source
  if valid(source) and source:GetClass():GetFName():ToString()==class then model=source end
 end) end
 return model
end
local function rebind(mvvm,screen,class,model)
 local count=0
 for _,widget in ipairs(FindAllOf("UserWidget") or {}) do
  if valid(widget) and owned(widget,screen) then
   local view=mvvm:K2_GetViewFromUserWidget(widget)
   if valid(view) then
    view:UninitializeBindings()
    view.Sources:ForEach(function(_,entry)
     local source=entry:get()
     if valid(source.Source) and source.Source:GetClass():GetFName():ToString()==class then
      source.Source=model; source.bSetManually=true
      if source.bAssignedToUserWidgetProperty then widget[source.SourceName:ToString()]=model end
      count=count+1
     end
    end)
    view:InitializeBindings()
   end
  end
 end
 assert(count>0,"Native HUD did not accept a separate "..class)
end
function HUD:mount(adapter)
 self.adapter=adapter; self.screens={}; self.reticles={}; self.last={}
 local host=adapter:host()
 local library=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
 local mvvm=StaticFindObject("/Script/ModelViewViewModel.Default__MVVMSubsystem")
 self.original=original("WBP_ModernHud_Main_C")
 self.original_reticle=original("WBP_ModernHud_Reticle_C")
 self.host_model=assert(source_model(mvvm,self.original,"VHUDMainViewModel"),"Original HUD model unavailable")
 self.host_reticle_model=assert(source_model(mvvm,self.original_reticle,"VHUDReticleViewModel"),"Original reticle model unavailable")
 local function create(asset,player)
  local widget=library:Create(host,StaticFindObject(asset),host)
  assert(valid(widget),"Native HUD asset unavailable")
  widget:SetVisibility(2)
  local pane=self.canvas:AddChildToCanvas(widget)
  pane:SetOffsets({Left=0,Top=0,Right=0,Bottom=0})
  if asset==assets.reticle then
   pane:SetAlignment({X=0.5,Y=0.5}); pane:SetPosition({X=0,Y=0}); pane:SetAutoSize(true)
  end
  return widget
 end
 for player=1,2 do
  self.screens[player]=create(assets.main,player)
  self.reticles[player]=create(assets.reticle,player)
  local model,reticle_model=self.host_model,self.host_reticle_model
  if player==2 then
   model=StaticConstructObject(StaticFindObject("/Script/Altar.VHUDMainViewModel"),self.screens[player])
   reticle_model=StaticConstructObject(StaticFindObject("/Script/Altar.VHUDReticleViewModel"),self.reticles[player])
   self.model,self.reticle_model=model,reticle_model
  end
  rebind(mvvm,self.screens[player],"VHUDMainViewModel",model)
  rebind(mvvm,self.reticles[player],"VHUDReticleViewModel",reticle_model)
  -- These nested native widgets cache the global model in Construct and have
  -- no MVVM view of their own. Point their value reads at the pane's model too.
  for _,name in ipairs({"Health","Magicka","Fatigue"}) do
   self.screens[player]["WBP_ModernHud_"..name].VHUDMainViewModel=model
  end
  local screen=self.screens[player]
  screen.hudmain_root:GetChildAt(2).Slot:SetHorizontalAlignment(3)
  screen.WBP_ModernHud_Compass.Slot:SetHorizontalAlignment(2)
  -- The compass artwork is inset within its own widget as well as the HUD slot.
  screen.WBP_ModernHud_Compass:SetRenderTranslation({X=0,Y=-17})
  for _,stat in ipairs({"Health","Magicka","Fatigue"}) do
   screen["WBP_ModernHud_"..stat]:SetRenderTranslation({X=0,Y=24})
  end
 end
 self.screen=self.screens[2]
 self.actor_address=adapter.actor:GetAddress()
end
function HUD:apply_layout(layout)
 if self.layout==layout then return end
 for player,screen in ipairs(self.screens) do
  local pane=Layout.anchors(layout,player)
  screen.Slot:SetAnchors(pane)
  screen.WBP_ModernHud_Compass.Slot:SetPadding({Left=0,Top=layout==Layout.stacked and 12 or 26,Right=0,Bottom=0})
  local center={X=(pane.Minimum.X+pane.Maximum.X)*0.5,Y=(pane.Minimum.Y+pane.Maximum.Y)*0.5}
  self.reticles[player].Slot:SetAnchors({Minimum=center,Maximum=center})
 end
 self.layout=layout
end
function HUD:field(name,value,refresh)
 if not refresh and self.last[name]==value then return end
 self.last[name]=value; self.model[name]=value
 self.model:K2_BroadcastFieldValueChanged({FieldName=FName(name)})
 self.model:K2_BroadcastFieldValueChanged({FieldName=FName("Get"..name)})
end
function HUD:copy_compass_markers()
 -- The campaign supplies the shared map and quest markers. Copy the native
 -- array so the guest's compass can position them using its own heading.
 self.model.CompassIconMarkers=self.host_model.CompassIconMarkers
 self.model:K2_BroadcastFieldValueChanged({FieldName=FName("CompassIconMarkers")})
 self.model:K2_BroadcastFieldValueChanged({FieldName=FName("GetCompassIconMarkers")})
end
function HUD:update_compass(yaw)
 if valid(self.model) then
  self:field("CompassDirectionValue",((yaw or 0)+90)%360)
 end
end
function HUD:show_status_bars()
 -- Native full-bar fade timers otherwise leave different subsets visible in
 -- each pane. Keep the same three native bars visible for both local players.
 for _,screen in ipairs(self.screens) do
  for _,stat in ipairs({{"Health","HealthBar"},{"Magicka","MagickaBar"},{"Fatigue","FatigueBar"}}) do
   local widget=screen["WBP_ModernHud_"..stat[1]]
   if valid(widget) then
    widget:SetVisibility(4); widget:SetRenderOpacity(1)
    local bar=widget[stat[2]]
    if valid(bar) then
     bar:StopAnimation(bar.FadeOut)
     bar:SetVisibility(4); bar:SetRenderOpacity(1)
     if valid(bar.ProgressBar) then bar.ProgressBar:SetRenderOpacity(1) end
    end
   end
  end
 end
end
function HUD:update_subtitle(visible)
 if visible and not valid(self.original_subtitle) then
  self.original_subtitle=original("WBP_ModernHud_Subtitle_C")
 end
 local source=visible and valid(self.original_subtitle) and self.original_subtitle
 local model=source and source.VHUDSubtitleViewModel
 local line=valid(model) and model.bSubtitleVisibility and model.Subtitle:ToString()
 if not line or line=="" then
  if valid(self.subtitle) then self.subtitle:SetVisibility(1) end
  self.subtitle_text=nil
  return
 end
 if not valid(self.subtitle) then
  self.subtitle=StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"),self.canvas)
  if not valid(self.subtitle) then return end
  local font=self.subtitle.Font
  font.Size=15
  self.subtitle:SetFont(font)
  self.subtitle:SetJustification(1)
  self.subtitle:SetAutoWrapText(true)
  self.subtitle:SetShadowOffset({X=1,Y=1})
  self.subtitle:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
  self.canvas:AddChildToCanvas(self.subtitle):SetOffsets({Left=18,Top=0,Right=18,Bottom=0})
 end
 self.subtitle.Slot:SetAnchors(Layout.anchors(self.adapter.layout,2,0.78,0.90))
 if self.subtitle_text~=line then
  self.subtitle:SetText(model.Subtitle)
  self.subtitle_text=line
 end
 self.subtitle:SetVisibility(4)
end
local function prompt_label(canvas)
 local text=StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"),canvas)
 local font=text.Font
 font.Size=16
 text:SetFont(font)
 text:SetJustification(1)
 text:SetShadowOffset({X=1,Y=2})
 text:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
 return text
end
function HUD:mount_interaction_prompt()
 local function make(class)
  return StaticConstructObject(StaticFindObject("/Script/UMG."..class),self.canvas)
 end
 local box=make("VerticalBox")
 local title=prompt_label(self.canvas)
 box:AddChildToVerticalBox(title):SetHorizontalAlignment(2)
 local row=make("HorizontalBox")
 box:AddChildToVerticalBox(row):SetHorizontalAlignment(2)
 local size=make("SizeBox")
 size:SetWidthOverride(22)
 size:SetHeightOverride(22)
 local button=make("Image")
 size:AddChild(button)
 local slot=row:AddChildToHorizontalBox(size)
 slot:SetPadding({Left=0,Top=0,Right=5,Bottom=0})
 slot:SetVerticalAlignment(2)
 local action=prompt_label(self.canvas)
 row:AddChildToHorizontalBox(action):SetVerticalAlignment(2)
 self.canvas:AddChildToCanvas(box):SetOffsets({Left=12,Top=0,Right=12,Bottom=0})
 self.interaction_prompt,self.interaction_title,self.interaction_row=box,title,row
 self.interaction_button,self.interaction_button_size,self.interaction_action=button,size,action
end
function HUD:interaction_button_label(controller)
 if self.interaction_controller==controller and self.interaction_fallback then
  return self.interaction_fallback
 end
 self.interaction_controller=controller
 local style=controller_style(controller)
 local key=style=="playstation" and "square" or style=="xbox" and "x"
 local path=button_textures[key]
 local texture=path and StaticFindObject(path)
 if path and not valid(texture) then LoadAsset(path); texture=StaticFindObject(path) end
 if valid(texture) then self.interaction_button:SetBrushFromTexture(texture,false) end
 self.interaction_button_size:SetVisibility(valid(texture) and 4 or 1)
 self.interaction_fallback=valid(texture) and "" or (key=="square" and "Square" or key=="x" and "X" or "Left face button")
 return self.interaction_fallback
end
function HUD:update_interaction_prompt(visible)
 local adapter=self.adapter
 local inventory=adapter.inventories and adapter.inventories[2]
 local dialogue=adapter.dialogues and adapter.dialogues.panels[2].session
 if not visible or adapter.guest_downed or adapter.guest_unloaded or adapter.guest_dialogue or dialogue
     or (inventory and inventory.open) or adapter.guest_crossing then
  if valid(self.interaction_prompt) then self.interaction_prompt:SetVisibility(1) end
  self:set_interaction_icon(interaction_icons.none)
  self.next_interaction_prompt=nil
  return
 end
 local now=adapter.native.clock_ms()
 if self.next_interaction_prompt and now<self.next_interaction_prompt then return end
 self.next_interaction_prompt=now+100
 local message=adapter.interaction_notice and now<adapter.interaction_notice_until and adapter.interaction_notice
 if adapter.guest_door or adapter.door_preload then message="Opening door…" end
 local icon=interaction_icons.none
 local action
 if not message then
  local target=adapter:guest_interaction_target()
  if target then
   icon=interaction_icons[target.kind]
   local reference=target.actor.TESRefComponent
   local form=valid(reference) and reference.TESForm
   local name=valid(form) and form.FullName:ToString()
   if name and name:sub(1,7)=="LOC_FN_" then
    local table_id=FName("/Game/Localization/StringTables/ST_FullNames.ST_FullNames")
    local texts=StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    name=texts:TextFromStringTable(table_id,name):ToString()
   end
   if not name or name=="" or name:find("MISSING STRING",1,true) then
    name=({npc="Character",door="Door",object="Object",pickup="Item"})[target.kind]
   end
   action=({npc="Talk",door="Open",object="Use",pickup="Take"})[target.kind]
   message=name
  end
 end
 self:set_interaction_icon(icon)
 if not message then
  if valid(self.interaction_prompt) then self.interaction_prompt:SetVisibility(1) end
  return
 end
 if not valid(self.interaction_prompt) then self:mount_interaction_prompt() end
 self.interaction_prompt.Slot:SetAnchors(Layout.anchors(adapter.layout,2,0.56,0.72))
 if message~=self.interaction_prompt_text then
  self.interaction_title:SetText(FText(message))
  self.interaction_prompt_text=message
 end
 if action then
  local fallback=self:interaction_button_label(adapter.guest_controller_name)
  local label=fallback~="" and fallback.."  "..action or action
  if self.interaction_action_text~=label then
   self.interaction_action:SetText(FText(label))
   self.interaction_action_text=label
  end
 end
 self.interaction_row:SetVisibility(action and 4 or 1)
 self.interaction_prompt:SetVisibility(4)
end
function HUD:update_recovery_prompts(visible)
 local adapter=self.adapter
 local down={adapter.host_downed,adapter.guest_downed}
 local recoveries={adapter.host_recovery,adapter.guest_recovery}
 local deadlines={adapter.host_revive_until,adapter.guest_revive_until}
 local styles={controller_style(adapter.host_controller_name),controller_style(adapter.guest_controller_name)}
 local now=adapter.native.clock_ms()
 self.recovery_prompts=self.recovery_prompts or {}
 self.recovery_shades=self.recovery_shades or {}
 for player=1,2 do
  local shade=self.recovery_shades[player]
  if visible and down[player] then
   if not valid(shade) then
    shade=StaticConstructObject(StaticFindObject("/Script/UMG.Border"),self.canvas)
    shade:SetBrushColor({R=0.10,G=0.10,B=0.10,A=0.40})
    local slot=self.canvas:AddChildToCanvas(shade)
    slot:SetOffsets({Left=0,Top=0,Right=0,Bottom=0})
    slot:SetZOrder(20)
    self.recovery_shades[player]=shade
   end
   shade.Slot:SetAnchors(Layout.anchors(adapter.layout,player))
   shade:SetVisibility(3)
  elseif valid(shade) then shade:SetVisibility(1) end

  local prompt=self.recovery_prompts[player]
  local message
  if visible and down[player] then
   local recovery=recoveries[player]
   if recovery then
    message=recovery.respawn and "Respawning…" or ("Player %d is reviving you…"):format(3-player)
   else
    local style=styles[player]
    local button=style=="playstation" and "Cross" or style=="xbox" and "A" or "Bottom face button"
    local notice=player==2 and adapter.interaction_notice and now<adapter.interaction_notice_until and adapter.interaction_notice
    message=button.."  Respawn now"
    if notice then message=notice.."\n"..message end
    if deadlines[player] then
     message=("Waiting for revive (%ds)\n"):format(math.max(0,math.ceil((deadlines[player]-now)/1000)))..message
    end
    local hold=adapter.revive_hold
    if hold and hold.by==3-player then
     message=message..("\nReviving (%ds)"):format(math.max(0,math.ceil((hold.until_time-now)/1000)))
    end
   end
  elseif visible and (player==1 and down[2] and adapter:can_revive_guest() or player==2 and down[1] and adapter:can_revive_host()) then
   local style=styles[player]
   local button=style=="playstation" and "Square" or style=="xbox" and "X" or "Left face button"
   local hold=adapter.revive_hold
   local seconds=hold and hold.by==player and math.max(0,math.ceil((hold.until_time-now)/1000)) or 10
   message=("Hold %s to revive Player %d (%ds)"):format(button,3-player,seconds)
  end
  if message then
   if not valid(prompt) then
    prompt=prompt_label(self.canvas)
    local slot=self.canvas:AddChildToCanvas(prompt)
    slot:SetOffsets({Left=12,Top=0,Right=12,Bottom=0})
    slot:SetZOrder(21)
    self.recovery_prompts[player]=prompt
   end
   prompt.Slot:SetAnchors(Layout.anchors(adapter.layout,player,0.60,0.78))
   if prompt:GetText():ToString()~=message then prompt:SetText(FText(message)) end
   prompt:SetVisibility(4)
  elseif valid(prompt) then
   prompt:SetVisibility(1)
  end
 end
end
function HUD:set_interaction_icon(icon)
 if valid(self.reticle_model) and self.reticle_model:GetReticleIcon()~=icon then
  self.reticle_model:SetReticleIcon(icon)
 end
end
function HUD:inventory_snapshot(adapter)
 if not adapter:has_inventory_backend() then return end
 if adapter.recover_equipment then return self.inventory end
 local menu=adapter.inventories and adapter.inventories[2]
 if menu and menu.open then return menu.snapshot or self.inventory end
 local now=adapter.native.clock_ms()
 if not self.inventory_request_at or now-self.inventory_request_at>1000 then
  self.inventory_request_at=now; self.inventory_request=now%1000000000
  adapter:command(adapter.actor_ref..".LSSInventory "..self.inventory_request)
 end
 local data=adapter.native.backend_inventory(tonumber(adapter.actor_ref,16))
 if data then
  local snapshot=json.decode(data)
  if snapshot.actor_ref==tonumber(adapter.actor_ref,16) and snapshot.request==self.inventory_request then self.inventory=snapshot end
 end
 return self.inventory
end
function HUD:destroy()
 for _,widgets in ipairs({self.recovery_prompts or {},self.recovery_shades or {}}) do
  for _,widget in pairs(widgets) do if valid(widget) then widget:RemoveFromParent() end end
 end
 self.recovery_prompts,self.recovery_shades=nil,nil
 if valid(self.subtitle) then self.subtitle:RemoveFromParent() end
 self.subtitle,self.subtitle_text,self.original_subtitle=nil,nil,nil
 if valid(self.interaction_prompt) then self.interaction_prompt:RemoveFromParent() end
 self.interaction_prompt,self.interaction_prompt_text,self.next_interaction_prompt=nil,nil,nil
 self.interaction_title,self.interaction_row,self.interaction_button,self.interaction_button_size,self.interaction_action=nil,nil,nil,nil,nil
 self.interaction_controller,self.interaction_fallback,self.interaction_action_text=nil,nil,nil
 for _,widgets in ipairs({self.screens or {},self.reticles or {}}) do
  for _,widget in ipairs(widgets) do if valid(widget) then widget:RemoveFromParent() end end
 end
 if valid(self.screen) then self.screen:RemoveFromParent() end
 local visible=self.adapter and self.adapter:gameplay_input_enabled()
 for _,widget in ipairs({self.original,self.original_reticle}) do
  if valid(widget) then widget:SetVisibility(visible and 4 or 1) end
 end
 self.screens,self.reticles={},{}
 self.layout=nil
 self.inventory,self.inventory_request,self.inventory_request_at=nil,nil,nil
 self.screen,self.model,self.reticle_model,self.actor_address=nil,nil,nil,nil
end
function HUD:update(session)
 local adapter=session.adapter
 if (session.state~="active" and session.state~="suspended") or not valid(adapter.actor) then self:destroy(); return end
 if not valid(self.screen) or self.actor_address~=adapter.actor:GetAddress() then self:destroy(); self:mount(adapter) end
 local visible=adapter:gameplay_input_enabled()
 for _,widgets in ipairs({self.screens,self.reticles}) do
  for _,widget in ipairs(widgets) do widget:SetVisibility(visible and 4 or 1) end
 end
 if valid(self.original) then self.original:SetVisibility(1) end
 if valid(self.original_reticle) then self.original_reticle:SetVisibility(1) end
 self:update_subtitle(visible)
 self:update_interaction_prompt(visible and session.state=="active")
 self:update_recovery_prompts(session.state=="active" and (visible or adapter.host_downed and not adapter.loading))
 if not visible then return end
 self:apply_layout(adapter.layout)
 local values=adapter.actor.ActorValuesPairingComponent
 for _,stat in ipairs({{8,"HealthBarValue"},{9,"MagickaBarValue"},{10,"FatigueBarValue"}}) do
  local current=values:GetFloatModifiedActorValue(stat[1])
  self:field(stat[2],math.max(0,math.min(1,current/math.max(current,values:GetFloatBaseActorValue(stat[1]),1))),true)
 end
 self:field("CurrentMagickaValue",values:GetFloatModifiedActorValue(9))
 self:field("MaxMagickaValue",values:GetFloatBaseActorValue(9))
 self:update_compass(adapter.yaw)
 self:copy_compass_markers()
 self:field("bIsOverencumbered",adapter.actor:IsOverEncumbered())
 local snapshot=self:inventory_snapshot(adapter)
 if snapshot then
  adapter.guest_spellbook=snapshot.spells
  local selected=adapter:guest_spell()
  local spell_icon=selected and Icons.resolve(selected)
  if valid(spell_icon) then
   self:field("SpellIcon",spell_icon)
  elseif self.last.SpellIcon then
   self:field("SpellIcon",CreateInvalidObject())
   self.last.SpellIcon=nil
  end
 end
 local form=adapter.actor.WeaponsPairingComponent:GetEquippedWeaponForm()
 if valid(form) then
  local form_id,bow=form:GetBPFormID(),form.Type==6
  self.reticle_model:SetWeaponTag(adapter.actor.WeaponsPairingComponent:GetEquippedWeaponGameplayTag())
  if snapshot then
   local ammo=0
   for _,item in ipairs(snapshot.items) do
    if item.form_id==form_id and item.equipped then
     if item.health then self:field("WeaponHealth",item.health) end
     local texture=Icons.resolve(item)
     if valid(texture) then self:field("WeaponIcon",texture) end
    end
    if bow and item.type==34 and item.equipped then ammo=item.count end
   end
   self:field("WeaponAmmo",ammo)
   local icon=self.screen.WBP_ModernHud_WeaponIcon
   if valid(icon) then icon:SetAmmoVisibilityOverride(bow) end
  end
 end
 self:show_status_bars()
end
return HUD
