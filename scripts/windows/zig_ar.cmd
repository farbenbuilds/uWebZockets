@echo off
if defined UWEBZOCKETS_ZIG (
    "%UWEBZOCKETS_ZIG%" ar %*
) else (
    zig ar %*
)
