-- Separate inventories backed by native actor snapshots. UI never opens the
-- global single-player inventory or sends its item indices to player one's VM.
local Inventory={}; Inventory.__index=Inventory
local json=require("lib.json")
local Icons=require("lib.icons")
local Layout=require("lib.layout")
local function valid(o) return o and o:IsValid() end
local types={[33]=0,[34]=0,[20]=1,[22]=1,[19]=2,[40]=3,[25]=4,[21]=5,[39]=6,[42]=7}
local categories={"All","Weapons","Apparel","Alchemy","Misc"}
local magic=6
local function display_name(texts,name)
    if name:sub(1,7)=="LOC_FN_" then
        local label=texts:TextFromStringTable(FName("/Game/Localization/StringTables/ST_FullNames.ST_FullNames"),name)
        if not label:ToString():find("MISSING STRING",1,true) then return label end
    end
    return FText(name)
end
function Inventory.new(adapter,canvas,tree,player)
    return setmetatable({adapter=adapter,canvas=canvas,tree=tree,player=player,category=1,index=1,buttons=0,objects={},items={},serial=0},Inventory)
end
function Inventory:actor_ref() return self.player==1 and 0x14 or tonumber(self.adapter.actor_ref,16) end
function Inventory:command_ref() return self.player==1 and "player" or string.format("%08X",self:actor_ref()) end
function Inventory:request()
    self.serial=self.serial+1
    self.request_id=(self.adapter.native.clock_ms()+self.serial)%1000000000
    self.requested_at=self.adapter.native.clock_ms(); self.snapshot=nil
    self.adapter:command(string.format("%s.LSSInventory %d",self:command_ref(),self.request_id))
end
function Inventory:mount()
    if valid(self.frame) then return end
    local function make(class) return StaticConstructObject(StaticFindObject("/Script/UMG."..class),self.tree) end
    self.frame=make("Border")
    self.frame:SetBrushColor({R=0.80,G=0.72,B=0.57,A=0.98})
    self.frame:SetPadding({Left=14,Right=14,Top=12,Bottom=12})
    local slot=self.canvas:AddChildToCanvas(self.frame)
    slot:SetOffsets({Left=12,Top=90,Right=12,Bottom=90})
    local box=make("VerticalBox"); self.frame:AddChild(box)
    self.title=make("TextBlock"); self.hint=make("TextBlock")
    for _,label in ipairs({self.title,self.hint}) do
        label:SetColorAndOpacity({SpecifiedColor={R=0.12,G=0.08,B=0.04,A=1},ColorUseRule=0})
        local font=label.Font; font.Size=13; label:SetFont(font)
    end
    box:AddChildToVerticalBox(self.title)
    self.list=make("ListView")
    self.list.EntryWidgetClass=StaticFindObject("/Game/UI/Original/GameMenuLayer/Inventory/MainPart/WBP_OriginalMenu_InventoryEntry.WBP_OriginalMenu_InventoryEntry_C")
    assert(valid(self.list.EntryWidgetClass),"Native inventory row asset is unavailable")
    box:AddChildToVerticalBox(self.list):SetSize({SizeRule=1,Value=1})
    box:AddChildToVerticalBox(self.hint)
    -- Controller navigation is handled per assigned pad; native global menu
    -- callbacks cannot receive mouse events from either pane.
    self.frame:SetVisibility(4)
end
function Inventory:toggle(category)
    if self.open then self:close(); return end
    self:mount(); self.open=true; self.index=1
    self.frame.Slot:SetAnchors(Layout.anchors(self.adapter.layout,self.player))
    self.category=category or (self.category==magic and 1 or self.category)
    self:request(); self.frame:SetVisibility(4)
    self.title:SetText(FText("Player "..self.player.." — Inventory"))
    self.hint:SetText(FText("Loading belongings…"))
end
function Inventory:close()
    self.open=false; self.snapshot=nil; self.items={}; self.objects={}
    if valid(self.list) then self.list:ClearListItems() end
    if valid(self.frame) then self.frame:SetVisibility(1) end
end
function Inventory:destroy()
    self:close()
    if valid(self.frame) then self.frame:RemoveFromParent() end
    self.frame,self.list,self.title,self.hint=nil,nil,nil,nil
