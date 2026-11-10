-- Resolve the owned item's native icon path to the corresponding remastered
-- texture. Avoid marshaling soft pointer internals through older UE4SS builds.
local Icons={}
local cache={}
function Icons.resolve(item)
    if type(item.icon_path)~="string" then return end
    local path=item.icon_path:lower():gsub("\\","/"):gsub("^menus/icons/","")
    if not path:match("^[%w_/%-]+%.dds$") then return end
    local directory,name=path:match("^(.-)([^/]+)%.dds$")
    if not name then return end
    local leaf="T_"..name
    local asset="/Game/Art/UI/Icons/Dynamic_Icons/menus/icons/"..directory..leaf.."."..leaf
    local texture=cache[asset]
    if texture==false then return end
    if texture and texture:IsValid() then return texture end
    texture=StaticFindObject(asset)
    if not texture:IsValid() then
        pcall(LoadAsset,asset)
        texture=StaticFindObject(asset)
    end
    if texture:IsValid() and texture:GetClass():GetFName():ToString()=="Texture2D" then cache[asset]=texture; return texture end
    cache[asset]=false
end
return Icons
