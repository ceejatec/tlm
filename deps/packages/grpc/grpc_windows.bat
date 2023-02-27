set INSTALL_DIR=%1
set PLATFORM=%2
set VERSION=%3
set CBDEPS_DIR=%4

rem Build and install cares and protobuf from third_party
cd third_party\protobuf\cmake
mkdir build
cd build
cmake -G Ninja ^
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl ^
  -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DCMAKE_INSTALL_PREFIX=%INSTALL_DIR% ^
  -Dprotobuf_BUILD_TESTS=OFF ^
  -Dprotobuf_MSVC_STATIC_RUNTIME=OFF ^
  -DCMAKE_PREFIX_PATH=%CBDEPS_DIR%/zlib.exploded ^
  .. || goto error
ninja install || goto error
cd ..\..\..\..

rem Build grpc binaries and libraries
rem Protobuf_USE_STATIC_LIBS necessary due to bug in CMake:
rem https://gitlab.kitware.com/paraview/paraview/issues/19527
mkdir .build
cd .build
cmake -G Ninja ^
  -D CMAKE_C_COMPILER=cl -D CMAKE_CXX_COMPILER=cl ^
  -D CMAKE_BUILD_TYPE=RelWithDebInfo ^
  -D "CMAKE_INSTALL_PREFIX=%INSTALL_DIR%" ^
  -D "CMAKE_PREFIX_PATH=%CBDEPS_DIR%/zlib.exploded;%CBDEPS_DIR%/openssl.exploded;%INSTALL_DIR%" ^
  -DgRPC_INSTALL=ON ^
  -DgRPC_BUILD_TESTS=OFF ^
  -DgRPC_PROTOBUF_PROVIDER=package ^
  -DgRPC_ZLIB_PROVIDER=package ^
  -DgRPC_CARES_PROVIDER=module ^
  -DCARES_STATIC_PIC=ON ^
  -DgRPC_SSL_PROVIDER=package ^
  -DgRPC_BUILD_GRPC_RUBY_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_PHP_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_CSHARP_PLUGIN=OFF ^
  -DgRPC_BUILD_GRPC_NODE_PLUGIN=OFF ^
  -DProtobuf_USE_STATIC_LIBS=ON ^
  .. || goto error
ninja install || goto error

goto :eof

:error
echo Failed with error %ERRORLEVEL%
exit /B %ERRORLEVEL%