end
function Inventory:populate(snapshot)
    self.snapshot=snapshot; self.items={}; self.objects={}
    if self.category==magic then
        self:populate_spells(snapshot.spells or {})
        return
    end
    local forms={}
    for _,form in ipairs(FindAllOf("TESForm") or {}) do
        if valid(form) then local ok,id=pcall(function() return form:GetBPFormID() end); if ok then forms[id]=form end end
    end
    local texts=StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    local gold=0
    for _,item in ipairs(snapshot.items) do
        if item.form_id==15 then gold=item.count end
        local category=types[item.type] or 8
        local keep=self.category==1 or (self.category==2 and category==0) or (self.category==3 and category==1)
            or (self.category==4 and (category==2 or category==3 or category==4)) or (self.category==5 and category>=5)
        if keep then
            local form=forms[item.form_id]
            local name=valid(form) and form.FullName:ToString() or item.name
            if name=="" then name=item.name end
            local props={Name=display_name(texts,name),Price=item.value,Weight=item.weight,Count=item.count,
                Health=item.health or 0,WeaponDamage=item.damage or 0,ArmorRating=item.armor or 0,Type=category,
                bIsEquiped=item.equipped,bIsFavorite=false,InventoryIndex=#self.items,StatusFlags=0,bIsInventoryItem=true,bIsInContainerMenu=false}
            if valid(form) then
                props.form=form
            end
            local icon=Icons.resolve(item)
            if valid(icon) then props.Icon=icon end
            local object=StaticConstructObject(StaticFindObject("/Script/Altar.VOriginalInventoryMenuItem"),self.adapter:host())
            object:SetProperties(props)
            self.items[#self.items+1]=item; self.objects[#self.objects+1]=object
        end
    end
    self.index=math.max(1,math.min(self.index,#self.items))
    self.list:BP_SetListItems(self.objects)
    if #self.items>0 then self.list:SetSelectedIndex(self.index-1) end
    self.title:SetText(FText(string.format("Player %d — %s     Gold: %d",self.player,categories[self.category],gold)))
    self.hint:SetText(FText("↑↓ Select   L1/R1 Category   × Equip / unequip   ○ Close"))
end
function Inventory:populate_spells(spells)
    local texts=StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    local row_class=StaticFindObject("/Script/Altar.VOriginalInventoryMenuItem")
    local ready
    for _,spell in ipairs(spells) do
        local name=display_name(texts,spell.name)
        local selected=spell.form_id==self.adapter.guest_spell_id
        if selected then ready=name:ToString() end
        local props={Name=name,Count=1,InventoryIndex=#self.items,Type=8,
            bIsEquiped=selected,bIsInventoryItem=true}
        local texture=Icons.resolve(spell)
        if valid(texture) then props.Icon=texture end
        local row=StaticConstructObject(row_class,self.adapter:host())
        row:SetProperties(props)
        self.items[#self.items+1]=spell
        self.objects[#self.objects+1]=row
    end
    self.index=math.max(1,math.min(self.index,#self.items))
    self.list:BP_SetListItems(self.objects)
    if #self.items>0 then self.list:SetSelectedIndex(self.index-1) end
    self.title:SetText(FText(ready and ("Player 2 — Magic    Ready: "..ready) or "Player 2 — Magic"))
    self.hint:SetText(FText(#self.items==0 and "No castable spells in Player 2's spellbook."
        or "↑↓ Select   × Ready spell   ○ Close   R1 Cast in game"))
end
function Inventory:activate()
    local snapshot=self.snapshot
    local item=self.items[self.index]
    if self.category==magic then
        if not snapshot or snapshot.request~=self.request_id or not item then return false end
        self.adapter.guest_spell_id=item.form_id
        self.adapter.guest_spellbook=snapshot.spells
        self.adapter.dirty=true
        self:populate(snapshot)
        return true
    end
    if not snapshot or snapshot.actor_ref~=self:actor_ref() or snapshot.request~=self.request_id or not item or item.count<1 then return false end
    if not ({[20]=true,[22]=true,[26]=true,[33]=true,[34]=true})[item.type] then
        self.hint:SetText(FText("This item cannot be equipped.")); return false
    end
    assert(math.type(item.form_id)=="integer" and item.form_id>0 and item.form_id<=0xffffffff)
    self.adapter:command(string.format("%s.%s %08X",self:command_ref(),item.equipped and "unequipitem" or "equipitem",item.form_id))
    if self.player==2 then self.adapter.dirty=true end
    self.refresh_at=self.adapter.native.clock_ms()+400; self.snapshot=nil
    return true
end
function Inventory:input(pad)
    local buttons=pad.buttons or 0
    local function pressed(mask) return (buttons & mask)~=0 and (self.buttons & mask)==0 end
    local was_open=self.open
    if pressed(8192) then self:toggle() end
    if self.player==2 and not self.open and not was_open and pressed(4) then self:toggle(magic) end
    if self.open then
        local now=self.adapter.native.clock_ms()
        -- These columns require native per-instance durability and derived
        -- combat values, which the snapshot does not yet expose. Hide them
        -- instead of presenting zero as a real statistic.
        for _,entry in ipairs(self.list:GetDisplayedEntryWidgets() or {}) do
            local row=entry:get()
            if valid(row) then
                for _,name in ipairs({"inv_entry_health","inv_entry_weapon_damage","inv_entry_armor_rating"}) do
                    if valid(row[name]) then row[name]:SetVisibility(1) end
                end
                for _,name in ipairs({"inv_entry_value","inv_entry_weight"}) do
                    if valid(row[name]) then row[name]:SetVisibility(self.category==magic and 1 or 4) end
                end
            end
        end
        if self.refresh_at and now>=self.refresh_at then self.refresh_at=nil; self:request() end
        if not self.snapshot then
            local data=self.adapter.native.backend_inventory(self:actor_ref())
            if data then
                local snapshot=json.decode(data)
                if snapshot.actor_ref==self:actor_ref() and snapshot.request==self.request_id then self:populate(snapshot) end
            end
            if not self.snapshot and now-self.requested_at>5000 then self.hint:SetText(FText("Inventory unavailable. Close and try again.")) end
        end
        if self.category~=magic and (pressed(256) or pressed(512)) then
            self.category=((self.category-1+(pressed(512) and 1 or -1))%#categories)+1
            self.index=1; if self.snapshot then self:populate(self.snapshot) end
        end
        local direction=((buttons & 2)~=0 or (pad.ly or 0)<-14000) and 1 or (((buttons & 1)~=0 or (pad.ly or 0)>14000) and -1 or 0)
        if direction~=0 and (direction~=self.direction or now>=(self.next_repeat or 0)) and #self.items>0 then
            self.index=((self.index-1+direction)%#self.items)+1
            self.list:SetSelectedIndex(self.index-1); self.list:BP_ScrollItemIntoView(self.objects[self.index])
            self.next_repeat=now+(direction~=self.direction and 320 or 130)
        end
        self.direction=direction
        if pressed(4096) then self:activate() end
    end
    self.buttons=buttons
    return self.open or was_open
end
return Inventory
