local function server_worker(srvtype, target, worker)
    local label = srvtype .. '/' .. target -- log label
    label = 'task: ' .. label .. ': '
    
    if OPT.debug then
        utils.log.enable_debug()
    end
    utils.log.info(label .. 'start')

    local err = 0
    local loop_count = 0
    local loop_latency = 0
    local check_latency = 0    
    
    local sleep = 1000 * OPT.sleep
    local s
    local v = 0
    local r = 0
    local ok = false
    local t0, t1

    core.sleep(2) -- wait for servers to start

    while true do
        s = sleep

        t0 = utils.now()        
        ok, r = worker(label, utils.strip_type(target))
        t0 = 1000 * (utils.now() - t0)

        if ok then
            v = r
            err = 0
                if OPT.latencyMetrics then 
                    loop_count = loop_count + 1
                    check_latency = check_latency + t0
                    if loop_count >= OPT.latencyMetrics then
                        utils.log.debug(label .. 'check latency: ' .. check_latency / loop_count)
                        M['server_latency'][target] = check_latency / loop_count
                        M['latency_count'][target] = M['latency_count'][target] + 1
                        loop_count = 0
                        loop_latency = 0
                        check_latency = 0
                    end
                end
        else
            if err < OPT.softFail then
                err = err + 1
                utils.log.warning(label .. 'soft-failed: ' .. v .. ' ' .. err .. '/' .. OPT.softFail ..': ' .. r)
            else
                v = 0
                s = OPT.failMultiplier * sleep
                utils.log.error(label .. 'hard-failed' .. ': ' .. r)
            end
        end
        set_server(target,v)
        core.msleep(s)
    end -- while
end

return function(srvtype, target, worker)
    core.register_task(server_worker, srvtype, target, worker)
end

