@echo off
if defined UWEBZOCKETS_ZIG (
    if defined UWEBZOCKETS_TARGET (
        "%UWEBZOCKETS_ZIG%" c++ -target "%UWEBZOCKETS_TARGET%" %*
    ) else (
        "%UWEBZOCKETS_ZIG%" c++ %*
    )
) else (
    if defined UWEBZOCKETS_TARGET (
        zig c++ -target "%UWEBZOCKETS_TARGET%" %*
    ) else (
        zig c++ %*
    )
)
