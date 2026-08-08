function(resolve_rustdesk_cargo output_variable)
    # Respect an explicit absolute override first. This is useful for CI and
    # non-standard Rust installations, but do not retain a stale CMake cache
    # path after a checkout or toolchain moves to another machine.
    if(DEFINED ${output_variable} AND
       NOT "${${output_variable}}" STREQUAL "" AND
       EXISTS "${${output_variable}}")
        set(${output_variable} "${${output_variable}}" PARENT_SCOPE)
        message(STATUS "RustDesk: cargo=${${output_variable}} (explicit)")
        return()
    endif()

    set(_rustdesk_rust_tool_hints)
    if(DEFINED ENV{CARGO_HOME} AND NOT "$ENV{CARGO_HOME}" STREQUAL "")
        list(APPEND _rustdesk_rust_tool_hints "$ENV{CARGO_HOME}/bin")
    endif()
    if(DEFINED ENV{HOME} AND NOT "$ENV{HOME}" STREQUAL "")
        list(APPEND _rustdesk_rust_tool_hints "$ENV{HOME}/.cargo/bin")
    endif()
    if(DEFINED ENV{USERPROFILE} AND NOT "$ENV{USERPROFILE}" STREQUAL "")
        list(APPEND _rustdesk_rust_tool_hints "$ENV{USERPROFILE}/.cargo/bin")
    endif()
    if(CMAKE_HOST_APPLE)
        # DevEco started from Finder does not inherit a shell's Homebrew PATH.
        list(APPEND _rustdesk_rust_tool_hints /opt/homebrew/bin /usr/local/bin)
    endif()
    list(REMOVE_DUPLICATES _rustdesk_rust_tool_hints)

    find_program(_rustdesk_cargo_program
        NAMES cargo cargo.exe
        HINTS ${_rustdesk_rust_tool_hints}
        NO_CACHE
    )

    # Homebrew's rustup package may expose only `rustup`, while Cargo itself
    # lives under ~/.rustup/toolchains. Ask rustup for the active executable
    # instead of embedding a host-specific toolchain path in the project.
    if(NOT _rustdesk_cargo_program)
        find_program(_rustdesk_rustup_program
            NAMES rustup rustup.exe
            HINTS ${_rustdesk_rust_tool_hints}
            NO_CACHE
        )
        if(_rustdesk_rustup_program)
            execute_process(
                COMMAND "${_rustdesk_rustup_program}" which cargo
                RESULT_VARIABLE _rustdesk_rustup_result
                OUTPUT_VARIABLE _rustdesk_rustup_cargo
                ERROR_VARIABLE _rustdesk_rustup_error
                OUTPUT_STRIP_TRAILING_WHITESPACE
            )
            if(_rustdesk_rustup_result EQUAL 0 AND
               IS_ABSOLUTE "${_rustdesk_rustup_cargo}" AND
               EXISTS "${_rustdesk_rustup_cargo}")
                set(_rustdesk_cargo_program "${_rustdesk_rustup_cargo}")
            endif()
        endif()
    endif()

    if(NOT _rustdesk_cargo_program)
        message(FATAL_ERROR
            "RustDesk: Cargo was not found. Install Rust with rustup, expose "
            "cargo/rustup to the DevEco build environment, or pass "
            "-D${output_variable}=<absolute cargo path>. On macOS CLI builds, "
            "source scripts/macos_env.sh first.")
    endif()

    set(${output_variable} "${_rustdesk_cargo_program}" PARENT_SCOPE)
    message(STATUS "RustDesk: cargo=${_rustdesk_cargo_program}")
endfunction()
