--[[
mpvEPG v0.3
lua script for mpv parses XMLTV data and displays scheduling information for current and upcoming broadcast programming.

Dependency: SLAXML (https://github.com/Phrogz/SLAXML)

Copyright © 2020 Peter Žember; MIT Licensed
See https://github.com/dafyk/mpvEPG for details.
--]]
require 'os'
require 'io'
require 'string'

local opts = {
    epg_dir        = '',       -- directory containing XMLTV files

    titleColor     = '00FBFE', -- now playing title color (hex BGR)
    subtitleColor  = '00FBFE', -- now playing sub-title color (hex BGR)
    descColor      = 'FFFFFF', -- now playing description color (hex BGR)
    clockColor     = '00FBFE', -- clock color (hex BGR)
    upcomingColor  = 'FFFFFF', -- upcoming list color (hex BGR)
    noEpgMsgColor  = '002DD1', -- no EPG message color (hex BGR)

    titleSize      = 50,       -- now playing title font size
    subtitleSize   = 40,       -- now playing sub-title font size
    descSize       = 30,       -- now playing description font size
    progressSize   = 40,       -- progress percentage font size
    upcomingTimeSize  = 25,    -- upcoming broadcast time font size
    upcomingTitleSize = 35,    -- upcoming broadcast title font size

    noEpgMsg       = 'No EPG for this channel', -- message when no EPG found
    duration       = 5,        -- seconds before EPG overlay hides
    utc_offset     = 0,        -- offset in hours between EPG timestamps (UTC) and local time; e.g. 2 for CEST (UTC+2)
}
require('mp.options').read_options(opts, 'mpvEPG')

-- resolve epg_dir: fall back to ~/.config/mpv/epg if not set via script-opts
local epg_dir = opts.epg_dir ~= '' and opts.epg_dir or (os.getenv('HOME')..'/.config/mpv/epg')



local ov = mp.create_osd_overlay('ass-events')
local utils = require 'mp.utils'

-- add scripts/lib to the Lua search path so slaxml/slaxdom can be found there
local script_path = debug.getinfo(1, 'S').source:match('^@(.+)$')
local script_dir = script_path:match('^(.+)[/\\][^/\\]+$')
package.path = utils.join_path(script_dir, 'lib/?.lua') .. ';' .. package.path

local SLAXML = require 'slaxdom'

-- Load and merge all .xml files from the configured directory into a single virtual root
local xmltvdata = {kids = {}}
local seen_programmes = {} -- deduplication key: channel+start+stop
local seen_channels = {}   -- deduplication key: channel id
local files = utils.readdir(epg_dir, 'files')
if files then
  table.sort(files)
  for _, name in ipairs(files) do
    if name:match('%.xml$') then
      local path = utils.join_path(epg_dir, name)
      local f = io.open(path)
      if f then
        local raw = f:read('*all')
        f:close()
        raw = raw:gsub('<!DOCTYPE[^>]*>', '')
        local parsed = SLAXML:dom(raw, {stripWhitespace=true}).root
        if parsed and parsed.kids then
          for _, kid in ipairs(parsed.kids) do
            if kid.type == 'element' and kid.name == 'programme' then
              local key = (kid.attr['channel'] or '')..'|'..(kid.attr['start'] or '')..'|'..(kid.attr['stop'] or '')
              if not seen_programmes[key] then
                seen_programmes[key] = true
                xmltvdata.kids[#xmltvdata.kids+1] = kid
              end
            elseif kid.type == 'element' and kid.name == 'channel' then
              local id = kid.attr['id'] or ''
              if not seen_channels[id] then
                seen_channels[id] = true
                xmltvdata.kids[#xmltvdata.kids+1] = kid
              end
            else
              xmltvdata.kids[#xmltvdata.kids+1] = kid
            end
          end
        end
        mp.msg.info('Loaded EPG file: '..name)
      else
        mp.msg.warn('Could not open EPG file: '..path)
      end
    end
  end
else
  mp.msg.error('Could not read EPG directory: '..epg_dir)
end

local assdraw = require 'mp.assdraw'
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
  if total < 0 then total = total + 24 * 60 end
  return string.format('%02d:%02d', math.floor(total / 60), total % 60)
end

--[[ Calculate tv show progress in percents
@param start {String} - program start, format: YYYYMMDDHHmm 
@param stop {String} - program end, format: YYYYMMDDHHmm 
@param now {String} - actual time, format: YYYYMMDDHHmm 
@returns {String} - Percentage of program progress in two decimal places
--]]
function calculatePercentage(start,stop,now)
  start = tonumber(unixTimestamp(start))
  stop = tonumber(unixTimestamp(stop))
  now = tonumber(unixTimestamp(now))
  return string.format('%0.2f', (now-start)/(stop-start)*100)
end

--[[ Convert YYYYMMDDHHmm string to unix timestamp
@param s {String} - time string, format: YYYYMMDDHHmm 
@returns {String} - unix timestamp
--]]
function unixTimestamp(s)
  p = '(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)'
  year,month,day,hour,min=s:match(p)
  return os.time({day=day,month=month,year=year,hour=hour,min=min})
end

--[[ Draw tv show progress bar and actual system time
@param percent {String} - tv show progress in percent
--]]
function progressBar(percent)
  ass = assdraw.ass_new()
  local w, h = mp.get_osd_size()
  local p = ((w-14)/100)*percent
  if not(w==0) then
    ass:new_event() -- progress bar background
    ass:append('{\\bord2}') -- border size
    ass:append('{\\1c&000000&}') -- background color
    ass:append('{\\3c&000000&}') -- border color
    ass:append('{\\1a&80&}') -- alpha
    ass:pos(7, -5)
    ass:draw_start()
    ass:round_rect_cw(0, 20, w-14, 10,1)
    ass:draw_stop()

    ass:new_event() -- progress bar
    ass:pos(7, -5)
    ass:append('{\\bord0}') -- border size
    ass:append('{\\shad0}') -- shadow
    ass:append('{\\1a&0&}') -- alpha
    ass:append('{\\1c&00FBFE&}') -- background color
    ass:append('{\\3c&000000&}') -- border color
    ass:draw_start()
    ass:rect_cw(1, 19, p, 11)
    ass:draw_stop()

    ass:new_event() -- clock background
    ass:pos(w-128, 21)
    ass:append('{\\bord2}') -- border size
    ass:append('{\\shad0}') -- shadow
    ass:append('{\\1a&80&}') -- alpha
    ass:append('{\\1c&000000&}') -- background color
    ass:append('{\\3c&000000&}') -- border color
    ass:draw_start()
    ass:round_rect_cw(0, 0, 121, 48, 2)
    ass:draw_stop()

    ass:new_event() -- clock
    ass:pos(w-122, 20)
    ass:append('{\\bord2}') -- border size
    ass:append('{\\shad0}') -- shadow
    ass:append('{\\fs50\\b1}') -- font-size
    ass:append('{\\1c&00FBFE&}') -- background color
    ass:append('{\\3c&000000&}') -- border color
    ass:append(os.date('%H:%M'))
  end
end

--[[ Create today TV schedule for channel from xmltv data
@param el {Table} - SLAXML:dom() parsed table
@param channel {String} - channel ID
@returns {String} - TV schedule
--]]
function getEPG(el,channel)
  -- subtract utc_offset to convert local time to UTC for comparison with XML timestamps
  local now_utc = os.time() - opts.utc_offset * 3600
  datelong = os.date('%Y%m%d%H%M', now_utc)
  date = string.sub(datelong, 1, 8)
  yesterday = os.date('%Y%m%d', now_utc - 24*60*60)

  local now = {title='', subtitle='', desc=''}
  program = {}
  local progress
  for _,n in ipairs(el.kids) do
    if n.type=='element' and n.name=='programme' then 
      progdate = string.sub(n.attr['start'], 1, 8)
      if n.attr['channel']==channel and (progdate==date or progdate==yesterday) then 
        progstart = string.sub(n.attr['start'], 1, 12)
        progstop = string.sub(n.attr['stop'], 1, 12)
        start = formatTime(n.attr['start'])
        stop = formatTime(n.attr['stop'])
        for _,o in ipairs(n.kids) do
          if o.name=='title' then
            for _,p in ipairs(o.kids) do
              if progstart<=datelong and progstop>=datelong then -- now playing title
                progress = calculatePercentage(progstart,progstop,datelong)
                now.title = string.format('{\\b1\\bord2\\fs%s\\1c&H%s}%s {\\fs%s}(%s%%)\\N',opts.titleSize,opts.titleColor,p.value,opts.progressSize,progress)
                progressBar(progress)
              elseif progstart>datelong then
                program[#program+1] = string.format('{\\b1\\be\\fs%s\\1c&H%s}⦗%s – %s⦘{\\b0\\fs%s} %s\\N',opts.upcomingTimeSize,opts.upcomingColor,start,stop,opts.upcomingTitleSize,p.value)
              end
            end
          elseif o.name=='sub-title' then
            for _,p in ipairs(o.kids) do
              if progstart<=datelong and progstop>=datelong then -- now playing sub-title
                now.subtitle = string.format('{\\bord2\\fs%s\\b1\\i1\\1c&H%s}⦗%s-%s⦘{\\b0}- %s\\N\\N',opts.subtitleSize,opts.subtitleColor,start,stop,p.value)
              end
            end
          elseif o.name=='desc' then
            for _,p in ipairs(o.kids) do
              if progstart<=datelong and progstop>=datelong then -- now playing description
                now.desc = string.format('{\\bord2\\fs%s\\1c&H%s}%s\\N\\N',opts.descSize,opts.descColor,p.value)
              end
            end
          end
        end
      end
    end
  end
  -- sub-title takes priority over desc; fall back to desc if no sub-title present
  if now.subtitle=='' then
    now.subtitle = now.desc ~= '' and now.desc or '\\N'
  end
  table.sort(program)
  table.insert(program,1,now.subtitle)
  table.insert(program,1,now.title)  
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
  for _,n in ipairs(el.kids) do
    if n.type=='element' and n.name=='channel' then
      -- direct id match (e.g. channel ID appears in stream URL)
      if n.attr['id'] == identifier then
        return n.attr['id']
      end
      -- display-name match (fallback)
      for _,o in ipairs(n.kids) do
        if o.name=='display-name' then
          for _,p in ipairs(o.kids) do
            if p.value == identifier then
              return n.attr['id']
            end
          end
        end
      end
    end
  end
  return nil
end

--[[ Displays today TV schedule
--]]
function showEPG()
  if not(timer==nil) then
    timer:kill()
    timer = nil
  end
  local w, h = mp.get_osd_size()
  local url = mp.get_property('stream-open-filename') or ''

  -- Try to find a channel ID by matching each known channel id against the stream URL.
  -- Pluto TV stream URLs typically contain the channel ID as a path segment.
  local channelID = nil
  for _,n in ipairs(xmltvdata.kids) do
    if n.type=='element' and n.name=='channel' then
      local id = n.attr['id']
      if id and url:find(id, 1, true) then
        channelID = id
        break
      end
    end
  end

  -- Fallback: try last URL segment as display-name or channel ID
  if not channelID then
    local segment = string.match(url, '[^/]+$')
    if segment then
      channelID = getChannelID(xmltvdata, segment)
    end
  end

  if channelID then
    local data = getEPG(xmltvdata, channelID)
    if data then
      ov.data = data
    else
      ov.data = string.format('{\\b0\\1c&H%s}%s',opts.noEpgMsgColor,opts.noEpgMsg)
      ass.text = ''
    end
  else
    ov.data = string.format('{\\b0\\1c&H%s}%s',opts.noEpgMsgColor,opts.noEpgMsg)
    ass.text = ''
  end
  ov:update()
  mp.set_osd_ass(w, h, ass.text)
  timer = mp.add_timeout(opts.duration, function() ov:remove(); mp.set_osd_ass(0, 0, ''); end )
end
 
-- Set key binding.
mp.add_key_binding('h', showEPG)
mp.register_event('file-loaded', showEPG)
