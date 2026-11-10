-- Player 2's own instance of the stock first-person graph. The camera and
-- equipment follow its sockets; the guest's world mesh still handles combat.
local Rig=require("lib.view_rig")
local Native={}
Native.__index=Native
local one={X=1,Y=1,Z=1}
local identity={Translation={X=0,Y=0,Z=0},Rotation={X=0,Y=0,Z=0,W=1},Scale3D=one}
local function valid(o) return o and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function child_mesh(child)
    if valid(child) and valid(child.ChildActor) then return child.ChildActor.RootSkeletalMeshComponent end
end
local function tag(name) return {TagName=FName(name)} end

function Native.new()
    return setmetatable({view=Rig.new(),math=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"),
        tags=StaticFindObject("/Script/GameplayTags.Default__BlueprintGameplayTagLibrary"),
        gait={walk=tag("Actor.Locomotion.Moving.Walking"),run=tag("Actor.Locomotion.Moving.Running")}},Native)
end

function Native:set_gait(gait)
    if self.active_gait==gait then return end
    local pawn=self.pawn
    if valid(pawn) then
        if self.owned_gait then pawn:RemoveGameplayTag(self.gait[self.active_gait],false) end
        self.owned_gait=false
        local t=self.gait[gait]
        if t and self.tags:IsGameplayTagValid(t) and not self.tags:HasTag(pawn.GameplayTags,t,true) then
            pawn:AddGameplayTag(t)
            self.owned_gait=true
        end
    end
    self.active_gait=gait
end

function Native:destroy()
    self:set_gait(nil)
    self.view:destroy()
    if valid(self.pawn) then
        if valid(self.arm) then self.arm:K2_DestroyComponent(self.pawn) end
        if valid(self.driver) then self.driver:K2_DestroyComponent(self.pawn) end
    end
    self.arm,self.driver,self.pawn,self.asset,self.next_sync=nil,nil,nil,nil,nil
    self.combat_key=nil
end

function Native:ensure(host,pawn)
    local template=host.Pawn.FirstPersonSkeletalMeshComponent
    if not valid(template) or not valid(pawn.MainSkeletalMeshComponent) then return end
    local source=template:GetAnimInstance()
    local body=pawn.MainSkeletalMeshComponent
    local asset=body:GetSkeletalMeshAsset()
    local arm=host.Pawn.FirstPersonCameraSpringArmComponent
    if not valid(source) or not valid(asset) or not valid(arm) then return end
    if not same(self.pawn,pawn) or not same(self.asset,asset) then self:destroy() end
    if not valid(self.driver) then
        self.pawn,self.asset=pawn,asset
        local driver=pawn:AddComponentByClass(self.view.skeletal,false,identity,false)
        if not valid(driver) then return end
        self.driver=driver
        driver:SetVisibility(false,false)
        driver:SetCollisionEnabled(0)
        driver:SetCastShadow(false)
        driver.VisibilityBasedAnimTickOption=0
        driver.bEnableUpdateRateOptimizations=false
        driver:SetSkeletalMeshAsset(asset)
        driver:SetAnimClass(source:GetClass())
        local anim=driver:GetAnimInstance()
        self.socket=arm:GetAttachSocketName()
        if not valid(anim) or not same(anim.PairedPawn,pawn) or not driver:DoesSocketExist(self.socket) then
            self:destroy()
            return
        end
        anim:SetRootMotionMode(2) -- Extract root motion without applying it.
        self.arm=pawn:AddComponentByClass(arm:GetClass(),true,identity,false)
        if not valid(self.arm) or not self.arm:K2_AttachToComponent(driver,self.socket,2,2,2,false) then
            self:destroy()
            return
        end
        self.arm.TargetArmLength=arm.TargetArmLength
        self.arm.SocketOffset=arm.SocketOffset
        self.arm.TargetOffset=arm.TargetOffset
        self.arm.bUsePawnControlRotation=false
        self.arm.bDoCollisionTest=arm.bDoCollisionTest
    end
    return template,body,arm
end

