#!/bin/bash -e

PREFIX=/tmp/buddycloud-server
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
if [ ! -x "$PREFIX/bin/node" ]; then
    cd "$TMPDIR"
    wget -c http://nodejs.org/dist/node-v0.4.11.tar.gz
    [ -f node-v0.4.11 ] || tar xvfz node-v0.4.11.tar.gz
    cd node-v0.4.11
    ./configure --prefix="$PREFIX"
    make JOBS="$JOBS"
    make install
fi

# npm
if [ ! -x "$PREFIX/bin/npm" ]; then
    cd "$TMPDIR"
    wget -c http://registry.npmjs.org/npm/-/npm-1.0.27.tgz
    tar xvfz npm-1.0.27.tgz
    mv package npm
    cd npm
    # Should go into $PREFIX along node
    make install
fi

# deps & coffeescript build
cd $SRCDIR
npm i .

rm -r "$TMPDIR"
echo "Now create the PG database, import the schema and"
echo "update config.js accordingly."
echo "Then run buddycloud-server like this:"
echo `which node` $SRCDIR/bin/channel-server
