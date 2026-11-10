-- Render-only copies of the guest's equipped meshes. The real gear stays
-- attached to the world character for animation, combat, and saving.
local FirstPerson={}
FirstPerson.__index=FirstPerson
local Rig=require("lib.view_rig")
local function valid(o) return o and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local grip_pitch=100
local sine,cosine=math.sin(math.rad(grip_pitch)),math.cos(math.rad(grip_pitch))
local function component(actor,class)
    if not valid(actor) then return end
    for _,entry in ipairs(actor:K2_GetComponentsByClass(class)) do
        local mesh=entry:get()
        if valid(mesh) then return mesh end
    end
end
local function hands(actor)
    local child=actor.HandsChildActorComponent
    if valid(child) and valid(child.ChildActor) then return child.ChildActor.RootSkeletalMeshComponent end
end
function FirstPerson.new()
    return setmetatable({
        view=Rig.new(),
        math=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"),
    },FirstPerson)
end
function FirstPerson:destroy()
    self.view:destroy()
    self.offset,self.weapon=nil,nil
    self.next_sync=nil
end
function FirstPerson:sync_equipment(actor,weapon)
    local view=self.view
    local animated=component(weapon,view.skeletal)
    view:sync("weapon",valid(animated) and animated or component(weapon,view.static),animated)
    local body=actor.MainSkeletalMeshComponent
    view:sync("hands",hands(actor),body)
    local skin=view:sync("skin",body,body)
    if skin then
        -- The body material stores its equipment visibility mask as bytes.
        -- Hide the body sections that the native first-person mesh masks out.
        body.CustomPrimitiveDataInternal.Data:ForEach(function(i,value)
            local scalar=value:get()
            if i==16 then scalar=math.floor(scalar) | 0x3f end
            skin.copy:SetCustomPrimitiveDataFloat(i-1,scalar)
        end)
    end
    local shield=actor.WeaponsPairingComponent:GetEquippedShieldActor()
    local shield_anim=component(shield,view.skeletal)
    view:sync("shield",valid(shield_anim) and shield_anim or component(shield,view.static),shield_anim)
end
function FirstPerson:update(host,actor,camera,now)
    local pairing=actor.WeaponsPairingComponent
    if not valid(pairing) or not actor:IsWeaponDrawn() then self:destroy(); return end
    local weapon=pairing:GetEquippedWeaponActor()
    if not valid(weapon) then self:destroy(); return end
    if not same(self.weapon,weapon) and actor.StateMachineComponent:GetActionState():ToString()~="Idle" then
        self:destroy()
        return
    end
    local view=self.view
    if not view:ensure(host,camera:GetTransform()) then self:destroy(); return end
    if not self.next_sync or now>=self.next_sync or not same(self.weapon,weapon) then
        if not same(self.weapon,weapon) then self.offset=nil end
        self.weapon=weapon
        self.next_sync=now+200
        self:sync_equipment(actor,weapon)
    end
    local equipped=view.meshes.weapon
    if not equipped or not valid(equipped.source) then self:destroy(); return end
    local actor_transform=actor:GetTransform()
    if not self.offset then
        local grip=self.math:MakeRelativeTransform(equipped.source:K2_GetComponentToWorld(),actor_transform).Translation
        -- Rotate the character pose around the grip into the view and keep
        -- the wrist near the lower right. The live animation drives swings.
        local forward,side,down=55,22,-22
        self.offset={X=cosine*forward+sine*down-grip.X,Y=side-grip.Y,Z=-sine*forward+cosine*down-grip.Z}
    end
    local offset=self.offset
    local rotation=self.math:ComposeRotators({Pitch=grip_pitch,Yaw=0,Roll=0},camera:K2_GetActorRotation())
    view.actor:K2_SetActorLocationAndRotation(camera:K2_GetActorLocation(),rotation,false,{},true)
    for _,mesh in pairs(view.meshes) do
        if valid(mesh.source) and valid(mesh.copy) then
            local pose=self.math:MakeRelativeTransform(mesh.source:K2_GetComponentToWorld(),actor_transform)
            local p=pose.Translation
            pose.Translation={X=p.X+offset.X,Y=p.Y+offset.Y,Z=p.Z+offset.Z}
            mesh.copy:K2_SetRelativeTransform(pose,false,{},true)
        elseif valid(mesh.copy) then
            mesh.copy:SetVisibility(false,false)
        end
    end
end
return FirstPerson