function Native:sync_gear(key,gear,body)
    local mesh=valid(gear) and gear.RootComponent
    local view=self.view
    if not valid(mesh) then view:remove(key); return end
    local skeletal=mesh:IsA(view.skeletal)
    local socket=mesh:GetAttachSocketName()
    if (not skeletal and not mesh:IsA(view.static))
        or not body:DoesSocketExist(socket) or not self.driver:DoesSocketExist(socket) then
        view:remove(key)
        return
    end
    local copy=view:sync(key,mesh,skeletal and mesh or nil)
    if copy then copy.socket=socket end
end

function Native:sync_meshes(pawn,body)
    local view=self.view
    local skin=view:sync("skin",body,self.driver)
    if skin then
        body.CustomPrimitiveDataInternal.Data:ForEach(function(i,value)
            local scalar=value:get()
            if i==16 then scalar=math.floor(scalar) | 0x3f end
            skin.copy:SetCustomPrimitiveDataFloat(i-1,scalar)
        end)
    end
    view:sync("hands",child_mesh(pawn.HandsChildActorComponent),self.driver)
    local pair=pawn.WeaponsPairingComponent
    local drawn=pawn:IsWeaponDrawn()
    local weapon=drawn and pair:GetEquippedWeaponActor()
    local shield=drawn and pair:GetEquippedShieldActor()
    local key=(drawn and "drawn:" or "sheathed:")..(valid(weapon) and weapon:GetAddress() or 0)
    if self.combat_key~=key then
        -- The secondary graph does not receive the player pawn's automatic
        -- locomotion refresh when the weapon moveset changes.
        self.driver:GetAnimInstance():UpdateLocomotionLinkTable()
        self.combat_key=key
    end
    self:sync_gear("weapon",weapon,body)
    self:sync_gear("shield",shield,body)
end

function Native:update(host,pawn,camera,eye,rotation,now,running)
    local template,body,stock_arm=self:ensure(host,pawn)
    if not template then return end
    local view,k=self.view,self.math
    if not view:ensure(host,camera:GetTransform()) then return end
    local velocity=pawn:GetVelocity()
    self:set_gait(pawn.PairedPawnMovementComponent:IsMovingOnGround()
        and velocity.X^2+velocity.Y^2>100 and (running and "run" or "walk") or nil)
    -- The player pawn distributes look pitch across its mesh root and arm.
    local height=host.Pawn.FirstPersonSkeletalMeshRoot.RelativeLocation.Z-host.Pawn.BaseEyeHeight
    local root_location={X=eye.X,Y=eye.Y,Z=pawn:K2_GetActorLocation().Z+pawn.BaseEyeHeight+height}
    local root=k:MakeTransform(root_location,{Pitch=rotation.Pitch*5/6,Yaw=rotation.Yaw,Roll=0},one)
    local relative=k:MakeTransform(template.RelativeLocation,template.RelativeRotation,template.RelativeScale3D)
    local transform=k:ComposeTransforms(relative,root)
    self.driver:K2_SetWorldTransform(transform,false,{},true)
    self.arm:K2_SetRelativeRotation({Pitch=rotation.Pitch/6,Yaw=stock_arm.RelativeRotation.Yaw,
        Roll=stock_arm.RelativeRotation.Roll},false,{},true)
    if not self.next_sync or now>=self.next_sync then
        self.next_sync=now+100
        self:sync_meshes(pawn,body)
    end
    local body_transform=body:K2_GetComponentToWorld()
    for _,mesh in pairs(view.meshes) do
        if valid(mesh.source) and valid(mesh.copy) then
            local pose=transform
            if mesh.socket then
                local offset=k:MakeRelativeTransform(mesh.source:K2_GetComponentToWorld(),body:GetSocketTransform(mesh.socket,0))
                pose=k:ComposeTransforms(offset,self.driver:GetSocketTransform(mesh.socket,0))
            elseif not same(mesh.source,body) then
                local offset=k:MakeRelativeTransform(mesh.source:K2_GetComponentToWorld(),body_transform)
                pose=k:ComposeTransforms(offset,transform)
            end
            mesh.copy:K2_SetWorldTransform(pose,false,{},true)
        elseif valid(mesh.copy) then mesh.copy:SetVisibility(false,false) end
    end
    return self.arm:K2_GetComponentLocation(),self.arm:K2_GetComponentRotation()
end

return Native
