require('print_r');

gerontes = {}

function task_netcheck(target)
    core.Info('GERONTES: start network check: ' .. target)
    local errors = 0
    local sleep = 1000 * gerontes.data.params.sleep
    local d = gerontes.data.net[target]
    while true do
        local s = sleep
        local t = core.tcp()
        t:settimeout(gerontes.data.params.timeout_tcp)
        local r = t:connect(d.ip, d.port)
        t:close()
        local v
        if r then
            v = 1
            errors = 0
        else
            v = d.value
            errors = errors + 1
            if errors > gerontes.data.params.fail_soft_net then
                r = 0
                s = gerontes.data.params.fail_multiplier * sleep
                core.Alert('GERONTES: netcheck: ' .. target .. ': hard-failed')
            else
                core.Warning('GERONTES: netcheck: ' .. target .. ': soft-failed: ' .. v .. ', ' .. errors .. '/' .. gerontes.data.params.fail_soft_net)
            end
        end 
        d.old_value = d.value
        d.value = v
        if not (d.value == d.old_value) then
            core.Info('GERONTES: netcheck: ' .. target .. ': ' .. d.old_value .. ' -> ' .. d.value)
            for _,g in ipairs(d.groups) do
                set_group(g)
            end
        end
        core.msleep(s)
    end
end

function task_servercheck(target)
    core.Info('GERONTES: start server check: ' .. target)
    local errors = 0
    local h = core.httpclient()
    local d = gerontes.data.servers[target]
    local sleep = 1000 * gerontes.data.params.sleep
    local timeout = 1000 * gerontes.data.params.timeout_http
    while true do
        local s = sleep
        local r = h:get{url=d.url, timeout=timeout}
        local v = nil
        -- d.url call returns the final value
        if d.type == 'precalc' then
            d.selector = '^([%d%.]+)$'
        end
        if r then
            for _,l in ipairs(core.tokenize(r.body, '\n')) do
                _, _, v = l:find(d.selector)
                if v then
                    break
                end
            end
        end
        if v then
            errors = 0
            v = tonumber(v)
            if not (d.type == 'precalc') then
                if d.type == 'up_time_sec' then
                    v = os.time() - v
                end
                v = 100 * v
                if d.weight then
                    v = v + d.weight
                end
            end
        else
            errors = errors + 1
            if errors > gerontes.data.params.fail_soft_server then
                s = gerontes.data.params.fail_multiplier * sleep
                v = 0
                core.Alert('GERONTES: servercheck: ' .. target .. ': hard-failed')
            else
                v = d.value
                core.Warning('GERONTES: servercheck: ' .. target .. ': soft-failed: ' .. v .. ', ' .. errors .. '/' .. gerontes.data.params.fail_soft_server)
            end
        end
        d.old_value = d.value
        if (v <= 0) or (v > d.value) then
            d.value = v
        end
        if not (d.value == d.old_value) then
            core.Info('GERONTES: servercheck: ' .. target .. ': ' .. d.old_value .. ' -> ' .. d.value)
            for _,g in ipairs(d.groups) do
                set_group(g)
            end
        end
        core.msleep(s)
    end
end

function service_dump(applet)
    local r = ''
    local function concat_r(x)
        r = r .. x
    end
    print_r(gerontes.data,false,concat_r)    

    applet:set_status(200)
    applet:add_header("content-length", string.len(r))
    applet:add_header("content-type", "text/plain")
    applet:start_response()
    applet:send(r)
end

function service_get(applet)
    -- path must be /ENDPOINT/server|group/NAME
    local path = core.tokenize(applet.path, '/')
    local tp = path[3]
    local n = path[4]
    local r = nil

    if tp == 'server' then
        if n and gerontes.data.servers[n] then
            r = gerontes.data.servers[n].value
        end
    else
        if tp == 'group' then
            if n and gerontes.data.groups[n] then
                r = gerontes.data.groups[n].value
            end
        end
    end

    if r then
        r = tostring(r)
        applet:add_header("content-type", "text/plain")
        applet:set_status(200)
        applet:add_header("content-length", r:len())
        applet:start_response()
        applet:send(r)    
    else
        applet:set_status(404)
        applet:start_response()
    end
