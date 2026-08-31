const exe = b.addExecutable(.{
    .name = "bimg",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
