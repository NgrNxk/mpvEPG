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
		closeElement = function(name, nsURI, nsPrefix) -- luacheck: ignore
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

local opts = {
	epg_dir = "", -- directory containing XMLTV files

	titleColor = "00FBFE", -- now playing title color (hex BGR)
	subtitleColor = "00FBFE", -- now playing sub-title color (hex BGR)
	descColor = "FFFFFF", -- now playing description color (hex BGR)
	clockColor = "00FBFE", -- clock color (hex BGR)
	upcomingColor = "FFFFFF", -- upcoming list color (hex BGR)
	noEpgMsgColor = "002DD1", -- no EPG message color (hex BGR)

	titleSize = 50, -- now playing title font size
	subtitleSize = 40, -- now playing sub-title font size
	descSize = 30, -- now playing description font size
	progressSize = 40, -- progress percentage font size
	upcomingTimeSize = 25, -- upcoming broadcast time font size
	upcomingTitleSize = 35, -- upcoming broadcast title font size

	noEpgMsg = "No EPG for this channel", -- message when no EPG found
	duration = 5, -- seconds before EPG overlay hides
	utc_offset = 0, -- offset in hours between EPG timestamps (UTC) and local time; e.g. 2 for CEST (UTC+2)
}
require("mp.options").read_options(opts, "mpvEPG")

-- resolve epg_dir: fall back to ~/.config/mpv/epg if not set via script-opts
local epg_dir = opts.epg_dir ~= "" and opts.epg_dir or (os.getenv("HOME") .. "/.config/mpv/epg")

local ov = mp.create_osd_overlay("ass-events")
local utils = require("mp.utils")

