-- LTSpice parser utilities

local type = type
local getmetatable = getmetatable
local setmetatable = setmetatable
local tonumber = tonumber
local tostring = tostring

local table = table
local io = io
local math = math

local winapi = require("winapi")	-- To convert UTF16 to UTF8 encoding
local vstruct = require("vstruct")	-- To read the binary byte data

local print = print

-- Create the module table here
local M = {}
package.loaded[...] = M
_ENV = M		-- Lua 5.2+

_VERSION = "1.21.06.11"	

-- File handling functions

-- To close the file
local function close(fs)
	if not type(fs) == "table" or not getmetatable(fs) or not getmetatable(fs).v == _VERSION then
		return
	end
	local fsmeta = getmetatable(fs)
	if not fsmeta.fileHandle then
		return nil, "File already closed"
	end
	fsmeta.fileHandle:close()
	fsmeta.fileHandle = nil
	return true		
end

-- Function to read the transient plot data
-- fs is the file structure
-- vars are the list of variables for which the data is required
-- start is the starting time - all data >= this time is returned
-- stop is the stop time - all data <= this time is returned
-- maxpoints is the maximum number of points to be returned. If nil then all points returned
local function read_transient(fs,vars,start,stop,maxpoints)
	if not type(vars) == "table" then
		return nil,"2nd argument should be list of variables whose data needs to be extracted."
	end
	local data = {[0]={}}
	local fm = getmetatable(fs)
	local fH = fm.fileHandle
	if not fH then
		return nil, "File already closed"
	end
	local offset = {}	-- To store the data offsets
	-- Each offset should correspond to the vars entry
	for i = 1,#vars do
		offset[i] = 0
	end
	
	for i = #vars,1,-1 do
		local found
		for j = 1,#fs.vars do
			if fs.vars[j] == vars[i] then
				found = true
				offset[i] = j-1
				break
			end
		end
		if not found then
			table.remove(vars,i)
			table.remove(offset,i)
		end
	end
	for i = 1,#offset do
		data[i] = {}
	end
	-- Do a binary search to find starting time point
	local chunkSize = (#fs.vars-1)*4+8 -- 4 bytes of data and 8 bytes for time
	local st = fs.datapos
	local stp = fs.datapos + (fs.numpts-1)*chunkSize
	local function getTime(pos)
		fH:seek("set",pos)
		local dat = fH:read(chunkSize)
		return math.abs(vstruct.read("f8",dat:sub(1,8))[1])
	end
	-- First either start or stop should lie in the file data
	local t1,t2,tmid,pts,midpos
	pts = fs.numpts
	t1 = getTime(st)
	t2 = getTime(stp)
	if not (start >= t1 and start <= t2) and not (stop >= t1 and stop <= t2) then
		return data		-- start - stop range does not overlap with t1 - t2
	end
	-- Update start/stop with the range that that exists in t1-t2
	if start < t1 then 
		start = t1
	end
	if stop > t2 then
		stop = t2
	end
	-- Now find the data position with first time >= start
	local found
	while not found do
		if start == t1 then
			found = st
			break
		end
		if start == t2 or pts == 2 then
			found = stp
			break
		end
		midpos = st+(math.ceil(pts/2)-1)*chunkSize
		tmid = getTime(midpos)
		if start == tmid then
			found = midpos
			break
		end
		if start > tmid then
			st = midpos
			t1 = tmid
			pts = pts - (math.ceil(pts/2)-1)
		else
			stp = midpos
			t2 = tmid
			pts = math.ceil(pts/2)
		end
	end
	-- found contains the point from where the data has to be extracted
	--found = fs.datapos
	fH:seek("set",found)
	local dat,time,done
	pts = 0
	local tData = data[0]
	while not done do
		dat = fH:read(chunkSize)
		if not dat then break end
		time = math.abs(vstruct.read("f8",dat:sub(1,8))[1])
		if time > stop then break end
		if time >= start then
			pts = pts + 1
			tData[pts] = time
			-- Now read all the variable data
			for j = 1,#vars do
				data[j][pts] = vstruct.read("f4",dat:sub(9+(offset[j]-1)*4,12+(offset[j]-1)*4))[1]
			end
			if maxpoints and pts >= maxpoints then
				break
			end
		end
	end	
	return data
end

-- Function to calculate the total energy supplied by integrating the power from t[start] to t[stop]
-- fs is the file structure
-- Vp is the array containing the +ve node voltages
-- Vn is the array containing the -ve node voltages (OPTIONAL). If not given this is assumed as ground.
-- I is the array containing the current
-- t is the array containing the time points
-- start is the start index from where the integral is to be calculated (default = 1)
-- stop is the stop index up till where the integral will be done (default = #t)
function getEnergy(fs,t,Vp,Vn,I,start,stop)
	local E = 0
	local Pi,Pim1
	start = start or 1
	stop = stop or #t
	local function fPi1(i,Vp,Vn,I)
		return (Vp[i]-Vn[i])*I[i]
	end
	local function fPi2(i,Vp,Vn,I)
		return Vp[i]*I[i]
	end
	local fPi = fPi1
	if not Vn then
		fPi = fPi2
	end
	for i = start+1,stop do	-- starting from start+1 since Pim1 takes the previous point
		Pi = fPi(i,Vp,Vn,I)
		Pim1 = fPi(i-1,Vp,Vn,I)
		E = E + 0.5*(Pi+Pim1)*(t[i]-t[i-1])
	end
	return E
end

-- Function to calculate the RMS value of the given wave vector
-- fs is the file structure
-- wave is the vector containing the waveform data
-- start is the start index from where the integral is to be calculated (default = 1)
-- stop is the stop index up till where the integral will be done (default = #t)
function getRMS(fs,t,wave,start,stop)
	local sum = 0
	start = start or 1
	stop = stop or #t
	for i = start+1,stop do
		sum = sum + (wave[i]^2)*(t[i]-t[i-1])
	end
	-- Mean sqrt
	return math.sqrt(sum/(t[stop]-t[start]))
end

-- Function to calculate the efficiency from a transient simulation
-- fs is the file structure
-- inv is an array containing input voltage data
-- ini is an array containing the input current data
-- outv is an array containing the output voltage data
-- outi is an array containing the output current data
-- time is an array containing the corresponding time points
function getEfficiency(fs,time,inv,ini,outv,outi)
	-- Now calculate the input Power
	local Pin = getEnergy(fs,time,inv,nil,ini)
	Pin = Pin/(time[#time]-time[1])
	-- Now calculate the output Power
	local Pout = getEnergy(fs,time,outv,nil,outi)
	Pout = Pout/(time[#time]-time[1])
	return Pout/Pin,Pout,Pin
end

--------------------------------------------------------------------------
local function readHeaderString(fH,header,lineNo,tag)
	return header[lineNo]:sub(#tag+1,-1):gsub("^%s*",""):gsub("%s*$","")
end

local function readHeaderFlags(fH,header,lineNo,tag)
	local fl = header[lineNo]:sub(#tag+1,-1):gsub("^%s*",""):gsub("%s*$","").." "
	local flags = {}
	for flag in fl:gmatch("(.-) ") do
		flags[#flags + 1] = flag
	end
	return flags
end

local function readHeaderNum(fH,header,lineNo,tag)
	local num = header[lineNo]:sub(#tag+1,-1):gsub("^%s*",""):gsub("%s*$","")
	return tonumber(num)
end

local function readHeaderVars(fh,header,lineNo,tag)
	local vars = {}
	local i = lineNo+1
	local line = header[i]
	while line:match("^%s%s*%d%d*%s%s*%a[^%s]*") do
		vars[#vars + 1] = line:match("^%s%s*%d%d*%s%s*(%a[^%s]*)")
		i = i + 1
		line = header[i]
	end
	return vars
end

-- Raw file parser
rawParser = function(filename)
	-- File structure definition
	local fs = {
		title = "",
		date = "",
		plotname = "",
		flags = {},
		vars = {},
		numpts = 0,
		offset = 0,
		mode = "Transient",		-- Support Transient, AC
		filetype = "binary",	-- Binary or ascii
		datapos = 0				-- position in file from where data begins
	}
	local tagMap = {	-- Key is the key of fs and value is the text in the beginning of line that contains that info in the raw file
			{"title", "Title:", readHeaderString},
			{"date", "Date:", readHeaderString},
			{"plotname", "Plotname:", readHeaderString},
			{"flags", "Flags:", readHeaderFlags},
			{"numpts", "No. Points:", readHeaderNum},
			{"offset", "Offset:", readHeaderNum},
			{"vars", "Variables:", readHeaderVars}
	}
	local dataTags = {
		{"Binary:%c","binary"},	-- Tag text, filetype string
		{"Values:%c","ascii"}
	}
	local modes = {
		"Transient",
		"AC",
		"FFT",
		"Noise"
	}
	local header = {}	-- To store the decoded header lines
	local f,msg = io.open(filename,"rb")	-- Assuming UTF-16LE encoding for the file
	if not f then 
		return nil,msg
	end
	local fsmeta = {
		fileHandle = f,
		__index = {
			v = _VERSION,
			close = close,
		}
	}
	local line = f:read("L")
	header[#header+1] = line
	
	-- Note UTF-8 is backward compatible with ASCII so the ASCII characters will appear with the right codepoints
	local headerStr = winapi.encode(winapi.CP_UTF16,winapi.CP_UTF8,table.concat(header))
	-- Function to check whether header has come to an end
	local checkEndHeader = function(l)
		for i = 1,#dataTags do
			if l:find(dataTags[i][1]) then
				return dataTags[i][2]
			end
		end
		return false
	end
	
	-- Parse the header
	while line and not checkEndHeader(headerStr) do
		--print(line)
		line = f:read("L")
		if line then
			header[#header+1] = line
			headerStr = winapi.encode(winapi.CP_UTF16,winapi.CP_UTF8,table.concat(header))
		end
	end
	if not line then
		return nil,"Premature file end"
	end
	fs.filetype = checkEndHeader(headerStr)
	-- Split headerStr into decoded header lines
	if headerStr:sub(-1,-1) ~= "\n" then
		headerStr = headerStr.."\n"
	end
	header = {}
	for l in headerStr:gmatch("([^\n]-)\n") do
		header[#header + 1] = l
	end
	fs.datapos = f:seek()+1		-- +1 for UTF-16 code
	for j = 1,#header do
		for i = 1,#tagMap do
			if header[j]:find(tagMap[i][2],1,true) then
				fs[tagMap[i][1]] = tagMap[i][3](f,header,j,tagMap[i][2])
				break
			end
		end
	end

	-- Set the mode
	for i = 1,#modes do
		if fs.plotname:find(modes[i]) then
			fs.mode = modes[i]
			break
		end
	end
	-- Check whether the file length is correct
	local size = f:seek("end")
	if size ~= fs.datapos+((#fs.vars-1)*4+8)*fs.numpts then
		return nil, "Incorrect file size. Expected: "..tostring(fs.datapos+((#fs.vars-1)*4+8)*fs.numpts).." got: "..tostring(size)
	end
	if fs.mode == "Transient" then
		fsmeta.__index.read = read_transient
		fsmeta.__index.getEfficiency = getEfficiency
		fsmeta.__index.getEnergy = getEnergy
		fsmeta.__index.getRMS = getRMS
	elseif fs.mode == "AC" then
		return nil,"AC file reading not added yet"
	elseif fs.mode == "FFT" then
		return nil,"FFT file reading not added yet"
	elseif fs.mode == "Noise" then
		return nil,"Noise file reading not added yet"
	else
		return nil,"Unknown file type"
	end
	return setmetatable(fs,fsmeta)
end