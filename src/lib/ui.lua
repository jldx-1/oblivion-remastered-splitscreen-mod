-- Native menu rows for setup and a hit-test-invisible canvas for player HUDs.
local UI={}
UI.__index=UI
local Races=require("lib.races")
local Layout=require("lib.layout")
local serial=0
local up,down=2,3 -- EUINavigation
local function valid(o) return o and o:IsValid() end
local function make(tree,class)
    serial=serial+1
    local o=StaticConstructObject(StaticFindObject("/Script/UMG."..class),tree,FName("LSS_"..class..serial))
    assert(valid(o),"Cannot create split-screen UI")
    return o
end
local function label(tree,value)
    local widget=make(tree,"TextBlock")
    local font=widget.Font; font.Size=14; widget:SetFont(font)
    widget:SetText(FText(value)); return widget
end
function UI.new(apply)
    return setmetatable({apply=apply},UI)
end
local function controller_name(pad)
    if pad.simulated then return "Simulated "..(pad.slot+1) end
    return "Controller "..(pad.slot+1)
end
local function current_pad(pads,assignment)
    local pad=assignment and pads[assignment.slot+1]
    return pad and pad.connected and pad.instance==assignment.instance and pad
end
function UI:close_setup()
    if not self.setup then return end
    for _,entry in ipairs(self.system_original or {}) do
        if valid(entry.widget) then entry.widget:SetVisibility(entry.visibility) end
    end
    for index,row in ipairs(self.system_rows) do
        if valid(row) then row:SetVisibility(index==1 and 0 or 1) end
    end
    if valid(self.system_hint) then self.system_hint:SetVisibility(1) end
    if valid(self.system_divider) then self.system_divider:SetVisibility(1) end
    self.setup=nil
