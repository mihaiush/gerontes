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
            if d.value == 0 then
                core.Info('GERONTES: netcheck ' .. target .. ' ok\n')
            end
        else
            v = d.value
            errors = errors + 1
            if errors > data.params.fail_soft_net then
                r = 0
                s = data.params.fail_multiplier * sleep
                core.Alert('GERONTES: netcheck ' .. target .. ' hard-failed\n')
            else
                core.Warning('GERONTES: netcheck ' .. target .. ' soft-failed -> ' .. v .. ', ' .. errors .. '\n')
            end
        end 
        d.value = v
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
            if d.value == 0 then
                core.Info('GERONTES: servercheck ' .. target .. ': ' .. v .. '\n')
            end
        else
            errors = errors + 1
            if errors > data.params.fail_soft_server then
                s = data.params.fail_multiplier * sleep
                v = 0
                core.Alert('GERONTES: servercheck ' .. target .. ' hard-failed\n')
            else
                v = d.value
                core.Warning('GERONTES: servercheck ' .. target .. ' soft-failed -> ' .. v .. ', ' .. errors .. '\n')
            end
        end
        d.value = v
        core.msleep(s)
    end
end

local function service_dump(applet)
    local r = 'net:\n'
    for t,v in pairs(data.net) do
        r = r .. '  ' .. t .. ' -> ' .. v.value .. '\n'
    end
    r = r .. 'servers:\n'
    for t,v in pairs(data.servers) do
        r = r .. '  ' .. t .. ' -> ' .. v.value .. '\n'
    end

    applet:set_status(200)
    applet:add_header("content-length", string.len(r))
    applet:add_header("content-type", "text/plain")
    applet:start_response()
    applet:send(r)
end

local function service_check(applet)
    local r = 'down'
    local sv = 0
    local sn
    local cmd = applet:getline()
    cmd = cmd:gsub('[\n\r]', '')
    cmd = core.tokenize(cmd, '_')
    local group = cmd[1]
    local server = cmd[2]
    core.Debug('GERONTES: check: group=' .. group .. ', server=' .. server)
    local g = data.groups[group]
    if g then
        if g.servers[server] then
            -- check network conectivity 
            local r_n = 1
            if g.net then
                r_n = 0
                for _,n in ipairs(g.net) do
                    if data.net[n].value == 1 then
                        -- if at least one netcheck is up -> OK
                        r_n = 1
                        break
                    end
                end
            end
            if r_n == 1 then
                for _,s in ipairs(g.servers) do
                    if (sv == 0) or ((data.servers[s].value > 0) and (data.servers[s].value < sv)) then
                        sv = data.servers[s].value
                        sn = s
                    end  
                end
                if (sn == server) and (sv > 0) then
                    r = 'up'
                end
            end
        else
            core.Alert('GERONTES: check: cmd: server `' .. server .. '` not in group `' .. group .. '`')
            print_r(g)
        end
    else
        core.Alert('GERONTES: check: cmd: group `' .. group .. '` not in config')
        print_r(data.groups)
    end
    applet:send(r .. '\n')    
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
    print_r(data)

    -- check config
    local err = false
    for gn, gd in pairs(data.groups) do
        for _,x in ipairs(gd.servers) do
            if not data.servers[x] then
                core.Alert('GERONTES: config: server ' .. gn .. '/' .. x .. ' unknown')
                err = true
            end
        end
        if gd.net then
            for _,x in ipairs(gd.net) do
                if not data.net[x] then
                    core.Alert('GERONTES: config: net ' .. gn .. '/' .. x .. ' unknown')
                    err = true
                end
            end
        else
            gd.net = {}
        end
    end
    if err then
        error('GERONTES: config error')
    end    

    for t,x in pairs(data.net) do
        x.value = 0
        core.register_task(task_netcheck, t)
    end

    for t,x in pairs(data.servers) do
        x.value = 0
        if not x.weight then
            x.weight = 0
        end
        core.register_task(task_servercheck, t)
    end    

    core.register_service('gerontes_dump', 'http', service_dump)
    core.register_service('gerontes_check', 'tcp', service_check)
end

return gerontes
