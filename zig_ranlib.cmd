@echo off
if defined UWEBZOCKETS_ZIG (
    "%UWEBZOCKETS_ZIG%" ranlib %*
) else (
    zig ranlib %*
)
