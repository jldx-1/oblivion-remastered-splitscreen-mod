local Session = {}
Session.__index = Session
local Races=require("lib.races")
function Session.new(adapter)
    return setmetatable({state = "idle", adapter = adapter, status = "Join Split-Screen", slot = nil}, Session)
end
function Session:begin()
    if self.state ~= "idle" then return false end
    local ok, reason = self.adapter:can_pair()
    if not ok then self.status = reason; return false end
    self.state, self.status = "pairing", "Press Options on the second controller to join"
    return true
end
function Session:pair(slot,choice)
    if self.state ~= "pairing" then return false end
    if slot == self.adapter:host_slot() then self.status = "Use the other controller"; return false end
    if not self.adapter:world_ready() then
        self.state, self.slot = "armed", slot
        self.armed_choice=choice
        self.status = choice and "Player 2 will join when gameplay resumes."
            or "Controller assigned. Load a game or start a new game."
        return true
    end
    if not choice and self.adapter.needs_character_setup and self.adapter:needs_character_setup() then
        self.state,self.slot,self.race_index="character",slot,1
        self.last_error=nil
        self.status="Choose Player 2's race"
        return true
    end
    self.state, self.slot = "joining", slot
    self.last_error=nil
    local ok, result, reason = pcall(self.adapter.join, self.adapter, slot,choice and choice.key)
    if not ok or not result then
        pcall(self.adapter.rollback, self.adapter)
        self.state, self.slot = "pairing", nil
        self.last_error=tostring(ok and reason or result)
        if self.adapter.log then self.adapter.log(self.last_error) end
        self.status = "Could not join. Reopen Split Screen."
        return false
    end
    if result == "pending" then
        self.status = "Preparing player 2..."
    else
        self.state, self.status = "active", "Player 2 joined"
    end
    return true
end
function Session:character_input(pad,previous)
    if self.state~="character" or pad.slot~=self.slot then return end
    if not pad.connected then
        self.state,self.slot="pairing",nil
        self.status="Reconnect Player 2 and press Options"
        return
    end
    local pressed=(pad.buttons or 0) & ~(previous or 0)
    if pressed & 8192~=0 then
        self.state,self.slot="pairing",nil
        self.status="Press Options to join"
    elseif pressed & 4096~=0 then
        local choice=Races[self.race_index]
        self.state="pairing"
        self:pair(pad.slot,choice)
    elseif pressed & 5~=0 then
        self.race_index=(self.race_index-2)%#Races+1
    elseif pressed & 10~=0 then
        self.race_index=self.race_index%#Races+1
    end
end
function Session:tick()
    if self.state == "armed" and self.adapter:world_ready() then
        local slot,choice = self.slot,self.armed_choice
        self.armed_choice=nil
        self.state = "pairing"
        self:pair(slot,choice)
    elseif self.state == "joining" then
        local ok, result, reason = pcall(self.adapter.poll_join, self.adapter)
        if ok and result == "pending" then return end
        if ok and result then self.state, self.status = "active", "Player 2 joined"; return end
        pcall(self.adapter.rollback, self.adapter)
        self.state, self.slot = "pairing", nil
        self.last_error=tostring(ok and reason or result)
        if self.adapter.log then self.adapter.log(self.last_error) end
        self.status = "Could not join. Reopen Split Screen."
    end
end
function Session:disconnect()
    if self.state ~= "active" then return end
    self.adapter:suspend()
    self.state, self.status = "suspended", "Player 2 disconnected. Reassign in Split Screen."
end
function Session:reconnect(slot)
    if self.state ~= "suspended" or slot == self.adapter:host_slot() then return false end
    self.slot = slot
    self.adapter:resume(slot)
    self.state, self.status = "active", "Player 2 reconnected"
    return true
end
function Session:leave()
    if self.state == "joining" then return false end
    if self.state == "active" or self.state == "suspended" then
        local ok, reason = self.adapter:leave()
        if not ok then self.status = reason; return false end
    else
        self.adapter:rollback()
    end
    self.state, self.slot, self.status = "idle", nil, "Join Split-Screen"
    self.armed_choice=nil
    return true
end
return Session