end
function UI:mount_system_rows(adapter,page)
    local template=page.settings_system_quit_button
    if not valid(template) then return end
    if not self.system_hook then
        RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked",function(context)
            if not self.system_enabled then return end
            local index=self.system_targets and self.system_targets[context:get():GetAddress()]
            if index then self.system_requested=index end
        end)
        self.system_hook=true
    end
    self:close_setup()
    for _,row in ipairs(self.system_rows or {}) do
        if valid(row) then row:RemoveFromParent() end
    end
    if valid(self.system_hint) then self.system_hint:RemoveFromParent() end
    if valid(self.system_divider) then self.system_divider:RemoveFromParent() end
    local host=adapter:host()
    local library=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local box=template:GetParent()
    local original,rows={},{}
    for index=0,box:GetChildrenCount()-1 do
        local child=box:GetChildAt(index)
        original[#original+1]={widget=child,visibility=child:GetVisibility()}
    end
    local divider=make(page.WidgetTree,"SizeBox")
    divider:SetHeightOverride(2)
    local line=make(page.WidgetTree,"Border")
    line:SetBrushColor({R=0.67,G=0.52,B=0.33,A=0.85})
    divider:AddChild(line)
    divider:SetVisibility(1)
    for index=1,7 do
        if index==4 then
            box:AddChildToVerticalBox(divider):SetPadding({Left=2,Top=14,Right=2,Bottom=3})
        end
        local row=library:Create(host,template:GetClass(),host)
        assert(valid(row),"Cannot mount split-screen settings")
        box:AddChildToVerticalBox(row):SetPadding({Left=0,Top=12,Right=0,Bottom=0})
        row:SetVisibility(index==1 and 0 or 1)
        rows[index]=row
    end
    local hint=label(page.WidgetTree,"")
    box:AddChildToVerticalBox(hint):SetPadding({Left=0,Top=12,Right=0,Bottom=0})
    hint:SetVisibility(1)
    self.system_page,self.system_rows,self.system_original,self.system_hint=page,rows,original,hint
    self.system_divider=divider
    self.system_exit_row=template
    self.system_exit=template.SaveLoadButton
    self.system_entry=rows[1].SaveLoadButton
    if valid(self.system_exit) and valid(self.system_entry) then
        self.system_entry:SetIsFocusable(true)
        self.system_exit:SetNavigationRuleExplicit(down,self.system_entry)
        self.system_entry:SetNavigationRuleExplicit(up,self.system_exit)
    end
    self.system_host=host
    self.system_labels={}
end
function UI:open_setup(session,pads)
    local active=session.state=="active" or session.state=="suspended"
    local slots={}
    if active then
        local first=pads[session.adapter:host_slot()+1]
        local second=pads[session.slot+1]
        if first and first.connected then slots[1]=first end
        if second and second.connected then slots[2]=second end
    else
        local first=current_pad(pads,self.menu_controller) or pads[session.adapter:host_slot()+1]
        if first and first.connected then slots[1]=first end
        if not slots[1] then
            for _,pad in ipairs(pads) do
                if pad.connected then slots[1]=pad; break end
            end
        end
    end
    local listen=not slots[1] and 1 or (not slots[2] and 2 or nil)
    self.setup={slots=slots,active=active,race=1,layout=session.adapter.layout or Layout.side_by_side,
        focus=listen and listen+1 or 4,listen=listen,
        notice=session.last_error and session.status or nil}
    for _,entry in ipairs(self.system_original) do entry.widget:SetVisibility(1) end
end
function UI:system_input(pad,pressed)
    if not pad.connected then return end
    local setup=self.setup
    if not setup and (pressed~=0 or math.max(math.abs(pad.lx or 0),math.abs(pad.ly or 0),
            math.abs(pad.rx or 0),math.abs(pad.ry or 0))>12000) then
        self.menu_controller=pad
    end
    if not self.system_enabled then return end
    if not setup then
        local entry,exit,host=self.system_entry,self.system_exit,self.system_host
        local function focused(widget)
            return valid(widget) and (widget:HasAnyUserFocus() or widget:HasFocusedDescendants())
        end
        if pressed & 32768~=0 or (pressed & 4096~=0 and focused(entry)) then
            self.system_requested=1
        elseif pressed & 2~=0 and (focused(exit) or focused(self.system_exit_row)) and valid(entry) then
            entry:SetUserFocus(host)
        elseif pressed & 1~=0 and focused(entry) and valid(exit) then
            exit:SetUserFocus(host)
        end
        return
    end
    if setup.listen and pressed & 16~=0 then
        local player=setup.listen
        local other=setup.slots[3-player]
        if other and other.slot==pad.slot and other.instance==pad.instance then
            setup.notice="Use a different controller for each player."
            return
        end
        setup.slots[player],setup.notice=pad,nil
        setup.listen=player==1 and not setup.slots[2] and 2 or nil
        setup.focus=setup.listen and 3 or 4
        if setup.slots[1] and setup.slots[2] then self.system_requested="pair" end
        return
    end
    local first=setup.slots[1]
    if first and (first.slot~=pad.slot or first.instance~=pad.instance) then return end
    local last=setup.active and 6 or 5
    if pressed & 3~=0 then
        local step=pressed & 1~=0 and -1 or 1
        local focus=setup.focus==7 and last+1 or setup.focus
        focus=(focus-2+step)%(last)+2
        setup.focus=focus>last and 7 or focus
    elseif setup.focus==4 and pressed & 12~=0 then
        local step=pressed & 4~=0 and -1 or 1
        setup.race=(setup.race-1+step)%#Races+1
        setup.notice=nil
        if setup.active then self.system_requested="settings" end
    elseif setup.focus==5 and pressed & 12~=0 then
        setup.layout=1-setup.layout
        setup.notice=nil
        if setup.active then self.system_requested="settings" end
    elseif pressed & (4096 | 32768)~=0 and not self.system_requested then
        self.system_requested=setup.focus
    end
end
function UI:apply_assignments(setup,pads)
    local first=current_pad(pads,setup.slots[1])
    local second=current_pad(pads,setup.slots[2])
    if not first or not second then
        setup.notice="Assign two connected controllers with Options."
        return false
    end
    local ok,message=self.apply(first.slot,second.slot,Races[setup.race],setup.layout)
    if not ok then setup.notice=message end
    return ok
end
function UI:system_action(index,session,pads)
    local setup=self.setup
    if not setup then self:open_setup(session,pads); return false end
    if index=="pair" then return self:apply_assignments(setup,pads) end
    if index=="settings" then self:apply_assignments(setup,pads); return false end
    setup.focus,setup.notice=index,nil
    if index==2 or index==3 then
        setup.listen=index-1
    elseif index==4 then
        setup.race=setup.race%#Races+1
        if setup.active then self:apply_assignments(setup,pads) end
    elseif index==5 then
        setup.layout=1-setup.layout
        if setup.active then self:apply_assignments(setup,pads) end
    elseif index==6 then
        if session:leave() then return true end
        setup.notice=session.status
    elseif index==7 then
        self:close_setup()
    end
    return false
end
function UI:draw_system_rows(session,pads)
    local setup=self.setup
    local labels={}
    if setup then
        for player=1,2 do
            local pad=current_pad(pads,setup.slots[player])
            local description=setup.listen==player and "Press Options now"
                or (pad and controller_name(pad) or "Assign controller")
            labels[player+1]="Player "..player.." controller  -  "..description
        end
        local name=Races[setup.race].label
        if setup.race==1 then
            name=setup.active and "Keep current look" or "Keep saved look or copy Player 1"
        end
        labels[4]="Player 2 character  -  "..name
        labels[5]="Screen layout  -  "..Layout.label(setup.layout)
        labels[6]=setup.active and "Unpair Controllers" or nil
        labels[7]="Back to Save & Load"
        local hint=setup.active and "D-pad: select or change options   |   Cross: confirm"
            or "Choose character and layout, then pair both controllers to start."
        self.system_hint:SetText(FText(setup.notice or hint))
        self.system_hint:SetVisibility(4)
        self.system_divider:SetVisibility(4)
    else
        labels[1]="Split Screen"
    end
    local targets={}
    for index,row in ipairs(self.system_rows) do
        local title=labels[index]
        local visibility=title and 0 or 1
        if row:GetVisibility()~=visibility then row:SetVisibility(visibility) end
        if title then targets[row.SaveLoadButton:GetAddress()]=index end
        if title and setup and setup.focus==index then title=">  "..title end
        if title and self.system_labels[index]~=title then
            self.system_labels[index]=title
            local text=FText(title)
            row.Label=text
            row.SaveLoadButton:SetButtonText(text)
        end
    end
    self.system_targets=targets
end
function UI:poll_system_menu(session,pads)
    local adapter=session.adapter
    local host=adapter:host()
    if not valid(host) or not valid(host.Pawn) then
        self.system_enabled,self.system_visible,self.system_requested=false,false,nil
        self:close_setup()
        return
    end
    if not valid(self.player_menu) then self.player_menu=FindFirstOf("VPlayerMenuViewModel") end
    local vm=self.player_menu
    local page=not adapter.loading and valid(vm) and vm.bIsVisible and vm:GetCurrentPage()
    local system=page==6
    self.system_visible=system
    local inventory=session.state=="active" and adapter.inventories and adapter.inventories[1]
    if inventory and page==1 and not self.open_inventory_at then
        self.open_inventory_at=adapter.native.clock_ms()+2000
        vm:RegisterCloseMenuHandler()
    elseif self.open_inventory_at then
        if not inventory or adapter.loading or system or adapter.native.clock_ms()>self.open_inventory_at then
            self.open_inventory_at=nil
        elseif page~=1 and adapter:gameplay_input_enabled() then
            self.open_inventory_at=nil
            if not inventory.open then inventory:toggle(1) end
        end
    end
    adapter:set_system_fullscreen(system)
    self.system_enabled=false
    if system then
        local settings=self.system_menu
        if not valid(settings) or not settings:IsActivated() then
            settings=nil
            for _,widget in ipairs(FindAllOf("WBP_Modern_SettingsMenu_C") or {}) do
                if valid(widget) and widget:IsActivated() then settings=widget; break end
            end
            self.system_menu=settings
        end
        if valid(settings) and valid(settings.PageSwitcher) then
            local switcher=settings.PageSwitcher.WidgetTree.RootWidget
            local page=valid(switcher) and switcher:GetActiveWidget()
            if valid(page) and page:IsA(StaticFindObject("/Game/UI/Modern/MenuLayer/Settings/Prefabs/WBP_Modern_Settings_SaveLoadPage.WBP_Modern_Settings_SaveLoadPage_C")) then
                if not self.system_rows or not valid(self.system_rows[1]) or not valid(self.system_page)
                    or self.system_page:GetAddress()~=page:GetAddress() then
                    self:mount_system_rows(adapter,page)
                end
                self.system_enabled=self.system_rows~=nil and settings.PopupSlot:GetChildrenCount()==0
                    and page.saveload_popup_sizebox:GetChildrenCount()==0
            end
        end
    end
    local request=self.system_requested
    self.system_requested=nil
    if not self.system_enabled then
        self:close_setup()
        return
    end
    if request and self:system_action(request,session,pads) then
        self:close_setup()
        vm:RegisterCloseMenuHandler()
    else
        self:draw_system_rows(session,pads)
    end
end
function UI:mount()
    if self.mounted and valid(self.screen) and valid(self.canvas) then return true end
    local engine=FindFirstOf("Engine")
    if not valid(engine) or not valid(engine.GameViewport) then return false end
    local gs=StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local host=gs:GetPlayerController(engine.GameViewport,0)
    local class=StaticFindObject("/Game/UI/Original/Prefabs/WBP_OriginalImageTile.WBP_OriginalImageTile_C")
    if not valid(host) or not valid(class) then return false end
    local library=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    self.screen=library:Create(host,class,host)
    assert(valid(self.screen) and valid(self.screen.WidgetTree),"Cannot create split-screen HUD")
    local tree=self.screen.WidgetTree
    local root=make(tree,"CanvasPanel"); tree.RootWidget=root
    self.hud=require("lib.native_hud").new(tree,root)
    self.canvas=root
    self.screen:SetVisibility(3)
    self.screen:AddToViewport(9000)
    self.mounted=true; return true
end
function UI:update_guest_dialogue(adapter,active)
    local dialogue=active and adapter.guest_dialogue
    local menu=dialogue and dialogue.menu
    local vm=valid(menu) and menu:IsActivated() and menu:IsVisible() and menu.VDialogueMenuViewModel
    local copy=self.guest_dialogue_panel
    if not valid(vm) then
        if valid(copy) then copy:RemoveFromParent() end
        self.guest_dialogue_panel,self.guest_dialogue_source=nil,nil
        return
    end
    if not valid(copy) or self.guest_dialogue_source~=menu:GetAddress() then
        if valid(copy) then copy:RemoveFromParent() end
        local library=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        copy=library:Create(adapter:host(),menu:GetClass(),adapter.pc)
        if not valid(copy) then return end
        local slot=self.canvas:AddChildToCanvas(copy)
        slot:SetOffsets({Left=0,Top=0,Right=0,Bottom=0})
        copy:SetVisibility(3)
        copy:SetVDialogueMenuViewModel(vm)
        copy["Update Speaker Name"](copy,vm.SpeakerName)
        copy["Update Subtitle"](copy,vm.Subtitle)
        copy["Update Subtitle Visibility"](copy,vm.bSubtitleVisibility)
        copy["Update Buttons Visibility"](copy,vm.ButtonsVisibility)
        local responses={}
        vm.Responses:ForEach(function(_,entry) responses[#responses+1]=entry:get() end)
        copy["Update Responses"](copy,responses)
        self.guest_dialogue_panel,self.guest_dialogue_source=copy,menu:GetAddress()
    end
    copy.Slot:SetAnchors(Layout.anchors(adapter.layout,2))
    local source,mirror=menu.dialog_scrollbox,copy.dialog_scrollbox
    if valid(source) and valid(mirror) then
        local index=source:GetFocusElementIndex()
        if index>=0 and index<mirror:GetSize() and mirror:GetFocusElementIndex()~=index then
            mirror:SetFocusedElementIndex(index)
        end
    end
end
function UI:update(session)
    if not self:mount() then return end
    local adapter=session.adapter
    if session.state=="active" and not adapter.guest_unloaded then
        if not adapter.inventories and adapter:has_inventory_backend() then
            local Inventory=require("lib.inventory")
            adapter.inventories={Inventory.new(adapter,self.canvas,self.screen.WidgetTree,1),Inventory.new(adapter,self.canvas,self.screen.WidgetTree,2)}
        end
        if not adapter.dialogues and adapter:has_guest_dialogue() then
            adapter.dialogues=require("lib.dialogue").new(adapter,self.canvas,self.screen.WidgetTree)
        end
        if not adapter:gameplay_input_enabled() then
            for _,menu in ipairs(adapter.inventories or {}) do menu:close() end
            if adapter.dialogues then adapter.dialogues:close(1); adapter.dialogues:close(2) end
        end
    elseif adapter.inventories or adapter.dialogues then
        for _,menu in ipairs(adapter.inventories or {}) do menu:destroy() end
        adapter.inventories=nil
        if adapter.dialogues then adapter.dialogues:destroy(); adapter.dialogues=nil end
    end
    self.hud:update(session)
    self:update_guest_dialogue(adapter,session.state=="active" and not adapter.guest_unloaded)
end
function UI:destroy()
    if valid(self.screen) then self.screen:RemoveFromParent() end
    self.screen,self.canvas,self.mounted=nil,nil,false
end
return UI
