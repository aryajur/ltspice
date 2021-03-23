-- Ltspice tester
require("submodsearcher")
lt = require("ltspice.waveparser")

fs,msg = lt.rawParser("RCtran.raw")
d= fs:read({"V(out)"},0,1)
lp = require("lua-plot")

p = lp.plot{}
p:AddSeries(d[0],d[1])
p:Show()
io.read()

-- Do the energy measurements
-- Get V(in), I(V1), V(out)
vars = {"V(in)","V(out)","I(V1)"}
d = fs:read(vars,0,1)

-- Find the input energy
Ein = fs:getEnergy(d[0],d[1],nil,d[3])

-- Energy dissipated in the resistor
Er = fs:getEnergy(d[0],d[1],d[2],d[3])

-- Energy going into the capacitor
Ec = fs:getEnergy(d[0],d[2],nil,d[3])

print("Input Energy:",Ein)
print("Resistor Energy:",Er)
print("Capacitor Energy:",Ec)
