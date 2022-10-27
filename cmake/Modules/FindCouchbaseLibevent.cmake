#
#     Copyright 2018 Couchbase, Inc.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Locate libevent include files and library files. On supported platforms
# all of the files is expected to be found in cbdeps. For non-supported
# platforms it should be possible to use a globally installed version
# of libevent (and we'll warn you about that).
#
# This module defines the following variables
#  LIBEVENT_FOUND - If libevent was found or not
#  LIBEVENT_LIBRARIES - The path and name of the libraries to link with
#  LIBEVENT_INCLUDE_DIR - The directory where event/event2.h is located
#

if (NOT DEFINED LIBEVENT_FOUND)
    include(PlatformIntrospection)

    cb_get_supported_platform(_is_supported_platform)
    if (_is_supported_platform)
        # Supported platforms should only use the provided hints and pick up
        # libevent from cbdeps
        set(NO_DEFAULT_PATH NO_DEFAULT_PATH)
    endif ()

    # Try to locate the directory of the file
    # If using cmake >= 3.0.0 we can try to use the REALPATH variable
    # (unfortunately I don't know when that was added)
    macro(get_directory _dirname filename)
        if (${CMAKE_VERSION} VERSION_LESS 3.0.0)
            get_filename_component(${_dirname} ${filename} DIRECTORY)
        else ()
            get_filename_component(resolved ${filename} REALPATH)
            get_filename_component(${_dirname} ${resolved} DIRECTORY)
        endif ()
    endmacro(get_directory _dirname filename)

    set(_libevent_exploded ${CMAKE_BINARY_DIR}/tlm/deps/libevent.exploded)
    set(_libevent_library_dir ${CMAKE_INSTALL_PREFIX})

    find_path(LIBEVENT_INCLUDE_DIR event2/event.h
              HINTS ${_libevent_exploded}/include
              ${NO_DEFAULT_PATH})

    if (NOT LIBEVENT_INCLUDE_DIR)
        message(FATAL_ERROR "Failed to locate event2/event.h")
    endif ()

    find_library(LIBEVENT_CORE_LIB
                 NAMES event_core
                 HINTS ${_libevent_library_dir}/lib
                 ${NO_DEFAULT_PATH})

    if (NOT LIBEVENT_CORE_LIB)
        message(FATAL_ERROR "Failed to locate event_core")
    endif ()

    find_library(LIBEVENT_EXTRA_LIB
                 NAMES event_extra
                 HINTS ${_libevent_library_dir}/lib
                 ${NO_DEFAULT_PATH})

    if (NOT LIBEVENT_EXTRA_LIB)
        message(FATAL_ERROR "Failed to locate event_extra")
    endif ()

    # The libevent built by cbdeps don't need this library, but in case
    # the user tries to use a global one we need to link with the pthreads
    # one for those platforms
    if (NOT _supported_platform)
        find_library(LIBEVENT_THREAD_LIB
                     NAMES event_pthreads
                     HINTS ${_libevent_library_dir}/lib
                     ${NO_DEFAULT_PATH})
        find_library(LIBEVENT_OPENSSL_LIB
                     NAMES event_openssl
                     HINTS ${_libevent_library_dir}/lib
                     ${NO_DEFAULT_PATH})
    endif ()

    get_directory(_libevent_core_dir ${LIBEVENT_CORE_LIB})
    get_directory(_libevent_extra_dir ${LIBEVENT_EXTRA_LIB})
    if (LIBEVENT_THREAD_LIB)
        get_directory(_libevent_pthreads_dir ${LIBEVENT_THREAD_LIB})
    endif ()
    if (LIBEVENT_OPENSSL_LIB)
        get_directory(_libevent_openssl_dir ${LIBEVENT_OPENSSL_LIB})
    endif ()

    message(STATUS "Found libevent headers in: ${LIBEVENT_INCLUDE_DIR}")
    message(STATUS "                     core: ${LIBEVENT_CORE_LIB}")
    message(STATUS "                    extra: ${LIBEVENT_EXTRA_LIB}")
    if (LIBEVENT_THREAD_LIB)
        message(STATUS "                 pthreads: ${LIBEVENT_THREAD_LIB}")
    endif ()
    if (LIBEVENT_OPENSSL_LIB)
        message(STATUS "                  openssl: ${LIBEVENT_OPENSSL_LIB}")
    endif ()

    # Set LIBEVENT_LIBRARIES to list all of the libevent libraries.
    # Yes, we could have had our targets only link with the ones
    # we absolutely need, but it's not worth the extra effort
    # trying to deal with when to link with the thread lib etc (for
    # installations using a non-cbdeps version of libevent
    set(_libevent_libraries "${LIBEVENT_CORE_LIB}")
    list(APPEND _libevent_libraries ${LIBEVENT_EXTRA_LIB})

    # Time to sanity-check our installation. All of the libraries should be
    # located in the same directory
    if (NOT "${_libevent_core_dir}" STREQUAL "${_libevent_extra_dir}")
        message(STATUS "WARNING: libevent_core and libevent_extra is not located")
        message(STATUS "         in the same directory. This could be the result of")
        message(STATUS "         two different versions of libevent being installed.")
        message(STATUS "         Resolve this and try again.")
        message(FATAL_ERROR "libevent_core and libevent_extra inconsistency (not located in the same directory)")
    endif ()

    # We should only use libevent_pthread and libevent_openssl if they exists
    # in the same directory as libevent_core and libevent_extras
    if (LIBEVENT_THREAD_LIB)
        if (${_libevent_core_dir} STREQUAL ${_libevent_pthreads_dir})
            list(APPEND _libevent_libraries ${LIBEVENT_THREAD_LIB})
        else ()
            message(STATUS "NOTE: Ignoring libevent_pthreads as it is located in another directory than libevent_core")
        endif ()
    endif ()

    if (LIBEVENT_OPENSSL_LIB)
        if (${_libevent_core_dir} STREQUAL ${_libevent_openssl_dir})
            list(APPEND _libevent_libraries ${LIBEVENT_OPENSSL_LIB})
        else ()
            message(STATUS "NOTE: Ignoring libevent_openssl as it is located in another directory than libevent_core")
        endif ()
    endif ()

    if (NOT ${LIBEVENT_INCLUDE_DIR} STREQUAL ${_libevent_exploded}/include)
        message(WARNING "Non-supported version of libevent headers detected, trying to use it anyway")
    endif ()

    if (NOT ${_libevent_core_dir} STREQUAL ${_libevent_library_dir}/lib)
        message(WARNING "Non-supported version of libevent libraries detected, trying to use anyway")
    endif ()

    set(LIBEVENT_LIBRARIES ${_libevent_libraries} CACHE STRING "libevent libraries" FORCE)
    set(LIBEVENT_FOUND true CACHE BOOL "Found libevent" FORCE)
    mark_as_advanced(LIBEVENT_FOUND LIBEVENT_INCLUDE_DIR LIBEVENT_LIBRARIES)
endif (NOT DEFINED LIBEVENT_FOUND)
