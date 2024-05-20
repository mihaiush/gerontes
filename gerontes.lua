require('print_r');

local gerontes = {}

local function task_netcheck(target)
    core.Info('GERONTES: start network check: ' .. target)
    local errors = 0
    local sleep = 1000 * data.params.sleep
    local d = data.net[target]
    while true do
        local s = sleep
        local t = core.tcp()
        t:settimeout(data.params.timeout_tcp)
        local r = t:connect(d.ip, d.port)
        t:close()
        local v
        if r then
            v = 1
            errors = 0
        else
            v = d.value
            errors = errors + 1
            if errors > data.params.fail_soft_net then
                r = 0
                s = data.params.fail_multiplier * sleep
                core.Alert('GERONTES: netcheck: ' .. target .. ': hard-failed')
            else
                core.Warning('GERONTES: netcheck: ' .. target .. ': soft-failed: ' .. v .. ', ' .. errors .. '/' .. data.params.fail_soft_net)
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

local function task_servercheck(target)
    core.Info('GERONTES: start server check: ' .. target)
    local errors = 0
    local h = core.httpclient()
    local d = data.servers[target]
    local sleep = 1000 * data.params.sleep
    local timeout = 1000 * data.params.timeout_http
    while true do
        local s = sleep
        local r = h:get{url=d.url, timeout=timeout}
        local v = nil
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
            if d.type == 'up_time_sec' then
                v = os.time() - v
            end
            v = 100 * v
            if d.weight then
                v = v + d.weight
            end
        else
            errors = errors + 1
            if errors > data.params.fail_soft_server then
                s = data.params.fail_multiplier * sleep
                v = 0
                core.Alert('GERONTES: servercheck: ' .. target .. ': hard-failed')
            else
                v = d.value
                core.Warning('GERONTES: servercheck: ' .. target .. ': soft-failed: ' .. v .. ', ' .. errors .. '/' .. data.params.fail_soft_server)
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

local function service_dump(applet)
    --[[
    local r = 'net:\n'
    for t,v in pairs(data.net) do
        r = r .. '  ' .. t .. ' -> ' .. v.value .. '\n'
    end
    r = r .. 'servers:\n'
    for t,v in pairs(data.servers) do
        r = r .. '  ' .. t .. ' -> ' .. v.value .. '\n'
    end
    --]]
    local r = ''
    local function concat_r(x)
        r = r .. x
    end
    print_r(data,false,concat_r)    

    applet:set_status(200)
    applet:add_header("content-length", string.len(r))
    applet:add_header("content-type", "text/plain")
    applet:start_response()
    applet:send(r)
end

function set_group(group)
    local d = data.groups[group]
    local master = nil
    local net_ok = true
    if d.net then
        net_ok = false
        for _,n in ipairs(d.net) do
            if data.net[n].value == 1 then
                net_ok = true
                break
            end
        end
    end
    if net_ok then
        local v = 0
        for _,s in ipairs(d.servers) do
            if not (data.servers[s].value == 0) and (data.servers[s].value < v) then
                v = data.servers[s].value
                master = s
            end
        end
    end
    for sn,so in pairs(core.backends[d.backend].servers) do
        if sn == master then
            core.Info('GERONTES: set_group:' .. group .. ': ' .. d.backend .. '/' .. sn .. ' UP')
            so:check_force_up()
        else
            core.Info('GERONTES: set_group:' .. group .. ': ' .. d.backend .. '/' .. sn .. ' DOWN')
            so:check_force_down()
        end
    end
end

data = {}

function gerontes.init(cfg)
    data = cfg
    
    -- default parameters
    p = data.params
    if not p then
        data.params = {}
        p = data.params
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

    data.groups = {}

    for t,x in pairs(data.net) do
        x.value = 0
        x.old_value = -1
        x.groups = {}
    end

    for t,x in pairs(data.servers) do
        x.value = 0
        x.old_value = -1
        x.groups = {}
        if not x.weight then
            x.weight = nil
        end
    end

    core.register_service('gerontes_dump', 'http', service_dump)

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
                    data.groups[g] = { backend=bn, servers={}, net={} }
                    for s,_ in pairs(bd.servers) do
                        if not data.servers[s] then
                            err = true
                            core.Alert('GERONTES: group: ' .. g .. ': server `' .. s ..'`, backend `' .. bn .. '` not found in config')
                        else
                            core.Alert('GERONTES: group: ' .. g .. ': server `' .. s ..'`')
                            table.insert(data.groups[g].servers, s)
                            table.insert(data.servers[s].groups, g)
                        end
                    end
                    -- add netchecks to group
                    if n then
                        _, _, n = n:find(':netcheck_(.+)')
                        if n then
                            for _,n in ipairs(core.tokenize(n, '_')) do
                                if not data.net[n] then
                                    err = true
                                    core.Alert('GERONTES: group: ' .. g .. ': netcheck `' .. n ..'`, backend `' .. bn .. '` not found in config')
                                else
                                    core.Alert('GERONTES: group: ' .. g .. ': netcheck `' .. n ..'`')
                                    table.insert(data.groups[g].net, n)
                                    table.insert(data.net[n].groups, g)
                                end
                            end 
                        end
                    end
                end
            end

            for t,x in pairs(data.net) do
                core.register_task(task_netcheck, t)
            end

            for t,x in pairs(data.servers) do
                core.register_task(task_servercheck, t)
            end

            print_r(data)

            if err then
                error('GERONTES: config error')
            end
        end
    )

end

return gerontes
