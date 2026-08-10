utils = require('gerontes.utils')

-- update servers status
-- it should be called for every server or xcheck status change
function update_servers(src)
    local mn    -- master name
    local mv    -- master value
    local sv

    local xcheck = 0
    if OPT.xCheck then
        xcheck = core.backends[OPT.xCheck]:get_srv_act()
    end
    M.xcheck = xcheck
    utils.log.debug('update_servers: ' .. src .. ': xcheck: ' .. tostring(xcheck))

    for bn,bd in pairs(B) do
        if bd.xcheck and xcheck == 0 and OPT.xCheckFreeze then 
            utils.log.warning('update_servers: ' .. src .. ': ' .. bn .. ': xcheck freeze, no update')
        else 
            mv = 0
            mn = ''
            for _,sn in ipairs(bd.servers) do
                sv = S[sn]
                if bd.xcheck and xcheck == 0 then
                    sv = 0
                end
                if sv > 0 and (mv == 0 or sv < mv) then
                    mn = sn
                    mv = sv
                end
            end
            bd.value = mv
            -- first DOWN then UP, no 2 servers can be up
            for sn,sd in pairs(core.backends[bn].servers) do
                if sn ~= mn then
                    sd:set_maint()
                    sd:shut_sess()
                    utils.log.info('update_servers: ' .. src .. ': ' .. bn .. '/' .. sn .. ' DOWN')
                    M['server_up'][bn][sn] = 0
                end
            end
            for sn,sd in pairs(core.backends[bn].servers) do
                if sn == mn then
                    sd:set_ready()
                    utils.log.info('update_servers: ' .. src .. ': ' .. bn .. '/' .. sn .. ' UP')
                    M['server_up'][bn][sn] = 1
                end
            end
        end
    end
end

function set_server(target, v)
    if S[target] ~= v then
        utils.log.info('server: ' .. target .. ': ' .. S[target] .. ' -> ' .. v)
        S[target] = v
        update_servers('server/' .. target)
    end
end

B = {} -- backends
S = {} -- servers
M = { ['xcheck'] = 0, ['loop_latency'] = {}, ['server_latency'] = {}, ['server_up'] = {}, ['latency_count'] = {}} -- metrics
core.register_init(
    function()
        local bo -- backend options
        for bn,bd in pairs(core.backends) do -- backend name, backend data
            _,_,_,bo = bn:find('(.+)__gerontes_?(.*)')
            if bo then
                M['server_up'][bn] = {}
                B[bn] = {}
                B[bn].value = 0
                bo = utils.parse_args({xcheck=false}, bo, ':', '_')
                utils.log.debug('backend: ' .. bn .. ': opt:\n' .. utils.dump(bo))
                B[bn]['xcheck'] = bo.xcheck
                if bo.xcheck then
                    if OPT.xCheck then
                        utils.log.info('backend: ' .. bn .. ': has xcheck')
                    else
                        utils.log.warning('backend: ' .. bn .. ': has xcheck but OPT.xCheck is not defined, drop xcheck')
                        B[bn]['xcheck'] = false
                    end
                end
                B[bn]['servers'] = {}
                for sn,sd in pairs(bd.servers) do
                    utils.log.info('backend: ' .. bn .. ': server: ' .. sn)
                    table.insert(B[bn]['servers'], sn)
                    S[sn] = 0
                    M['latency_count'][sn] = 0
                end
            end
        end

        utils.log.debug('backends:\n' .. utils.dump(B))
        utils.log.debug('servers:\n' .. utils.dump(S))

        update_servers('init')

        -- events on xcheck servers
        if OPT.xCheck then
            if not core.backends[OPT.xCheck] then
                utils.log.error('backend `' .. OPT.xCheck .. '` not found, verify haproxy config', true)
            end
            for sn,sd in pairs(core.backends[OPT.xCheck].servers) do
                sd:event_sub(
                    {"SERVER_UP", "SERVER_DOWN"}, 
                    function()
                        update_servers('xcheck/' .. sn)
                    end
                )
            end
        end

        -- run check controllers    
        for target,_ in pairs(S) do
            local tp = utils.split(target,'::',1)
            if tp[2] and tp[1] ~= OPT.type then
                tp = tp[1]
            else
                tp = OPT.type
            end
            local srvcheck = require('gerontes.srvcheck_' .. tp)
            srvcheck(target)
        end
    end
)

-- options
OPT = {}
OPT.type           = '_'   -- server type
OPT.sleep          = 0.3   -- seconds between 2 checks
OPT.timeout        = 1     -- check timeout seconds
OPT.softFail       = 5     -- how many times a server check can fail before marking it down
OPT.failMultiplier = 15    -- multiplier of sleep in case the server/network were marked down
OPT.ipcSock        = '/dev/shm/gerontes-ipc.sock'   -- socket used for communication with background processes
OPT.kubeApi        = '/dev/shm/gerontes-kubeapi.sock'
OPT.debug          = false
OPT.xCheck         = nil   -- what backend to use for extra check
OPT.xCheckFreeze   = false -- if xCheck fails no updates, freeze status
OPT.mysqlUser      = nil
OPT.mysqlPassword  = nil
OPT.redisAuth      = nil
OPT.haproxyMetrics = false -- haproxy metrics url 
OPT.latencyMetrics = false -- after how many checks to report latency metrics
OPT.staticMetrics  = false -- file with static metrics calculated at startup
OPT.watchTimeout   = 600   -- seconds, after what to to close watch connections
OPT = utils.parse_args(OPT, {...})
if OPT.debug then
    utils.log.enable_debug()
end
if OPT.logColors then
    utils.log.enable_colors()
end
-- mask passwords
mopt = {}
for ok, ov in pairs(OPT) do
    if ok:lower():find('passw') or ok:lower():find('auth') then
        mopt[ok] = 'MASKED'
    else
        mopt[ok] = ov
    end
end
utils.log.info('opt:\n' .. utils.dump(mopt))

STATIC_METRICS = ''
if OPT.staticMetrics then
    for l in io.lines(OPT.staticMetrics) do
        STATIC_METRICS = STATIC_METRICS .. 'gerontes_' .. l .. '\n'
    end  
end

-- receive events from forks
if OPT.ipcSock then
    local service_ipc = require('gerontes.service_ipc')
    core.register_service('gerontes_ipc', 'tcp', service_ipc)
end

-- http interface
local service_httpd = require('gerontes.service_httpd')
core.register_service('gerontes_httpd', 'http', service_httpd)
