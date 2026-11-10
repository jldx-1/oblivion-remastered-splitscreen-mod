local Compass={}
local fields={"Name","LocalisedName","Angle","Distance","bUser2","Type","bFastTravelEnabled",
    "bUser9","Depth","bIsVisible","bIsThroughLoadDoor","bIsAQuestTarget","bIsThePlayerMarker"}

function Compass.markers(original,records)
    local own,used,result={},{},{}
    for _,marker in ipairs(records) do own[marker.name]=marker end
    for _,marker in ipairs(original) do
        local name=type(marker.Name)=="string" and marker.Name or marker.Name:ToString()
        local current=own[name]
        if current or marker.bIsAQuestTarget or marker.bIsThePlayerMarker then
            local copy={}
            for _,key in ipairs(fields) do copy[key]=marker[key] end
            copy.Name=name
            if current and not marker.bIsAQuestTarget and not marker.bIsThePlayerMarker then
                copy.Angle,copy.Distance=current.angle,current.distance
                used[name]=true
            end
            result[#result+1]=copy
        end
    end
    for _,marker in ipairs(records) do
        if not used[marker.name] then
            result[#result+1]={Name=marker.name,Angle=marker.angle,Distance=marker.distance,Type=marker.type,
                bFastTravelEnabled=marker.flags & 2~=0,bIsVisible=true,Depth=0,
                bUser2=false,bUser9=false,bIsThroughLoadDoor=false,bIsAQuestTarget=false,bIsThePlayerMarker=false}
        end
    end
    return result
end

return Compass
