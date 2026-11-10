-- The native first-person mode hides Player 1's world body globally. Render
-- copies of those hidden parts for Player 2 and exclude the native camera arms
-- from that same view. Player 1 retains their normal first-person meshes.
local Rig=require("lib.view_rig")
local Body={}
Body.__index=Body
local function valid(object) return object and object:IsValid() end
local function children(root)
    local result={}
    if valid(root) then root:GetChildrenComponents(true,result) end
    return result
end
local function set_hidden(native,array,index,component)
    -- UE4SS exposes an array's reflected storage, but its Lua weak-property
    -- setter cannot assign an array element. Use its native weak assignment
    -- on the existing eight-byte slot, with no game-specific field offsets.
    assert(index>=1 and index<=#array and array:GetArrayDataAddress()~=0)
    native.set_weak_component(array:GetArrayDataAddress()+(index-1)*8,component)
end
function Body.new(native)
    return setmetatable({native=native,view=Rig.new(),hidden={},policies={},
        primitive=StaticFindObject("/Script/Engine.PrimitiveComponent"),
        math=StaticFindObject("/Script/Engine.Default__KismetMathLibrary")},Body)
end
function Body:filter(controller,desired)
    local array=controller.HiddenPrimitiveComponents
    for index,address in pairs(self.hidden) do
        local present=index<=#array and array[index]:Get()
        if valid(present) and present:GetAddress()==address then
            if desired[address] then desired[address]=nil
            else
                set_hidden(self.native,array,index,0)
                self.hidden[index]=nil
            end
        else self.hidden[index]=nil end
    end
    local free={}
    for index=1,#array do
        local present=array[index]:Get()
        if valid(present) then desired[present:GetAddress()]=nil
        else free[#free+1]=index end
    end
    for address in pairs(desired) do
        local index=table.remove(free)
        if not index then
            index=#array+1
            -- Accessing the next entry reserves a slot with UE's allocator.
            local entry=array[index]
            assert(#array==index and not entry:Get():IsValid(),"Could not allocate a visibility slot")
        end
        set_hidden(self.native,array,index,address)
        self.hidden[index]=address
    end
end
function Body:restore_animation(address)
    local policy=self.policies[address]
    if not policy then return end
    if valid(policy.source) then
        policy.source.VisibilityBasedAnimTickOption=policy.visibility
        policy.source.bEnableUpdateRateOptimizations=policy.optimized
    end
    self.policies[address]=nil
end
function Body:destroy()
    if valid(self.controller) and next(self.hidden) then self:filter(self.controller,{}) end
    self.controller,self.next_sync=nil,nil
    self.hidden={}
    self.view:destroy()
    for address in pairs(self.policies) do self:restore_animation(address) end
end
function Body:copy_world_mesh(source,seen)
    if not valid(source) or source:IsVisible() or source.bHiddenInGame then return end
    if not source:IsA(self.view.skeletal) or not valid(source:GetSkeletalMeshAsset()) then return end
    local address=source:GetAddress()
    local mesh=self.view:sync(address,source,source)
    if not mesh then return end
    seen[address]=true
    if not self.policies[address] then
        self.policies[address]={source=source,visibility=source.VisibilityBasedAnimTickOption,
            optimized=source.bEnableUpdateRateOptimizations}
        source.VisibilityBasedAnimTickOption=0
        source.bEnableUpdateRateOptimizations=false
    end
    source.CustomPrimitiveDataInternal.Data:ForEach(function(index,value)
        mesh.copy:SetCustomPrimitiveDataFloat(index-1,value:get())
    end)
end
function Body:copy_gripped(key,actor,first,world,filtered)
    local component=valid(actor) and actor.RootComponent
    if not valid(component) or not filtered[component:GetAddress()] then self.view:remove(key); return end
    local socket=component:GetAttachSocketName()
    if not first:DoesSocketExist(socket) or not world:DoesSocketExist(socket)
        or not (component:IsA(self.view.skeletal) or component:IsA(self.view.static)) then
        self.view:remove(key)
        return
    end
    local mesh=self.view:sync(key,component,component:IsA(self.view.skeletal) and component or nil)
    if mesh then mesh.socket=socket end
end
function Body:refresh(pawn,world,controller)
    local filtered={}
    for _,entry in ipairs(children(pawn.FirstPersonSkeletalMeshRoot)) do
        local component=entry:get()
        if valid(component) and component:IsA(self.primitive) then filtered[component:GetAddress()]=true end
    end
    local seen={}
    self:copy_world_mesh(world,seen)
    for _,entry in ipairs(children(world)) do self:copy_world_mesh(entry:get(),seen) end
    for address in pairs(self.policies) do
        if not seen[address] then
            self.view:remove(address)
            self:restore_animation(address)
        end
    end
    local pairing=pawn.WeaponsPairingComponent
    local first=pawn.FirstPersonSkeletalMeshComponent
    self:copy_gripped("weapon",pairing:GetEquippedWeaponActor(),first,world,filtered)
    self:copy_gripped("shield",pairing:GetEquippedShieldActor(),first,world,filtered)
    self:filter(controller,filtered)
end
function Body:update(host,controller,now)
    local pawn=host.Pawn
    local world=pawn.MainSkeletalMeshComponent
    if host.POV~=0 or not valid(world) or world:IsVisible()
        or not valid(pawn.FirstPersonSkeletalMeshComponent) or not valid(pawn.WeaponsPairingComponent) then
        self:destroy()
        return
    end
    if not self.view:ensure(host,pawn:GetTransform()) then self:destroy(); return end
    self.controller=controller
    if not self.next_sync or now>=self.next_sync then
        self.next_sync=now+200
        self:refresh(pawn,world,controller)
    end
    for _,mesh in pairs(self.view.meshes) do
        if valid(mesh.source) and valid(mesh.copy) then
            local transform=mesh.source:K2_GetComponentToWorld()
            if mesh.socket then
                local grip=pawn.FirstPersonSkeletalMeshComponent:GetSocketTransform(mesh.socket,0)
                local offset=self.math:MakeRelativeTransform(transform,grip)
                transform=self.math:ComposeTransforms(offset,world:GetSocketTransform(mesh.socket,0))
            end
            mesh.copy:K2_SetWorldTransform(transform,false,{},true)
        elseif valid(mesh.copy) then mesh.copy:SetVisibility(false,false) end
    end
end
return Body
