# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file Copyright.txt or https://cmake.org/licensing for details.

set(prefix "${TEST_PREFIX}")
set(suffix "${TEST_SUFFIX}")
set(extra_args ${TEST_EXTRA_ARGS})
set(properties ${TEST_PROPERTIES})
set(post_suite_filter ${TEST_POST_SUITE_FILTER})
set(script)
set(suite)
set(tests)

if(TEST_FILTER)
    set(filter "--gtest_filter=${TEST_FILTER}")
else()
    set(filter)
endif()

function(add_command NAME)
  set(_args "")
  foreach(_arg ${ARGN})
    # Couchbase mod : allow us to pass a bracket arguments as-is.
    # This allows passing of lists (semicolon separated) as arguments for
    # the command without them being split. Example use-case:
    # set_tests_properties(ENVIRONMENT...) where we want to specify multiple
    # environment variable properties.
    if (_arg MATCHES "^\\[==\\[.*\\]==\\]$")
      set(_args "${_args} ${_arg}")
    elseif(_arg MATCHES "[^-./:a-zA-Z0-9_]")
      set(_args "${_args} [==[${_arg}]==]")
    else()
      set(_args "${_args} ${_arg}")
    endif()
  endforeach()
  set(script "${script}${NAME}(${_args})\n" PARENT_SCOPE)
endfunction()

# Run test executable to get list of available tests
if(NOT EXISTS "${TEST_EXECUTABLE}")
  message(FATAL_ERROR
    "Specified test executable does not exist.\n"
    "  Path: '${TEST_EXECUTABLE}'"
  )
endif()
execute_process(
  COMMAND ${TEST_EXECUTOR} "${TEST_EXECUTABLE}" --gtest_list_tests ${filter}
  TIMEOUT ${TEST_DISCOVERY_TIMEOUT}
  WORKING_DIRECTORY ${TEST_WORKING_DIR}
  OUTPUT_VARIABLE output
  RESULT_VARIABLE result
)
if(NOT ${result} EQUAL 0)
  string(REPLACE "\n" "\n    " output "${output}")
  message(FATAL_ERROR
    "Error running test executable.\n"
    "  Path: '${TEST_EXECUTABLE}'\n"
    "  Result: ${result}\n"
    "  Output:\n"
    "    ${output}\n"
  )
endif()

string(REPLACE "\n" ";" output "${output}")

# Parse output
foreach(line ${output})
  # Skip header
  if(NOT line MATCHES "gtest_main\\.cc")
    # Do we have a module name or a test name?
    if(NOT line MATCHES "^  ")
      # Module; remove trailing '.' to get just the name...
      string(REGEX REPLACE "\\.( *#.*)?" "" suite "${line}")
      if(line MATCHES "#" AND NOT NO_PRETTY_TYPES)
        string(REGEX REPLACE "/[0-9]\\.+ +#.*= +" "/" pretty_suite "${line}")
      else()
        set(pretty_suite "${suite}")
      endif()
      string(REGEX REPLACE "^DISABLED_" "" pretty_suite "${pretty_suite}")
      # If defining one test per GoogleTest suite; then add a wildcard
      # for the current suite.
      if (ONE_CTEST_PER_SUITE)
        add_command(add_test
          "${prefix}${pretty_suite}"
          ${TEST_EXECUTOR}
          "${TEST_EXECUTABLE}"
          "--gtest_filter=${suite}.${post_suite_filter}*"
          ${extra_args}
        )
        add_command(set_tests_properties
          "${prefix}${pretty_suite}"
          PROPERTIES
          WORKING_DIRECTORY "${TEST_WORKING_DIR}"
          ${properties}
        )
      endif()
    # Only add a CTest test if we are not grouping by GoogleTest suite.
    elseif(NOT ONE_CTEST_PER_SUITE)
      # Test name; strip spaces and comments to get just the name...
      string(REGEX REPLACE " +" "" test "${line}")
      if(test MATCHES "#" AND NOT NO_PRETTY_VALUES)
        string(REGEX REPLACE "/[0-9]+#GetParam..=" "/" pretty_test "${test}")
      else()
        string(REGEX REPLACE "#.*" "" pretty_test "${test}")
      endif()
      string(REGEX REPLACE "^DISABLED_" "" pretty_test "${pretty_test}")
      string(REGEX REPLACE "#.*" "" test "${test}")
      # ...and add to script
      add_command(add_test
        "${prefix}${pretty_suite}.${pretty_test}${suffix}"
        ${TEST_EXECUTOR}
        "${TEST_EXECUTABLE}"
        "--gtest_filter=${suite}.${test}"
        "--gtest_also_run_disabled_tests"
        ${extra_args}
      )
      if(suite MATCHES "^DISABLED" OR test MATCHES "^DISABLED")
        add_command(set_tests_properties
          "${prefix}${pretty_suite}.${pretty_test}${suffix}"
          PROPERTIES DISABLED TRUE
        )
      endif()
      add_command(set_tests_properties
        "${prefix}${pretty_suite}.${pretty_test}${suffix}"
        PROPERTIES
        WORKING_DIRECTORY "${TEST_WORKING_DIR}"
        ${properties}
      )
     list(APPEND tests "${prefix}${pretty_suite}.${pretty_test}${suffix}")
    endif()
  endif()
endforeach()

# Create a list of all discovered tests, which users may use to e.g. set
# properties on the tests
add_command(set ${TEST_LIST} ${tests})

# Write CTest script
file(WRITE "${CTEST_FILE}" "${script}")
