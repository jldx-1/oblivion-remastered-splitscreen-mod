-- Explicit development input source. It does not emulate hardware in Windows.
local Simulator={}; Simulator.__index=Simulator
local fields={"buttons","lx","ly","rx","ry","lt","rt"}
function Simulator.new(native)
    return setmetatable({native=native,samples={{},{}},original=native.poll},Simulator)
end
function Simulator:set(player,sample)
    assert(player==1 or player==2,"Simulation player must be 1 or 2")
    local values={}
    for _,name in ipairs(fields) do
        local value=sample[name] or 0
        assert(type(value)=="number" and value==value,"Invalid simulated controller value")
        values[name]=value
    end
    self.samples[player]=values
end
function Simulator:reset() self.samples={{},{}} end
function Simulator:poll()
    local pads={}
    for slot=0,3 do
        local pad={slot=slot,connected=slot<2,instance=-1-slot,simulated=true,name="Simulated controller "..(slot+1)}
        for _,name in ipairs(fields) do pad[name]=slot<2 and (self.samples[slot+1][name] or 0) or 0 end
        pads[#pads+1]=pad
    end
    return pads
end
function Simulator:install() self.native.poll=function() return self:poll() end end
return Simulator
