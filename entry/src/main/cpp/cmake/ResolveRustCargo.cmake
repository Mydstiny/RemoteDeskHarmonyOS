function(resolve_rustdesk_rust_toolchain cargo_output_variable rustc_output_variable)
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

    # Respect valid overrides while ignoring stale cache entries left behind
    # when a checkout or Rust toolchain moves to another machine.
    if(DEFINED ${cargo_output_variable} AND
       NOT "${${cargo_output_variable}}" STREQUAL "" AND
       IS_ABSOLUTE "${${cargo_output_variable}}" AND
       EXISTS "${${cargo_output_variable}}" AND
       NOT IS_DIRECTORY "${${cargo_output_variable}}")
        set(_rustdesk_cargo_program "${${cargo_output_variable}}")
        set(_rustdesk_cargo_source "explicit")
    else()
        find_program(_rustdesk_cargo_program
            NAMES cargo cargo.exe
            HINTS ${_rustdesk_rust_tool_hints}
            NO_CACHE
        )
        if(_rustdesk_cargo_program)
            set(_rustdesk_cargo_source "search")
        endif()
    endif()

    set(_rustdesk_rustc_explicit FALSE)
    if(DEFINED ${rustc_output_variable} AND
       NOT "${${rustc_output_variable}}" STREQUAL "" AND
       IS_ABSOLUTE "${${rustc_output_variable}}" AND
       EXISTS "${${rustc_output_variable}}" AND
       NOT IS_DIRECTORY "${${rustc_output_variable}}")
        set(_rustdesk_rustc_program "${${rustc_output_variable}}")
        set(_rustdesk_rustc_source "explicit")
        set(_rustdesk_rustc_explicit TRUE)
    endif()

    # A cargo returned by `rustup which cargo` and its matching rustc normally
    # live in the same toolchain directory. Resolve this before invoking
    # rustup so an explicitly selected Cargo cannot accidentally pair with a
    # different compiler channel.
    if(_rustdesk_cargo_program AND NOT _rustdesk_rustc_explicit)
        get_filename_component(_rustdesk_cargo_directory
            "${_rustdesk_cargo_program}" DIRECTORY)
        if(WIN32)
            set(_rustdesk_sibling_rustc
                "${_rustdesk_cargo_directory}/rustc.exe")
        else()
            set(_rustdesk_sibling_rustc
                "${_rustdesk_cargo_directory}/rustc")
        endif()
        if(EXISTS "${_rustdesk_sibling_rustc}")
            set(_rustdesk_rustc_program "${_rustdesk_sibling_rustc}")
            set(_rustdesk_rustc_source "cargo sibling")
        endif()
    endif()

    if(NOT _rustdesk_rustc_program)
        find_program(_rustdesk_rustc_program
            NAMES rustc rustc.exe
            HINTS ${_rustdesk_rust_tool_hints}
            NO_CACHE
        )
        if(_rustdesk_rustc_program)
            set(_rustdesk_rustc_source "search")
        endif()
    endif()

    # Homebrew's rustup package may expose only `rustup`, while Cargo itself
    # lives under ~/.rustup/toolchains. Ask rustup for the active executables
    # instead of embedding host-specific toolchain paths in the project.
    if(NOT _rustdesk_cargo_program OR NOT _rustdesk_rustc_program)
        find_program(_rustdesk_rustup_program
            NAMES rustup rustup.exe
            HINTS ${_rustdesk_rust_tool_hints}
            NO_CACHE
        )
        if(_rustdesk_rustup_program AND NOT _rustdesk_cargo_program)
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
                set(_rustdesk_cargo_source "rustup")
            endif()
        endif()
        if(_rustdesk_rustup_program AND NOT _rustdesk_rustc_program)
            execute_process(
                COMMAND "${_rustdesk_rustup_program}" which rustc
                RESULT_VARIABLE _rustdesk_rustup_rustc_result
                OUTPUT_VARIABLE _rustdesk_rustup_rustc
                ERROR_VARIABLE _rustdesk_rustup_rustc_error
                OUTPUT_STRIP_TRAILING_WHITESPACE
            )
            if(_rustdesk_rustup_rustc_result EQUAL 0 AND
               IS_ABSOLUTE "${_rustdesk_rustup_rustc}" AND
               EXISTS "${_rustdesk_rustup_rustc}")
                set(_rustdesk_rustc_program "${_rustdesk_rustup_rustc}")
                set(_rustdesk_rustc_source "rustup")
            endif()
        endif()
    endif()

    if(NOT _rustdesk_cargo_program)
        message(FATAL_ERROR
            "RustDesk: Cargo was not found. Install Rust with rustup, expose "
            "cargo/rustup to the DevEco build environment, or pass "
            "-D${cargo_output_variable}=<absolute cargo path>. On macOS CLI builds, "
            "source scripts/macos_env.sh first.")
    endif()

    if(NOT _rustdesk_rustc_program)
        message(FATAL_ERROR
            "RustDesk: rustc was not found. Install the active Rust toolchain "
            "with rustup, expose rustc/rustup to the DevEco build environment, "
            "or pass -D${rustc_output_variable}=<absolute rustc path>. On "
            "macOS CLI builds, source scripts/macos_env.sh first.")
    endif()

    set(${cargo_output_variable} "${_rustdesk_cargo_program}" PARENT_SCOPE)
    set(${rustc_output_variable} "${_rustdesk_rustc_program}" PARENT_SCOPE)
    message(STATUS
        "RustDesk: cargo=${_rustdesk_cargo_program} (${_rustdesk_cargo_source})")
    message(STATUS
        "RustDesk: rustc=${_rustdesk_rustc_program} (${_rustdesk_rustc_source})")
endfunction()
