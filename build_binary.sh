#!/bin/bash -e

PREFIX=/opt/buddycloud-server
TMPDIR=/tmp/buddycloud-server-build
JOBS=3

echo Please make sure build-dependencies are installed:
echo \# apt-get install build-essential libssl-dev libexpat-dev libicu-dev libpq-dev
echo
echo This script will build node.js and npmjs for you.
echo
echo Press return
read


SRCDIR=`pwd`
export PATH="$PREFIX/bin:$PATH"
[ -d "$TMPDIR" ] || mkdir "$TMPDIR"

# Build node
NODE_VER=0.4.12
if [ ! -x "$PREFIX/bin/node" ]; then
    cd "$TMPDIR"
    wget -c http://nodejs.org/dist/node-v${NODE_VER}.tar.gz
    [ -f node-v${NODE_VER} ] || tar xvfz node-v${NODE_VER}.tar.gz
    cd node-v${NODE_VER}
    ./configure --prefix="$PREFIX"
    make JOBS="$JOBS"
    make install
fi

# npm
NPM_VER=1.0.103
if [ ! -x "$PREFIX/bin/npm" ]; then
    cd "$TMPDIR"
    wget -c http://registry.npmjs.org/npm/-/npm-${NPM_VER}.tgz
    tar xvfz npm-${NPM_VER}.tgz
    mv package npm
    cd npm
    # Should go into $PREFIX along node
    make install
fi

# deps & coffeescript build
cd $SRCDIR
npm i .

rm $PREFIX/bin/buddycloud-server
cp _opt_buddycloud-server_bin_buddycloud-server $PREFIX/bin/buddycloud-server

rm -r "$TMPDIR"
echo "Now create the PG database, import the schema and"
echo "update config.js accordingly."
echo "Then run buddycloud-server like this:"
echo "export PATH=$(dirname $(which node)):\$PATH"
echo "$SRCDIR/bin/channel-server"
