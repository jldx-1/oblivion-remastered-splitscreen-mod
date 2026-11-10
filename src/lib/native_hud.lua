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
 if valid(self.subtitle) then self.subtitle:RemoveFromParent() end
 self.subtitle,self.subtitle_text,self.original_subtitle=nil,nil,nil
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
 if not visible then return end
 self:apply_layout(adapter.layout)
 local values=adapter.actor.ActorValuesPairingComponent
 for _,stat in ipairs({{8,"HealthBarValue"},{9,"MagickaBarValue"},{10,"FatigueBarValue"}}) do
  local current=values:GetFloatModifiedActorValue(stat[1])
  self:field(stat[2],math.max(0,math.min(1,current/math.max(current,values:GetFloatBaseActorValue(stat[1]),1))),true)
 end
 self:field("CurrentMagickaValue",values:GetFloatModifiedActorValue(9))
 self:field("MaxMagickaValue",values:GetFloatBaseActorValue(9))
 self:field("CompassDirectionValue",((adapter.yaw or 0)+90)%360)
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
