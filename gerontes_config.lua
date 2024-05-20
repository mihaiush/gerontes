gerontes_config =  {
    net = {
        a = {
            ip = '10.74.58.10',
            port = 3128,
        },
        b = {
            ip = '10.74.58.150',
            port = 3128,
        },
        c = {
            ip = '127.0.0.1',
            port = 111,
        }
    },
    servers = {
        redis = {
            type = 'start_time_sec',
            url = 'http://localhost:15020/stats/prometheus',
            selector = '^redis_start_time_seconds%s+([^%s]+)$'
        },
        mariadb = {
            type = 'up_time_sec',
            url = 'http://localhost:9104/metrics',
            selector = '^mysql_global_status_uptime%s+([^%s]+)$',
            weight = 1
        }
    }
}

return gerontes_config
