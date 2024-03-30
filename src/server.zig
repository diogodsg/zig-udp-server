const std = @import("std");
const net = std.net;
const os = std.os;

pub fn sendFile(socket: os.socket_t) !void {
    const bufferSize: usize = 1024;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3001);

    var buffer: [bufferSize]u8 = undefined;
    const file = try std.fs.cwd().openFile("file.txt", .{});
    defer file.close();
    while (true) {
        const bytesRead = try file.read(buffer[0..]);
        if (bytesRead == 0) break;

        const result = try os.sendto(socket, buffer[0..bytesRead], 0, &address.any, address.getOsSockLen());
        if (result != bytesRead) {
            return std.debug.print("Failed to send complete data: {}\n", .{result});
        }
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
        var buffer: [1024]u8 = undefined;

        while (true) {
            const bytesRead = try os.recvfrom(self.socket, buffer[0..], 0, null, null);

            if (bytesRead == 0) break;

            const message = buffer[0..bytesRead];
            std.debug.print("Received {d} bytes: {s}\n", .{ bytesRead, message });
            // _ = try os.sendto(self.socket, buffer[0..bytesRead], 0, &address.any, address.getOsSockLen());
            try sendFile(self.socket);
        }
    }
};

pub fn main() !void {
    var socket = try Socket.init("127.0.0.1", 3000);
    try socket.bind();
    try socket.listen();
}
