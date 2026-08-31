const std = @import("std");

/// Represents image dimensions in pixels.
const ImageSize = struct {
    width: u32,
    height: u32,
};

/// Command-line arguments parsed from user input.
const CliArgs = struct {
    image_path: []const u8,
    max_width: u32,
};

/// Entry point for the bimg ASCII image renderer.
/// Parses command-line arguments, queries image dimensions,
/// converts and resizes the image, then renders it as colored ASCII art.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try parseCliArgs(allocator);
    const orig_size = try queryImageDimensions(allocator, args.image_path);
    const render_size = calculateTerminalSize(orig_size, args.max_width);

    try processImage(allocator, args.image_path, render_size);
}

/// Parses command-line arguments and returns structured CLI options.
///
/// Expected usage: `bimg <image-path> [max-width]`
/// - image_path: Path to the input image file
/// - max_width: Maximum terminal columns for output (default: 120)
fn parseCliArgs(allocator: std.mem.Allocator) !CliArgs {
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

    return .{
        .image_path = image_path,
        .max_width = max_width,
    };
}

/// Queries ImageMagick for the source image's real dimensions in pixels.
///
/// Runs `magick identify -format "%w %h"` and parses the output.
/// Returns an error if ImageMagick fails or output format is unexpected.
fn queryImageDimensions(allocator: std.mem.Allocator, path: []const u8) !ImageSize {
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

/// Calculates render dimensions that fit within the terminal width.
///
/// Each pixel prints as 2 characters wide x 1 line tall. Since terminal
/// characters are roughly twice as tall as wide, that doubling already
/// cancels out the aspect correction, so a straight proportional scale works.
fn calculateTerminalSize(orig: ImageSize, max_width: u32) ImageSize {
    const width = @min(orig.width, max_width);
    const height_f: f64 = @as(f64, @floatFromInt(width)) *
        (@as(f64, @floatFromInt(orig.height)) / @as(f64, @floatFromInt(orig.width)));

    return .{
        .width = width,
        .height = @max(1, @as(u32, @intFromFloat(@round(height_f)))),
    };
}

/// Converts and resizes an image to BMP format using ImageMagick.
///
/// Creates a temporary BMP file at `/tmp/bimg-render.bmp` with exact
/// dimensions specified by `size`. The BMP format allows easy pixel access.
fn processImage(allocator: std.mem.Allocator, input_path: []const u8, size: ImageSize) !void {
    const bmp_path = "/tmp/bimg-render.bmp";
    try convertImageToBmp(allocator, input_path, bmp_path, size);

    const pixels = try allocator.alloc([3]u8, size.width * size.height);
    try loadBmpPixels(allocator, bmp_path, pixels, size);

    renderToTerminal(pixels, size);
}

/// Converts an image to BMP format with exact target dimensions using ImageMagick.
///
/// Uses `magick input -resize WxH! output` to force exact dimensions
/// (the `!` flag ignores aspect ratio to match requested size exactly).
fn convertImageToBmp(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, size: ImageSize) !void {
    const resize_arg = try std.fmt.allocPrint(allocator, "{d}x{d}!", .{ size.width, size.height });

    var magick = std.process.Child.init(
        &[_][]const u8{ "magick", input_path, "-resize", resize_arg, output_path },
        allocator,
    );
    magick.stdout_behavior = .Inherit;
    magick.stderr_behavior = .Inherit;

    try magick.spawn();
    const result = try magick.wait();
    if (result.Exited != 0) return error.ConvertFailed;
}

/// Reads BMP file and extracts pixel data into the provided buffer.
///
/// Handles BMP's bottom-up row order and row padding (rows are padded
/// to 4-byte boundaries). Each pixel is stored as [B, G, R] (BMP order).
fn loadBmpPixels(allocator: std.mem.Allocator, path: []const u8, pixels: []([3]u8), size: ImageSize) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [54]u8 = undefined;
    _ = try file.readAll(&header);

    const pixel_offset = std.mem.readInt(u32, header[10..14], .little);

    const row_stride = (size.width * 3 + 3) / 4 * 4;
    const row_buf = try allocator.alloc(u8, row_stride);

    for (0..size.height) |y| {
        const src_row = size.height - 1 - y; // BMP rows are stored bottom-up
        try file.seekTo(pixel_offset + src_row * row_stride);
        _ = try file.readAll(row_buf);

        for (0..size.width) |x| {
            const px = x * 3;
            pixels[y * size.width + x] = .{ row_buf[px], row_buf[px + 1], row_buf[px + 2] };
        }
    }
}

/// Renders pixel data as colored ASCII art in the terminal.
///
/// Each pixel is converted to an ASCII character based on luminance,
/// then printed with 24-bit ANSI color escape codes matching the
/// original RGB values. Each pixel is printed twice horizontally
/// to approximate square aspect ratio in terminal fonts.
fn renderToTerminal(pixels: []const [3]u8, size: ImageSize) void {
    for (0..size.height) |y| {
        for (0..size.width) |x| {
            const b = pixels[y * size.width + x][0];
            const g = pixels[y * size.width + x][1];
            const r = pixels[y * size.width + x][2];

            const luminance = @as(f16, @floatFromInt(r)) * 0.299 +
                @as(f16, @floatFromInt(g)) * 0.587 +
                @as(f16, @floatFromInt(b)) * 0.114;

            const char = luminanceToAsciiChar(luminance);
            std.debug.print("\x1b[38;2;{};{};{}m{c}{c}\x1b[0m", .{ r, g, b, char, char });
        }
        std.debug.print("\n", .{});
    }
}

/// Maps a luminance value (0-255) to an ASCII character for display.
///
/// Uses the standard ramp " .:-=+*#%@" where darker values map to
/// spaces and brighter values map to denser characters. This creates
/// a visual representation of brightness levels.
fn luminanceToAsciiChar(val: f16) u8 {
    const chars = " .:-=+*#%@";
    const index: usize = @intFromFloat(val / 255.0 * (chars.len - 1));
    return chars[index];
}
