const std = @import("std");
const net = std.net;
const os = std.os;

const GetFileRequest = struct { filename: []const u8 };

const BUFFER_SIZE = 1024 * 4;

pub fn handleRequest(socket: os.socket_t, message: []const u8) !void {
    var it = std.mem.split(u8, message, "\n");
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

        try sendFile(socket, fileRequest.filename);
    }
}

pub fn generateCheckSum(filename: []const u8) !u32 {

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

    std.debug.print("CRC32 checksum for file '{s}' is: {x}\n", .{ filename, checksum });

    return checksum;
}

pub fn sendFile(socket: os.socket_t, filename: []const u8) !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", 3001);

    var buffer: [BUFFER_SIZE]u8 = undefined;
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const fileStat = try file.stat();

    // Ensure both operands are of type f64
    const fileSizeFloat: f64 = @as(f64, @floatFromInt(fileStat.size));
    const bufferSizeFloat: f64 = @as(f64, @floatFromInt(BUFFER_SIZE));

    std.debug.print("Filesize: {}\n", .{fileStat.size});
    std.debug.print("parts: {}\n", .{@ceil(fileSizeFloat / bufferSizeFloat)});
    const allocator = std.heap.page_allocator;
    var count: u8 = 0;
    const checksum = try generateCheckSum(filename);
    var headers = try std.fmt.allocPrint(allocator, "--output-file={s}\n--parts={:0>5}/{:0>5}\n--checksum={d}\n--data=", .{ "output-file.txt", count, 0, checksum });
    const dataSize: f64 = @as(f64, @floatFromInt(BUFFER_SIZE - headers.len));
    const totalParts = @as(u32, @intFromFloat(@ceil(fileSizeFloat / dataSize))) - 1;

    while (true) {
        headers = try std.fmt.allocPrint(allocator, "--output-file={s}\n--parts={:0>5}/{:0>5}\n--checksum={d}\n--data=", .{ "output-file.txt", count, totalParts, checksum });
        _ = @memcpy(buffer[0..headers.len], headers);
        const bytesRead = try file.read(buffer[headers.len..]);
        if (bytesRead == 0) break;
        const data = buffer[0 .. bytesRead + headers.len];
        const result = try os.sendto(socket, data, 0, &address.any, address.getOsSockLen());
        if (result != bytesRead + headers.len) {
            return std.debug.print("Failed to send complete data: {}\n", .{result});
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

        while (true) {
            const bytesRead = try os.recvfrom(self.socket, buffer[0..], 0, null, null);

            if (bytesRead == 0) break;

            const message = buffer[0..bytesRead];
            std.debug.print("Received {d} bytes: {s}\n", .{ bytesRead, message });
            // _ = try os.sendto(self.socket, buffer[0..bytesRead], 0, &address.any, address.getOsSockLen());
            try handleRequest(self.socket, message);
        }
    }
};

pub fn main() !void {
    var socket = try Socket.init("127.0.0.1", 3000);
    try socket.bind();
    try socket.listen();
}
