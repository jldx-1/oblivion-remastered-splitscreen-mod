local Races={
    {label="Copy Player 1"},
    {key="Argonian",label="Argonian"},
    {key="Breton",label="Breton"},
    {key="DarkElf",label="Dark Elf"},
    {key="HighElf",label="High Elf"},
    {key="Imperial",label="Imperial"},
    {key="Khajiit",label="Khajiit"},
    {key="Nord",label="Nord"},
    {key="Orc",label="Orc"},
    {key="Redguard",label="Redguard"},
    {key="WoodElf",label="Wood Elf"},
}

function Races.contains(key)
    if type(key)~="string" then return false end
    for _,choice in ipairs(Races) do
        if choice.key==key then return true end
    end
    return false
end

function Races.apply(actor,key)
    assert(Races.contains(key),"Unknown race")
    local path="/Game/Forms/actors/race/"..key.."."..key
    local race=StaticFindObject(path)
    if not race:IsValid() then
        LoadAsset(path)
        race=StaticFindObject(path)
    end
    assert(race:IsValid(),"Race asset is unavailable")
    local session=StaticConstructObject(StaticFindObject("/Script/Altar.VPhenotypeCustomizationSession"),actor)
    assert(session:IsValid(),"Cannot initialize character customization")
    session:StartFromCharacter(actor,false)
    local ok,err=pcall(session.SetRace,session,race,true)
    session:EndSession()
    assert(ok,err)
    assert(actor:GetRace():GetBPFormID()==race:GetBPFormID(),"Player 2's race did not apply")
end

return Races
