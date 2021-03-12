-- LTSpice utilities

local type = type
local getmetatable = getmetatable
local setmetatable = setmetatable
local tonumber = tonumber

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

_VERSION = "1.21.03.05"	

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
	local varList = {}
	for i = #vars,1,-1 do
		local found
		for j = 1,#fs.vars do
			if fs.vars[j] == vars[i] then
				found = true
				offset[#offset + 1] = j-1
				
				break
			end
		end
		if not found then
			table.remove(vars,i)
		end
	end
	table.sort(offset)
	for i = 1,#offset do
		varList[#varList + 1] = fs.vars[offset[i]]
		data[i] = {}
	end
	fH:seek("set",fs.datapos)
	local chunkSize = (#fs.vars-1)*4+8 -- 4 bytes of data and 8 bytes for time
	local dat,time,pts
	pts = 0
	for i = 1,fs.numpts do
		dat = fH:read(chunkSize)
		time = math.abs(vstruct.read("f8",dat:sub(1,8))[1])
		if time >= start and time <= stop then
			pts = pts + 1
			data[0][pts] = time
			for j = 1,#offset do
				data[j][pts] = vstruct.read("f4",dat:sub(9+(offset[j]-1)*4,12+(offset[j]-1)*4))[1]
			end
			if maxpoints and pts >= maxpoints then
				break
			end
		end
	end	
	return varList,data
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
		return nil, "Incorrect file size."
	end
	if fs.mode == "Transient" then
		fsmeta.__index.read = read_transient
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