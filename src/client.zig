const std = @import("std");
const os = std.os;
const net = std.net;
fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    var line = (try reader.readUntilDelimiterOrEof(
        buffer,
        '\n',
    )) orelse return null;
    // trim annoying windows-only carriage return character
    if (@import("builtin").os.tag == .windows) {
        return std.mem.trimRight(u8, line, "\r");
    } else {
        return line;
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

            const filename = "output.txt";

            // Open or create the file for writing
            const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_write });
            defer file.close();
            var stat = try file.stat();
            try file.seekTo(stat.size);

            // Write data to the file
            try file.writeAll(message);
            // try sendFile(self.socket, &self.address);
        }
    }
};

pub fn sendMessage() !void {
    const ip = "127.0.0.1";
    const port: u16 = 3000;

    const stdout = std.io.getStdOut();
    const stdin = std.io.getStdIn();

    try stdout.writeAll(
        \\ Enter your name:
    );

    var input_buffer: [100]u8 = undefined;
    const input = (try nextLine(stdin.reader(), &input_buffer)).?;
    try stdout.writer().print(
        "Your name is: \"{s}\"\n",
        .{input},
    );

    const sock = try os.socket(os.AF.INET, os.SOCK.DGRAM, 0);
    defer os.closeSocket(sock);

    const address = try std.net.Address.parseIp4(ip, port);
    const message = "russsskiiii mi amigo";
    _ = try os.sendto(sock, message, 0, &address.any, address.getOsSockLen());
}

pub fn main() !void {
    var socket = try Socket.init("127.0.0.1", 3001);
    try socket.bind();
    _ = try sendMessage();
    try socket.listen();

    // var buffer: [1024]u8 = undefined;

    // if (result != input_buffer.len) {}

    // const bytesRead = try std.os.recvfrom(sock, buffer[0..], 0, null, null);

    // if (bytesRead == 0) {}
    // std.debug.print("Received {d} bytes: \n", .{bytesRead});

    // std.debug.print("Message sent successfully! {}\n", .{result});
}
