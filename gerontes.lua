require('print_r');

local gerontes = {}

local function task_netcheck(target, sleep)
    core.Info('Start network check: ' .. target)
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
                core.Info('Netcheck ' .. target .. ' ok\n')
            end
        else
            v = d['value']
            errors = errors + 1
            if errors > 10 then
                r = 0
                s = 10 * sleep
                core.Alert('Netcheck ' .. target .. ' hard-failed\n')
            else
                core.Warning('Netcheck ' .. target .. ' soft-failed -> ' .. v .. ', ' .. errors .. '\n')
            end
        end 
        data['net'][target]['value'] = v
        core.msleep(s)
    end
end

local function task_servercheck(target, sleep)
    core.Info('Start server check: ' .. target)
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
                core.Info('Servercheck ' .. target .. ': ' .. v .. '\n')
            end
        else
            errors = errors + 1
            if errors > 3 then
                s = 10 * sleep
                v = 0
                core.Alert('Servercheck ' .. target .. ' hard-failed\n')
            else
                v = d['value']
                core.Warning('Servercheck ' .. target .. ' soft-failed -> ' .. v .. ', ' .. errors .. '\n')
            end
        end
        data['servers'][target]['value'] = v
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
    local cmd = applet:getline()
    cmd = cmd:gsub('[\n\r]', '')
    cmd = core.tokenize(cmd, '_')
    local group = cmd[1]
    local server = cmd[2]
    local weight = cmd[3]
    if weight then
        weight = tonumber(weight)
    else
        weight = 0
    end
    core.Info('Health check: cmd: group=' .. group .. ', server=' .. server .. ', weight=' .. weight)
    
end

data = {}

function gerontes.init(cfg)
    data = cfg
    -- print_r(data)

    for t,_ in pairs(data['net']) do
        core.register_task(task_netcheck, t, 300)
    end

    for t,_ in pairs(data['servers']) do
        core.register_task(task_servercheck, t, 300)
    end    

    core.register_service('gerontes_dump', 'http', service_dump)
    core.register_service('gerontes_check', 'tcp', service_check)
end

return gerontes
