ARG VERSION=3.4.3-trixie

FROM docker.io/haproxy:$VERSION AS build

USER 0

RUN \
    LUA_VERSION=$(haproxy -vv | awk '/: Lua /{print $NF}' | awk -F'.' '{print $1"."$2}') &&\
    echo "export LUA_VERSION=$LUA_VERSION" >>/environ &&\
    echo "LUAROCKS='luarocks-${LUA_VERSION} --tree /build'" >>/environ

RUN \
    . /environ &&\
    echo 'APT::Install-Recommends "false";' >>/etc/apt/apt.conf &&\
    echo 'APT::Install-Suggests "false";' >>/etc/apt/apt.conf &&\
    export DEBIAN_FRONTEND=noninteractive &&\
    apt-get -y update &&\
    apt-get -y install \
        build-essential \
        git \
        luarocks \
        lua${LUA_VERSION} \
        liblua${LUA_VERSION}-dev \
        libmariadb-dev-compat \
        libpq-dev \
        libssl-dev

RUN \
    . /environ &&\
    luarocks-${LUA_VERSION} install luarocks-build-hooks

RUN \
    . /environ &&\
    $LUAROCKS install time-sleep &&\
    $LUAROCKS install luaposix &&\
    $LUAROCKS install ansicolors &&\
    $LUAROCKS install string-split &&\
    $LUAROCKS install lunajson &&\
    $LUAROCKS install redis-lua &&\
    $LUAROCKS install luasql-postgres PGSQL_INCDIR=/usr/include/postgresql

RUN \
    . /environ &&\
    cd /tmp &&\
    git clone https://github.com/lunarmodules/luasql.git &&\
    cd luasql &&\
    $LUAROCKS make rockspec/luasql-mysql-2.8.0-1.rockspec MYSQL_INCDIR=/usr/include/mysql

COPY static /static/
RUN \ 
    . /environ &&\
    cp -rv /static/* /build/share/lua/$LUA_VERSION/

FROM docker.io/haproxy:$VERSION

USER 0

COPY --from=build /build/lib/lua /usr/local/lib/lua/
COPY --from=build /build/share/lua /usr/local/share/lua/

RUN \
    echo 'APT::Install-Recommends "false";' >>/etc/apt/apt.conf &&\
    echo 'APT::Install-Suggests "false";' >>/etc/apt/apt.conf &&\
    export DEBIAN_FRONTEND=noninteractive &&\
    apt-get -y update &&\
    apt-get -y install \
        tini \
        libmariadb3 \
        libpq5 \ 
        openssl

RUN \
    userdel haproxy ;\
    useradd -u 1000 -d /tmp haproxy

VOLUME /tmp
USER 1000
ENTRYPOINT ["/usr/bin/tini", "-vw", "--", "haproxy"]