-- Load and merge all .xml files from the configured directory into a single virtual root
local xmltvdata = { kids = {} }
local seen_programmes = {} -- deduplication key: channel+start+stop
local seen_channels = {} -- deduplication key: channel id
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
								xmltvdata.kids[#xmltvdata.kids + 1] = kid
							end
						elseif kid.type == "element" and kid.name == "channel" then
							local id = kid.attr["id"] or ""
							if not seen_channels[id] then
								seen_channels[id] = true
								xmltvdata.kids[#xmltvdata.kids + 1] = kid
							end
						else
							xmltvdata.kids[#xmltvdata.kids + 1] = kid
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

local assdraw = require("mp.assdraw")
local ass = assdraw.ass_new()

local timer

--[[ Extract hours and minutes from xmltv timestamp, apply utc_offset, and format to HH:MM
@param time {String} - xmltv timestamp (UTC)
@returns {String} - local time in form HH:MM
--]]
function formatTime(time)
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

--[[ Calculate tv show progress in percents
@param start {String} - program start, format: YYYYMMDDHHmm 
@param stop {String} - program end, format: YYYYMMDDHHmm 
@param now {String} - actual time, format: YYYYMMDDHHmm 
@returns {String} - Percentage of program progress in two decimal places
--]]
function calculatePercentage(start, stop, now)
	start = tonumber(unixTimestamp(start))
	stop = tonumber(unixTimestamp(stop))
	now = tonumber(unixTimestamp(now))
	return string.format("%0.2f", (now - start) / (stop - start) * 100)
end

--[[ Convert YYYYMMDDHHmm string to unix timestamp
@param s {String} - time string, format: YYYYMMDDHHmm 
@returns {String} - unix timestamp
--]]
function unixTimestamp(s)
	p = "(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)"
	year, month, day, hour, min = s:match(p)
	return os.time({ day = day, month = month, year = year, hour = hour, min = min })
end

--[[ Draw tv show progress bar and actual system time
@param percent {String} - tv show progress in percent
--]]
function progressBar(percent)
	ass = assdraw.ass_new()
	local w, h = mp.get_osd_size()
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
@returns {String} - TV schedule
--]]
function getEPG(el, channel)
	-- subtract utc_offset to convert local time to UTC for comparison with XML timestamps
	local now_utc = os.time() - opts.utc_offset * 3600
	datelong = os.date("%Y%m%d%H%M", now_utc)
	date = string.sub(datelong, 1, 8)
	yesterday = os.date("%Y%m%d", now_utc - 24 * 60 * 60)

	local now = { title = "", subtitle = "", desc = "" }
	program = {}
	local progress
	for _, n in ipairs(el.kids) do
		if n.type == "element" and n.name == "programme" then
			progdate = string.sub(n.attr["start"], 1, 8)
			if n.attr["channel"] == channel and (progdate == date or progdate == yesterday) then
				progstart = string.sub(n.attr["start"], 1, 12)
				progstop = string.sub(n.attr["stop"], 1, 12)
				start = formatTime(n.attr["start"])
				stop = formatTime(n.attr["stop"])
				for _, o in ipairs(n.kids) do
					if o.name == "title" then
						for _, p in ipairs(o.kids) do
							if progstart <= datelong and progstop >= datelong then -- now playing title
								progress = calculatePercentage(progstart, progstop, datelong)
								now.title = string.format(
									"{\\b1\\bord2\\fs%s\\1c&H%s}%s {\\fs%s}(%s%%)\\N",
									opts.titleSize,
									opts.titleColor,
									p.value,
									opts.progressSize,
									progress
								)
								progressBar(progress)
							elseif progstart > datelong then
								program[#program + 1] = string.format(
									"{\\b1\\be\\fs%s\\1c&H%s}⦗%s – %s⦘{\\b0\\fs%s} %s\\N",
									opts.upcomingTimeSize,
									opts.upcomingColor,
									start,
									stop,
									opts.upcomingTitleSize,
									p.value
								)
							end
						end
					elseif o.name == "sub-title" then
						for _, p in ipairs(o.kids) do
							if progstart <= datelong and progstop >= datelong then -- now playing sub-title
								now.subtitle = string.format(
									"{\\bord2\\fs%s\\b1\\i1\\1c&H%s}⦗%s-%s⦘{\\b0}- %s\\N\\N",
									opts.subtitleSize,
									opts.subtitleColor,
									start,
									stop,
									p.value
								)
							end
						end
					elseif o.name == "desc" then
						for _, p in ipairs(o.kids) do
							if progstart <= datelong and progstop >= datelong then -- now playing description
								now.desc = string.format(
									"{\\bord2\\fs%s\\1c&H%s}%s\\N\\N",
									opts.descSize,
									opts.descColor,
									p.value
								)
							end
						end
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
function getChannelID(el, identifier)
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
function setEPGChapters(channelID)
	if not channelID then return end

	local now_utc = os.time() - opts.utc_offset * 3600
	local datelong = os.date("%Y%m%d%H%M", now_utc)
	local date = string.sub(datelong, 1, 8)
	local yesterday = os.date("%Y%m%d", now_utc - 24 * 60 * 60)

	-- collect all programmes for this channel (current + upcoming)
	local chapters = {}
	for _, n in ipairs(xmltvdata.kids) do
		if n.type == "element" and n.name == "programme" and n.attr["channel"] == channelID then
			local progdate = string.sub(n.attr["start"], 1, 8)
			if progdate == date or progdate == yesterday then
				local progstart = string.sub(n.attr["start"], 1, 12)
				local progstop  = string.sub(n.attr["stop"],  1, 12)
				-- include currently running and future programmes
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
					-- offset in seconds from now as float; current programme gets 0.0
					local offset = math.max(0.0, tonumber(unixTimestamp(progstart)) - now_utc + 0.0)
					chapters[#chapters + 1] = { time = offset, title = title }
				end
			end
		end
	end

	if #chapters == 0 then return end

	-- sort by time offset
	table.sort(chapters, function(a, b) return a.time < b.time end)

	mp.set_property_native("chapter-list", chapters)
	mp.msg.info(string.format("EPG: set %d chapter(s) for channel %s", #chapters, channelID))
end

--[[ Resolve the current channel ID from the active stream URL.
@returns {String} - channel ID, or nil if not found
--]]
function resolveChannelID()
	local url = mp.get_property("stream-open-filename") or mp.get_property("path") or ""
	local channelID = nil
	for _, n in ipairs(xmltvdata.kids) do
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
			channelID = getChannelID(xmltvdata, segment)
		end
	end
	return channelID
end

--[[ Displays today TV schedule
--]]
function showEPG()
	if not (timer == nil) then
		timer:kill()
		timer = nil
	end
	local w, h = mp.get_osd_size()
	local channelID = resolveChannelID()

	if channelID then
		local data = getEPG(xmltvdata, channelID)
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
	timer = mp.add_timeout(opts.duration, function()
		ov:remove()
		mp.set_osd_ass(0, 0, "")
	end)
end

-- Set key binding.
mp.add_key_binding("h", showEPG)

mp.register_event("file-loaded", function()
	local channelID = resolveChannelID()
	setEPGChapters(channelID)
	showEPG()
end)
