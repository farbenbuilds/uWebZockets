const std = @import("std");
const sanitizers = @import("sanitizers.zig");

/// Optional SQL code and native SQLite artifacts for one target.
pub const Config = struct {
    options_module: *std.Build.Module,
    enabled: bool,
    sqlite_enabled: bool,
    sqlite_library: ?*std.Build.Step.Compile = null,
    sqlite_c: ?*std.Build.Module = null,

    pub fn attach(self: Config, module: *std.Build.Module) void {
        module.addImport("module_options", self.options_module);
        if (self.sqlite_c) |c_module| module.addImport("sqlite_c", c_module);
        if (self.sqlite_library) |library| module.linkLibrary(library);
    }
};

/// SQL remains opt-in; SQLite adds no system-library dependency.
pub fn configure(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitizer: sanitizers.Config,
) Config {
    const sql_enabled = b.option(bool, "sql", "Enable the optional SQL module") orelse false;
    const sqlite_enabled = b.option(bool, "sqlite", "Enable the optional SQLite SQL backend") orelse false;
    if (sqlite_enabled and !sql_enabled) @panic("-Dsqlite=true requires -Dsql=true");

    const options = b.addOptions();
    options.addOption(bool, "sql", sql_enabled);
    options.addOption(bool, "sqlite", sqlite_enabled);
    var config = Config{ .options_module = options.createModule(), .enabled = sql_enabled, .sqlite_enabled = sqlite_enabled };
    if (!sqlite_enabled) return config;

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = if (sanitizer.sanitize) .full else null,
        .omit_frame_pointer = if (sanitizer.instrument_c) false else null,
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = sanitizers.instrumented_flags(b, &.{
            "-std=gnu11",                    "-ffunction-sections",             "-fdata-sections",
            "-DSQLITE_THREADSAFE=2",         "-DSQLITE_OMIT_LOAD_EXTENSION",    "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=1",  "-DSQLITE_MAX_VARIABLE_NUMBER=64", "-DSQLITE_MAX_COLUMN=64",
            "-DSQLITE_MAX_SQL_LENGTH=65536", "-DSQLITE_MAX_LENGTH=1048576",
        }, sanitizer),
    });
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite/sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    config.sqlite_c = translate.createModule();
    config.sqlite_library = b.addLibrary(.{
        .name = "uwz_sqlite",
        .linkage = .static,
        .root_module = module,
    });
    return config;
}
