local lumen = require'lumen'

local log 				= lumen.log
local sched 			= lumen.sched
local streams			= lumen.stream

local socket = require 'socket'
--local pipes = require 'lumen.pipes'


--get locals for some useful things
local setmetatable, ipairs, table, type = setmetatable, ipairs, table, type 

local CHUNK_SIZE = 1480 --65536

local recvt, sendt={}, {}

local sktds = setmetatable({}, { __mode = 'k' })

local M = {}

-- streams for incomming data
local read_streams = setmetatable({}, { __mode = 'k' })

---------------------------------------
-- replace sched's default get_time and idle with luasocket's
sched.get_time = socket.gettime 
sched.idle = socket.sleep

-- pipe for async writing
--local write_pipes = setmetatable({}, weak_key)
--local outstanding_data = setmetatable({}, weak_key)

local unregister = function (fd)
  local sktd = sktds[fd]
  if not sktd then return end
  for i=1, #recvt do
    if recvt[i] == fd then
      table.remove(recvt, i)
      break
    end
  end
  if sendt[fd] then
    for i=1, #sendt do
      if sendt[i] == fd then
        table.remove(sendt, i)
        sendt[fd] = nil
        break
      end
    end
    sktd.write_stream = nil
    sktd.outstanding_data = nil
  end
  read_streams [sktd] = nil
  sktd.partial = nil
  sktds[fd] = nil
end
local function handle_incomming(sktd, data)
  if type(sktd.handler) == 'function' then 
    --local ok, errcall = pcall(sktd.handler, sktd, data) 
    local ok, errcall = xpcall(function () return sktd.handler(sktd, data) end, debug.traceback)
    if not ok then 
      log('SELECTOR', 'ERROR', 'Handler died with "%s"', tostring(errcall))
      sktd:close()
    elseif errcall==false then 
      log('SELECTOR', 'DETAIL', 'Handler finished connection')
      sktd:close()
    end
  elseif read_streams[sktd] then
    read_streams[sktd]:write(data)
  else
    sched.signal(sktd.events.data, data)
  end
end
local function handle_incomming_error(sktd, err)
  err = err or 'fd closed'
  if type(sktd.handler) == 'function' then 
    local ok, errcall = xpcall(function () return sktd.handler(sktd, nil, err) end, debug.traceback)
    --local ok, errcall = pcall(sktd.handler,sktd, nil, err)
  elseif read_streams[sktd] then
    read_streams[sktd]:write(nil, err)
  else
    sched.signal(sktd.events.data, nil, err)
  end
end
local function send_from_pipe (fd)
  local sktd = sktds[fd]
  local out_data = sktd.outstanding_data
  if out_data then 
    local data, next_pos = out_data.data, out_data.last+1
    local last, err, lasterr = fd:send(data, next_pos, next_pos+CHUNK_SIZE )
    if last == #data then
      -- all the oustanding data sent
      sktd.outstanding_data = nil
      return
    elseif err == 'closed' then 
      sktd:close()
      handle_incomming_error(sktd, 'error writing:'..tostring(err))
      return
    end
    sktd.outstanding_data.last = last or lasterr
  else
    local streamd = sktd.write_stream ; if not streamd then return end
    if streamd.len>0 then 
      local data, serr = streamd:read()
      local last , err, lasterr = fd:send(data, 1, CHUNK_SIZE)
      if err == 'closed' then
        sktd:close()
        handle_incomming_error(sktd, 'error writing:'..tostring(err))
        sched.signal(sktd.events.async_finished, false, err)
        return
      end
      last = last or lasterr
      if last < #data then
        sktd.outstanding_data = {data=data,last=last}
      end
    else
      --emptied the outgoing pipe, stop selecting to write
      for i=1, #sendt do
        if sendt[i] == fd then
          table.remove(sendt, i)
          sendt[fd] = nil
          break
        end
      end
      sched.signal(sktd.events.async_finished, true)
    end
  end
end
local init_sktd = function(sktdesc)
  sktdesc.send_sync = M.send_sync
  sktdesc.send = M.send
  sktdesc.send_async = M.send_async
  sktdesc.getsockname = M.getsockname
  sktdesc.getpeername = M.getpeername
  sktdesc.close = M.close
  return sktdesc
