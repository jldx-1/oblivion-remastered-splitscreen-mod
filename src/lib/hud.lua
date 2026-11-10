-- Player 2's values come from its paired actor, never the host's HUD model.
local HUD={}
HUD.__index=HUD
local serial=0
local function valid(o) return o and o:IsValid() end
local function make(tree,class)
    serial=serial+1
    return StaticConstructObject(StaticFindObject("/Script/UMG."..class),tree,FName("LSS_HUD_"..class..serial))
end
local function text(tree,value,size)
    local t=make(tree,"TextBlock")
    local font=t.Font; font.Size=size or 12; t:SetFont(font); t:SetText(FText(value))
    return t
end
function HUD.new(tree,canvas)
    local self=setmetatable({rows={}},HUD)
    self.frame=make(tree,"Border")
    self.frame:SetBrushColor({R=0.025,G=0.018,B=0.012,A=0.8})
    self.frame:SetPadding({Left=10,Right=10,Top=8,Bottom=8})
    local box=make(tree,"VerticalBox"); self.frame:AddChild(box)
    self.weapon=text(tree,"",12); box:AddChildToVerticalBox(self.weapon):SetPadding({Left=0,Right=0,Top=0,Bottom=5})
    for i,definition in ipairs({{"Health",8,{R=0.65,G=0.08,B=0.05,A=1}},
        {"Magicka",9,{R=0.08,G=0.28,B=0.7,A=1}},{"Fatigue",10,{R=0.1,G=0.5,B=0.2,A=1}}}) do
        local label=text(tree,"",11); box:AddChildToVerticalBox(label)
        local size=make(tree,"SizeBox"); size:SetHeightOverride(7)
        local bar=make(tree,"ProgressBar"); bar:SetFillColorAndOpacity(definition[3]); size:AddChild(bar)
        box:AddChildToVerticalBox(size):SetPadding({Left=0,Right=0,Top=1,Bottom=4})
        self.rows[i]={name=definition[1],value=definition[2],label=label,bar=bar}
    end
    local hint=text(tree,"△ Draw / sheath   R2 Attack   L2 Block",10)
    box:AddChildToVerticalBox(hint):SetPadding({Left=0,Right=0,Top=4,Bottom=0})
    local size=make(tree,"SizeBox"); size:SetWidthOverride(270); size:AddChild(self.frame)
    local slot=canvas:AddChildToCanvas(size)
    slot:SetAnchors({Minimum={X=1,Y=1},Maximum={X=1,Y=1}})
    slot:SetAlignment({X=1,Y=1}); slot:SetPosition({X=-18,Y=-18}); slot:SetAutoSize(true)
    self.crosshair=text(tree,"·",20)
    local cross=canvas:AddChildToCanvas(self.crosshair)
    cross:SetAnchors({Minimum={X=0.75,Y=0.5},Maximum={X=0.75,Y=0.5}})
    cross:SetAlignment({X=0.5,Y=0.5}); cross:SetAutoSize(true)
    self.frame:SetVisibility(1); self.crosshair:SetVisibility(1)
    return self
end
function HUD:update(session)
    local adapter=session.adapter
    local actor=adapter.actor
    local visible=session.state=="active" and valid(actor) and adapter:gameplay_input_enabled()
    self.frame:SetVisibility(visible and 3 or 1); self.crosshair:SetVisibility(visible and 3 or 1)
    if not visible then return end
    local values=actor.ActorValuesPairingComponent
    for _,row in ipairs(self.rows) do
        local current=values:GetFloatModifiedActorValue(row.value)
        local maximum=math.max(current,values:GetFloatBaseActorValue(row.value),1)
        row.label:SetText(FText(string.format("%s  %.0f / %.0f",row.name,current,maximum)))
        row.bar:SetPercent(math.max(0,math.min(1,current/maximum)))
    end
    local form=actor.WeaponsPairingComponent:GetEquippedWeaponForm()
    local name="Unarmed"
    if valid(form) then
        name=form.FullName:ToString()
        if name=="" or name:sub(1,4)=="LOC_" then
            name=({[0]="One-handed blade",[1]="Two-handed blade",[2]="One-handed blunt weapon",[3]="Two-handed blunt weapon",[4]="Staff",[5]="Bow"})[form.Type] or "Equipped weapon"
        end
    end
    self.weapon:SetText(FText(name..(actor:IsWeaponDrawn() and "  •  Ready" or "  •  Sheathed")))
end
return HUD
