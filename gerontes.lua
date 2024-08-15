require('print_r');

gerontes = {}

function task_netcheck(target)
    core.Info('GERONTES: start network check: ' .. target)
    local errors = 0
    local sleep = 1000 * gerontes.params.sleep
    local d = gerontes.net[target]
    while true do
        local s = sleep
        local t = core.tcp()
        t:settimeout(gerontes.params.timeout_tcp)
        local r = t:connect(d.ip, d.port)
        t:close()
        local v
        if r then
            v = 1
            errors = 0
        else
            v = d.value
            errors = errors + 1
            if errors > gerontes.params.fail_soft_net then
                r = 0
                s = gerontes.params.fail_multiplier * sleep
                core.Alert('GERONTES: netcheck: ' .. target .. ': hard-failed')
            else
                core.Warning('GERONTES: netcheck: ' .. target .. ': soft-failed: ' .. v .. ', ' .. errors .. '/' .. gerontes.params.fail_soft_net)
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
    local d = gerontes.servers[target]
    local sleep = 1000 * gerontes.params.sleep
    local timeout = 1000 * gerontes.params.timeout_http
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
            if errors > gerontes.params.fail_soft_server then
                s = gerontes.params.fail_multiplier * sleep
                v = 0
                core.Alert('GERONTES: servercheck: ' .. target .. ': hard-failed')
            else
                v = d.value
                core.Warning('GERONTES: servercheck: ' .. target .. ': soft-failed: ' .. v .. ', ' .. errors .. '/' .. gerontes.params.fail_soft_server)
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

    r = r .. '\nPARAMS:\n'
    print_r(gerontes.params,false,concat_r)

    r = r .. '\nSERVERS:\n'
    print_r(gerontes.servers,false,concat_r)

    r = r .. '\nNET:\n'
    print_r(gerontes.net,false,concat_r)

    r = r .. '\nGROUPS:\n'
    print_r(gerontes.groups,false,concat_r)     

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
        if n and gerontes.servers[n] then
            r = gerontes.servers[n].value
        end
    else
        if tp == 'group' then
            if n and gerontes.groups[n] then
                r = gerontes.groups[n].value
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
    local d = gerontes.groups[group]
    local master = nil
    local net_ok = true
    local v = 0
    if d.net then
        net_ok = false
        for _,n in ipairs(d.net) do
            if gerontes.net[n].value == 1 then
                net_ok = true
                break
            end
        end
    end
    if net_ok then
        for _,s in ipairs(d.servers) do
            if (v == 0) or (gerontes.servers[s].value < v) then
                v = gerontes.servers[s].value
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

gerontes.params = {}
gerontes.servers = {}
gerontes.net = {}
gerontes.groups = {}

function gerontes.init(data)
    
    -- default parameters
    if data.params then
        gerontes.params = data.params
    end
    p = gerontes.params
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

    gerontes.servers = data.servers
    if data.net then
        gerontes.net = data.net
    end

    -- defaults for netchecks
    for _,x in pairs(gerontes.net) do
        x.value = 0
        x.old_value = -1
        x.groups = {}
    end

    -- defaults for servers
    for _,x in pairs(gerontes.servers) do
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
            local opt
            local n
            for bn,bd in pairs(core.backends) do
                _, _, g, opt = bn:find('(.+)__gerontes(.*)')
                if g then
                    core.Info('GERONTES: group: found `' .. g .. '` in backend `' .. bn .. '`')
                    -- add servers to group
                    gerontes.groups[g] = { backend=bn, servers={}, net={}, value=0 }
                    for s,_ in pairs(bd.servers) do
                        if not gerontes.servers[s] then
                            err = true
                            core.Alert('GERONTES: group: ' .. g .. ': server `' .. s ..'`, backend `' .. bn .. '` not found in config')
                        else
                            core.Alert('GERONTES: group: ' .. g .. ': server `' .. s ..'`')
                            table.insert(gerontes.groups[g].servers, s)
                            table.insert(gerontes.servers[s].groups, g)
                        end
                    end
                    -- add netchecks to group
                    if opt then
                        _, _, n = opt:find(':netcheck_(.+)')
                        if n then
                            for _,n in ipairs(core.tokenize(n, '_')) do
                                if not gerontes.net[n] then
                                    err = true
                                    core.Alert('GERONTES: group: ' .. g .. ': netcheck `' .. n ..'`, backend `' .. bn .. '` not found in config')
                                else
                                    core.Alert('GERONTES: group: ' .. g .. ': netcheck `' .. n ..'`')
                                    table.insert(gerontes.groups[g].net, n)
                                    table.insert(gerontes.net[n].groups, g)
                                end
                            end 
                        else
                            n, _, _ = opt:find(':netcheck')
                            if n then
                                for n, _ in pairs(gerontes.net) do
                                    core.Alert('GERONTES: group: ' .. g .. ': netcheck `' .. n ..'`')
                                    table.insert(gerontes.groups[g].net, n)
                                    table.insert(gerontes.net[n].groups, g)
                                end
                            end
                        end
                    end
                end
            end

            if err then
                error('GERONTES: config error')
            end

            -- register check tasks after data processing done
            for t,_ in pairs(gerontes.net) do
                core.register_task(task_netcheck, t)
            end
            for t,_ in pairs(gerontes.servers) do
                core.register_task(task_servercheck, t)
            end
        end
    )

end

return gerontes
