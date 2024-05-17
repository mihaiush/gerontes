require('print_r');

local gerontes = {}

local function task_netcheck(target, sleep)
    core.Info('GERONTES: start network check: ' .. target)
    local errors = 0
    while true do
        local d = data['net'][target]
        local s = sleep
        local t = core.tcp()
        t:settimeout(2)
        local r = t:connect(d['ip'], d['port'])
        t:close()
        local v
        if r then
            v = 1
            errors = 0
            if d['value'] == 0 then
                core.Info('GERONTES: netcheck ' .. target .. ' ok\n')
            end
        else
            v = d['value']
            errors = errors + 1
            if errors > 10 then
                r = 0
                s = 10 * sleep
                core.Alert('GERONTES: netcheck ' .. target .. ' hard-failed\n')
            else
                core.Warning('GERONTES: netcheck ' .. target .. ' soft-failed -> ' .. v .. ', ' .. errors .. '\n')
            end
        end 
        d['value'] = v
        core.msleep(s)
    end
end

local function task_servercheck(target, sleep)
    core.Info('GERONTES: start server check: ' .. target)
    local errors = 0
    local h = core.httpclient()
    while true do
        local d = data['servers'][target]
        local s = sleep
        local r = h:get{url=d['url'], timeout=2000}
        local v = nil
        if r then
            for _,l in ipairs(core.tokenize(r['body'], '\n')) do
                _, _, v = l:find(d['selector'])
                if v then
                    break
                end
            end
        end
        if v then
            errors = 0
            v = tonumber(v)
            if d['type'] == 'start_time_sec' then
                v = v
            end
            if d['value'] == 0 then
                core.Info('GERONTES: servercheck ' .. target .. ': ' .. v .. '\n')
            end
        else
            errors = errors + 1
            if errors > 3 then
                s = 10 * sleep
                v = 0
                core.Alert('GERONTES: servercheck ' .. target .. ' hard-failed\n')
            else
                v = d['value']
                core.Warning('GERONTES: servercheck ' .. target .. ' soft-failed -> ' .. v .. ', ' .. errors .. '\n')
            end
        end
        d['value'] = v
        core.msleep(s)
    end
end

local function service_dump(applet)
    local r = 'net:\n'
    for t,v in pairs(data['net']) do
        r = r .. '  ' .. t .. ' -> ' .. v['value'] .. '\n'
    end
    r = r .. 'servers:\n'
    for t,v in pairs(data['servers']) do
        r = r .. '  ' .. t .. ' -> ' .. v['value'] .. '\n'
    end

    applet:set_status(200)
    applet:add_header("content-length", string.len(r))
    applet:add_header("content-type", "text/plain")
    applet:start_response()
    applet:send(r)
end

local function service_check(applet)
    local r = 'down\n'
    local sv = 0
    local sn
    local cmd = applet:getline()
    cmd = cmd:gsub('[\n\r]', '')
    cmd = core.tokenize(cmd, '_')
    local group = cmd[1]
    local server = cmd[2]
    core.Debug('GERONTES: check: group=' .. group .. ', server=' .. server)
    local g = data['groups'][group]
    if g then
        -- print_r(g)
        if data['servers'][server] then
            -- check network conectivity 
            local r_n = 1
            if g['net'] then
                -- print_r(g['net'])
                r_n = 0
                for _,n in ipairs(g['net']) do
                    if data['net'][n] then
                        if data['net'][n]['value'] == 1 then
                            -- if at least one netcheck is up -> OK
                            -- print_r(data['net'][n])
                            r_n = 1
                            break
                        end
                    else
                        core.Alert('GERONTES: check: group `' .. group .. '`, netcheck `' .. n .. '` not in config')
                        break
                    end
                end
            end
            if r_n == 1 then
                for _,s in ipairs(g['servers']) do
                    -- print_r(s)
                    -- print_r(data['servers'][s])
                    if data['servers'][s] then
                        if (sv == 0) or ((data['servers'][s]['value'] > 0) and (data['servers'][s]['value'] < sv)) then
                            sv = data['servers'][s]['value']
                            sn = s
                        end  
                    else
                        core.Alert('GERONTES: check: group `' .. group .. '`, server `' .. s .. '` not in config')
                        sv = 0
                        break
                    end
                end
                if (sn == server) and (sv > 0) then
                    r = 'up\n'
                end
            end
        else
            core.Alert('GERONTES: check: cmd: server `' .. server .. '` not in config')
        end
    else
        core.Alert('GERONTES: check: cmd: group `' .. group .. '` not in config')
    end
    applet:send(r)    
end

data = {}

function gerontes.init(cfg)
    data = cfg

    for t,x in pairs(data['net']) do
        x['value'] = 0
        core.register_task(task_netcheck, t, 300)
    end

    for t,x in pairs(data['servers']) do
        x['value'] = 0
        core.register_task(task_servercheck, t, 300)
    end    

    core.register_service('gerontes_dump', 'http', service_dump)
    core.register_service('gerontes_check', 'tcp', service_check)
end

return gerontes
