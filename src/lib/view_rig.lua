-- An unpaired render actor for meshes that only belong in Player 2's view.
local Rig={}
Rig.__index=Rig
local function valid(object) return object and object:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local identity={Translation={X=0,Y=0,Z=0},Rotation={X=0,Y=0,Z=0,W=1},Scale3D={X=1,Y=1,Z=1}}

function Rig.new()
    return setmetatable({
        static=StaticFindObject("/Script/Engine.StaticMeshComponent"),
        skeletal=StaticFindObject("/Script/Engine.SkeletalMeshComponent"),
        meshes={},
    },Rig)
end
function Rig:ensure(host,transform)
    local owner=host:GetViewTarget()
    if not valid(owner) then return false end
    if not valid(self.actor) then
        local gs=StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local rig=gs:BeginDeferredActorSpawnFromClass(host,StaticFindObject("/Script/Engine.CameraActor"),transform,2,owner,0)
        if not valid(rig) then return false end
        self.actor=gs:FinishSpawningActor(rig,transform,0)
        if not valid(self.actor) then return false end
    end
    if not same(self.owner,owner) then
        self.actor:SetOwner(owner)
        self.owner=owner
    end
    return true
end
function Rig:remove(key)
    local mesh=self.meshes[key]
    if mesh and valid(mesh.copy) then
        mesh.copy:SetVisibility(false,false)
        if valid(self.actor) then mesh.copy:K2_DestroyComponent(self.actor) end
    end
    self.meshes[key]=nil
end
function Rig:destroy()
    if not self.actor then return end
    for _,mesh in pairs(self.meshes) do
        if valid(mesh.copy) then mesh.copy:SetVisibility(false,false) end
    end
    if valid(self.actor) then self.actor:K2_DestroyActor() end
    self.actor,self.owner=nil,nil
    self.meshes={}
end
function Rig:sync(key,source,leader)
    local skeletal=valid(leader)
    local asset=valid(source) and (skeletal and source:GetSkeletalMeshAsset() or source.StaticMesh)
    local mesh=self.meshes[key]
    if mesh and same(mesh.source,source) and same(mesh.asset,asset) and valid(mesh.copy) then return mesh end
    self:remove(key)
    if not valid(asset) then return end
    local copy=self.actor:AddComponentByClass(skeletal and self.skeletal or self.static,false,identity,false)
    if not valid(copy) then return end
    if skeletal then
        copy:SetSkeletalMeshAsset(asset)
        copy:SetLeaderPoseComponent(leader,true,false)
    else
        copy:SetStaticMesh(asset)
        -- The fallback mesh respects the per-view owner filter.
        copy:SetForceDisableNanite(true)
    end
    for i=0,source:GetNumMaterials()-1 do
        local material=source:GetMaterial(i)
        if valid(material) then copy:SetMaterial(i,material) end
    end
    copy:SetCollisionEnabled(0)
    copy:SetCastShadow(false)
    copy:SetOwnerNoSee(true)
    mesh={source=source,asset=asset,copy=copy}
    self.meshes[key]=mesh
    return mesh
end
return Rig
