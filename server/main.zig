const std = @import("std");
const net = std.net;
const os = std.os;

const GetFileRequest = struct { filename: []const u8, part: i32, corrupt: bool };

const BUFFER_SIZE = 1024 * 4;

pub fn handleRequest(socket: os.socket_t, message: []const u8, client_address: net.Address) !void {
    var it = std.mem.split(u8, message, "\n");
    const endpoint = it.next().?;

    // std.debug.print("Received Message={s}\n\n", .{message});

    if (std.mem.eql(u8, endpoint, "GET /file")) {
        // std.debug.print("{s}\n", .{endpoint});
        var fileRequest = GetFileRequest{ .filename = "", .part = -1, .corrupt = false };
        while (it.next()) |x| {
            var index = std.mem.indexOf(u8, x, "=").?;
            if (std.mem.eql(u8, x[0..index], "--file-name")) {
                fileRequest.filename = x[index + 1 ..];
            } else if (std.mem.eql(u8, x[0..index], "--part")) {
                fileRequest.part = try std.fmt.parseInt(i32, x[index + 1 ..], 10);
            } else if (std.mem.eql(u8, x[0..index], "--corrupt")) {
                const shouldCorrupt = x[index + 1 ..];
                if (std.mem.eql(u8, shouldCorrupt, "true")) fileRequest.corrupt = true;
            }
        }
        var hasFile = true;
        std.fs.cwd().access(fileRequest.filename, .{}) catch |e|
            switch (e) {
            error.FileNotFound => {
                std.debug.print("File {s} doesn't exists", .{fileRequest.filename});
                hasFile = false;
            },
            else => return e,
        };

        if (!hasFile) {
            _ = try os.sendto(socket, "File Not Found", 0, &client_address.any, client_address.getOsSockLen());

            return;
        }
        try sendFile(socket, fileRequest.filename, fileRequest.part, fileRequest.corrupt, client_address);
    }
}

pub fn generateCheckSumForFile(filename: []const u8) !u32 {

    // Open the file
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    // Create a CRC32 hasher
    var crc32 = std.hash.Crc32.init();

    // Read the file in chunks and update the CRC32 hash
    var buffer: [BUFFER_SIZE]u8 = undefined;
    while (true) {
        const bytesRead = try file.read(buffer[0..]);
        if (bytesRead == 0) break;
        crc32.update(buffer[0..bytesRead]);
    }

    const checksum = crc32.final();

    // std.debug.print("CRC32 checksum for file '{s}' is: {x}\n", .{ filename, checksum });

    return checksum;
}

pub fn generateCheckSumForPart(part: []const u8) !u32 {
    var crc32 = std.hash.Crc32.init();

    crc32.update(part);

    const checksum = crc32.final();

    return checksum;
}

pub fn sendFile(socket: os.socket_t, filename: []const u8, part: i32, corrupt: bool, address: net.Address) !void {
    var buffer: [BUFFER_SIZE]u8 = undefined;
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const fileStat = try file.stat();

    const fileSizeFloat: f64 = @as(f64, @floatFromInt(fileStat.size));

    const allocator = std.heap.page_allocator;
    var count: u8 = 0;
    const checksum = try generateCheckSumForFile(filename);
    var headers = try std.fmt.allocPrint(allocator, "--output-file={s}\n--parts={:0>5}/{:0>5}\n--checksum={:0>16}/{:0>16}\n--data=", .{ filename, count, 0, checksum, checksum });
    const dataSize: f64 = @as(f64, @floatFromInt(BUFFER_SIZE - headers.len));
    const totalParts = @as(u32, @intFromFloat(@ceil(fileSizeFloat / dataSize))) - 1;
    const headerSize = headers.len;
    while (true) {
        const bytesRead = try file.read(buffer[headerSize..]);
        const partChecksum = try generateCheckSumForPart(buffer[headerSize..]);
        headers = try std.fmt.allocPrint(allocator, "--output-file={s}\n--parts={:0>5}/{:0>5}\n--checksum={:0>16}/{:0>16}\n--data=", .{ filename, count, totalParts, partChecksum, checksum });
        _ = @memcpy(buffer[0..headers.len], headers);
        if (bytesRead == 0) {
            break;
        }

        if (part == -1 or part == count) {
            std.debug.print("\n\nsending part: {}\n\n", .{count});
            var size = bytesRead + headers.len;
            if (corrupt) size = size / 2;
            const data = buffer[0..size];
            const result = try os.sendto(socket, data, 0, &address.any, address.getOsSockLen());
            if (result != bytesRead + headers.len) {
                return std.debug.print("Failed to send complete data: {}\n", .{result});
            }
        }
        count += 1;
    }
}

const Socket = struct {
    address: net.Address,
    socket: os.socket_t,

    pub fn init(ip: []const u8, port: u16) !Socket {
        const parsed_address = try net.Address.parseIp4(ip, port);
        const sock = try os.socket(os.AF.INET, os.SOCK.DGRAM, 0);
        errdefer os.closeSocket(sock);
        return Socket{ .address = parsed_address, .socket = sock };
    }

    pub fn bind(self: *Socket) !void {
        try os.bind(self.socket, &self.address.any, self.address.getOsSockLen());
    }

    pub fn listen(self: *Socket) !void {
        var buffer: [BUFFER_SIZE]u8 = undefined;

        var sa: net.Address = undefined;
        var sl: os.socklen_t = @sizeOf(os.sockaddr.in);

        while (true) {
            var sl_copy = sl;
            const bytesRead = try os.recvfrom(self.socket, buffer[0..], 0, &sa.any, &sl_copy);

            if (bytesRead == 0) break;

            const message = buffer[0..bytesRead];
            std.debug.print("Received {d} bytes: {s}\n", .{ bytesRead, message });
            // _ = try os.sendto(self.socket, buffer[0..bytesRead], 0, &address.any, address.getOsSockLen());
            try handleRequest(self.socket, message, sa);
        }
    }
};

pub fn main() !void {
    var socket = try Socket.init("172.23.110.147", 3000);
    try socket.bind();
    try socket.listen();
}