end

function set_group(group)
    local d = gerontes.data.groups[group]
    local master = nil
    local net_ok = true
    local v = 0
    if d.net then
        net_ok = false
        for _,n in ipairs(d.net) do
            if gerontes.data.net[n].value == 1 then
                net_ok = true
                break
            end
        end
    end
    if net_ok then
        for _,s in ipairs(d.servers) do
            if (v == 0) or (gerontes.data.servers[s].value < v) then
                v = gerontes.data.servers[s].value
                master = s
            end
        end
    end
    d.value = v
    for sn,so in pairs(core.backends[d.backend].servers) do
        if (sn == master) and (v > 0) then
            core.Info('GERONTES: set_group: ' .. group .. ': ' .. d.backend .. '/' .. sn .. ' UP')
            so:check_force_up()
        else
            core.Info('GERONTES: set_group: ' .. group .. ': ' .. d.backend .. '/' .. sn .. ' DOWN')
            so:check_force_down()
        end
    end
end

gerontes.data = {}

function gerontes.init(data)
    gerontes.data = data
    
    -- default parameters
    p = gerontes.data.params
    if not p then
        gerontes.data.params = {}
        p = gerontes.data.params
    end
    if not p.sleep then
        p.sleep = 0.3
    end
    if not p.timeout_tcp then
        p.timeout_tcp = p.sleep
    end    
    if not p.timeout_http then
        p.timeout_http = 5 * p.sleep
    end
    if not p.fail_multiplier then
        p.fail_multiplier = 10
    end
    if not p.fail_soft_net then
        p.fail_soft_net = 10
    end
    if not p.fail_soft_server then
        p.fail_soft_server = 3
    end

    gerontes.data.groups = {}

    -- defaults for netchecks
    for _,x in pairs(gerontes.data.net) do
        x.value = 0
        x.old_value = -1
        x.groups = {}
    end

    -- defaults for servers
    for _,x in pairs(gerontes.data.servers) do
        x.value = 0
        x.old_value = -1
        x.groups = {}
        if not x.weight then
            x.weight = nil
        end
    end

    core.register_service('gerontes_dump', 'http', service_dump)
    core.register_service('gerontes_get', 'http', service_get)

    -- runs after haproxy config load
    core.register_init(
        function()
            local err = false
            local g
            local n
            for bn,bd in pairs(core.backends) do
                _, _, g, n = bn:find('(.+)__gerontes(.*)')
                if g then
                    core.Info('GERONTES: group: found `' .. g .. '`')
                    -- add servers to group
                    gerontes.data.groups[g] = { backend=bn, servers={}, net={}, value=0 }
                    for s,_ in pairs(bd.servers) do
                        if not gerontes.data.servers[s] then
                            err = true
                            core.Alert('GERONTES: group: ' .. g .. ': server `' .. s ..'`, backend `' .. bn .. '` not found in config')
                        else
                            core.Alert('GERONTES: group: ' .. g .. ': server `' .. s ..'`')
                            table.insert(gerontes.data.groups[g].servers, s)
                            table.insert(gerontes.data.servers[s].groups, g)
                        end
                    end
                    -- add netchecks to group
                    if n then
                        _, _, n = n:find(':netcheck_(.+)')
                        if n then
                            for _,n in ipairs(core.tokenize(n, '_')) do
                                if not gerontes.data.net[n] then
                                    err = true
                                    core.Alert('GERONTES: group: ' .. g .. ': netcheck `' .. n ..'`, backend `' .. bn .. '` not found in config')
                                else
                                    core.Alert('GERONTES: group: ' .. g .. ': netcheck `' .. n ..'`')
                                    table.insert(gerontes.data.groups[g].net, n)
                                    table.insert(gerontes.data.net[n].groups, g)
                                end
                            end 
                        end
                    end
                end
            end

            print_r(data)

            if err then
                error('GERONTES: config error')
            end

            -- register check tasks after data processing done
            for t,_ in pairs(gerontes.data.net) do
                core.register_task(task_netcheck, t)
            end
            for t,_ in pairs(gerontes.data.servers) do
                core.register_task(task_servercheck, t)
            end
        end
    )

end

return gerontes
