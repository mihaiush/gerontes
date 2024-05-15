gerontes_config =  {
    ['net'] = {
        ['bs-f5-proxy'] = {
            ['ip'] = '10.74.58.10',
            ['port'] = 3128,
            ['value'] = 0
        },
        ['bap-f5-proxy'] = {
            ['ip'] = '10.74.58.150',
            ['port'] = 3128,
            ['value'] = 0
        },
    },
    ['servers'] = {
        ['redis'] = {
            ['type'] = 'start_time_sec',
            ['url'] = 'http://localhost:15020/stats/prometheus',
            ['selector'] = '^redis_start_time_seconds%s+([^%s]+)$',
            ['value'] = 0
        }
    },
    ['groups'] = {
        ['local'] = {
            ['servers'] = {
                [1] = 'redis'
            }
        },
        ['global'] = {
            ['servers'] = {
                [1] = 'redis'
            },
            ['net'] = {
                [1] = 'bap-f5-proxy'
            }
        }
    }
}

return gerontes_config
