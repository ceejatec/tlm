#!/bin/bash -ex

# Copyright 2018-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.

INSTALL_DIR=$1
PLATFORM=$2
VERSION=$3
CBDEPS_DIR=$4

# Build and install abseil, cares and protobuf from third_party
cd third_party/abseil-cpp
mkdir build
cd build
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DABSL_BUILD_TESTING=ON \
      -DABSL_PROPAGATE_CXX_STD=ON \
      -DABSL_USE_GOOGLETEST_HEAD=ON \
      -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
      -DCMAKE_INSTALL_LIBDIR=lib \
      ..
if [ "$(uname)" = "Linux" ]; then
  sed -i'' 's/[0-9a-zA-Z\/-]*\/librt.so//' CMakeFiles/Export/lib/cmake/absl/abslTargets.cmake
fi
make -j8 install
cd ../../..

cd third_party/protobuf/cmake
mkdir build
cd build
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -Dprotobuf_BUILD_TESTS=OFF \
  -D CMAKE_PREFIX_PATH="${CBDEPS_DIR}/zlib.exploded" \
  ..
make -j8 install
cd ../../../..

cd third_party/cares/cares
mkdir build
cd build
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCARES_STATIC=ON -DCARES_STATIC_PIC=ON -DCARES_SHARED=OFF \
  ..
make -j8 install
cd ../../../..

# Build grpc binaries and libraries
mkdir .build
cd .build
cmake -D CMAKE_BUILD_TYPE=RelWithDebInfo \
  -D CMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
  -D CMAKE_INSTALL_LIBDIR=lib \
  -D CMAKE_PREFIX_PATH="${CBDEPS_DIR}/zlib.exploded;${CBDEPS_DIR}/openssl.exploded;${INSTALL_DIR}" \
  -D absl_DIR="${INSTALL_DIR}/../grpc/grpc-prefix/src/grpc/third_party/abseil-cpp" \
  -DgRPC_INSTALL=ON \
  -DgRPC_BUILD_TESTS=OFF \
  -DgRPC_ABSL_PROVIDER=package \
  -DgRPC_PROTOBUF_PROVIDER=package \
  -DgRPC_ZLIB_PROVIDER=package \
  -DgRPC_CARES_PROVIDER=package \
  -DgRPC_SSL_PROVIDER=package \
  ..
make -j8 install

exit 0
