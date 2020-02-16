#! /bin/bash
set -eo pipefail

repo=$1
commit=$2
reponame=$3
rename=$4
configextra=$5
target_host=$6
bits=$7

unpackdep() {
    archive=$(basename $1)
    curl -sL -o ${archive} $1
    echo "$2 ${archive}" | sha256sum --check
    tar xf ${archive}
    rm ${archive}
}

# build lightning deps
LNBUILDROOT=$PWD/ln_build_root
mkdir $LNBUILDROOT

export ANDROID_NDK_HOME=/opt/android-ndk-r20b
export PATH=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}
export AR=${target_host/v7a}-ar
export AS=${target_host}24-clang
export CC=${target_host}24-clang
export CXX=${target_host}24-clang++
export LD=${target_host/v7a}-ld
export STRIP=${target_host/v7a}-strip
export LDFLAGS="-pie"
export MAKE_HOST=${target_host/v7a}
export HOST=${target_host/v7a}
export CONFIGURATOR_CC="/usr/bin/gcc"

NDKARCH=arm
if [ "$target_host" = "i686-linux-android" ]; then
    NDKARCH=x86
elif [ "$target_host" = "x86_64-linux-android" ]; then
    NDKARCH=x86_64
elif [ "$target_host" = "aarch64-linux-android" ]; then
    NDKARCH=arm64
fi

num_jobs=4
if [ -f /proc/cpuinfo ]; then
    num_jobs=$(grep ^processor /proc/cpuinfo | wc -l)
fi

## build cln first

# sqlite
unpackdep https://www.sqlite.org/2018/sqlite-autoconf-3260000.tar.gz 5daa6a3fb7d1e8c767cd59c4ded8da6e4b00c61d3b466d0685e35c4dd6d7bf5d
cd sqlite-autoconf-3260000
./configure --enable-static --disable-readline --disable-threadsafe --host=${target_host} CC=$CC --prefix=${LNBUILDROOT}
make -j $num_jobs
make install
cd ..
rm -rf sqlite-autoconf-3260000

# gmp
unpackdep https://gmplib.org/download/gmp/gmp-6.1.2.tar.bz2 5275bb04f4863a13516b2f39392ac5e272f5e1bb8057b18aec1c9b79d73d8fb2
cd gmp-6.1.2
./configure --enable-static --disable-assembly --host=${target_host} CC=$CC --prefix=${LNBUILDROOT}
make -j $num_jobs
make install
cd ..
rm -rf gmp-6.1.2

# download lightning
git clone https://github.com/ElementsProject/lightning.git lightning
cd lightning
git checkout v0.8.1rc3

# set virtualenv for lightning
python3 -m virtualenv venv
. venv/bin/activate
pip install -r requirements.txt

# set standard cc for the configurator
sed -i 's/$CC ${CWARNFLAGS-$BASE_WARNFLAGS} $CDEBUGFLAGS $COPTFLAGS -o $CONFIGURATOR $CONFIGURATOR.c/$CONFIGURATOR_CC ${CWARNFLAGS-$BASE_WARNFLAGS} $CDEBUGFLAGS $COPTFLAGS -o $CONFIGURATOR $CONFIGURATOR.c/g' configure
sed -i 's/-Wno-maybe-uninitialized/-Wno-uninitialized/g' configure
./configure CONFIGURATOR_CC=${CONFIGURATOR_CC} --prefix=${LNBUILDROOT} --disable-developer --disable-compat --disable-valgrind --enable-static

cp /repo/lightning-gen_header_versions.h gen_header_versions.h
# update arch based on toolchain
sed "s'NDKCOMPILER'${CC}'" /repo/lightning-config.vars > config.vars
sed "s'NDKCOMPILER'${CC}'" /repo/lightning-config.h > ccan/config.h

# patch makefile
patch -p1 < /repo/lightning-makefile.patch
patch -p1 < /repo/lightning-addr.patch
patch -p1 < /repo/lightning-endian.patch

# build external libraries and source
make PIE=1 DEVELOPER=0 || echo "continue"
make clean -C ccan/ccan/cdump/tools
make LDFLAGS="" CC="${CONFIGURATOR_CC}" LDLIBS="-L/usr/local/lib" -C ccan/ccan/cdump/tools
make PIE=1 DEVELOPER=0
deactivate
cd ..


# packaging
if [ "${reponame}" != "${rename}" ]; then
    mv ${reponame}/depends/${target_host/v7a/}/bin/${reponame}d ${reponame}/depends/${target_host/v7a/}/bin/${rename}d
    mv ${reponame}/depends/${target_host/v7a/}/bin/${reponame}-cli ${reponame}/depends/${target_host/v7a/}/bin/${rename}-cli
    outputtar=/repo/${target_host/v7a/}_${rename}.tar
else
    outputtar=/repo/${target_host/v7a/}_$(basename $(dirname ${repo})).tar
fi
# tar -cf ${outputtar} -C ${reponame}/depends/${target_host/v7a/}/bin ${rename}d ${rename}-cli tor
tar -rf ${outputtar} -C lightning/lightningd lightning_channeld lightning_closingd lightning_connectd lightning_gossipd lightning_hsmd lightning_onchaind lightning_openingd lightningd
tar -rf ${outputtar} -C lightning plugins/autoclean plugins/fundchannel plugins/pay
tar -rf ${outputtar} -C lightning/cli lightning-cli
xz ${outputtar}
