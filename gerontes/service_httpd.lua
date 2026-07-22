local function metrics()
    local r = STATIC_METRICS
    local v,x

    if OPT.haproxyMetrics then
        local m = core.httpclient():get{url=OPT.haproxyMetrics}
        if m.status == 200 then
            r = r .. '\n' .. m.body .. '\n'
        end
        m = nil
    end

    r = r .. 'gerontes_info{type="' .. OPT.type .. '"} 1\n'

    if OPT.xCheck then
        x = 'on'
    else
        x = 'off'
    end
    r = r .. 'gerontes_xcheck {xcheck="' .. x .. '"} ' .. M.xcheck .. '\n'

    for sn,sv in pairs(S) do
        r = r .. 'gerontes_server_value{server="' .. sn .. '"} ' .. tostring(sv) .. '\n'
        if M['loop_latency'][sn] ~= nil then
            r = r .. 'gerontes_loop_latency_msec{server="' .. sn .. '"} ' .. tostring(M['loop_latency'][sn]) .. '\n'
        end
        if M['server_latency'][sn] ~= nil then
            r = r .. 'gerontes_server_latency_msec{server="' .. sn .. '"} ' .. tostring(M['server_latency'][sn]) .. '\n'
        end
        if M['latency_count'][sn] ~= nil then
            r = r .. 'gerontes_latency_count{server="' .. sn .. '"} ' .. tostring(M['latency_count'][sn]) .. '\n'
        end

    end

    for bn,bd in pairs(B) do
        if bd.xcheck then
            x = 'on'
        else
            x = 'off'
        end
        r = r .. 'gerontes_proxy_value{proxy="' .. bn .. '",xcheck="' .. x .. '"} ' .. bd.value .. '\n'
        for sn,sd in pairs(core.backends[bn].servers) do
            r = r .. 'gerontes_server_up{server="' .. sn .. '",proxy="' .. bn .. '",xcheck="' .. x .. '"} ' .. tostring(M['server_up'][bn][sn]) .. '\n'
        end
    end

    return r
end

local function proxyvalue(q)
    local r
    if B[q] then
        r = tostring(B[q].value)
    end
    return r
end

local function servervalue(q)
    return tostring(S[q])
end

return function(applet)
    local r
    local rc
    
    local qs = utils.parse_args({}, applet.qs, '=', '&')

    if qs.cmd == nil or qs.cmd == 'metrics' then
        r = metrics()
    elseif qs.cmd == 'proxy' then
        r = proxyvalue(qs.query)
    elseif qs.cmd == 'server' then
        r = servervalue(qs.query)
    end

    if r then
        rc = 200
    else
        rc = 500
        r = 'Empty response'
    end

    applet:set_status(rc)
    applet:add_header("content-length", string.len(r))
    applet:add_header("content-type", "text/plain")
    applet:start_response()
    applet:send(r)

    r = nil
end
