posix = require('posix')

local master_pid = posix.getpid().pid
local err_ipc_ping='ipc check failed'

local function ipc(msg)
    local socket = posix.sys.socket
    local sockfd = socket.socket (socket.AF_UNIX, socket.SOCK_STREAM, 0)
    local r = socket.connect(sockfd, {family = socket.AF_UNIX, path = OPT.ipcSock})
    if r == 0 then
        socket.send(sockfd, msg .. "\n")
        r = socket.recv(sockfd, 1024)
        socket.shutdown(sockfd, socket.SHUT_RDWR)
    else
        r = 'err'
    end
    return string.gsub(r, '\n$', '')
end

local function server_worker(srvtype, target, worker, to_flag)
    local label = srvtype .. '/' .. target -- log label
    
    local main_data = '/dev/shm/gerontes_' .. string.gsub(label,'[^%a%d]','_')
    local worker_data = main_data .. '_worker' -- pass data from worker
    main_data = main_data .. '_main' -- pass data between loops
    label = 'fork: ' .. label .. ': '
    
    local msleep = require('time.sleep.msleep')
    local socket = require('socket')

    if OPT.debug then
        utils.log.enable_debug()
    end
    utils.log.info(label .. 'start')

    -- save vars between forks
    local v_old = 0
    local err = 0
    local loop_count = 0
    local loop_latency = 0
    local check_latency = 0    
    local function save_vars(...)
        local f = io.open(main_data, 'w+')
        f:write(v_old .. '\n')
        f:write(err .. '\n')
        f:write(loop_count .. '\n')
        f:write(loop_latency .. '\n')
        f:write(check_latency .. '\n')
        f:close()
    end
    local function load_vars()
        local f = io.open(main_data, 'r')
        v_old = tonumber(f:read('*line'))
        err = tonumber(f:read('*line'))
        loop_count = tonumber(f:read('*line'))
        loop_latency = tonumber(f:read('*line'))
        check_latency = tonumber(f:read('*line'))
        f:close()
    end
    
    local sleep = 1000 * OPT.sleep
    local s
    local v = 0
    local r = 0
    local ok = false
    local t0, t1
    local sw = 1000 * OPT.timeout / 50 -- worker check sleep
    if sw < 10 then
        sw = 10
    end
    
    msleep(2000) -- wait for haproxy init phase to finish and ipc to start
    if not OPT.ipcSock or ipc('ping') ~= 'ok' then
        error(err_ipc_ping)
    end

    os.remove(main_data)    
    save_vars()
    
    while true do
        t0 = socket.gettime()
        if posix.fork() == 0 then
            load_vars()
            s = sleep

            if to_flag then
                t1 = socket.gettime()
                ok, r = worker(label, utils.strip_type(target))
                t1 = 1000 * (socket.gettime() - t1)
            else
                -- we fork in order to implement timeout
                os.remove(worker_data)
                local fdata
                local pid = posix.fork()
                if pid == 0 then
                    t1 = socket.gettime()
                    ok, r = worker(label, utils.strip_type(target))
                    t1 = 1000 * (socket.gettime() - t1)
                    -- write fdata        
                    fdata = io.open(worker_data, 'w+')
                    fdata:write(tostring(ok) .. '\n')
                    fdata:write(r .. '\n')
                    fdata:write(t1 .. '\n')
                    fdata:close()
                    os.exit()
                end

                local j = 1000 * OPT.timeout / sw
                -- wait for worker to terminate or timeout
                while j > 0 do
                    msleep(sw)
                    if posix.wait(-1, posix.WNOHANG) ~= 0 then
                        break
                    end
                    j = j - 1
                end
                -- read data
                fdata = io.open(worker_data, 'r')
                if fdata then
                    ok = utils.tobool(fdata:read('*line'))
                    r = fdata:read('*line')
                    t1 = tonumber(fdata:read('*line'))
                    fdata:close()
                    if ok then
                        -- worker ok
                        ok = true
                        r = tonumber(r)
                    end
                else
                    -- worker timeout
                    ok = false
                    r = 'timeout'
                    -- kill worker
                    posix.kill(pid, 9)
                    s = 1 -- we already waited timeout
                end
            end

            t0 = 1000 * (socket.gettime() - t0)

            if ok then
                v = r
                err = 0
                if OPT.latencyMetrics then 
                    loop_count = loop_count + 1
                    loop_latency = loop_latency + t0
                    check_latency = check_latency + t1
                    if loop_count >= OPT.latencyMetrics then
                        -- utils.log.debug(label .. 'loop latency: ' .. loop_latency / loop_count)
                        -- utils.log.debug(label .. 'check latency: ' .. check_latency / loop_count)
                        ipc('metrics ' .. target .. ' ' .. loop_latency / loop_count .. ' ' .. check_latency / loop_count) 
                        loop_count = 0
                        loop_latency = 0
                        check_latency = 0
                    end
                end
            else
                if err < OPT.softFail then
                    v = v_old
                    err = err + 1
                    utils.log.warning(label .. 'soft-failed: ' .. v .. ' ' .. err .. '/' .. OPT.softFail ..': ' .. r)
                else
                    v = 0
                    s = OPT.failMultiplier * sleep
                    utils.log.error(label .. 'hard-failed' .. ': ' .. r)
                end
            end
            -- send ipc message 
            if v ~= v_old then 
                utils.log.info(label .. v_old .. ' -> ' .. v)
                if ipc('server ' .. target .. ' ' .. v) == 'ok' then
                    v_old = v
                end
            end

            save_vars()
            msleep(s)
            os.exit()
        end -- fork
        posix.wait()
    end -- while
end

return function(srvtype, target, worker, to_flag)
    utils.log.debug('fork: ' .. srvtype .. ': ' .. target .. ': timeout: ' .. tostring(to_flag))
    if posix.fork() == 0 then
        while true do
            ok, r = pcall(server_worker, srvtype, target, worker, to_flag)
            if not ok then
                if r:find(err_ipc_ping) then
                    utils.log.error('fork: ' .. srvtype .. ': ' .. target .. ': ' .. err_ipc_ping .. ', verify ipc listener in haproxy config')
                    posix.kill(master_pid, 15)
                else
                    utils.log.error('fork: ' .. srvtype .. ': ' .. target .. ': ' .. r)
                end
            end
        end
        -- this branch shoud stop here, not to move after init phase of haproxy
        os.exit(1)
    end
end

