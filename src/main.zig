const std = @import("std");

const Size = struct { width: u32, height: u32 };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip program name
    const image_path = args.next() orelse {
        std.debug.print("usage: bimg <image-path> [max-width]\n", .{});
        return error.MissingArgument;
    };

    const max_width: u32 = if (args.next()) |w|
        try std.fmt.parseInt(u32, w, 10)
    else
        120;

    const orig_size = try getImageSize(allocator, image_path);
    const render_size = computeRenderSize(orig_size, max_width);

    const bmp_path = "/tmp/bimg-render.bmp";
    try convertToBmp(allocator, image_path, bmp_path, render_size);

    const pixels = try allocator.alloc([3]u8, render_size.width * render_size.height);
    try loadBmp(allocator, bmp_path, pixels, render_size);

    render(pixels, render_size);
}

/// Ask imagemagick for the source image's real dimensions.
fn getImageSize(allocator: std.mem.Allocator, path: []const u8) !Size {
    var child = std.process.Child.init(
        &[_][]const u8{ "magick", "identify", "-format", "%w %h", path },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const stdout = child.stdout.?;
    const output = try stdout.readToEndAlloc(allocator, 1024);
    const result = try child.wait();
    if (result.Exited != 0) return error.IdentifyFailed;

    var it = std.mem.tokenizeScalar(u8, output, ' ');
    const w_str = it.next() orelse return error.BadDimensions;
    const h_str = it.next() orelse return error.BadDimensions;

    return .{
        .width = try std.fmt.parseInt(u32, std.mem.trim(u8, w_str, " \n\r"), 10),
        .height = try std.fmt.parseInt(u32, std.mem.trim(u8, h_str, " \n\r"), 10),
    };
}

/// Fit the image within max_width columns, preserving aspect ratio.
/// Each pixel prints as 2 characters wide x 1 line tall; since terminal
/// characters are roughly twice as tall as wide, that doubling already
/// cancels out the aspect correction, so a straight proportional scale works.
fn computeRenderSize(orig: Size, max_width: u32) Size {
    const width = @min(orig.width, max_width);
    const height_f: f64 = @as(f64, @floatFromInt(width)) *
        (@as(f64, @floatFromInt(orig.height)) / @as(f64, @floatFromInt(orig.width)));

    return .{
        .width = width,
        .height = @max(1, @as(u32, @intFromFloat(@round(height_f)))),
    };
}

fn convertToBmp(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, size: Size) !void {
    const resize_arg = try std.fmt.allocPrint(allocator, "{d}x{d}!", .{ size.width, size.height });
    const bmp_target = try std.fmt.allocPrint(allocator, "BMP3:{s}", .{output_path});

    var magick = std.process.Child.init(
        &[_][]const u8{
            "magick", input_path,
            "-resize", resize_arg,
            "-background", "black",
            "-alpha", "remove",
            "-alpha", "off",
            "-type", "TrueColor",
            "-depth", "8",
            bmp_target,
        },
        allocator,
    );
    magick.stdout_behavior = .Inherit;
    magick.stderr_behavior = .Inherit;

    try magick.spawn();
    const result = try magick.wait();
    if (result.Exited != 0) return error.ConvertFailed;
}

fn render(pixels: []const [3]u8, size: Size) void {
    for (0..size.height) |y| {
        for (0..size.width) |x| {
            const r = pixels[y * size.width + x][2];
            const g = pixels[y * size.width + x][1];
            const b = pixels[y * size.width + x][0];

            const val = @as(f16, @floatFromInt(r)) * 0.299 +
                @as(f16, @floatFromInt(g)) * 0.587 +
                @as(f16, @floatFromInt(b)) * 0.114;

            const char = valueToAscii(val);
            std.debug.print("\x1b[38;2;{};{};{}m{c}{c}\x1b[0m", .{ r, g, b, char, char });
        }
        std.debug.print("\n", .{});
    }
}

fn loadBmp(allocator: std.mem.Allocator, path: []const u8, pixels: []([3]u8), size: Size) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [54]u8 = undefined;
    _ = try file.readAll(&header);

    const bpp = std.mem.readInt(u16, header[28..30], .little);
    if (bpp != 24) {
        std.debug.print("error: expected 24-bit BMP, got {}-bit\n", .{bpp});
        return error.UnsupportedBitDepth;
    }

    const pixel_offset = std.mem.readInt(u32, header[10..14], .little);

    const row_stride = (size.width * 3 + 3) / 4 * 4;
    const row_buf = try allocator.alloc(u8, row_stride);

    for (0..size.height) |y| {
        const src_row = size.height - 1 - y; // BMP rows are bottom-up
        try file.seekTo(pixel_offset + src_row * row_stride);
        _ = try file.readAll(row_buf);

        for (0..size.width) |x| {
            const px = x * 3;
            pixels[y * size.width + x] = .{ row_buf[px], row_buf[px + 1], row_buf[px + 2] };
        }
    }
}

fn valueToAscii(val: f16) u8 {
    const chars = " .:-=+*#%@";
    const index: usize = @intFromFloat(val / 255.0 * (chars.len - 1));
    return chars[index];
}
