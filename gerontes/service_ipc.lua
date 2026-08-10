return function(applet)
    local r
    local l = applet:getline()
    l = string.gsub(l, '[\r\n]', '')
    utils.log.debug('ipc: recive: ' .. l)
    l = utils.split(l,' ')
    local cmd = l[1]
    if cmd == 'ping' then
        r = 'ok'
    elseif cmd == 'server' then
        S[l[2]] = tonumber(l[3])
        update_servers('ipc/' .. l[2])
        -- set_server(l[2], tonumber(l[3]))
        r = 'ok'
    elseif cmd == 'metrics' then
        M['loop_latency'][l[2]] = l[3]
        M['server_latency'][l[2]] = l[4]
        M['latency_count'][l[2]] = M['latency_count'][l[2]] + 1
        r = 'ok'
    else
        r = 'err'
    end
    applet:send(r .. '\n')
end

