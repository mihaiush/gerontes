local json = require('lunajson')

local function server_worker(srvtype, target, worker, apicall)
    local label = srvtype .. '/' .. target -- log label
    label = 'kubewatch: ' .. label .. ': '
 
    if OPT.debug then
        utils.log.enable_debug()
    end
    utils.log.info(label .. 'start')

    apicall = apicall .. '&resourceVersion=0&watch=true'
    utils.log.debug(label .. 'api call: ' .. apicall)

    local request = 'GET ' .. apicall .. ' HTTP/1.1\r\n' ..
                    'Host: 127.0.0.1\r\n' ..
                    '\r\n'

    local sleep = 1000 * OPT.sleep
    local err = 0

    core.sleep(2) -- wait for servers to start

    M['latency_count'][target] = 0
   
    while true do
        local r = 'unknown'
        local ok = false
        local data
        local s = sleep
        
        local tcp = core.tcp()
        tcp:settimeout(OPT.timeout)
        local t0 = utils.now()
        utils.log.debug(label .. 'connect')
        local ka = utils.split(OPT.kubeApi, ':')
        if ka[2] then
            ok, r = tcp:connect(ka[1], ka[2])
        else
            ok, r = tcp:connect('unix@' .. ka[1])
            local ka_addr = 'unix@' .. ka[1]
        end
        if ok then
            ok, r = tcp:send(request)
            if ok then
                local r_code, r_text, chunked

                -- read headers
                while true do
                    data, ok = tcp:receive()
                    if ok == nil then
                        data = data:lower()
                        ok = true
                    else
                        r = ok
                        ok = false
                        break
                    end
                    if not r_code then
                        data = utils.split(data, ' ')
                        r_code = tonumber(data[2])
                        r_text = data[3]
                    elseif data == 'transfer-encoding: chunked' then
                        chunked = true
                    end
                    if data == '' then break end -- empty line, end of headers
                end

                -- check headers
                if ok then
                    if r_code ~= 200 then
                        r = r_code .. '/' .. r_text
                        ok = false 
                    elseif not chunked then
                        r = 'not chunked'
                        ok = false
                    end
                end

                -- read events
                if ok then
                    t0 = 1000 * (utils.now() - t0)
                    M['server_latency'][target] = t0
                    M['latency_count'][target] = M['latency_count'][target] + 1
                    utils.log.debug(label .. 'api latency: ' .. t0)
                
                    tcp:settimeout(OPT.watchTimeout)
                    while true do
                        -- read chunk size
                        while true do
                            -- loop until no blank line
                            data, ok = tcp:receive()
                            if ok == nil then
                                if data ~= '' then
                                    data = tonumber(data,16)
                                    ok = true
                                    break
                                end
                            else
                                data = nil
                                r = ok
                                ok = true -- most likely watch timeout
                                s = 1
                                break
                            end
                        end
                        if data == nil then
                            break
                        end
                        -- read chunk
                        data, ok = tcp:receive(data)
                        if ok == nil then
                            ok, r = pcall(json.decode, data)
                            if ok then
                                ok, r = worker(label, r)
                            end
                            if ok then
                                err = 0
                                set_server(target, r)
                            else
                                break 
                            end
                        else
                            r = ok
                            ok = false
                            break
                        end
                    end
                end
                
            end
        end

        tcp:close()

        if not ok then
            if err < OPT.softFail then
                err = err + 1
                utils.log.warning(label .. 'soft-failed: ' .. S[target] .. ' ' .. err .. '/' .. OPT.softFail ..': ' .. r)
            else
                s = OPT.failMultiplier * sleep
                utils.log.error(label .. 'hard-failed' .. ': ' .. r)
                set_server(target, 0)
            end
        end

        core.msleep(s)
    end -- while
end

return function(srvtype, target, worker, apicall)
    core.register_task(server_worker, srvtype, target, worker, apicall)
end

