# This module provides facilities for building Go code.
#
# The Couchbase build utilizes several different versions of the Go
# compiler in the production builds. Several macros here accept
# GOVERSION arguments to specify a Go version. This should be a *major*
# version, eg. "1.18", not a fully-specified version such as "1.18.4".
# This is to facilitate easily upgrading Go to remediate security
# vulnerabilities.

# Prevent double-definition if two projects use this script
IF (NOT FindCouchbaseGo_INCLUDED)

  ###################################################################
  # THINGS YOU MAY NEED TO UPDATE OVER TIME

  # On MacOS, we frequently need to enforce a newer version of Go.
  SET (GO_MAC_MINIMUM_VERSION 1.17)

  # List of private Go module paths that are missing when syncing
  # strictly the source-available projects.
  SET (GO_PRIVATE_MODULE_PATHS
    cbftx
    hebrew
    goproj/src/github.com/couchbase/eventing-ee
    goproj/src/github.com/couchbase/plasma
    goproj/src/github.com/couchbase/query-ee
    goproj/src/github.com/couchbase/regulator
  )

  # END THINGS YOU MAY NEED TO UPDATE OVER TIME
  ####################################################################

  SET (CB_GO_CODE_COVERAGE 0 CACHE BOOL "Whether to use Go code coverage")
  SET (CB_GO_RACE_DETECTOR 0 CACHE BOOL "Whether to add race detector flag while generating go binaries")

  IF (DEFINED ENV{GOBIN})
    MESSAGE (FATAL_ERROR "The environment variable GOBIN is set. "
      "This will break the Couchbase build. Please unset it and re-build.")
  ENDIF (DEFINED ENV{GOBIN})

  INCLUDE (ParseArguments)

  # Have to remember cwd when this find is INCLUDE()d
  SET (TLM_MODULES_DIR "${CMAKE_CURRENT_LIST_DIR}")

  # Create any 'private' module paths
  IF (NOT BUILD_ENTERPRISE)
    FOREACH (PRIV_PATH ${GO_PRIVATE_MODULE_PATHS})
      SET (_fakedir "${PROJECT_SOURCE_DIR}/${PRIV_PATH}")
      IF (NOT IS_DIRECTORY "${_fakedir}")
        MESSAGE (STATUS "Creating directory ${_fakedir} with empty go.mod")
        FILE (MAKE_DIRECTORY "${_fakedir}")
      ENDIF ()
      SET (_fakegomod "${_fakedir}/go.mod")
      IF (NOT EXISTS "${_fakegomod}")
        FILE (TOUCH "${_fakedir}/go.mod")
      ENDIF ()
    ENDFOREACH ()
  ENDIF ()

  # This macro is called by GoInstall() / GoYacc() / etc. to find the
  # appropriate Go compiler to use. It will set the variable named by
  # "var" to the full path of the corresponding GOROOT, or raise an error
  # if the requested version cannot be found. It will set the variable named
  # by "ver" to the actual version of Go used.
  MACRO (GET_GOROOT VERSION var ver UNSHIPPED)
    SET (_request_version ${VERSION})

    # MacOS often requires a newer Go version for $REASONS
    IF (APPLE)
      IF (${_request_version} VERSION_LESS "${GO_MAC_MINIMUM_VERSION}")
        IF ("$ENV{CB_MAC_GO_WARNING}" STREQUAL "")
          MESSAGE (${_go_warning} "Forcing Go version ${GO_MAC_MINIMUM_VERSION} on MacOS "
            "(to suppress this warning, set environment variable "
            "CB_MAC_GO_WARNING to any value")
          SET (_go_warning WARNING)
          SET (ENV{CB_MAC_GO_WARNING} true)
        ENDIF ()
        SET (_request_version ${GO_MAC_MINIMUM_VERSION})
      ENDIF ()
    ENDIF ()

    # Compute the major version from the requested version.
    # Transition: existing code specifies a complete Go version, eg. 1.18.4.
    # We want to trim that to a major version, eg. 1.18.
    STRING (REGEX MATCHALL "[0-9]+" _ver_bits "${_request_version}")
    LIST (LENGTH _ver_bits _num_ver_bits)
    IF (_num_ver_bits EQUAL 2)
      SET (_major_version "${_request_version}")
    ELSEIF (_num_ver_bits EQUAL 3)
      LIST (POP_BACK _ver_bits)
      LIST (JOIN _ver_bits "." _major_version)
      IF (NOT ${UNSHIPPED})
        MESSAGE (WARNING "Please change GOVERSION to ${_major_version}, not ${_request_version}")
      ENDIF ()
    ELSE ()
      MESSAGE (FATAL_ERROR "Illegal Go version ${_request_version}!")
    ENDIF ()

    # Map X.Y version to specific version for download for all shipped binaries
    SET (GOVER_FILE
      "${CMAKE_SOURCE_DIR}/golang/versions/${_major_version}.txt"
    )
    IF (NOT EXISTS "${GOVER_FILE}")
      IF (${UNSHIPPED})
        # Just revert to the originally-requested version
        MESSAGE (STATUS "Go version ${VERSION} is not supported, but using "
                 "anyway as target is unshipped (but consider upgrading)")
        SET (_ver_final "${VERSION}")
      ELSE ()
        MESSAGE (FATAL_ERROR "Go version ${_request_version} no longer supported - please upgrade!")
      ENDIF ()
    ELSE ()
      FILE (STRINGS "${GOVER_FILE}" _ver_final LIMIT_COUNT 1)
    ENDIF ()

    GET_GO_VERSION ("${_ver_final}" ${var})
    SET (${ver} ${_ver_final})
  ENDMACRO (GET_GOROOT)

  INCLUDE (CBDownloadDeps)

  # No compiler yet
  SET (GO_SINGLE_EXECUTABLE)
  SET (GO_SINGLE_ROOT)

  # Master target for "all go binaries"
  ADD_CUSTOM_TARGET(all-go)

  # Set up clean targets. Note: the hardcoded godeps and goproj is kind of
  # a hack; it should build that up from the GOPATHs passed to GoInstall.
  SET (GO_BINARY_DIR "${CMAKE_BINARY_DIR}/gopkg")
  ADD_CUSTOM_TARGET (go_realclean
    COMMAND "${CMAKE_COMMAND}" -E remove_directory "${GO_BINARY_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E remove_directory "${CMAKE_SOURCE_DIR}/godeps/bin"
    COMMAND "${CMAKE_COMMAND}" -E remove_directory "${CMAKE_SOURCE_DIR}/goproj/bin")
  ADD_DEPENDENCIES (realclean go_realclean)

  # Go build/install already performs it's own parallelism internally, so
  # we don't also want to have the CMake generator attempt to parallelise (i.e.
  # run multiple `go build/install` targets in parallel).
  # If we do (particulary for machines which have large numbers of CPUs but
  # perhaps not as large RAM) then we can end up exhausing the RAM of the
  # machine.
  # Define a CMake JOB_POOL which has concurrency 1, which is used by the
  # 'go build' and 'go install' custom targets below.
  # Note: At time of writing this is only supported by the Ninja generators,
  # is it ignored by other generators.
  SET_PROPERTY (GLOBAL APPEND PROPERTY JOB_POOLS golang_build_pool=1)

  # Adds a target named TARGET which (always) calls "go install
  # PACKAGE".  This delegates incremental-build responsibilities to
  # the go compiler, which is generally what you want.
  #
  # Required arguments:
  #
  # TARGET - name of CMake target to create
  #
  # PACKAGE - A single Go package to build. When this is specified,
  # the package and all dependencies on GOPATH will be built, using
  # the Go compiler's normal dependency-handling system.
  #
  # GOPATH - Every entry on this list will be placed onto the GOPATH
  # environment variable before invoking the compiler.
  #
  # GOVERSION - the version of the Go compiler required for this target.
  # See file header comment.
  #
  # Optional arguments:
  #
  # UNSHIPPED - for targets that are NOT part of the Server deliverable
  #
  # GCFLAGS - flags that will be passed (via -gcflags) to all compile
  # steps; should be a single string value, with spaces if necessary
  #
  # GOTAGS - tags that will be passed (viga -tags) to all compile
  # steps; should be a single string value, with spaces as necessary
  #
  # LDFLAGS - flags that will be passed (via -ldflags) to all compile
  # steps; should be a single string value, with spaces if necessary
  #
  # NOCONSOLE - for targets that should not launch a console at runtime
  # (on Windows - silently ignored on other platforms)
  #
  # DEPENDS - list of other CMake targets on which TARGET will depend
  #
  # INSTALL_PATH - if specified, a CMake INSTALL() directive will be
  # created to install the output into the named path
  #
  # OUTPUT - name of the installed executable (only applicable if
  # INSTALL_PATH is specified). Default value is the basename of
  # PACKAGE, per the go compiler. On Windows, ".exe" will be
  # appended.
  #
  # CGO_INCLUDE_DIRS - path(s) to directories to search for C include files
  #
  # CGO_LIBRARY_DIRS - path(s) to libraries to search for C link libraries
  #
  MACRO (GoInstall)

    PARSE_ARGUMENTS (Go "DEPENDS;GOPATH;CGO_INCLUDE_DIRS;CGO_LIBRARY_DIRS"
        "TARGET;PACKAGE;OUTPUT;INSTALL_PATH;GOVERSION;GCFLAGS;GOTAGS;GOBUILDMODE;LDFLAGS"
      "NOCONSOLE;UNSHIPPED" ${ARGN})

    IF (NOT Go_TARGET)
      MESSAGE (FATAL_ERROR "TARGET is required!")
    ENDIF (NOT Go_TARGET)
    IF (NOT Go_PACKAGE)
      MESSAGE (FATAL_ERROR "PACKAGE is required!")
    ENDIF (NOT Go_PACKAGE)
    IF (NOT Go_GOVERSION)
      MESSAGE (FATAL_ERROR "GOVERSION is required!")
    ENDIF (NOT Go_GOVERSION)
    IF (NOT Go_GOBUILDMODE)
      SET(Go_GOBUILDMODE "default")
    ENDIF (NOT Go_GOBUILDMODE)

    # Special short-term transition
    IF (Go_TARGET STREQUAL "convertschema")
      SET (Go_UNSHIPPED 1)
    ENDIF ()

    # Hunt for the requested package on GOPATH (used for installing)
    SET (_found)
    FOREACH (_dir ${Go_GOPATH})
      FILE (TO_NATIVE_PATH "${_dir}/src/${Go_PACKAGE}" _pkgdir)
      IF (IS_DIRECTORY "${_pkgdir}")
        SET (_found 1)
        SET (_workspace "${_dir}")
        BREAK ()
      ENDIF (IS_DIRECTORY "${_pkgdir}")
    ENDFOREACH (_dir)
    IF (NOT _found)
      MESSAGE (FATAL_ERROR "Package ${Go_PACKAGE} not found in any workspace on GOPATH!")
    ENDIF (NOT _found)

    # Extract the binary name from the package, and tweak for Windows.
    GET_FILENAME_COMPONENT (_pkgexe "${Go_PACKAGE}" NAME)
    IF (WIN32)
      SET (_pkgexe "${_pkgexe}.exe")
    ENDIF (WIN32)
    IF (Go_OUTPUT)
      IF (WIN32)
        SET (Go_OUTPUT "${Go_OUTPUT}.exe")
      ENDIF (WIN32)
    ENDIF (Go_OUTPUT)

    # Concatenate NOCONSOLE with LDFLAGS
    IF (WIN32 AND ${Go_NOCONSOLE})
      SET (_ldflags "-H windowsgui ${Go_LDFLAGS}")
    ELSE (WIN32 AND ${Go_NOCONSOLE})
      SET (_ldflags "${Go_LDFLAGS}")
    ENDIF (WIN32  AND ${Go_NOCONSOLE})

    # If Sanitizers are enabled then add a runtime linker path to
    # locate libasan.so / libubsan.so etc.
    # This isn't usually needed if we are running on the same machine
    # as we built (as the sanitizer libraries are typically in
    # /usr/lib/ or similar), however when creating a packaged build
    # which will be installed and run on a different machine we need
    # to ensure that the runtime linker knows how to find our copies
    # of libasan.so etc in $PREFIX/lib.
    IF (CB_ADDRESSSANITIZER OR CB_UNDEFINED_SANITIZER)
      SET (_ldflags "${_ldflags} -r \$ORIGIN/../lib")
    ENDIF()

    # Compute path to Go compiler
    GET_GOROOT ("${Go_GOVERSION}" _goroot _gover ${Go_UNSHIPPED})

    # Go install target
    ADD_CUSTOM_TARGET ("${Go_TARGET}" ALL
      COMMAND "${CMAKE_COMMAND}"
      -D "GOROOT=${_goroot}"
      -D "GOVERSION=${_gover}"
      -D "GO_BINARY_DIR=${GO_BINARY_DIR}/go-${_gover}"
      -D "CMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
      -D "GOPATH=${Go_GOPATH}"
      -D "WORKSPACE=${_workspace}"
      -D "REPOSYNC=${TLM_MODULES_DIR}/../../.."
      -D "CGO_CFLAGS=$<TARGET_PROPERTY:${Go_TARGET},COMPILE_OPTIONS>"
      -D "CGO_LDFLAGS=$<TARGET_PROPERTY:${Go_TARGET},LINK_OPTIONS>"
      -D "GCFLAGS=${Go_GCFLAGS}"
      -D "GOTAGS=${Go_GOTAGS}"
      -D "GOBUILDMODE=${Go_GOBUILDMODE}"
      -D "LDFLAGS=${_ldflags}"
      -D "PKGEXE=${_pkgexe}"
      -D "PACKAGE=${Go_PACKAGE}"
      -D "OUTPUT=${Go_OUTPUT}"
      -D "CGO_INCLUDE_DIRS=${Go_CGO_INCLUDE_DIRS}"
      -D "CGO_LIBRARY_DIRS=${Go_CGO_LIBRARY_DIRS}"
      -D "CB_GO_CODE_COVERAGE=${CB_GO_CODE_COVERAGE}"
      -D "CB_GO_RACE_DETECTOR=${CB_GO_RACE_DETECTOR}"
      -D "CB_ADDRESSSANITIZER=${CB_ADDRESSSANITIZER}"
      -D "CB_UNDEFINEDSANITIZER=${CB_UNDEFINEDSANITIZER}"
      -D "CB_THREADSANITIZER=${CB_THREADSANITIZER}"
      -D "CB_GO_UNSHIPPED=${Go_UNSHIPPED}"
      -P "${TLM_MODULES_DIR}/go-install.cmake"
      COMMENT "Building Go target ${Go_TARGET} using Go ${_gover}"
      JOB_POOL golang_build_pool
      VERBATIM)
    IF (Go_DEPENDS)
      ADD_DEPENDENCIES (${Go_TARGET} ${Go_DEPENDS})
    ENDIF (Go_DEPENDS)
    ADD_DEPENDENCIES (all-go ${Go_TARGET})
    MESSAGE (STATUS "Added Go build target '${Go_TARGET}' using Go ${_gover}")

    # The go compiler itself does parallel building, so to avoid
    # overloading the machine we want to only build on Go target at
    # once. If we are using Ninja as the CMake Generator then this is
    # already handled by the JOB_POOL property, otherwise we make them
    # all depend on any earlier Go targets.
    IF (NOT CMAKE_GENERATOR STREQUAL "Ninja")
      GET_PROPERTY (_go_targets GLOBAL PROPERTY CB_GO_TARGETS)
      IF (_go_targets)
        ADD_DEPENDENCIES(${Go_TARGET} ${_go_targets})
      ENDIF (_go_targets)
      SET_PROPERTY (GLOBAL APPEND PROPERTY CB_GO_TARGETS ${Go_TARGET})
    ENDIF ()

    # Tweaks for installing and output renaming. go-install.cmake will
    # arrange for the workspace's bin directory to contain a file with
    # the right name (either OUTPUT, or the Go package name if OUTPUT
    # is not specified). We need to know what that name is so we can
    # INSTALL() it.
    IF (Go_OUTPUT)
      SET (_finalexe "${Go_OUTPUT}")
    ELSE (Go_OUTPUT)
      SET (_finalexe "${_pkgexe}")
    ENDIF (Go_OUTPUT)
    IF (Go_INSTALL_PATH)
      INSTALL (PROGRAMS "${_workspace}/bin/${_finalexe}"
        DESTINATION "${Go_INSTALL_PATH}")
    ENDIF (Go_INSTALL_PATH)

  ENDMACRO (GoInstall)

  # Top-level target which depends on all individual -tidy targets.
  ADD_CUSTOM_TARGET (go-mod-tidy)

  # Top-level target which runs go-mod-tidy repeatedly until no new
  # module changes are detected. This is necessary due to our use of
  # "replace" directives in go.mod files and circular dependencies.
  ADD_CUSTOM_TARGET (go-mod-tidy-all
    COMMAND "${CMAKE_COMMAND}" -P "${TLM_MODULES_DIR}/go-modtidyall.cmake"
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
    COMMENT "Ensuring all go.mod files are tidied"
    VERBATIM)

  # Adds a target named TARGET which (always) calls "go build
  # PACKAGE".  This delegates incremental-build responsibilities to
  # the go compiler, which is generally what you want. This target
  # presumes that the package in question is using Go modules to
  # declare itself and its dependencies. One consequence of this
  # is that there must be go.mod and go.sum files in the source
  # directory that calls GoModBuild() or some parent directory.
  #
  # The first time GoModBuild() is called in a given directory,
  # an additional target named TARGET-tidy will also be created
  # that calls "go mod tidy -v" using the appropriate Go version
  # and modules cache. There is also a global target "go-mod-tidy"
  # which invokes all such targets. NOTE: this tidy target will
  # be given the same dependencies as the main build target. If
  # you need to depend on, say, a target which generates source code
  # in another project, be sure to include this dependency in the
  # *first* GoModBuild() call, so that the tidy target will also
  # know about that dependency.
  #
  # Required arguments:
  #
  # TARGET - name of CMake target to create
  #
  # PACKAGE - A single Go package to build. This should produce a single
  # executable as output.
  #
  # GOVERSION - the version of the Go compiler required for this target.
  # See file header comment.
  #
  # Optional arguments:
  #
  # UNSHIPPED - for targets that are NOT part of the Server deliverable
  #
  # GCFLAGS - flags that will be passed (via -gcflags) to all compile
  # steps; should be a single string value, with spaces if necessary
  #
  # GOTAGS - tags that will be passed (viga -tags) to all compile
  # steps; should be a single string value, with spaces as necessary
  #
  # LDFLAGS - flags that will be passed (via -ldflags) to all compile
  # steps; should be a single string value, with spaces if necessary
  #
  # NOCONSOLE - for targets that should not launch a console at runtime
  # (on Windows - silently ignored on other platforms)
  #
  # DEPENDS - list of other CMake targets on which TARGET will depend
  #
  # INSTALL_PATH - if specified, a CMake INSTALL() directive will be
  # created to install the output into the named path
  #
  # ALT_INSTALL_PATHS - if specified, the executable will be copied
  # to each listed directory when built (not at install time).
  #
  # OUTPUT - name of the produced executable. Default value is the basename of
  # PACKAGE, per the go compiler. On Windows, ".exe" will be appended.
  #
  # CGO_INCLUDE_DIRS - path(s) to directories to search for C include files
  #
  # CGO_LIBRARY_DIRS - path(s) to libraries to search for C link libraries
  #
  MACRO (GoModBuild)

    PARSE_ARGUMENTS (Go "DEPENDS;CGO_INCLUDE_DIRS;CGO_LIBRARY_DIRS;ALT_INSTALL_PATHS"
        "TARGET;PACKAGE;OUTPUT;INSTALL_PATH;GOVERSION;GCFLAGS;GOTAGS;GOBUILDMODE;LDFLAGS"
      "NOCONSOLE;UNSHIPPED" ${ARGN})

    IF (NOT Go_TARGET)
      MESSAGE (FATAL_ERROR "TARGET is required!")
    ENDIF ()
    IF (NOT Go_PACKAGE)
      MESSAGE (FATAL_ERROR "PACKAGE is required!")
    ENDIF ()
    IF (NOT Go_GOVERSION)
      MESSAGE (FATAL_ERROR "GOVERSION is required!")
    ENDIF ()
    IF (NOT Go_GOBUILDMODE)
        SET(Go_GOBUILDMODE "default")
    ENDIF ()

    # Extract the binary name from the package, and tweak for Windows.
    IF (Go_OUTPUT)
      SET (_exe "${Go_OUTPUT}")
    ELSE ()
      GET_FILENAME_COMPONENT (_exe "${Go_PACKAGE}" NAME)
    ENDIF ()
    SET (_exe "${CMAKE_CURRENT_BINARY_DIR}/${_exe}")
    IF (WIN32)
      SET (_exe "${_exe}.exe")
    ENDIF ()

    # Concatenate NOCONSOLE with LDFLAGS
    IF (WIN32 AND ${Go_NOCONSOLE})
      SET (_ldflags "-H windowsgui ${Go_LDFLAGS}")
    ELSE ()
      SET (_ldflags "${Go_LDFLAGS}")
    ENDIF ()

    # If Sanitizers are enabled then add a runtime linker path to
    # locate libasan.so / libubsan.so etc.
    # This isn't usually needed if we are running on the same machine
    # as we built (as the sanitizer libraries are typically in
    # /usr/lib/ or similar), however when creating a packaged build
    # which will be installed and run on a different machine we need
    # to ensure that the runtime linker knows how to find our copies
    # of libasan.so etc in $PREFIX/lib.
    IF (CB_ADDRESSSANITIZER OR CB_UNDEFINED_SANITIZER)
      SET (_ldflags "${_ldflags} -r \$ORIGIN/../lib")
    ENDIF()

    # Compute path to Go compiler
    GET_GOROOT ("${Go_GOVERSION}" _goroot _gover ${Go_UNSHIPPED})
    SET (_goexe "${_goroot}/bin/go")

    # Path to go binary dir for this target
    SET (_gobindir "${GO_BINARY_DIR}/go-${_gover}")

    # Go mod build target
    ADD_CUSTOM_TARGET ("${Go_TARGET}" ALL
      COMMAND "${CMAKE_COMMAND}"
        -D "GOEXE=${_goexe}"
        -D "GOVERSION=${_gover}"
        -D "GO_BINARY_DIR=${_gobindir}"
        -D "CMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
        -D "REPOSYNC=${TLM_MODULES_DIR}/../../.."
        -D "CB_PRODUCTION_BUILD=${CB_PRODUCTION_BUILD}"
        -D "CGO_CFLAGS=$<TARGET_PROPERTY:${Go_TARGET},COMPILE_OPTIONS>"
        -D "CGO_LDFLAGS=$<TARGET_PROPERTY:${Go_TARGET},LINK_OPTIONS>"
        -D "GCFLAGS=${Go_GCFLAGS}"
        -D "GOTAGS=${Go_GOTAGS}"
        -D "GOBUILDMODE=${Go_GOBUILDMODE}"
        -D "LDFLAGS=${_ldflags}"
        -D "PACKAGE=${Go_PACKAGE}"
        -D "OUTPUT=${_exe}"
        -D "ALT_INSTALL_PATHS=${Go_ALT_INSTALL_PATHS}"
        -D "CGO_INCLUDE_DIRS=${Go_CGO_INCLUDE_DIRS}"
        -D "CGO_LIBRARY_DIRS=${Go_CGO_LIBRARY_DIRS}"
        -D "CB_GO_CODE_COVERAGE=${CB_GO_CODE_COVERAGE}"
        -D "CB_GO_RACE_DETECTOR=${CB_GO_RACE_DETECTOR}"
        -D "CB_ADDRESSSANITIZER=${CB_ADDRESSSANITIZER}"
        -D "CB_UNDEFINEDSANITIZER=${CB_UNDEFINEDSANITIZER}"
        -D "CB_THREADSANITIZER=${CB_THREADSANITIZER}"
        -D "CB_GO_UNSHIPPED=${Go_UNSHIPPED}"
        -P "${TLM_MODULES_DIR}/go-modbuild.cmake"
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      COMMENT "Building Go Modules target ${Go_TARGET} using Go ${_gover}"
      JOB_POOL golang_build_pool
      VERBATIM)
    IF (Go_DEPENDS)
      ADD_DEPENDENCIES (${Go_TARGET} ${Go_DEPENDS})
    ENDIF ()
    ADD_DEPENDENCIES (all-go ${Go_TARGET})
    MESSAGE (STATUS "Added Go Modules build target '${Go_TARGET}' using Go ${_gover}")

    # go-modbuild.cmake will produce the output executable in the
    # current binary dir. Install it from there if requested.
    IF (Go_INSTALL_PATH)
      INSTALL (PROGRAMS "${_exe}" DESTINATION "${Go_INSTALL_PATH}")
    ENDIF ()

    # See if we need to create a -tidy target for this directory.
    GET_PROPERTY (_tidy_dirs GLOBAL PROPERTY CB_GO_TIDY_DIRS)
    LIST (FIND _tidy_dirs "${CMAKE_CURRENT_SOURCE_DIR}" _found)
    IF (_found EQUAL -1)
      SET (_tidy_target "${Go_TARGET}-tidy")
      ADD_CUSTOM_TARGET ("${_tidy_target}"
        COMMAND "${CMAKE_COMMAND}"
          -D "GOEXE=${_goexe}"
          -D "GO_BINARY_DIR=${_gobindir}"
          -D "CB_PRODUCTION_BUILD=${CB_PRODUCTION_BUILD}"
          -P "${TLM_MODULES_DIR}/go-modtidy.cmake"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "Tidying go.mod for ${Go_TARGET} using Go ${_gover}"
        VERBATIM)
      MESSAGE (STATUS "Added Go mod tidy target ${_tidy_target}")
      ADD_DEPENDENCIES (go-mod-tidy "${_tidy_target}")
      IF (Go_DEPENDS)
        ADD_DEPENDENCIES ("${_tidy_target}" ${Go_DEPENDS})
      ENDIF ()
      SET_PROPERTY (GLOBAL APPEND PROPERTY CB_GO_TIDY_DIRS
        "${CMAKE_CURRENT_SOURCE_DIR}")
    ENDIF ()

  ENDMACRO (GoModBuild)

  # NO LONGER NEEEDED - remove this when query and cbft remove their usage
  MACRO (GoPrivateMod)

    MESSAGE (WARNING "GoPrivateMod() no longer used - please delete")

  ENDMACRO (GoPrivateMod)

  # Adds a test named NAME which calls go test in the DIR
  # Required arguments:
  #
  # TARGET - name of the test to create
  #
  # PACKAGE - A single Go package to build. When this is specified,
  # the package and all dependencies on GOPATH will be built, using
  # the Go compiler's normal dependency-handling system.
  #
  # GOPATH - Every entry on this list will be placed onto the GOPATH
  # environment variable before invoking the compiler.
  #
  # GOVERSION - the version of the Go compiler required for this target.
  # See file header comment.
  #
  # Optional arguments:
  #
  # GCFLAGS - flags that will be passed (via -gcflags) to all compile
  # steps; should be a single string value, with spaces if necessary
  #
  # GOTAGS - tags that will be passed (viga -tags) to all compile
  # steps; should be a single string value, with spaces as necessary
  #
  # LDFLAGS - flags that will be passed (via -ldflags) to all compile
  # steps; should be a single string value, with spaces if necessary
  #
  # NOCONSOLE - for targets that should not launch a console at runtime
  # (on Windows - silently ignored on other platforms)
  #
  # DEPENDS - list of other CMake targets on which TARGET will depend
  #
  # CGO_INCLUDE_DIRS - path(s) to directories to search for C include files
  #
  # CGO_LIBRARY_DIRS - path(s) to libraries to search for C link libraries
  #

  MACRO (GoTest)

  PARSE_ARGUMENTS (Go "DEPENDS;GOPATH;CGO_INCLUDE_DIRS;CGO_LIBRARY_DIRS"
      "TARGET;PACKAGE;GOVERSION;GCFLAGS;GOTAGS;GOBUILDMODE;LDFLAGS"
        "NOCONSOLE" ${ARGN})

  IF (NOT Go_TARGET)
    MESSAGE (FATAL_ERROR "TARGET is required!")
  ENDIF (NOT Go_TARGET)
  IF (NOT Go_PACKAGE)
    MESSAGE (FATAL_ERROR "PACKAGE is required!")
  ENDIF (NOT Go_PACKAGE)
  IF (NOT Go_GOVERSION)
    MESSAGE (FATAL_ERROR "GOVERSION is required!")
  ENDIF (NOT Go_GOVERSION)
  IF (NOT Go_GOBUILDMODE)
      SET(Go_GOBUILDMODE default)
  ENDIF (NOT Go_GOBUILDMODE)

  # Concatenate NOCONSOLE with LDFLAGS
  IF (WIN32 AND ${Go_NOCONSOLE})
    SET (_ldflags "-H windowsgui ${Go_LDFLAGS}")
  ELSE (WIN32 AND ${Go_NOCONSOLE})
    SET (_ldflags "${Go_LDFLAGS}")
  ENDIF (WIN32  AND ${Go_NOCONSOLE})

  # Compute path to Go compiler
  GET_GOROOT ("${Go_GOVERSION}" _goroot _gover 1)

  add_test(NAME "${Go_TARGET}"
             COMMAND "${CMAKE_COMMAND}"
             -D "GOROOT=${_goroot}"
             -D "GOVERSION=${_gover}"
             -D "GO_BINARY_DIR=${GO_BINARY_DIR}/go-${_gover}"
             -D "CMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
             -D "GOPATH=${Go_GOPATH}"
             -D "WORKSPACE=${_workspace}"
             -D "CGO_LDFLAGS=${CMAKE_CGO_LDFLAGS}"
             -D "GCFLAGS=${Go_GCFLAGS}"
             -D "GOTAGS=${Go_GOTAGS}"
             -D "GOBUILDMODE=${Go_GOBUILDMODE}"
             -D "LDFLAGS=${_ldflags}"
             -D "PACKAGE=${Go_PACKAGE}"
             -D "CGO_INCLUDE_DIRS=${Go_CGO_INCLUDE_DIRS}"
             -D "CGO_LIBRARY_DIRS=${Go_CGO_LIBRARY_DIRS}"
             -D "CB_GO_CODE_COVERAGE=${CB_GO_CODE_COVERAGE}"
             -D "CB_GO_RACE_DETECTOR=${CB_GO_RACE_DETECTOR}"
             -P "${TLM_MODULES_DIR}/go-test.cmake")

  ENDMACRO (GoTest)

  # Adds a target named TARGET which (always) calls "go tool yacc
  # PATH".
  #
  # Required arguments:
  #
  # TARGET - name of CMake target to create
  #
  # YFILE - Absolute path to .y file.
  #
  # Optional arguments:
  #
  # DEPENDS - list of other CMake targets on which TARGET will depend
  #
  # GOVERSION - the version of the Go compiler required for this target.
  # See file header comment.
  #
  MACRO (GoYacc)

    PARSE_ARGUMENTS (goyacc "DEPENDS" "TARGET;YFILE;GOVERSION" "" ${ARGN})

    # Only build this target if somebody uses this macro
    IF (NOT TARGET goyacc)
      GoInstall (TARGET goyacc UNSHIPPED
      PACKAGE golang.org/x/tools/cmd/goyacc
      GOVERSION ${goyacc_GOVERSION}
      GOPATH "${CMAKE_SOURCE_DIR}/godeps")
    ENDIF ()

    IF (NOT goyacc_TARGET)
      MESSAGE (FATAL_ERROR "TARGET is required!")
    ENDIF (NOT goyacc_TARGET)
    IF (NOT goyacc_YFILE)
      MESSAGE (FATAL_ERROR "YFILE is required!")
    ENDIF (NOT goyacc_YFILE)

    GET_FILENAME_COMPONENT (_ypath "${goyacc_YFILE}" PATH)
    GET_FILENAME_COMPONENT (_yfile "${goyacc_YFILE}" NAME)

    SET(goyacc_OUTPUT "${_ypath}/y.go")

    # Compute path to Go compiler
    GET_GOROOT ("${goyacc_GOVERSION}" _goroot _gover 1)

    ADD_CUSTOM_COMMAND(OUTPUT "${goyacc_OUTPUT}"
                       COMMAND "${CMAKE_COMMAND}"
                       -D "GOROOT=${_goroot}"
                       -D "GOYACC_EXECUTABLE=${CMAKE_SOURCE_DIR}/godeps/bin/goyacc"
                       -D "YFILE=${_yfile}"
                       -P "${TLM_MODULES_DIR}/go-yacc.cmake"
                       DEPENDS ${goyacc_YFILE} goyacc
                       WORKING_DIRECTORY "${_ypath}"
                       COMMENT "Build Go yacc target ${goyacc_TARGET} using Go ${_gover}"
                       VERBATIM)

    ADD_CUSTOM_TARGET ("${goyacc_TARGET}"
                       DEPENDS "${goyacc_OUTPUT}")
    MESSAGE (STATUS "Added Go yacc target '${goyacc_TARGET}' using Go ${_gover}")

    IF (Go_DEPENDS)
      ADD_DEPENDENCIES (${goyacc_TARGET} ${goyacc_DEPENDS})
    ENDIF (Go_DEPENDS)

  ENDMACRO (GoYacc)

  SET (FindCouchbaseGo_INCLUDED 1)

ENDIF (NOT FindCouchbaseGo_INCLUDED)
