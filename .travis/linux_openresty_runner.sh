#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -ex

export_or_prefix() {
    export OPENRESTY_PREFIX="/usr/local/openresty-debug"
}

create_lua_deps() {
    sudo luarocks make --lua-dir=${OPENRESTY_PREFIX}/luajit rockspec/apisix-master-0.rockspec --tree=deps --only-deps --local
    echo "Create lua deps cache"
    sudo rm -rf build-cache/deps
    sudo cp -r deps build-cache/
    sudo cp rockspec/apisix-master-0.rockspec build-cache/
}

before_install() {
    sudo cpanm --notest Test::Nginx >build.log 2>&1 || (cat build.log && exit 1)
    docker pull redis:3.0-alpine
    docker run --rm -itd -p 6379:6379 --name apisix_redis redis:3.0-alpine
}

do_install() {
    wget -qO - https://openresty.org/package/pubkey.gpg | sudo apt-key add -
    sudo apt-get -y update --fix-missing
    sudo apt-get -y install software-properties-common
    sudo add-apt-repository -y "deb http://openresty.org/package/ubuntu $(lsb_release -sc) main"
    sudo add-apt-repository -y ppa:longsleep/golang-backports

    sudo apt-get update

    sudo apt-get install openresty-debug
    sudo luarocks install --lua-dir=${OPENRESTY_PREFIX}/luajit luacov-coveralls

    export GO111MOUDULE=on

    export_or_prefix

    if [ ! -f "build-cache/apisix-master-0.rockspec" ]; then
        create_lua_deps

    else
        src=`md5sum rockspec/apisix-master-0.rockspec | awk '{print $1}'`
        src_cp=`md5sum build-cache/apisix-master-0.rockspec | awk '{print $1}'`
        if [ "$src" = "$src_cp" ]; then
            echo "Use lua deps cache"
            sudo cp -r build-cache/deps ./
        else
            create_lua_deps
        fi
    fi

    git clone https://github.com/iresty/test-nginx.git test-nginx
    make utils

    git clone https://github.com/apache/openwhisk-utilities.git .travis/openwhisk-utilities
    cp .travis/ASF* .travis/openwhisk-utilities/scancode/

    ls -l ./
    if [ ! -f "build-cache/grpc_server_example" ]; then
        wget https://github.com/iresty/grpc_server_example/releases/download/20200314/grpc_server_example-amd64.tar.gz
        tar -xvf grpc_server_example-amd64.tar.gz
        mv grpc_server_example build-cache/
    fi

    if [ ! -f "build-cache/proto/helloworld.proto" ]; then
        if [ ! -f "grpc_server_example/main.go" ]; then
            git clone https://github.com/iresty/grpc_server_example.git grpc_server_example
        fi

        cd grpc_server_example/
        mv proto/ ../build-cache/
        cd ..
    fi

    if [ ! -f "build-cache/grpcurl" ]; then
        wget https://github.com/api7/grpcurl/releases/download/20200314/grpcurl-amd64.tar.gz
        tar -xvf grpcurl-amd64.tar.gz
        mv grpcurl build-cache/
    fi
}

script() {
    export_or_prefix
    export PATH=$OPENRESTY_PREFIX/nginx/sbin:$OPENRESTY_PREFIX/luajit/bin:$OPENRESTY_PREFIX/bin:$PATH
    openresty -V
    sudo service etcd start

    ./build-cache/grpc_server_example &

    ./bin/apisix help
    ./bin/apisix init
    ./bin/apisix init_etcd
    ./bin/apisix start
    mkdir -p logs
    sleep 1

    sudo sh ./t/grpc-proxy-test.sh
    sleep 1

    ./bin/apisix stop
    sleep 1

    make lint && make license-check || exit 1
    APISIX_ENABLE_LUACOV=1 prove -Itest-nginx/lib -r t
}

after_success() {
    cat luacov.stats.out
    luacov-coveralls
}

case_opt=$1
shift

case ${case_opt} in
before_install)
    before_install "$@"
    ;;
do_install)
    do_install "$@"
    ;;
script)
    script "$@"
    ;;
after_success)
    after_success "$@"
    ;;
esac
