#!/bin/bash -e

[ "x$PREFIX" = "x" ] && PREFIX=/opt/buddycloud-server
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
NODE_VER=0.6.11
if [ ! -x "$PREFIX/bin/node" ]; then
    cd "$TMPDIR"
    wget -c http://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}.tar.gz
    [ -f node-v${NODE_VER} ] || tar xvfz node-v${NODE_VER}.tar.gz
    cd node-v${NODE_VER}
    ./configure --prefix="$PREFIX"
    make JOBS="$JOBS"
    make install
fi

# deps & coffeescript build
cd $SRCDIR
# devDeps
npm i coffee-script muffin
# Install runtime deps globally, so they land in our $PATH which can
# later be packaged up.
npm i . -g
./node_modules/.bin/cake build

rm $PREFIX/bin/buddycloud-server
cp _opt_buddycloud-server_bin_buddycloud-server $PREFIX/bin/buddycloud-server

rm -r "$TMPDIR"
echo "Now create the PG database, import the schema and"
echo "update config.js accordingly."
echo "Then run buddycloud-server like this:"
echo "export PATH=$(dirname $(which node)):\$PATH"
echo "$SRCDIR/bin/channel-server"
