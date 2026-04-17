--[[
mpvEPG v0.3
lua script for mpv parses XMLTV data and displays scheduling information for current and upcoming broadcast programming.

Dependency: SLAXML (https://github.com/Phrogz/SLAXML)

Copyright © 2020 Peter Žember; MIT Licensed
See https://github.com/dafyk/mpvEPG for details.
--]]

---========================== SLAXML PART START ============================---
-------------------------------------------------------------------------------
--  v0.8 Copyright © 2013-2018 Gavin Kistner <!@phrogz.net>; MIT Licensed    --
--           See http://github.com/Phrogz/SLAXML for details.                --
--                Copyright (c) 2013-2018 Gavin Kistner                      --
-------------------------------------------------------------------------------
local SLAXML = {
	VERSION = "0.8",
	_call = {
		pi = function(target, content)
			print(string.format("<?%s %s?>", target, content))
		end,
		comment = function(content)
			print(string.format("<!-- %s -->", content))
		end,
		startElement = function(name, nsURI, nsPrefix)
			io.write("<")
			if nsPrefix then
				io.write(nsPrefix, ":")
			end
			io.write(name)
			if nsURI then
				io.write(" (ns='", nsURI, "')")
			end
			print(">")
		end,
		attribute = function(name, value, nsURI, nsPrefix)
			io.write("  ")
			if nsPrefix then
				io.write(nsPrefix, ":")
			end
			io.write(name, "=", string.format("%q", value))
			if nsURI then
				io.write(" (ns='", nsURI, "')")
			end
			io.write("\n")
		end,
		text = function(text, cdata)
			print(string.format("  %s: %q", cdata and "cdata" or "text", text))
		end,
		closeElement = function(name, _, nsPrefix) -- luacheck: ignore
			io.write("</")
			if nsPrefix then
				io.write(nsPrefix, ":")
			end
			print(name .. ">")
		end,
	},
}

function SLAXML:parser(callbacks)
	return { _call = callbacks or self._call, parse = SLAXML.parse }
end

function SLAXML:parse(xml, options)
	if not options then
		options = { stripWhitespace = false }
	end

	-- Cache references for maximum speed
	local find, sub, gsub, char, push, pop, concat =
		string.find, string.sub, string.gsub, string.char, table.insert, table.remove, table.concat

	local first, last, match1, match2, pos2, nsURI
	local unpack = unpack or table.unpack
	local pos = 1
	local state = "text"
	local textStart = 1
	local currentElement = {}
	local currentAttributes = {}
	local currentAttributeCt -- manually track length since the table is re-used
	local nsStack = {}
	local anyElement = false

	local utf8markers = { { 0x7FF, 192 }, { 0xFFFF, 224 }, { 0x1FFFFF, 240 } }
	-- convert unicode code point to utf-8 encoded character string
	local function utf8(decimal)
		if decimal < 128 then
			return char(decimal)
		end
		local charbytes = {}
		for bytes, vals in ipairs(utf8markers) do
			if decimal <= vals[1] then
				for b = bytes + 1, 2, -1 do
					local mod = decimal % 64
					decimal = (decimal - mod) / 64
					charbytes[b] = char(128 + mod)
				end
				charbytes[1] = char(vals[2] + decimal)
				return concat(charbytes)
			end
		end
	end
	local entityMap = {
		["lt"] = "<",
		["gt"] = ">",
		["amp"] = "&",
		["quot"] = '"',
		["apos"] = "'",
	}
	local entitySwap = function(orig, n, s)
		return entityMap[s] or n == "#" and utf8(tonumber("0" .. s)) or orig
	end
	---
	local function unescape(str)
		return gsub(str, "(&(#?)([%d%a]+);)", entitySwap)
	end

	local function finishText()
		if first > textStart and self._call.text then
			local text = sub(xml, textStart, first - 1)
			if options.stripWhitespace then
				text = gsub(text, "^%s+", "")
				text = gsub(text, "%s+$", "")
				if #text == 0 then
					text = nil
				end
			end
			if text then
				self._call.text(unescape(text), false)
			end
		end
	end
	local function findPI()
		first, last, match1, match2 = find(xml, "^<%?([:%a_][:%w_.-]*) ?(.-)%?>", pos)

		if first then
			finishText()
			if self._call.pi then
				self._call.pi(match1, match2)
			end
			pos = last + 1
			textStart = pos
			return true
		end
	end
	local function findComment()
		first, last, match1 = find(xml, "^<!%-%-(.-)%-%->", pos)
		if first then
			finishText()
			if self._call.comment then
				self._call.comment(match1)
			end
			pos = last + 1
			textStart = pos
			return true
		end
	end

	local function nsForPrefix(prefix)
		-- http://www.w3.org/TR/xml-names/#ns-decl
		if prefix == "xml" then
			return "http://www.w3.org/XML/1998/namespace"
		end
		for i = #nsStack, 1, -1 do
			if nsStack[i][prefix] then
				return nsStack[i][prefix]
			end
		end
		error(("Cannot find namespace for prefix %s"):format(prefix))
	end

	local function startElement()
		anyElement = true
		first, last, match1 = find(xml, "^<([%a_][%w_.-]*)", pos)
		if first then
			-- reset the nsURI, since this table is re-used
			currentElement[2] = nil
			-- reset the nsPrefix, since this table is re-used
			currentElement[3] = nil
			finishText()
			pos = last + 1
			first, last, match2 = find(xml, "^:([%a_][%w_.-]*)", pos)
			if first then
				currentElement[1] = match2
				currentElement[3] = match1 -- Save the prefix for later resolution
				match1 = match2
				pos = last + 1
			else
				currentElement[1] = match1
				for i = #nsStack, 1, -1 do
					if nsStack[i]["!"] then
						currentElement[2] = nsStack[i]["!"]
						break
					end
				end
			end
			currentAttributeCt = 0
			push(nsStack, {})
			return true
		end
	end

	local function findAttribute()
		first, last, match1 = find(xml, "^%s+([:%a_][:%w_.-]*)%s*=%s*", pos)
		if first then
			pos2 = last + 1
			-- FIXME: disallow non-entity ampersands
			first, last, match2 = find(xml, '^"([^<"]*)"', pos2)
			if first then
				pos = last + 1
				match2 = unescape(match2)
			else
				-- FIXME: disallow non-entity ampersands
				first, last, match2 = find(xml, "^'([^<']*)'", pos2)
				if first then
					pos = last + 1
					match2 = unescape(match2)
				end
			end
		end
		if match1 and match2 then
			local currentAttribute = { match1, match2 }
			local prefix, name = string.match(match1, "^([^:]+):([^:]+)$")
			if prefix then
				if prefix == "xmlns" then
					nsStack[#nsStack][name] = match2
				else
					currentAttribute[1] = name
					currentAttribute[4] = prefix
				end
			else
				if match1 == "xmlns" then
					nsStack[#nsStack]["!"] = match2
					currentElement[2] = match2
				end
			end
			currentAttributeCt = currentAttributeCt + 1
			currentAttributes[currentAttributeCt] = currentAttribute
			return true
		end
	end
	-- disabled for EPGTV, becouse unused
	local function findCDATA()
		--[[
        first, last, match1 = find( xml, '^<!%[CDATA%[(.-)%]%]>', pos )
        if first then
            finishText()
            if self._call.text then self._call.text(match1,true) end
            pos = last+1
            textStart = pos
            return true
        end
        --]]
	end

	local function closeElement()
		first, last, match1 = find(xml, "^%s*(/?)>", pos)
		if first then
			state = "text"
			pos = last + 1
			textStart = pos
			-- Resolve namespace prefixes AFTER all
			-- new/redefined prefixes have been parsed
			if currentElement[3] then
				currentElement[2] = nsForPrefix(currentElement[3])
			end
			if self._call.startElement then
				self._call.startElement(unpack(currentElement))
			end
			if self._call.attribute then
				for i = 1, currentAttributeCt do
					if currentAttributes[i][4] then
						currentAttributes[i][3] = nsForPrefix(currentAttributes[i][4])
					end
					self._call.attribute(unpack(currentAttributes[i]))
				end
			end

			if match1 == "/" then
				pop(nsStack)
				if self._call.closeElement then
					self._call.closeElement(unpack(currentElement))
				end
			end
			return true
		end
	end

	local function findElementClose()
		first, last, match1, match2 = find(xml, "^</([%a_][%w_.-]*)%s*>", pos)
		if first then
			nsURI = nil
			for i = #nsStack, 1, -1 do
				if nsStack[i]["!"] then
					nsURI = nsStack[i]["!"]
					break
				end
			end
		else
			first, last, match2, match1 = find(xml, "^</([%a_][%w_.-]*):([%a_][%w_.-]*)%s*>", pos)
			if first then
				nsURI = nsForPrefix(match2)
			end
		end
		if first then
			finishText()
			if self._call.closeElement then
				self._call.closeElement(match1, nsURI)
			end
			pos = last + 1
			textStart = pos
			pop(nsStack)
			return true
		end
	end

	while pos < #xml do
		if state == "text" then
			if not (findPI() or findComment() or findCDATA() or findElementClose()) then
				if startElement() then
					state = "attributes"
				else
					first, last = find(xml, "^[^<]+", pos)
					pos = (first and last or pos) + 1
				end
			end
		elseif state == "attributes" then
			if not findAttribute() then
				if not closeElement() then
					error("Was in an element and couldn't find attributes or the close.")
				end
			end
		end
	end

	if not anyElement then
		error("Parsing did not discover any elements")
	end
	if #nsStack > 0 then
		error("Parsing ended with unclosed elements")
	end
end

function SLAXML:dom(xml, opts)
	if not opts then
		opts = {}
	end
	local rich = not opts.simple
	local push, pop = table.insert, table.remove
	local doc = { type = "document", name = "#doc", kids = {} }
	local current, stack = doc, { doc }
	local builder = SLAXML:parser({
		startElement = function(name, nsURI, nsPrefix)
			local el = {
				type = "element",
				name = name,
				kids = {},
				el = rich and {} or nil,
				attr = {},
				nsURI = nsURI,
				nsPrefix = nsPrefix,
				parent = rich and current or nil,
			}
			if current == doc then
				if doc.root then
					error(
						("Encountered element '%s' when the document already has a root '%s' element"):format(
							name,
							doc.root.name
						)
					)
				end
				doc.root = rich and el or nil
			end
			push(current.kids, el)
			if current.el then
				push(current.el, el)
			end
			current = el
			push(stack, el)
		end,
		attribute = function(name, value, nsURI, nsPrefix)
			if not current or current.type ~= "element" then
				error(("Encountered an attribute %s=%s but I wasn't inside an element"):format(name, value))
			end
			local attr = {
				type = "attribute",
				name = name,
				nsURI = nsURI,
				nsPrefix = nsPrefix,
				value = value,
				parent = rich and current or nil,
			}
			if rich then
				current.attr[name] = value
			end
			push(current.attr, attr)
		end,
		closeElement = function(name)
			if current.name ~= name or current.type ~= "element" then
				error(
					("Received a close element notification for '%s' but was inside a '%s' %s"):format(
						name,
						current.name,
						current.type
					)
				)
			end
			pop(stack)
			current = stack[#stack]
		end,
		text = function(value, cdata)
			-- documents may only have text node children that are whitespace: https://www.w3.org/TR/xml/#NT-Misc
			if current.type == "document" and not value:find("^%s+$") then
				error(
					("Document has non-whitespace text at root: '%s'"):format(
						value:gsub("[\r\n\t]", { ["\r"] = "\\r", ["\n"] = "\\n", ["\t"] = "\\t" })
					)
				)
			end
			push(current.kids, {
				type = "text",
				name = "#text",
				cdata = cdata and true or nil,
				value = value,
				parent = rich and current or nil,
			})
		end,
		comment = function(value)
			push(current.kids, { type = "comment", name = "#comment", value = value, parent = rich and current or nil })
		end,
		pi = function(name, value)
			push(current.kids, { type = "pi", name = name, value = value, parent = rich and current or nil })
		end,
	})
	builder:parse(xml, opts)
	return doc
end
-------------------------------------------------------------------------------
---============================ SLAXML PART END ============================---

require("os")
require("io")
require("string")

-- forward declaration so M3U helpers can use it; assigned below after require("mp.utils")
local utils

local opts = {
	epg_dir = "", -- directory containing XMLTV files

	titleColor = "00FBFE", -- now playing title color (hex BGR)
	subtitleColor = "00FBFE", -- now playing sub-title color (hex BGR)
	descColor = "FFFFFF", -- now playing description color (hex BGR)
	clockColor = "00FBFE", -- clock color (hex BGR)
	upcomingColor = "FFFFFF", -- upcoming list time/title color (hex BGR)
	upcomingDescColor = "FFFFFF", -- upcoming list description color (hex BGR)
	noEpgMsgColor = "002DD1", -- no EPG message color (hex BGR)

	titleSize = 50, -- now playing title font size
	subtitleSize = 40, -- now playing sub-title font size
	descSize = 30, -- now playing description font size
	progressSize = 40, -- progress percentage font size
	upcomingTimeSize = 35, -- upcoming broadcast time font size
	upcomingTitleSize = 35, -- upcoming broadcast title font size
	upcomingDescSize = 22, -- upcoming broadcast description font size

	noEpgMsg = "No EPG for this channel", -- message when no EPG found
	duration = 5, -- seconds before EPG overlay hides
	utc_offset = 0, -- offset in hours between EPG timestamps (UTC) and local time; e.g. 2 for CEST (UTC+2)
	epg_cache_hours = 6, -- hours before a cached EPG file is considered stale and re-downloaded
	max_upcoming = 5, -- maximum number of upcoming programmes to display (set to 0 to show all)
}
require("mp.options").read_options(opts, "mpvEPG")
utils = require("mp.utils")

-- resolve epg_dir: use mp.command_native to expand ~~ and environment variables
local epg_dir = mp.command_native({ "expand-path", opts.epg_dir })

-- ============================================================
-- M3U header parsing and EPG download helpers
-- ============================================================

--[[ Parse the first line of an M3U file and return url-tvg list and tvg-shift.
@param path {String} - absolute path to the M3U file
@returns urls {Table}, tvg_shift {Number|nil}
--]]
local function parseM3UHeader(path)
	local f = io.open(path, "r")
	if not f then
		mp.msg.warn("M3U: cannot open file: " .. path)
		return {}, nil
	end
	local line = f:read("*l") -- read first line only
	f:close()

	if not line or not line:match("^#EXTM3U") then
		mp.msg.warn("M3U: not a valid M3U file or missing #EXTM3U header: " .. path)
		return {}, nil
	end

	-- extract url-tvg="..." (may contain comma-separated URLs)
	local url_tvg_raw = line:match('[%s;]url%-tvg%s*=%s*"([^"]*)"')
	local urls = {}
	if url_tvg_raw then
		for url in url_tvg_raw:gmatch("[^,%s]+") do
			urls[#urls + 1] = url
		end
	end

	-- extract tvg-shift="..." or tvg-shift="+3" (with or without quotes)
	local shift_raw = line:match("[%s;]tvg%-shift%s*=%s*[\"']?([+%-]?%d+%.?%d*)[\"']?")
	local tvg_shift = shift_raw and tonumber(shift_raw) or nil

	return urls, tvg_shift
end

--[[ Return the file-system modification time of a file (seconds since epoch),
     or nil if the file does not exist.
@param path {String}
@returns {Number|nil}
--]]
local function fileModTime(path)
	local info = utils.file_info(path)
	return info and info.mtime or nil
end

--[[ Download a URL to destPath using curl.
     If the URL ends with .gz the content is decompressed via gunzip.
     Returns true on success, false otherwise.
@param url {String}
@param destPath {String} - destination .xml file (always uncompressed)
@returns {Boolean}
--]]
local function downloadEPG(url, destPath)
	local is_gz = url:match("%.gz$") or url:match("%.gz%?")
	local cmd

	if is_gz then
		cmd = string.format('curl -sL "%s" | gunzip -c > "%s"', url, destPath)
	else
		cmd = string.format('curl -sL -o "%s" "%s"', destPath, url)
	end

	mp.msg.info("EPG download: " .. url .. " -> " .. destPath)
	local ret = os.execute(cmd)
	-- os.execute returns 0 or true on success depending on Lua version
	if ret == 0 or ret == true then
		mp.msg.info("EPG download succeeded: " .. destPath)
		return true
	else
		mp.msg.warn("EPG download failed for: " .. url)
		return false
	end
end

--[[ Derive a safe filename from a URL (strips protocol and replaces special chars).
@param url {String}
@returns {String} - filename without directory
--]]
local function urlToFilename(url)
	local name = url:gsub("^https?://", ""):gsub("[^%w%.%-_]", "_")
	-- strip trailing .gz so the stored file is always the decompressed .xml
	name = name:gsub("_gz$", ""):gsub("%.gz$", "")
	if not name:match("%.xml$") then
		name = name .. ".xml"
	end
	return name
end

local loadXMLFiles
--[[ Resolve the M3U path loaded playlist file.
@returns {String|nil}
--]]
local function resolveM3UPath()
	-- mpv stores the playlist source file in "playlist-path"
	local playlist_path = mp.get_property("playlist-path") or ""
	if playlist_path ~= "" and playlist_path:match("[Mm]3[Uu]8?$") then
		mp.msg.debug("Match via playlist_path: " .. playlist_path)
		return playlist_path
	end

	local stream_file_name = mp.get_property("stream-open-filename") or ""
	if stream_file_name ~= "" and stream_file_name:match("[Mm]3[Uu]8?$") then
		mp.msg.debug("Match via stream_file_name: " .. stream_file_name)
		return stream_file_name
	end

	-- fallback: first entry in the internal playlist
	local entry = mp.get_property("playlist/0/filename") or ""
	if entry ~= "" and entry:match("[Mm]3[Uu]8?$") then
		mp.msg.debug("Match via playlist/0/filename: " .. entry)
		return entry
	end

	-- IPC fallback: try 'path' property which is set earlier
	local path = mp.get_property("path") or ""
	if path ~= "" and path:match("[Mm]3[Uu]8?$") then
		mp.msg.debug("Match via path: " .. path)
		return path
	end

	return nil
end

--[[ Main entry point: parse M3U header, download stale EPG files and load them.
     Called once at startup before the regular XML directory scan.
--]]
local function loadEPGFromM3U()
	local m3u_path = resolveM3UPath()
	mp.msg.debug("resolved m3u_path = " .. tostring(m3u_path))

	if not m3u_path then
		mp.msg.info("M3U EPG: no M3U file found, skipping header-based EPG download")
		return
	end
	mp.msg.info("M3U EPG: parsing header from " .. m3u_path)

	local urls, tvg_shift = parseM3UHeader(m3u_path)

	-- Apply tvg-shift only when utc_offset was not explicitly configured (remains 0)
	if tvg_shift and opts.utc_offset == 0 then
		mp.msg.info(string.format("M3U EPG: applying tvg-shift %+g as utc_offset", tvg_shift))
		opts.utc_offset = tvg_shift
	end

	local stale_secs = opts.epg_cache_hours * 3600
	local now = os.time()

	-- verify epg_dir exists before attempting any download
	local dir_info = utils.file_info(epg_dir)
	if not dir_info or not dir_info.is_dir then
		mp.msg.warn("M3U EPG: epg_dir does not exist, skipping download: " .. epg_dir)
		return
	end

	local downloaded = false
	for _, url in ipairs(urls) do
		local filename = urlToFilename(url)
		local destPath = utils.join_path(epg_dir, filename)
		local mtime = fileModTime(destPath)
		local age = mtime and (now - mtime) or math.huge

		if age >= stale_secs then
			if downloadEPG(url, destPath) then
				downloaded = true
			end
		else
			mp.msg.info(string.format("M3U EPG: %s is fresh (%.1fh old), skipping download", filename, age / 3600))
		end
	end

	-- Reload XML files if we downloaded new ones
	if downloaded then
		mp.msg.info("M3U EPG: reloading XML files after download")
		loadXMLFiles()
	end
end

local ov = mp.create_osd_overlay("ass-events")

-- Load and merge all .xml files from the configured directory into a single virtual root
Xmltvdata = { kids = {} }
local seen_programmes = {} -- deduplication key: channel+start+stop
local seen_channels = {} -- deduplication key: channel id

--[[ Load or reload all XML files from epg_dir into xmltvdata.
     Can be called multiple times to refresh after downloads.
--]]
function loadXMLFiles()
	-- Clear existing data
	Xmltvdata = { kids = {} }
	seen_programmes = {}
	seen_channels = {}

	local files = utils.readdir(epg_dir, "files")
	if files then
		table.sort(files)
		for _, name in ipairs(files) do
			if name:match("%.xml$") then
				local path = utils.join_path(epg_dir, name)
				local f = io.open(path)
				if f then
					local raw = f:read("*all")
					f:close()
					raw = raw:gsub("<!DOCTYPE[^>]*>", "")
					local parsed = SLAXML:dom(raw, { stripWhitespace = true }).root
					if parsed and parsed.kids then
						for _, kid in ipairs(parsed.kids) do
							if kid.type == "element" and kid.name == "programme" then
								local key = (kid.attr["channel"] or "")
									.. "|"
									.. (kid.attr["start"] or "")
									.. "|"
									.. (kid.attr["stop"] or "")
								if not seen_programmes[key] then
									seen_programmes[key] = true
									Xmltvdata.kids[#Xmltvdata.kids + 1] = kid
								end
							elseif kid.type == "element" and kid.name == "channel" then
								local id = kid.attr["id"] or ""
								if not seen_channels[id] then
									seen_channels[id] = true
									Xmltvdata.kids[#Xmltvdata.kids + 1] = kid
								end
							else
								Xmltvdata.kids[#Xmltvdata.kids + 1] = kid
							end
						end
					end
					mp.msg.info("Loaded EPG file: " .. name)
				else
					mp.msg.warn("Could not open EPG file: " .. path)
				end
			end
		end
	else
		mp.msg.error("Could not read EPG directory: " .. epg_dir)
	end
end

-- Parse M3U header and download EPG files referenced there before loading XMLs
loadEPGFromM3U()

-- Load downloaded XML files initially
loadXMLFiles()

local assdraw = require("mp.assdraw")
local ass = assdraw.ass_new()

local timerOSD
local show_upcoming_desc = false -- toggle state for upcoming descriptions

--[[ Extract hours and minutes from xmltv timestamp, apply utc_offset, and format to HH:MM
@param time {String} - xmltv timestamp (UTC)
@returns {String} - local time in form HH:MM
--]]
local function formatTime(time)
	local h = tonumber(string.sub(time, 9, 10))
	local m = tonumber(string.sub(time, 11, 12))
	local total = h * 60 + m + opts.utc_offset * 60
	-- wrap around midnight
	total = total % (24 * 60)
	if total < 0 then
		total = total + 24 * 60
	end
	return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

--[[ Convert YYYYMMDDHHmm string to unix timestamp
@param s {String} - time string, format: YYYYMMDDHHmm 
@returns {String} - unix timestamp
--]]
local function unixTimestamp(s)
	local p = "(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)"
	local year, month, day, hour, min = s:match(p)
	return os.time({ day = day, month = month, year = year, hour = hour, min = min })
end

--[[ Calculate tv show progress in percents
@param start {String} - program start, format: YYYYMMDDHHmm 
@param stop {String} - program end, format: YYYYMMDDHHmm 
@param now {String} - actual time, format: YYYYMMDDHHmm 
@returns {String} - Percentage of program progress in two decimal places
--]]
local function calculatePercentage(start, stop, now)
	start = tonumber(unixTimestamp(start))
	stop = tonumber(unixTimestamp(stop))
	now = tonumber(unixTimestamp(now))
	return string.format("%0.2f", (now - start) / (stop - start) * 100)
end

--[[ Draw tv show progress bar and actual system time
@param percent {String} - tv show progress in percent
--]]
local function progressBar(percent)
	ass = assdraw.ass_new()
	local w, _ = mp.get_osd_size()
	local p = ((w - 14) / 100) * percent
	if not (w == 0) then
		ass:new_event() -- progress bar background
		ass:append("{\\bord2}") -- border size
		ass:append("{\\1c&000000&}") -- background color
		ass:append("{\\3c&000000&}") -- border color
		ass:append("{\\1a&80&}") -- alpha
		ass:pos(7, -5)
		ass:draw_start()
		ass:round_rect_cw(0, 20, w - 14, 10, 1)
		ass:draw_stop()

		ass:new_event() -- progress bar
		ass:pos(7, -5)
		ass:append("{\\bord0}") -- border size
		ass:append("{\\shad0}") -- shadow
		ass:append("{\\1a&0&}") -- alpha
		ass:append("{\\1c&00FBFE&}") -- background color
		ass:append("{\\3c&000000&}") -- border color
		ass:draw_start()
		ass:rect_cw(1, 19, p, 11)
		ass:draw_stop()

		ass:new_event() -- clock background
		ass:pos(w - 128, 21)
		ass:append("{\\bord2}") -- border size
		ass:append("{\\shad0}") -- shadow
		ass:append("{\\1a&80&}") -- alpha
		ass:append("{\\1c&000000&}") -- background color
		ass:append("{\\3c&000000&}") -- border color
		ass:draw_start()
		ass:round_rect_cw(0, 0, 121, 48, 2)
		ass:draw_stop()

		ass:new_event() -- clock
		ass:pos(w - 122, 20)
		ass:append("{\\bord2}") -- border size
		ass:append("{\\shad0}") -- shadow
		ass:append("{\\fs50\\b1}") -- font-size
		ass:append("{\\1c&00FBFE&}") -- background color
		ass:append("{\\3c&000000&}") -- border color
		ass:append(os.date("%H:%M"))
	end
end

--[[ Create today TV schedule for channel from xmltv data
@param el {Table} - SLAXML:dom() parsed table
@param channel {String} - channel ID
@param show_desc {Boolean} - whether to show descriptions in upcoming list
@returns {String} - TV schedule
--]]
local function getEPG(el, channel, show_desc)
	-- subtract utc_offset to convert local time to UTC for comparison with XML timestamps
	local now_utc = os.time() - opts.utc_offset * 3600
	local datelong = os.date("%Y%m%d%H%M", now_utc)
	local date = string.sub(datelong, 1, 8)
	local yesterday = os.date("%Y%m%d", now_utc - 24 * 60 * 60)

	local now = { title = "", subtitle = "", desc = "" }
	local program = {}
	local progress
	for _, n in ipairs(el.kids) do
		if n.type == "element" and n.name == "programme" then
			local progdate = string.sub(n.attr["start"], 1, 8)
			if n.attr["channel"] == channel and (progdate == date or progdate == yesterday) then
				local progstart = string.sub(n.attr["start"], 1, 12)
				local progstop = string.sub(n.attr["stop"], 1, 12)
				local start = formatTime(n.attr["start"])
				local stop = formatTime(n.attr["stop"])

				-- collect all data for this programme
				local prog_title = ""
				local prog_subtitle = ""
				local prog_desc = ""

				for _, o in ipairs(n.kids) do
					if o.name == "title" then
						for _, p in ipairs(o.kids) do
							prog_title = p.value or ""
						end
					elseif o.name == "sub-title" then
						for _, p in ipairs(o.kids) do
							prog_subtitle = p.value or ""
						end
					elseif o.name == "desc" then
						for _, p in ipairs(o.kids) do
							prog_desc = p.value or ""
						end
					end
				end

				-- now process based on time
				if progstart <= datelong and progstop >= datelong then
					-- now playing
					progress = calculatePercentage(progstart, progstop, datelong)
					now.title = string.format(
						"{\\b1\\bord2\\fs%s\\1c&H%s}%s {\\fs%s}(%s%%)\\N",
						opts.titleSize,
						opts.titleColor,
						prog_title,
						opts.progressSize,
						progress
					)
					progressBar(progress)

					if prog_subtitle ~= "" then
						now.subtitle = string.format(
							"{\\bord2\\fs%s\\b1\\i1\\1c&H%s}⦗%s-%s⦘{\\b0}- %s\\N\\N",
							opts.subtitleSize,
							opts.subtitleColor,
							start,
							stop,
							prog_subtitle
						)
					elseif prog_desc ~= "" then
						now.desc =
							string.format("{\\bord2\\fs%s\\1c&H%s}%s\\N\\N", opts.descSize, opts.descColor, prog_desc)
					end
				elseif progstart > datelong then
					-- upcoming programme
					if opts.max_upcoming == 0 or #program < opts.max_upcoming then
						local entry = string.format(
							"{\\b1\\be\\fs%s\\1c&H%s}⦗%s – %s⦘{\\b0\\fs%s} %s\\N",
							opts.upcomingTimeSize,
							opts.upcomingColor,
							start,
							stop,
							opts.upcomingTitleSize,
							prog_title
						)
						-- add description if available and if show_desc is true
						if show_desc and prog_desc ~= "" then
							entry = entry
								.. string.format(
									"{\\bord2\\fs%s\\1c&H%s}%s\\N",
									opts.upcomingDescSize,
									opts.upcomingDescColor,
									prog_desc
								)
						end
						program[#program + 1] = entry
					end
				end
			end
		end
	end
	-- sub-title takes priority over desc; fall back to desc if no sub-title present
	if now.subtitle == "" then
		now.subtitle = now.desc ~= "" and now.desc or "\\N"
	end
	table.sort(program)
	table.insert(program, 1, now.subtitle)
	table.insert(program, 1, now.title)
	return table.concat(program)
end

--[[ Search for channel ID in combined XMLTV data by display-name or direct channel ID match.
     Checks the stream URL for a known channel id from <channel id="..."> elements,
     or matches a <display-name> child element against the given identifier string.
@param el {Table} - SLAXML:dom() parsed table
@param identifier {String} - channel ID or display name from stream URL
@returns {String} - channel ID, or nil if not found
--]]
local function getChannelID(el, identifier)
	for _, n in ipairs(el.kids) do
		if n.type == "element" and n.name == "channel" then
			-- direct id match (e.g. channel ID appears in stream URL)
			if n.attr["id"] == identifier then
				return n.attr["id"]
			end
			-- display-name match (fallback)
			for _, o in ipairs(n.kids) do
				if o.name == "display-name" then
					for _, p in ipairs(o.kids) do
						if p.value == identifier then
							return n.attr["id"]
						end
					end
				end
			end
		end
	end
	return nil
end

--[[ Set chapter markers from EPG data for the current channel.
     Chapter 0 is placed at position 0 (= now / current programme).
     Upcoming programmes get offsets relative to now (in seconds).
@param channelID {String} - channel ID to look up
--]]
local function setEPGChapters(channelID)
	if not channelID then
		return
	end

	local now_utc = os.time() - opts.utc_offset * 3600
	local datelong = os.date("%Y%m%d%H%M", now_utc)
	local date = string.sub(datelong, 1, 8)
	local yesterday = os.date("%Y%m%d", now_utc - 24 * 60 * 60)

	-- collect current and future programmes for this channel
	local chapters = {}
	for _, n in ipairs(Xmltvdata.kids) do
		if n.type == "element" and n.name == "programme" and n.attr["channel"] == channelID then
			local progdate = string.sub(n.attr["start"], 1, 8)
			if progdate == date or progdate == yesterday then
				local progstart = string.sub(n.attr["start"], 1, 12)
				local progstop = string.sub(n.attr["stop"], 1, 12)
				-- only current and future programmes
				if progstop >= datelong then
					local title = ""
					for _, o in ipairs(n.kids) do
						if o.name == "title" then
							for _, p in ipairs(o.kids) do
								title = p.value or ""
								break
							end
							break
						end
					end
					local display_time = formatTime(n.attr["start"])
					chapters[#chapters + 1] =
						{ start_unix = tonumber(unixTimestamp(progstart)), title = display_time .. " " .. title }
				end
			end
		end
	end

	if #chapters == 0 then
		return
	end

	-- sort by start time
	table.sort(chapters, function(a, b)
		return a.start_unix < b.start_unix
	end)

	-- chapters at their real offsets from now; current programme at 0.0,
	-- future ones at their seconds-from-now distance
	local chapter_list = {}
	for _, c in ipairs(chapters) do
		local offset = math.max(0.0, c.start_unix - now_utc)
		chapter_list[#chapter_list + 1] = { time = offset, title = c.title }
	end

	mp.set_property_native("chapter-list", chapter_list)
	mp.msg.info(string.format("EPG: set %d chapter(s) for channel %s", #chapter_list, channelID))
end

--[[ Resolve the current channel ID from the active stream URL.
@returns {String} - channel ID, or nil if not found
--]]
local function resolveChannelID()
	local url = mp.get_property("stream-open-filename") or mp.get_property("path") or ""
	local channelID = nil
	for _, n in ipairs(Xmltvdata.kids) do
		if n.type == "element" and n.name == "channel" then
			local id = n.attr["id"]
			if id and url:find(id, 1, true) then
				channelID = id
				break
			end
		end
	end
	if not channelID then
		local segment = string.match(url, "[^/]+$")
		if segment then
			channelID = getChannelID(Xmltvdata, segment)
		end
	end
	return channelID
end

--[[ Displays today TV schedule
--]]
local function showEPG()
	if not (timerOSD == nil) then
		timerOSD:kill()
		timerOSD = nil
	end
	local w, h = mp.get_osd_size()
	local channelID = resolveChannelID()

	if channelID then
		local data = getEPG(Xmltvdata, channelID, show_upcoming_desc)
		if data then
			ov.data = data
		else
			ov.data = string.format("{\\b0\\1c&H%s}%s", opts.noEpgMsgColor, opts.noEpgMsg)
			ass.text = ""
		end
	else
		ov.data = string.format("{\\b0\\1c&H%s}%s", opts.noEpgMsgColor, opts.noEpgMsg)
		ass.text = ""
	end
	ov:update()
	mp.set_osd_ass(w, h, ass.text)
	timerOSD = mp.add_timeout(opts.duration, function()
		ov:remove()
		mp.set_osd_ass(0, 0, "")
		-- reset description toggle when OSD disappears
		show_upcoming_desc = false
		if not (timerOSD == nil) then
			timerOSD:kill()
			timerOSD = nil
		end
	end)
end

-- Set key binding with toggle functionality.
mp.add_key_binding("h", function()
	local channelID = resolveChannelID()

	if timerOSD ~= nil then
		-- OSD was visible, toggle description display
		show_upcoming_desc = not show_upcoming_desc
		showEPG()
	else
		-- OSD was not visible, show it without descriptions first
		show_upcoming_desc = false
		loadEPGFromM3U()
		setEPGChapters(channelID)
		showEPG()
	end
end)

mp.register_event("file-loaded", function()
	local channelID = resolveChannelID()
	setEPGChapters(channelID)
	-- When auto-showing on file load, don't show descriptions initially
	show_upcoming_desc = false
	showEPG()
end)

-- Watch for playlist-path changes (more reliable for IPC loadfile)
mp.observe_property("playlist-path", "string", function(_, value)
	if value and value ~= "" and value:match("[Mm]3[Uu]8?$") then
		mp.msg.info("Playlist path changed to: " .. value)
		loadEPGFromM3U()
	end
end)
