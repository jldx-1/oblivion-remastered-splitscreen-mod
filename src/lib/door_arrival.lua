local DoorArrival={}

-- Native door positions use Oblivion units and the opposite Y axis.
local units=1.42875
local function finite(value)
    return type(value)=="number" and math.abs(value)<math.huge
end
local function triple(value)
    return type(value)=="table" and finite(value[1]) and finite(value[2]) and finite(value[3])
end
local function yaw(value)
    return (value+180)%360-180
end

function DoorArrival.resolve(link,position,rotation,half_height)
    local offset=link.arrival_offset
    local arrival=link.arrival_rotation
    local door=link.destination_rotation
    if not triple(offset) or not triple(arrival) or not triple(door)
        or not finite(position.X) or not finite(position.Y) or not finite(position.Z)
        or not finite(rotation.Pitch) or not finite(rotation.Roll) or not finite(rotation.Yaw)
        or not finite(half_height) or half_height<=0 then return end
    -- Vertical doors allow the paired door yaw to account for level rotation.
    if math.abs(rotation.Pitch)>1 or math.abs(rotation.Roll)>1
        or math.abs(door[1])>0.0175 or math.abs(door[2])>0.0175
        or math.abs(arrival[1])>0.0175 or math.abs(arrival[2])>0.0175 then return end
    local alignment=yaw(rotation.Yaw-math.deg(door[3]))
    local angle=math.rad(alignment)
    local x,y=offset[1]*units,-offset[2]*units
    return {
        X=position.X+x*math.cos(angle)-y*math.sin(angle),
        Y=position.Y+x*math.sin(angle)+y*math.cos(angle),
        Z=position.Z+offset[3]*units+half_height,
    },{Pitch=0,Yaw=yaw(alignment+math.deg(arrival[3])),Roll=0}
end

function DoorArrival.matches_native(link,actor,tolerance)
    local arrival,position=link.arrival,actor.native_position
    if not actor.cell_ref or actor.cell_ref==0 or not triple(arrival) or not triple(position)
        or not link.target_cell or type(link.target_cell.interior)~="boolean" then return false end
    if link.target_cell.interior and actor.cell_ref~=link.destination_cell then return false end
    if actor.interior~=nil and actor.interior~=link.target_cell.interior then return false end
    -- Exterior arrival coordinates can be in an adjacent grid cell.
    return (position[1]-arrival[1])^2+(position[2]-arrival[2])^2+(position[3]-arrival[3])^2<=(tolerance or 32)^2
end

function DoorArrival.origin_offset(link,actor,max_distance)
    local source,position=link.source_position,actor.native_position
    if not triple(source) or not triple(position) then return end
    local x,y,z=position[1]-source[1],position[2]-source[2],position[3]-source[3]
    if x*x+y*y+z*z>(max_distance or 400)^2 then return end
    return {x,y,z}
end

return DoorArrival
