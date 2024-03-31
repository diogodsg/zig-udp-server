const std = @import("std");

const GetFileRequest = struct { filename: []const u8 };

pub fn parseRequest() void {
    var it = std.mem.split(u8, "GET /file\n--file-name=file.txt", "\n");
    const endpoint = it.next().?;

    std.debug.print("Method={s}\n", .{endpoint});

    if (std.mem.eql(u8, endpoint, "GET /file")) {
        std.debug.print("{s}\n", .{endpoint});
        var fileRequest = GetFileRequest{ .filename = "" };
        while (it.next()) |x| {
            var index = std.mem.indexOf(u8, x, "=").?;
            fileRequest.filename = x[index + 1 ..];
        }

        std.debug.print("FileName={s}\n", .{fileRequest.filename});
    }
}

pub fn makeResponse() void {
    var buffer: [1024]u8 = undefined;
    const name = "--output-file=";
    // const part = "";
    // const age = 30;
    var sourceString = "--name=" ++ name ++ "\n";
    // const sourceString = std.fmt.format(&stringBuffer, "Name: {}, Age: {}", .{ name, age });
    std.debug.print("sourceString: {s}\n", .{sourceString});

    // Copy bytes from sourceString to buffer
    _ = @memcpy(buffer[0..sourceString.len], sourceString);
}

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    // const name = 6;
    const allocator = std.heap.page_allocator;

    const sourceString = try std.fmt.allocPrint(allocator, "--name={:0>6}", .{100});

    // const age = 30;
    // var sourceString = "--name=" ++ x ++ "\n";
    // const sourceString = std.fmt.format(&stringBuffer, "Name: {}, Age: {}", .{ name, age });
    std.debug.print("sourceString: {s}\n", .{sourceString});

    // Copy bytes from sourceString to buffer
    _ = @memcpy(buffer[0..sourceString.len], sourceString);
    std.log.info("'{:0>2}'", .{1});
    const a = try std.fmt.parseInt(u32, "00009", 10);
    // // Print buffer content
    std.debug.print("Buffer: {}\n", .{a});
}
