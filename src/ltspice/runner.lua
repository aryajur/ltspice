-- Ltspice simulation utilities

local lfs = require("lfs")
local diskOP = require("diskOP")

local os = os
local print = print

-- Create the module table here
local M = {}
package.loaded[...] = M
_ENV = M		-- Lua 5.2+

_VERSION = "1.21.03.23"	

PATH = "."	-- Path where the simulation data will be stored
EXEC = "C:/Program Files/LTC/LTspiceXVII/XVIIx64.exe"

local function getParam(obj,param)
	
end

-- If file extension ends in .asc then it will generate a .net file to use
function newRunner(file)
	if not diskOP.file_exists(file) then
		return nil,"Could not find file: "..file
	end
	if file:sub(-4,-1):lower() ~= ".asc" and file:sub(-4,-1):lower() ~= ".net" then
		return nil,"Only .asc and .net files accepted."
	end
	-- verify the path
	if not diskOP.verifyPath(PATH) then
		return nil,"Working directory: "..PATH.." not a valid path."
	end
	-- Change to PATH
	local stat,msg = lfs.chdir(PATH)
	if not stat then
		return nil,"Could not change to the path: "..PATH..": "..msg
	end
	local fName, ascfile
	if EXEC:find(" ") and EXEC:sub(1,1) ~= '"' then
		EXEC = '"'..EXEC..'"'
	end
	ascfile = file
	if file:find(" ") and file:sub(1,1) ~= '"' then
		ascfile = '"'..file..'"'
	end
	-- If asc file then convert to netlist
	if file:sub(-4,-1):lower() == ".asc" then
		print("EXECUTE: "..'"'..EXEC.." -netlist "..ascfile..'"')
		os.execute('"'..EXEC.." -netlist "..ascfile..'"')
		fName = diskOP.getFileName(file):sub(1,-4).."net"
	else
		fName = diskOP.getFileName(file)
	end
	-- Copy the file
	print("COPY:",file:sub(1,-4).."net",PATH,fName)
	print(diskOP.copyFile(file:sub(1,-4).."net",PATH,fName))

	local obj = {
		file = fName
	}
end