end
local register_server = function (sktd)
  sktd.isserver=true
  sktd.fd:settimeout(0)
  sktds[sktd.fd] = sktd
  --normalize_pattern(skt_table.pattern)
  --sktmode[sktd] = pattern
  recvt[#recvt+1]=sktd.fd
end
local register_client = function (sktd)
  sktd.fd:settimeout(0)
  sktds[sktd.fd] = sktd
  recvt[#recvt+1]=sktd.fd
end
local step = function (timeout)
  local recvt_ready, sendt_ready, err_select = socket.select(recvt, sendt, timeout)
  if err_select~='timeout' then
    for _, fd in ipairs(sendt_ready) do
      send_from_pipe(fd)
    end
    for _, fd in ipairs(recvt_ready) do
      local sktd = sktds[fd]
      --if sktd then 
      local pattern=sktd.pattern
      if sktd.isserver then 
        local client, err=fd:accept()
			  log('SELECTOR', 'DEBUG', 'Connection accepted: %s with err "%s" from select err "%s"', tostring(client), tostring(err), tostring(err_select))
        if client then
          local skt_table_client = {
            fd=client,
            --task=module_task,
            events={data=client},
            pattern=pattern,
          }
          local insktd = init_sktd(skt_table_client)
          if sktd.handler=='stream' then
            local s = streams.new()
            read_streams[insktd] = s
            insktd.stream = s
          else
            skt_table_client.handler = sktd.handler
          end
          sched.signal(sktd.events.accepted, insktd)
          register_client(insktd)
        else
          sched.signal(sktd.events.accepted, nil, err)
        end
      else
        if type(pattern) == "number" and pattern <= 0 then
          local data,err,part = fd:receive(CHUNK_SIZE)
          data = data or part
          if data then 
            handle_incomming(sktd, data)
          end
          if err=='closed' then
            handle_incomming_error(sktd, err)
            sktd:close()
          end
        else
          local data,err,part = fd:receive(pattern,sktd.partial)
          sktd.partial=part
          if data then
            handle_incomming(sktd, data)
          elseif err=='closed' then 
            handle_incomming_error(sktd, err)
            sktd:close()
          end
        end
        --end
      end
    end
  end
end
---------------------------------------

local normalize_pattern = function(pattern)
  if pattern=='*l' or pattern=='line' then
    return '*l'
  end
  if tonumber(pattern) and tonumber(pattern)>0 then
    return pattern
  end
  if not pattern or pattern == '*a' 
  or (tonumber(pattern) and tonumber(pattern)<=0) then
    return  0 --'*a'
  end
  log('SELECTOR', 'WARN', 'Could not normalize pattern "%s"', tostring(pattern))
end

M.init = function()
  M.new_tcp_server = function (locaddr, locport, pattern, handler)
    --address, port, backlog, pattern)
    local fd, errmsg = socket.bind(locaddr, locport)
    if not fd then return nil, errmsg end

    local sktd=init_sktd({
      fd = fd,
      --task=module_task,
      pattern = normalize_pattern(pattern),
      handler = handler,
    })
    sktd.events = {accepted=sktd.fd}
    if sktd.pattern=='*l' and handler == 'stream' then sktd.pattern=nil end
    register_server(sktd)
    return sktd
  end
  M.new_tcp_client = function (address, port, locaddr, locport, pattern, handler, timeout)
    --address, port, locaddr, locport, pattern)
    local now = sched.get_time()
    local fd = socket.tcp()
    --FIXME timeout handling for connecting should be made within main select()
    timeout = timeout or 20 -- a default value
    fd:settimeout(0)
    local ok, errmsg
    repeat
        ok, errmsg = fd:connect(address, port, locaddr, locport)
        if not ok then sched.sleep(0.1) end
    until ok or sched.get_time()-now>timeout
    if not ok then return nil, errmsg end

    local sktd=init_sktd({
      fd = fd,
      --task=module_task,
      pattern = normalize_pattern(pattern),
      handler = handler,
    })
    
    sktd.events = {data=sktd.fd, async_finished={}}
    if sktd.pattern=='*l' and handler == 'stream' then sktd.pattern=nil end
    if handler=='stream' then
      local s = streams.new()
      read_streams[sktd] = s
      sktd.stream = s
    end
    register_client(sktd)
    return sktd
  end
  M.new_udp = function ( address, port, locaddr, locport, pattern, handler)
    --address, port, locaddr, locport, count)
    local sktd=init_sktd({
      fd=socket.udp(),
      --task=module_task,
      pattern=pattern,
      handler = handler,
    })
    sktd.events = {data=sktd.fd, async_finished={}}
    if locaddr or locport then
      sktd.fd:setsockname(locaddr or '*', locport or 0)
    end
    if address or port then
      sktd.fd:setpeername(address or '*', port)
    end
    register_client(sktd)
    return sktd
  end
  M.close = function(sktd)
    unregister(sktd.fd)
    sktd.fd:close()
  end
  M.send_sync = function(sktd, data)
    local start, err,done=0, nil, nil
    while true do
      start, err=sktd.fd:send(data,start+1)
      done = start==#data
      if done or err then
        break
      else
        sched.wait()
      end
    end
    return done, err, start
  end
  M.send = M.send_sync
  M.send_async = function (sktd, data)
    --make sure we're selecting to write
    local skt=sktd.fd
    if not sendt[skt] then 
      sendt[#sendt+1] = skt
      sendt[skt]=true
    end
    
    local streamd = sktd.write_stream
    
    -- initialize the pipe on first send
    if not streamd then
      streamd = streams.new(M.ASYNC_SEND_BUFFER)
      sktd.write_stream = streamd
    end
    streamd:write(data)
    
    sched.wait()
  end
  M.new_fd = function ()
    return nil, 'Not supported by luasocket'
  end
  M.getsockname = function(sktd)
    return sktd.fd:getsockname()
  end
  M.getpeername = function(sktd)
    return sktd.fd:getpeername()
  end

  M.task=sched.run(function ()
    while true do
      local _, t, _ = sched.wait()
      step( t )
    end
  end)
  
  --[[
	M.register_server = service.register_server
	M.register_client = service.register_client
	M.unregister = service.unregister
	--]]
  return M
end

return M


