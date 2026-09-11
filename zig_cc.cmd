@echo off
if defined UWEBZOCKETS_ZIG (
    if defined UWEBZOCKETS_TARGET (
        "%UWEBZOCKETS_ZIG%" cc -target "%UWEBZOCKETS_TARGET%" %*
    ) else (
        "%UWEBZOCKETS_ZIG%" cc %*
    )
) else (
    if defined UWEBZOCKETS_TARGET (
        zig cc -target "%UWEBZOCKETS_TARGET%" %*
    ) else (
        zig cc %*
    )
)
