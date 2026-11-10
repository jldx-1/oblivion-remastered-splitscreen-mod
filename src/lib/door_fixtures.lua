local hotel={entrance=0x2c3ac,exit=0x2b092,cell=0x2aeea,level="L_ICTalosPlazaTheTiberSeptimHotel_LevelInstance"}
local sewers={entrance=0x671f7,exit=0x97166,cell=0x96ac3,level="L_ImperialSewerSystemTalosPlaza_LevelInstance"}
local upstairs={cell=0x3ad17,level="L_ICTalosPlazaTheTiberSeptimHotelUpstairs_LevelInstance"}
local entries={hotel,sewers}
local Fixtures={hotel=hotel,sewers=sewers,upstairs=upstairs}
local streamed_door={
    [hotel.exit]={hotel,-27294035,1268425133,1099977104,1018543723},
    [sewers.exit]={sewers,-1313803467,1319545238,-1079013954,2138736203},
}
local streamed_stair_door={
    [0x3ade6]={hotel,2064545008,1118306183,-703276127,1171546621},
    [0x3adeb]={upstairs,1797009852,1106174957,-507023200,-1861179952},
    [0x3c3c1]={hotel,1008932136,1260642189,1566448268,-68009589},
    [0x3c7ef]={upstairs,-962454116,1145959008,-1233753666,1509041493},
}

local function streamed_reference(doors,name,guid)
    for ref,authored in pairs(doors) do
        if name:find("/"..authored[1].level.."_LSS.",1,true) and guid.A==authored[2] and guid.B==authored[3]
            and guid.C==authored[4] and guid.D==authored[5] then return ref end
    end
end

function Fixtures.door_reference(adapter,door)
    local component=door.TESRefComponent
    if not component or not component:IsValid() then return end
    if component.bIsPaired then
        local id=component:GetHexFormRefID()
        if type(id)~="string" then id=id:ToString() end
        id=id:gsub("^0[xX]","")
        if #id==8 and id:match("^%x+$") then return tonumber(id,16) end
        return
    end
    if not adapter.experimental_background_sewer or os.getenv("LSS_KEEP_PLAZA_GRID_FIXTURE")~="1"
        or component.FormIDInstance~=0 then return end
    -- Background instances can have the exterior runtime cell name. The
    -- authored GUID and instance package still identify these exact doors.
    local name=door:GetFullName()
    local guid=component.Guid
    return streamed_reference(streamed_door,name,guid)
        or adapter.experimental_upstairs and streamed_reference(streamed_stair_door,name,guid)
end

function Fixtures.rendered_door(adapter,ref)
    for _,door in ipairs(FindAllOf("VDoor") or {}) do
        if door:IsValid() and Fixtures.door_reference(adapter,door)==ref then return door end
    end
end

function Fixtures.includes(ref)
    for _,fixture in ipairs(entries) do
        if ref==fixture.entrance or ref==fixture.exit then return true end
    end
end

function Fixtures.visible(fixture)
    for _,stream in ipairs(FindAllOf("VLevelStreaming") or {}) do
        if stream:IsValid() and stream:IsLevelLoaded() and stream:IsLevelVisible() then
            local level=stream:GetLoadedLevel()
            if level:IsValid() and level:GetFullName():find(fixture.level,1,true) then
                return true
            end
        end
    end
end

function Fixtures.match(source,link)
    for _,fixture in ipairs(entries) do
        local entering=source==fixture.entrance and link.destination_ref==fixture.exit and link.destination_cell==fixture.cell
        local leaving=source==fixture.exit and link.destination_ref==fixture.entrance
        if entering or leaving then return fixture end
    end
end

return Fixtures
