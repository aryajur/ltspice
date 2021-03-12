-- Ltspice tester
require("submodsearcher")
lt = require("ltspice")

fs,msg = lt.rawParser("RCtran.raw")
v,d= fs:read({"V(out)"},0,1)
lp = require("lua-plot")

p = lp.plot{}
p:AddSeries(d[0],d[1])
p:Show()
io.read()